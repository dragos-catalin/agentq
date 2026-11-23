# Land waiters use config `landWaitMin`, not the generic -TimeoutMin default (60). On 2026-11-23 the 60-min
# default made the codai land queue advance only by expiry: 10 waiters "timed out after 60 min" in 90 min and
# re-queued at the back. Here landWaitMin=1 while a blocker holds the land: the waiter must give up after
# 1 min (proving the config, not 60, bounds the wait). The blocker's push then hands the pre-push hook the
# tree it gated (AGENTQ_LAND_GREEN_TREE/_GATE). Isolated in %TEMP%; ~75 s.
# `landRequeueMax: 0` keeps that single window explicit: the requeue-on-timeout behaviour has its own suite
# (test-land-reap.ps1), which would otherwise make this waiter land once the blocker released.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqlw-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'
$env:AGENTQ_LAND_NO_PREGATE = '1'
$env:AGENTQ_RUN_BUILD = Join-Path $PSScriptRoot 'fake-gate.ps1'
$env:FAKE_GATE_LOG = Join-Path $tmp 'gates.log'
$env:FAKE_GATE_HOLD = Join-Path $tmp 'hold.flag'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$cfg = Join-Path $tmp 'cfg.json'
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"minFreeCommitGB":0,"landBatchMax":1,"landWaitMin":1,"landRequeueMax":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
function Topic([string]$name, [string]$file) {
  git -C $tw checkout -q -B $name origin/dev
  Set-Content (Join-Path $tw $file) $name; git -C $tw add $file; git -C $tw commit -qm "topic $name"
  git -C $tw push -q origin $name 2>$null
  git -C $repo fetch -q origin 2>$null
}
# The land push tells the pre-push hook which tree just passed which gate (codai's hook skips its second
# `gate:platform` on that exact tree). The hook records what it was told and what it is pushing.
$hookLog = Join-Path $tmp 'prepush.log'
$hook = Join-Path $repo '.git\hooks\pre-push'
"#!/bin/sh`necho `"`$AGENTQ_LAND_GREEN_TREE|`$(git rev-parse 'HEAD^{tree}')|`$AGENTQ_LAND_GREEN_GATE`" >> '$($hookLog -replace '\\', '/')'`nexit 0`n" | Set-Content -NoNewline $hook
$procs = @()
try {
  Set-Content $env:FAKE_GATE_HOLD 'x'
  Topic 'blocker' 'blk.txt'; Topic 'w1' 'w1.txt'
  $bOut = Join-Path $tmp 'blocker.out'
  $cmd = "`$env:AGENTQ_SESSION='s-blk'; Set-Location '$repo'; & pwsh -NoProfile -File '$Aq' land -Branch blocker -Onto dev -Gate 'gate' -Purpose 'land blocker' *> '$bOut'; exit `$LASTEXITCODE"
  $b = Start-Process pwsh -ArgumentList @('-NoProfile', '-Command', $cmd) -PassThru -WindowStyle Hidden
  $procs += $b
  for ($i = 0; $i -lt 120 -and -not (Select-String -LiteralPath $env:FAKE_GATE_LOG -Pattern 'blocker' -Quiet -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
  Check 'blocker holds the land gate' (Select-String -LiteralPath $env:FAKE_GATE_LOG -Pattern 'blocker' -Quiet -ErrorAction SilentlyContinue)
  $env:AGENTQ_SESSION = 's-w1'
  Push-Location $repo
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $o = @(& pwsh -NoProfile -File $Aq land -Branch w1 -Onto dev -Gate 'gate' -Purpose 'land w1' 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $code = $LASTEXITCODE; $sw.Stop()
  Pop-Location
  Check 'waiter exits 3 (wait timeout)' ($code -eq 3) "code=$code $o"
  Check 'timeout names landWaitMin=1' ($o -match 'after 1 min') $o
  Check 'gave up near 1 min, not 60' ($sw.Elapsed.TotalSeconds -ge 55 -and $sw.Elapsed.TotalSeconds -lt 300) "$($sw.Elapsed.TotalSeconds)s"
  Remove-Item $env:FAKE_GATE_HOLD -Force
  Check 'blocker still lands' ($b.WaitForExit(240000) -and $b.ExitCode -eq 0) (Get-Content $bOut -Raw -ErrorAction SilentlyContinue)
  $h = @(Get-Content $hookLog -ErrorAction SilentlyContinue)
  $parts = if ($h.Count) { $h[-1].Split('|') } else { @('', '', '') }
  Check 'pre-push told the gated tree' ($h.Count -ge 1 -and $parts[0] -and $parts[0] -eq $parts[1]) ($h -join ' / ')
  Check 'pre-push told the gate command' ($parts[2] -eq 'gate') ($h -join ' / ')
} finally {
  foreach ($p in $procs) { if (-not $p.HasExited) { try { $p.Kill($true) } catch {} } }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'ALL PASS'
