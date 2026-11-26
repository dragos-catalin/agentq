# Tests for agentq-reclaim.ps1 — the explicit, proof-based slot-lease reclaim verb.
#
# SAFETY: every fixture lives under a temp root and is reached ONLY through $env:AGENTQ_HOME /
# $env:CODAI_WT_ROOT, so the real ~/.codai/coord leases and the real worktrees are never touched. The suite
# runs reclaim in report-only mode first (proving the default releases nothing), then -Apply, then a MUTATION
# check that replaces the predicate with an always-safe stub and asserts the suite would go RED.
param()
$ErrorActionPreference = 'Stop'
# Native exit codes (git) must not become terminating errors.
try { $PSNativeCommandUseErrorActionPreference = $false } catch {}

$reclaim = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\agentq-reclaim.ps1')).Path
$agentq = (Resolve-Path (Join-Path $PSScriptRoot '..\bin\agentq.ps1')).Path

# --- hermetic root --------------------------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqreclaim-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:CODAI_GH_ROOT = Join-Path $tmp 'gh'
# Every side-effecting agentq startup hook off: the release shells out to `agentq unlease`, and without
# these a release can reach the hub/registry/store and stall (measured: unlease did not return without them).
foreach ($g in 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_PRUNE', 'AGENTQ_NO_AGENT_LIMIT', 'AGENTQ_NO_FAIRSHARE', 'AGENTQ_NO_FLAKES', 'AGENTQ_NO_GREEN', 'AGENTQ_NO_JOBOBJ', 'AGENTQ_NO_STORE', 'AGENTQ_NO_POSTLAND', 'AGENTQ_NO_LAND_INSTALL', 'AGENTQ_NO_LAND_QUARANTINE') { Set-Item "Env:$g" '1' }
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
$env:AGENTQ_SESSION = 'reclaim-suite'
New-Item -ItemType Directory -Force (Join-Path $env:AGENTQ_HOME 'leases') | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseDirtyIdleMin":240,"leaseOwnerGoneIdleMin":120,"leaseMaxIdleMin":600,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "PASS $name" }
  else { Write-Host "FAIL $name  $detail" -ForegroundColor Red; $script:fail++ }
}

$kids = New-Object System.Collections.ArrayList
function Start-Live {
  $p = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 300' -PassThru -WindowStyle Hidden
  [void]$script:kids.Add($p)
  return $p
}
function Get-DeadPid {
  for ($i = 0; $i -lt 6; $i++) {
    $p = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'exit 0' -PassThru -WindowStyle Hidden
    $id = $p.Id; $p.WaitForExit()
    Start-Sleep -Milliseconds 120
    if (-not (Get-Process -Id $id -ErrorAction SilentlyContinue)) { return $id }
  }
  return 0
}

# One standalone repo (leaf name == slot name -> the repo name agentq resolves), one lease file under
# <AGENTQ_HOME>/leases/<name>/<name>.json. state: clean-pushed | clean-unpushed | no-upstream | dirty.
function New-SlotRepo([string]$name, [string]$state) {
  $dir = Join-Path $env:CODAI_WT_ROOT $name
  New-Item -ItemType Directory -Force $dir | Out-Null
  & git -C $dir init -q -b main
  [IO.File]::WriteAllText((Join-Path $dir 'a.txt'), "a`n")
  & git -C $dir add -A; & git -C $dir commit -qm init
  $bare = Join-Path $tmp ("remotes\$name.git")
  & git init -q --bare -b main $bare
  & git -C $dir remote add origin $bare
  switch ($state) {
    'clean-pushed' { & git -C $dir push -q -u origin main 2>$null }
    'clean-unpushed' { & git -C $dir push -q -u origin main 2>$null; [IO.File]::WriteAllText((Join-Path $dir 'b.txt'), "b`n"); & git -C $dir add -A; & git -C $dir commit -qm second }
    'no-upstream' { }
    'dirty' { & git -C $dir push -q -u origin main 2>$null; [IO.File]::WriteAllText((Join-Path $dir 'd.txt'), "d`n") }
  }
  return $dir
}
function Write-Lease([string]$name, [hashtable]$h) {
  $d = Join-Path $env:AGENTQ_HOME "leases\$name"
  New-Item -ItemType Directory -Force $d | Out-Null
  $p = Join-Path $d "$name.json"
  [IO.File]::WriteAllText($p, ($h | ConvertTo-Json -Compress -Depth 6))
  return $p
}
function LeasePath([string]$name) { Join-Path $env:AGENTQ_HOME "leases\$name\$name.json" }

# Run reclaim and return the parsed JSON rows, keyed by slot.
function Run-Reclaim([string[]]$extra) {
  $o = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $reclaim @extra 2>&1 | ForEach-Object { "$_" })
  $script:lastCode = $LASTEXITCODE
  $script:lastRaw = ($o -join "`n")
  $rows = @()
  foreach ($line in $o) {
    if ($line -match '^\s*\{') { try { $rows += ($line | ConvertFrom-Json) } catch {} }
  }
  $bySlot = @{}
  foreach ($r in $rows) { $bySlot[[string]$r.slot] = $r }
  return $bySlot
}

try {
  # ---- fixtures ----------------------------------------------------------------------------------------
  $liveA = Start-Live; $slotA = New-SlotRepo 'keepdirty' 'dirty'
  [void](Write-Lease 'keepdirty' @{ leaseId = 'la1'; repo = 'keepdirty'; slot = 'keepdirty'; role = 'task'; path = $slotA; branch = ''; purpose = 'alive+dirty'; session = 'sib'; pid = $liveA.Id; procStart = $liveA.StartTime.ToUniversalTime().ToString('o'); created = [DateTime]::UtcNow.AddHours(-48).ToString('o'); host = 'X'; claims = @() })

  $liveB = Start-Live; $slotB = New-SlotRepo 'keepunpushed' 'clean-unpushed'
  [void](Write-Lease 'keepunpushed' @{ leaseId = 'lb1'; repo = 'keepunpushed'; slot = 'keepunpushed'; role = 'task'; path = $slotB; branch = ''; purpose = 'alive+clean+unpushed'; session = 'sib'; pid = $liveB.Id; procStart = $liveB.StartTime.ToUniversalTime().ToString('o'); created = [DateTime]::UtcNow.AddHours(-48).ToString('o'); host = 'X'; claims = @() })

  $liveC = Start-Live; $slotC = New-SlotRepo 'relidle' 'clean-pushed'
  [void](Write-Lease 'relidle' @{ leaseId = 'lc1'; repo = 'relidle'; slot = 'relidle'; role = 'task'; path = $slotC; branch = ''; purpose = 'alive+clean+pushed+idle'; session = 'sib'; pid = $liveC.Id; procStart = $liveC.StartTime.ToUniversalTime().ToString('o'); created = [DateTime]::UtcNow.AddHours(-48).ToString('o'); host = 'X'; claims = @() })

  $deadD = Get-DeadPid; $slotD = New-SlotRepo 'reldead' 'dirty'   # dirty -> the release must produce a real backup ref
  [void](Write-Lease 'reldead' @{ leaseId = 'ld1'; repo = 'reldead'; slot = 'reldead'; role = 'task'; path = $slotD; branch = ''; purpose = 'dead pid'; session = 'sib'; pid = $deadD; procStart = $null; created = [DateTime]::UtcNow.AddHours(-48).ToString('o'); host = 'X'; claims = @() })

  $liveE = Start-Live; $slotE = New-SlotRepo 'relrecycled' 'clean-pushed'
  [void](Write-Lease 'relrecycled' @{ leaseId = 'le1'; repo = 'relrecycled'; slot = 'relrecycled'; role = 'task'; path = $slotE; branch = ''; purpose = 'recycled pid'; session = 'sib'; pid = $liveE.Id; procStart = [DateTime]::UtcNow.AddHours(-1).ToString('o'); created = [DateTime]::UtcNow.AddHours(-48).ToString('o'); host = 'X'; claims = @() })

  $deadF = Get-DeadPid; $slotF = New-SlotRepo 'keeppregate' 'clean-pushed'
  [void](Write-Lease 'keeppregate' @{ leaseId = 'lf1'; repo = 'keeppregate'; slot = 'keeppregate'; role = 'task'; path = $slotF; branch = ''; purpose = 'future pre-gate'; session = 'sib'; pid = $deadF; procStart = $null; created = [DateTime]::UtcNow.AddHours(-48).ToString('o'); host = 'X'; claims = @(); pregatePid = 999998; pregateUntil = [DateTime]::UtcNow.AddHours(1).ToString('o') })

  $gdir = Join-Path $env:AGENTQ_HOME 'leases\garbage'; New-Item -ItemType Directory -Force $gdir | Out-Null
  [IO.File]::WriteAllText((Join-Path $gdir 'garbage.json'), '{ this is not json')

  # sanity: every slot's git view is as intended
  Check 'setup: dead pid is really gone' ($deadD -gt 0 -and -not (Get-Process -Id $deadD -ErrorAction SilentlyContinue)) "deadD=$deadD"
  Check 'setup: keepdirty is dirty' (@(& git -C $slotA status --porcelain).Count -gt 0)

  # ---- (h) the DEFAULT is report-only: nothing is released --------------------------------------------
  $pre = @(Get-ChildItem (Join-Path $env:AGENTQ_HOME 'leases') -Recurse -Filter '*.json').Count
  $w = Run-Reclaim @('-Json')                       # no -Apply => report only
  Check 'h0 default run exits 0' ($script:lastCode -eq 0) "code=$($script:lastCode)"
  $releasedNow = @($w.Values | Where-Object { $_.verdict -eq 'released' }).Count
  Check 'h1 report-only releases nothing (no released verdict)' ($releasedNow -eq 0) "released=$releasedNow"
  $post = @(Get-ChildItem (Join-Path $env:AGENTQ_HOME 'leases') -Recurse -Filter '*.json').Count
  Check 'h2 report-only deletes no lease file' ($pre -eq $post) "pre=$pre post=$post"
  Check 'h3 -WhatIf is accepted and also releases nothing' ((Run-Reclaim @('-WhatIf', '-Json')).Values.Verdict -notcontains 'released')

  # ---- predicate: kept cases --------------------------------------------------------------------------
  Check 'a alive+dirty => kept (uncommitted work)' ($null -ne $w['keepdirty'] -and -not $w['keepdirty'].safe -and $w['keepdirty'].reason -match 'uncommitted') $w['keepdirty'].reason
  Check 'b alive+clean+unpushed => kept (unpushed)' ($null -ne $w['keepunpushed'] -and -not $w['keepunpushed'].safe -and $w['keepunpushed'].reason -match 'unpushed') $w['keepunpushed'].reason
  Check 'f future pregateUntil => kept (pre-gate)' ($null -ne $w['keeppregate'] -and -not $w['keeppregate'].safe -and $w['keeppregate'].reason -match 'pre-gate') $w['keeppregate'].reason
  Check 'g unreadable JSON => kept and reported' ($null -ne $w['garbage'] -and -not $w['garbage'].safe -and $w['garbage'].reason -match 'unreadable') $w['garbage'].reason

  # ---- predicate: releasable cases --------------------------------------------------------------------
  Check 'c alive+clean+pushed+idle => would-release' ($null -ne $w['relidle'] -and $w['relidle'].safe -and $w['relidle'].verdict -eq 'would-release') $w['relidle'].reason
  Check 'd dead pid => would-release' ($null -ne $w['reldead'] -and $w['reldead'].safe -and $w['reldead'].verdict -eq 'would-release') $w['reldead'].reason
  Check 'e recycled pid => would-release' ($null -ne $w['relrecycled'] -and $w['relrecycled'].safe -and $w['relrecycled'].verdict -eq 'would-release') $w['relrecycled'].reason

  # ---- (j) not this process's own slot: run from INSIDE a releasable slot -> kept ----------------------
  Push-Location $slotC
  try { $wSelf = Run-Reclaim @('-Json') } finally { Pop-Location }
  Check 'j cwd inside the slot => kept (not this process own)' ($null -ne $wSelf['relidle'] -and -not $wSelf['relidle'].safe -and $wSelf['relidle'].reason -match 'holds the slot') $wSelf['relidle'].reason

  # ---- -Apply: only the proven-safe leases are released, backup-first ---------------------------------
  $ap = Run-Reclaim @('-Apply', '-Json')
  Check 'apply exits 0' ($script:lastCode -eq 0) "code=$($script:lastCode)"
  Check 'c released' ($ap['relidle'].verdict -eq 'released') $ap['relidle'].reason
  Check 'd released' ($ap['reldead'].verdict -eq 'released') $ap['reldead'].reason
  Check 'e released' ($ap['relrecycled'].verdict -eq 'released') $ap['relrecycled'].reason
  Check 'a still kept after apply' (Test-Path (LeasePath 'keepdirty'))
  Check 'b still kept after apply' (Test-Path (LeasePath 'keepunpushed'))
  Check 'f still kept after apply' (Test-Path (LeasePath 'keeppregate'))
  Check 'g still kept after apply' (Test-Path (LeasePath 'garbage'))
  Check 'c lease record removed' (-not (Test-Path (LeasePath 'relidle')))
  Check 'd lease record removed' (-not (Test-Path (LeasePath 'reldead')))
  Check 'e lease record removed' (-not (Test-Path (LeasePath 'relrecycled')))
  $bk = @(& git -C $slotD for-each-ref --format='%(refname)' 'refs/backup/wt/reldead/')
  Check 'd released AFTER a backup ref was written (backup-first)' ($bk.Count -ge 1) ($bk -join ',')

  # ---- journal: every decision is recorded as lease-reclaim -------------------------------------------
  $jl = Join-Path $env:AGENTQ_HOME 'journal.jsonl'
  $lines = @(Get-Content -LiteralPath $jl -ErrorAction SilentlyContinue) | Where-Object { $_ -match '"event":"lease-reclaim"' }
  $objs = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
  Check 'journal has lease-reclaim entries with slot/pid/verdict/reason/safe' (
    $objs.Count -ge 7 -and
    (@($objs | Where-Object { $_.PSObject.Properties.Name -contains 'slot' }).Count -eq $objs.Count) -and
    (@($objs | Where-Object { $_.PSObject.Properties.Name -contains 'pid' }).Count -eq $objs.Count) -and
    (@($objs | Where-Object { $_.PSObject.Properties.Name -contains 'verdict' }).Count -eq $objs.Count) -and
    (@($objs | Where-Object { $_.PSObject.Properties.Name -contains 'reason' }).Count -eq $objs.Count) -and
    (@($objs | Where-Object { $_.PSObject.Properties.Name -contains 'safe' }).Count -eq $objs.Count)
  ) "entries=$($objs.Count)"

  # ---- (i) MUTATION: replace the predicate with an always-safe stub -> the kept cases must flip ---------
  $src = Get-Content -LiteralPath $reclaim -Raw
  $repl = "function Test-SlotSafeToRelease(`$lease, `$facts) {`n  return [pscustomobject]@{ Safe = `$true; Verdict = 'release'; Reason = 'MUTATED-ALWAYS-SAFE' }`n}`n"
  $mut = [regex]::Replace($src, '(?ms)^function Test-SlotSafeToRelease\(.*?^}\s*$', { param($m) $repl })
  Check 'i0 mutation actually rewrote the predicate' ($mut -ne $src -and $mut -match 'MUTATED-ALWAYS-SAFE')
  $mutPath = Join-Path $tmp 'agentq-reclaim-mut.ps1'
  [IO.File]::WriteAllText($mutPath, $mut)
  $mo = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $mutPath -WhatIf -Json 2>&1 | ForEach-Object { "$_" })
  $mrows = @()
  foreach ($line in $mo) { if ($line -match '^\s*\{') { try { $mrows += ($line | ConvertFrom-Json) } catch {} } }
  $flipped = @($mrows | Where-Object { $_.slot -in @('keepdirty', 'keepunpushed', 'keeppregate', 'garbage') -and $_.safe })
  Check 'i1 an always-safe predicate IS detected (the suite would go RED)' ($flipped.Count -ge 1) ("flipped=" + (($flipped | ForEach-Object { $_.slot }) -join ','))
} finally {
  foreach ($p in $kids) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} }
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'CODAI_GH_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_PRUNE', 'AGENTQ_NO_AGENT_LIMIT', 'AGENTQ_NO_FAIRSHARE', 'AGENTQ_NO_FLAKES', 'AGENTQ_NO_GREEN', 'AGENTQ_NO_JOBOBJ', 'AGENTQ_NO_STORE', 'AGENTQ_NO_POSTLAND', 'AGENTQ_NO_LAND_INSTALL', 'AGENTQ_NO_LAND_QUARANTINE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
