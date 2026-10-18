# `agentq land` runs a repo-owned scripts/land-finalize.ps1 after the picks (ADR 0003 W3, changelog
# fragments): exit 0 -> its extra commit is pushed with the picks; exit 2 -> land exit 9, nothing pushed,
# journaled. A repo without the script lands exactly as before. Isolated in %TEMP%; bare repo = origin.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqfin-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_SESSION = 'test-F'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Tip { "$((git -C $repo ls-remote origin refs/heads/dev) -split "`t" | Select-Object -First 1)".Trim() }

# Fake finalizer: consumes changes/*.md into VERSION + one commit (exit 0); a file named BAD -> exit 2.
$fin = @'
param([string]$Worktree, [string]$Onto, [string]$Base, [string]$Branch)
Set-Location $Worktree
if (Test-Path changes/BAD.md) { [Console]::Error.WriteLine('fragment BAD.md invalid'); 'FINALIZE version=none fragments=0 legacy=0 commit=none'; exit 2 }
$f = @(Get-ChildItem changes -Filter *.md -ErrorAction SilentlyContinue)
if (-not $f.Count) { 'FINALIZE version=none fragments=0 legacy=0 commit=none'; exit 0 }
$v = [int](Get-Content VERSION) + 1
Set-Content VERSION "$v"; $f | ForEach-Object { git rm -q $_.FullName }
git add VERSION; git -c user.email=t@t -c user.name=t commit -q --no-verify -m "chore(release): $v" -m "Landed-Topic: $Branch" -m "Base: $Base"
"FINALIZE version=$v fragments=$($f.Count) legacy=0 commit=$(git rev-parse HEAD)"; exit 0
'@

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'VERSION') '1'; Set-Content (Join-Path $repo 'a.txt') 'a'
git -C $repo add VERSION a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
function NewTopic([string]$name) { git -C $tw fetch -q origin; git -C $tw checkout -q -B $name origin/dev 2>$null }
Push-Location $repo
try {
  # --- 0. no finalizer in the repo: plain land, no release commit ----------------------------
  NewTopic 'plain'
  Set-Content (Join-Path $tw 'p.txt') 'p'; git -C $tw add p.txt; git -C $tw commit -qm 'plain change'; git -C $tw push -q origin plain 2>$null
  $o = AQ land -Branch plain -Onto dev -Purpose 'plain'
  Check 'no finalizer: land exit 0' ($code -eq 0) $o
  git -C $repo fetch -q origin
  Check 'no finalizer: tip is the pick itself' ((git -C $repo log -1 --format=%s origin/dev) -eq 'plain change')
  Check 'no finalizer: no finalize output' (-not ($o -match 'finalize:')) $o

  # --- install the finalizer on dev ------------------------------------------------------------
  git -C $repo pull -q --no-rebase origin dev 2>$null
  New-Item -ItemType Directory -Force (Join-Path $repo 'scripts') | Out-Null
  [IO.File]::WriteAllText((Join-Path $repo 'scripts\land-finalize.ps1'), $fin)
  git -C $repo add scripts/land-finalize.ps1; git -C $repo commit -qm 'add finalizer'; git -C $repo push -q origin dev 2>$null

  # --- 1. fragment -> finalizer commit pushed after the pick ---------------------------------
  NewTopic 'frag'
  New-Item -ItemType Directory -Force (Join-Path $tw 'changes') | Out-Null
  Set-Content (Join-Path $tw 'changes\20261018-x.md') '- x'; Set-Content (Join-Path $tw 'b.txt') 'b'
  git -C $tw add changes b.txt; git -C $tw commit -qm 'feature b'; git -C $tw push -q origin frag 2>$null
  $base = Tip
  $o = AQ land -Branch frag -Onto dev -Purpose 'frag'
  Check 'finalize ok: land exit 0' ($code -eq 0) $o
  git -C $repo fetch -q origin
  $subs = @(git -C $repo log --format=%s "$base..origin/dev")
  Check 'finalize ok: pick + ONE release commit' ($subs.Count -eq 2 -and $subs[0] -eq 'chore(release): 2' -and $subs[1] -eq 'feature b') ($subs -join ' / ')
  Check 'finalize ok: fragment consumed' (-not (git -C $repo ls-tree --name-only origin/dev changes/))
  $body = (@(git -C $repo log -1 --format=%B origin/dev) -join "`n")
  Check 'finalize ok: -Base = origin/<onto> before the picks' ($body -match "Base: $base") $body
  Check 'finalize ok: -Branch passed' ($body -match 'Landed-Topic: frag')
  Check 'finalize ok: output relayed' ($o -match 'finalize: FINALIZE version=2') $o

  # --- 2. finalizer refuses -> exit 9, nothing pushed, journaled -----------------------------
  NewTopic 'bad'
  New-Item -ItemType Directory -Force (Join-Path $tw 'changes') | Out-Null
  Set-Content (Join-Path $tw 'changes\BAD.md') 'oops'; Set-Content (Join-Path $tw 'c.txt') 'c'
  git -C $tw add changes c.txt; git -C $tw commit -qm 'feature c'; git -C $tw push -q origin bad 2>$null
  $t0 = Tip
  $o = AQ land -Branch bad -Onto dev -Purpose 'bad'
  Check 'finalize refused: land exit 9' ($code -eq 9) $o
  Check 'finalize refused: nothing pushed' ((Tip) -eq $t0)
  Check 'finalize refused: message names the script' ($o -match 'land-finalize\.ps1 exit 2') $o
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'land-finalize-failed' })
  Check 'finalize refused: journaled with the reason' ($j.Count -eq 1 -and "$($j[0].reason)" -match 'BAD') ($j | ConvertTo-Json -Compress)
  Check 'finalize refused: land slot released' (-not (Test-Path (Join-Path $env:AGENTQ_HOME 'leases\repo\land.json')))
  $bk = @(git --git-dir=$bare for-each-ref --format='%(objectname)' refs/backup/wt/repo/land)
  Check 'finalize refused: refused result not backed up' (-not @($bk | Where-Object { (git --git-dir=$bare log -1 --format=%s $_) -eq 'feature c' }).Count)
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
