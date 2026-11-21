# Slot take-over safety (2026-11-20 incident): a new lease RESETS the worktree, so the previous holder's
# unsaved work is backed up first - but that backup used to be invisible (the ref was discarded with [void]
# and only expire/break wrote a notice). Consequence: 2026-11-20 21:59 another session leased codai/task-3,
# the work WAS saved to refs/backup/wt/codai/task-3/20261120-215948-8a2e and nobody was told, so the holder
# rebuilt it. This suite proves the four guarantees that close it:
#   1. the take-over prints a note naming the ref+sha and how to restore,
#   2. it is journalled (lease-takeover) and the previous holder is NOTIFIED (its next call shows it),
#   3. the slot history survives the lease record (a later take-over can still name the holder),
#   4. `agentq recover` lists and restores, refuses the shared clone, and never writes another session's slot.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqrc-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0,"scratchIdleMin":900}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Age($leaseJson, [int]$min) {
  $hb = "$leaseJson.hb"; [IO.File]::SetLastWriteTimeUtc($hb, [DateTime]::UtcNow.AddMinutes(-$min))
  $l = Get-Content $leaseJson -Raw | ConvertFrom-Json; $l.created = [DateTime]::UtcNow.AddMinutes(-$min - 5).ToString('o'); $l.pid = 999999; $l.procStart = $null
  [IO.File]::WriteAllText($leaseJson, ($l | ConvertTo-Json -Compress))
  $gd = ((Get-Content (Join-Path $l.path '.git') -Raw) -replace '^gitdir:\s*', '').Trim()
  foreach ($n in 'index', 'HEAD', 'logs\HEAD') { $p = Join-Path $gd $n; if (Test-Path $p) { [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddMinutes(-$min)) } }
}

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  # ---- the holder works in task-1 and has NOT committed
  $env:AGENTQ_SESSION = 'owner-A'
  $la = (AQ lease -Purpose 'work A' -Json | Select-Object -Last 1 | ConvertFrom-Json)
  Check '0 slot leased' ($la.slot -eq 'task-1' -and (Test-Path $la.path)) ($la | ConvertTo-Json -Compress)
  [IO.File]::WriteAllText((Join-Path $la.path 'wip.txt'), "unsaved work`n")
  $lf = Join-Path $env:AGENTQ_HOME "leases\repo\$($la.slot).json"
  Age $lf 30   # holder gone: the lease is stale, so another session may take the slot

  # ---- another session takes the slot over
  $env:AGENTQ_SESSION = 'owner-B'
  $out = AQ lease -Purpose 'work B' -Slot task-1
  Check '1 take-over prints the note' ($out -match 'still held another session') $out
  Check '1 note names the ref' ($out -match 'refs/backup/wt/repo/task-1/') $out
  Check '1 note names the previous holder' ($out -match 'last holder: owner-A') $out
  Check '1 note says how to restore' ($out -match 'agentq recover') $out
  $ref = ([regex]::Match($out, 'refs/backup/wt/repo/task-1/\S+')).Value
  Check '1 ref captured' ([bool]$ref) $out

  # ---- journalled + slot history survives the lease record
  $jr = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
  Write-Host ("RAW lease-takeover: " + (@(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | Select-String -SimpleMatch 'lease-takeover') -join ''))
  $tk = @($jr | Where-Object { $_.event -eq 'lease-takeover' -and $_.resource -eq "slot:repo:$($ref.Split('/')[4])" })
  Check '2 journalled lease-takeover with the ref' ($tk.Count -ge 1 -and $tk[-1].ref -eq $ref -and $tk[-1].holderSession -eq 'owner-A') ($jr | Where-Object { $_.event -in 'lease-takeover', 'backup' } | ConvertTo-Json -Depth 3)
  $hist = Join-Path $env:AGENTQ_HOME 'slots\repo--task-1.jsonl'
  $hh = @(Get-Content $hist -ErrorAction SilentlyContinue)
  Check '2 slot history file written' ($hh.Count -ge 2) (($hh -join ' | '))
  Check '2 history names the holder and the ref' (($hh -join '') -match 'owner-A' -and ($hh -join '') -match 'refs/backup/wt/repo/task-1/') ($hh -join ' | ')
  Check '2 history records the lease that took over' (($hh -join '') -match '"event":"lease"' -and ($hh -join '') -match '"holder":"owner-B"') ($hh -join ' | ')

  # ---- the previous holder is told (its next agentq call prints the notice)
  $env:AGENTQ_SESSION = 'owner-A'
  # `status` is READ-ONLY and does not consume notices (that is the ADR 0009 stage 0 rule) - any verb that
  # does work prints them, which is exactly what a returning holder runs first.
  $st = AQ note -Message 'holder A is back'
  Check '3 previous holder is notified' ($st -match 'NOTICE your lease' -and $st -match 'lease-takeover' -and $st -match [regex]::Escape($ref)) $st
  $st2 = AQ status
  Check '3 the notice is consumed once' (-not ($st2 -match 'NOTICE your lease')) $st2

  # ---- recover: list
  $env:AGENTQ_SESSION = 'owner-B'
  $lst = AQ recover -Repo repo -Slot task-1
  Check '4 recover lists the ref' ([bool]$ref -and $lst -match [regex]::Escape($ref)) "ref='$ref' `n$lst"
  Check '4 recover lists the slot history' ($lst -match 'owner-A' -and $lst -match 'who was there') $lst
  # repo-wide listing (no -Slot) must find it too: for-each-ref matches with FNM_PATHNAME, so `<repo>/*`
  # silently returns nothing while `<repo>/<slot>/*` works - the bug this assertion exists for.
  $all = AQ recover -Repo repo
  Check '4 recover without -Slot lists it' ($all -match [regex]::Escape($ref)) $all
  Check '4 recover without -Slot is not empty' (-not ($all -match 'no backups for')) $all

  # ---- recover: preview writes nothing
  $sc = (AQ lease -Role scratch -Purpose 'recover target' -Json | Select-Object -Last 1 | ConvertFrom-Json)
  Check '4 scratch slot leased' (Test-Path $sc.path) ($sc | ConvertTo-Json -Compress)
  $prev = AQ recover -Repo repo -Ref $ref -To $sc.path
  Check '4 preview writes nothing' ($prev -match 'dry run' -and -not (Test-Path (Join-Path $sc.path 'wip.txt'))) $prev

  # ---- recover: refuses the shared clone
  $bad = AQ recover -Repo repo -Ref $ref -To $repo -Apply
  Check '4 refuses the shared clone' ($script:code -ne 0 -and $bad -match 'SHARED clone') "exit=$($script:code) $bad"

  # ---- recover: restore, and the file is back with its content
  $ap = AQ recover -Repo repo -Ref $ref -To $sc.path -Apply
  $restored = Join-Path $sc.path 'wip.txt'
  Check '4 restore applies' (Test-Path $restored) "$ap (slot=$($sc.path))"
  if (Test-Path $restored) { Check '4 restored content matches' ((Get-Content $restored -Raw).Trim() -eq 'unsaved work') (Get-Content $restored -Raw) }
  $rjr = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ } | Where-Object { $_.event -eq 'recover' })
  Check '4 restore journalled' ($rjr.Count -ge 1 -and $rjr[-1].sha) ($rjr | ConvertTo-Json -Depth 3)

  # ---- recover: refuses a slot leased by another live session
  $env:AGENTQ_SESSION = 'someone-else'
  $oth = AQ recover -Repo repo -Ref $ref -To $sc.path -Apply
  Check '4 refuses another session slot' ($script:code -ne 0 -and $oth -match 'leased by owner-B') "exit=$($script:code) $oth"

  # ---- a lease on a CLEAN, pushed slot must NOT claim a take-over
  $env:AGENTQ_SESSION = 'owner-C'
  $lc = (AQ lease -Purpose 'clean' -Json | Select-Object -Last 1 | ConvertFrom-Json)
  Check '5 clean slot lease' (Test-Path $lc.path) ($lc | ConvertTo-Json -Compress)
  $env:AGENTQ_SESSION = 'owner-D'
  $env:AGENTQ_SESSION = 'owner-C'
  $o2 = AQ unlease -Repo $lc.path -LeaseId $lc.leaseId
  Check '5 clean unlease says nothing to back up' ($o2 -match 'nothing to back up') $o2
} finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'ALL OK'
