# W3-x (2026-11-27): `agentq land` must refuse BEFORE queueing a topic whose TIP is a merge of
# origin/<onto> back into itself whose resolution silently REVERTS origin/<onto>'s content (dropped a
# file, or rolled a file back to an older version) - a clean merge `merge-tree` cannot see as a conflict.
# The naive rule it must NOT be ("the topic contains a merge whose parent is already an ancestor of
# origin/<onto>") is a false-positive generator: merging origin/main into a branch and later letting main
# advance is legitimate. Fixture B is the false-positive control; D a real merge of both sides.
# Isolated in %TEMP%; bare repo = origin. Mutation-checked: disable the guard and A goes red.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqstale-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_SESSION = 'test-SB'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
# A throwaway origin + clone. Each fixture gets its OWN repo (a different repo NAME -> its own land slot),
# so one scenario's push cannot move the ground under the next.
function New-Fx([string]$n) {
  $bare = Join-Path $tmp "$n.git"; $repo = Join-Path $tmp $n
  git init -q --bare -b main $bare
  git init -q -b main $repo
  git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
  git -C $repo remote add origin $bare
  @{ bare = $bare; repo = $repo }
}
function GitAt([string]$r, [string[]]$a) { & git -C $r @a 2>&1 | Out-Null; if ($LASTEXITCODE) { throw "git $($a -join ' ') in $r failed" } }
function Bare-Tip($f) { "$(& git -C $f.bare rev-parse main)".Trim() }

# ---- A: MUST REFUSE. main has X with a MAIN-CHANGE line; the topic is built from an older base, merges
# a commit already in main, and its resolution writes X back to the older content. merge-tree sees a
# clean merge - no conflict - so only the merged-tree comparison can catch it.
$fa = New-Fx 'fa'; $ra = $fa.repo
Set-Content (Join-Path $ra 'X.txt') "line-one`nOLD-VALUE`nline-three"
Set-Content (Join-Path $ra 'keep.txt') 'keep'
GitAt $ra @('add', '-A'); GitAt $ra @('commit', '-qm', 'base (X=old)')
$SA = "$(& git -C $ra rev-parse HEAD)".Trim()
GitAt $ra @('push', '-q', '-u', 'origin', 'main')
Set-Content (Join-Path $ra 'X.txt') "line-one`nMAIN-CHANGE`nline-three"
GitAt $ra @('commit', '-qam', 'main: X has MAIN-CHANGE')
GitAt $ra @('push', '-q', 'origin', 'main')
GitAt $ra @('checkout', '-q', '-b', 'topic', $SA)
Set-Content (Join-Path $ra 'topic.txt') 't'
GitAt $ra @('add', 'topic.txt'); GitAt $ra @('commit', '-qm', 'topic t')
GitAt $ra @('merge', '-q', '--no-ff', 'main', '-m', 'topic merges main')
Set-Content (Join-Path $ra 'X.txt') "line-one`nOLD-VALUE`nline-three"
GitAt $ra @('add', 'X.txt'); GitAt $ra @('commit', '-q', '--amend', '--no-edit')
GitAt $ra @('push', '-q', 'origin', 'topic')
GitAt $ra @('checkout', '-q', 'main')
$t0a = Bare-Tip $fa
Push-Location $ra
try { $o = AQ land -Branch topic -Onto main -Purpose 'stale revert' } finally { Pop-Location }
Check 'A: refused (exit 5)' ($code -eq 5) $o
Check 'A: names the reverted path X.txt' ($o -match 'X\.txt') $o
Check 'A: says nothing queued' ($o -match 'Nothing queued') $o
Check 'A: names the escape hatch' ($o -match 'AGENTQ_LAND_NO_STALEBASE') $o
Check 'A: nothing pushed' ((Bare-Tip $fa) -eq $t0a)
$ja = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json })
Check 'A: journaled land-stale-base' (@($ja | Where-Object event -eq 'land-stale-base').Count -ge 1)
Check 'A: never queued a land' (-not @($ja | Where-Object { $_.event -eq 'queued' -and "$($_.resource)" -eq 'land:fa' }).Count)

# ---- B: MUST NOT be refused - the false-positive control. The topic merges origin/main into itself and
# KEEPS all of main's content (its own change is a brand-new file, never in main).
$fb = New-Fx 'fb'; $rb = $fb.repo
Set-Content (Join-Path $rb 'F.txt') 'v1'; Set-Content (Join-Path $rb 'keep.txt') 'keep'
GitAt $rb @('add', '-A'); GitAt $rb @('commit', '-qm', 'base')
$SB = "$(& git -C $rb rev-parse HEAD)".Trim()
GitAt $rb @('push', '-q', '-u', 'origin', 'main')
Set-Content (Join-Path $rb 'G.txt') 'g'; GitAt $rb @('add', 'G.txt'); GitAt $rb @('commit', '-qm', 'main: add G')
GitAt $rb @('push', '-q', 'origin', 'main')
GitAt $rb @('checkout', '-q', '-b', 'topic', $SB)
Set-Content (Join-Path $rb 'New.txt') 'n'; GitAt $rb @('add', 'New.txt'); GitAt $rb @('commit', '-qm', 'topic: add New.txt')
GitAt $rb @('merge', '-q', '--no-ff', 'main', '-m', 'topic merges main (keeps all)')
GitAt $rb @('push', '-q', 'origin', 'topic')
GitAt $rb @('checkout', '-q', 'main')
Push-Location $rb
try { $o = AQ land -Branch topic -Onto main -Purpose 'legit merge keeps main' } finally { Pop-Location }
Check 'B: NOT refused (lands)' ($code -eq 0 -and $o -match 'landed topic') $o

# ---- C: MUST NOT be refused - an explicit deletion of a file the topic itself added, never in main.
$fc = New-Fx 'fc'; $rc = $fc.repo
Set-Content (Join-Path $rc 'keep.txt') 'keep'
GitAt $rc @('add', '-A'); GitAt $rc @('commit', '-qm', 'base')
$SC = "$(& git -C $rc rev-parse HEAD)".Trim()
GitAt $rc @('push', '-q', '-u', 'origin', 'main')
Set-Content (Join-Path $rc 'G.txt') 'g'; GitAt $rc @('add', 'G.txt'); GitAt $rc @('commit', '-qm', 'main: add G')
GitAt $rc @('push', '-q', 'origin', 'main')
GitAt $rc @('checkout', '-q', '-b', 'topic', $SC)
Set-Content (Join-Path $rc 'del.txt') 'doomed'; GitAt $rc @('add', 'del.txt'); GitAt $rc @('commit', '-qm', 'topic: add del.txt')
GitAt $rc @('merge', '-q', '--no-ff', 'main', '-m', 'topic merges main')
& git -C $rc rm -q del.txt 2>&1 | Out-Null; GitAt $rc @('commit', '-q', '--amend', '--no-edit')   # delete it in the resolution
GitAt $rc @('push', '-q', 'origin', 'topic')
GitAt $rc @('checkout', '-q', 'main')
Push-Location $rc
try { $o = AQ land -Branch topic -Onto main -Purpose 'delete topic-owned file' } finally { Pop-Location }
Check 'C: NOT refused (lands)' ($code -eq 0 -and $o -match 'landed topic') $o

# ---- D: MUST NOT be refused - the topic changes a file main ALSO changed, but its result is a real
# merge of both sides (it contains main's new bytes).
$fd = New-Fx 'fd'; $rd = $fd.repo
Set-Content (Join-Path $rd 'F.txt') "L1`nL2`nL3"
GitAt $rd @('add', '-A'); GitAt $rd @('commit', '-qm', 'base')
$SD = "$(& git -C $rd rev-parse HEAD)".Trim()
GitAt $rd @('push', '-q', '-u', 'origin', 'main')
Set-Content (Join-Path $rd 'F.txt') "L1`nL2`nL3-MAIN"; GitAt $rd @('commit', '-qam', 'main: F L3')
GitAt $rd @('push', '-q', 'origin', 'main')
GitAt $rd @('checkout', '-q', '-b', 'topic', $SD)
Set-Content (Join-Path $rd 'F.txt') "L1-TOPIC`nL2`nL3"; GitAt $rd @('commit', '-qam', 'topic: F L1')
GitAt $rd @('merge', '-q', '--no-ff', 'main', '-m', 'topic merges main (both sides kept)')
GitAt $rd @('push', '-q', 'origin', 'topic')
GitAt $rd @('checkout', '-q', 'main')
Push-Location $rd
try { $o = AQ land -Branch topic -Onto main -Purpose 'real merge of both sides' } finally { Pop-Location }
Check 'D: NOT refused (lands)' ($code -eq 0 -and $o -match 'landed topic') $o

# ---- exact-leaf cleanup assertion: the whole fixture root is gone afterwards, so nothing leaks into
# %TEMP% (the reaper sweeps it, but a suite must not rely on that).
foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_LAND_NO_STALEBASE', 'AGENTQ_LAND_NO_PRECHECK') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
if (Test-Path (Join-Path $tmp 'wt')) { Get-ChildItem -LiteralPath (Join-Path $tmp 'wt') -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object { $_.IsReadOnly = $false } }
cmd /c rmdir /s /q "`"$tmp`"" 2>$null
Check 'cleanup: the fixture root is gone' (-not (Test-Path -LiteralPath $tmp)) $tmp
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
