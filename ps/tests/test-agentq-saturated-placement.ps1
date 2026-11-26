# Placement + propose while the machine is SATURATED (OQ-004 follow-up, 2026-11-26).
# OFFLINE: the load probe is faked through AGENTQ_PROBE_FAKE (a file holding the milliseconds to report)
# and the cloud tool is a stub (AGENTQ_CLOUD_TOOL) that records its args and exits with STUB_EXIT. No real
# sample is taken, the real cloud is never reached. Isolated in %TEMP% (AGENTQ_HOME + AGENTQ_CONFIG).
#
# Three behaviours changed in ps/bin/agentq.ps1:
#   1. Resolve-Placement: on the `auto` path a SATURATED shared load record now returns where='cloud'
#      (reason 'auto: machine saturated (...)'). The branch is reached only on `auto`, and only after the
#      build:machine-full and RAM gates - an explicit `-Where local` has already returned above it.
#   2. The explicit opt-out still wins: AGENTQ_WHERE=local stays local while saturated.
#   3. Invoke-Propose: while saturated it prints 'skip: burst cannot admit anything while admission is
#      saturated' and creates NO burst file. A burst raises capacity, but admission's load hold is applied
#      AFTER the rank test, so the extra slot would be unusable - offering it as a remedy made `propose`
#      report an action that changes nothing.
param([string]$Aq)
$ErrorActionPreference = 'Stop'
if (-not $Aq) { $Aq = Join-Path (Split-Path $PSScriptRoot) 'bin\agentq.ps1' }
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agentq-sat-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null

$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_JOBOBJ = '1'
$env:AGENTQ_SESSION = 'sat-test'
Remove-Item Env:AGENTQ_WHERE -ErrorAction SilentlyContinue
Remove-Item Env:AGENTQ_NO_ADMISSION -ErrorAction SilentlyContinue

# The shared admission load record. AGENTQ_PROBE_FAKE is the number of ms every sample reports.
$fake = Join-Path $tmp 'probe-ms.txt'; $env:AGENTQ_PROBE_FAKE = $fake

# machineCap 1: one build holds the machine, so a second build must WAIT (that is how case 3 makes a
# waiter). cloudWorkspaces maps the repo named 'repo' to the workspace the stub must receive.
$cfgFile = Join-Path $tmp 'agentq-config.json'
@{ machineCap = 1; quickBurst = 0; agingMin = 0; idleYieldMin = 0; minFreeCommitGB = 0; cloudWorkspaces = @{ repo = 'wsrepo' }; cloudAutoMinSec = 240 } | ConvertTo-Json | Set-Content $cfgFile
$env:AGENTQ_CONFIG = $cfgFile

# The cloud stub: records every invocation's args, exits with STUB_EXIT (0 by default).
$stub = Join-Path $tmp 'stub.ps1'; $rec = Join-Path $tmp 'stub.log'
@"
`$a = @(`$args); Add-Content -LiteralPath '$rec' -Value (`$a -join ' ')
exit ([int]`$(if (`$env:STUB_EXIT) { `$env:STUB_EXIT } else { 0 }))
"@ | Set-Content $stub
$env:AGENTQ_CLOUD_TOOL = $stub

$repo = Join-Path $tmp 'repo'
New-Item -ItemType Directory -Force $repo | Out-Null
git -C $repo init -q -b main; git -C $repo config user.email t@t; git -C $repo config user.name t
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
$J = Join-Path $env:AGENTQ_HOME 'journal.jsonl'
function Journal { @(Get-Content $J -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
function Calls { @(Get-Content $rec -ErrorAction SilentlyContinue) }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function St { try { (AQ status -Json) | ConvertFrom-Json } catch { $null } }
function Run([string]$dir, [string[]]$extra, [string]$cmd = 'pnpm typecheck') {
  $a = @('-NoProfile', '-File', $Aq, 'run', '-Resource', 'build', '-Purpose', 'sattest', '-MinFreeGB', '0', '-TimeoutMin', '1', '-Repo', $dir) + $extra + @('--') + ($cmd -split ' ')
  & pwsh @a 2>$null | Out-Null; $LASTEXITCODE
}
# Make the shared record say "$ms" for the whole window (3 forced samples so the median is "$ms").
function Load([int]$ms) { [IO.File]::WriteAllText($fake, "$ms"); foreach ($i in 1..3) { $null = AQ probe -Force } }
# A local run that defects on the busy build:machine queue (-NoWait -> exit 3) instead of executing a
# child process: on a heavily loaded box a real child start can take minutes, and -TimeoutMin bounds only
# the QUEUE wait, not command execution. Placement is still decided (and journaled) before the queue check.
function RunNoWaitLocal([string]$dir, [string]$purpose) {
  $a = @('-NoProfile', '-File', $Aq, 'run', '-Resource', 'build:machine', '-Purpose', $purpose, '-MinFreeGB', '0', '-NoWait', '-Repo', $dir, '--', 'pwsh', '-NoProfile', '-Command', 'exit 0')
  & pwsh @a 2>$null | Out-Null; $LASTEXITCODE
}
$burst = Join-Path $env:AGENTQ_HOME 'queues\build_machine\burst.json'
$hHolder = $null; $hWaiter = $null
Push-Location $repo
try {
  # --- Case 1: saturated + auto -> cloud ------------------------------------------------
  Load 2000
  $n = (Calls).Count
  $rc = Run $repo @('-Where', 'auto') 'pnpm typecheck'
  Check '1 saturated + auto places the run on the cloud stub' ($rc -eq 0 -and (Calls).Count -eq $n + 1) "rc=$rc calls=$((Calls).Count)"
  $c = "$((Calls) | Select-Object -Last 1)"
  Check '1 the cloud stub received the configured -Ws' ($c -match '-Ws wsrepo') "$c"
  Check '1 the placement journal names the saturation' (@(Journal | Where-Object { $_.event -eq 'placement' -and "$($_.reason)" -match 'auto: machine saturated' }).Count -ge 1) ''

  # --- A holder now occupies the single machine slot (used by case 2 and case 3) ---------
  # The record stays saturated (2000): the fake file was written in case 1 and every read sees it.
  $hs = Join-Path $tmp 'holder.ps1'; $hout = Join-Path $tmp 'holder.out'
  [IO.File]::WriteAllText($hs, "`$env:AGENTQ_SESSION = 'sat-hold'`n& pwsh -NoProfile -File '$Aq' run -Resource build:machine -Purpose 'sat holder' -MinFreeGB 0 -TimeoutMin 5 -Repo '$repo' -- pwsh -NoProfile -Command 'Start-Sleep -Seconds 120' *> '$hout'`n")
  $hHolder = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $hs -WindowStyle Hidden -PassThru
  $held = $false; $until = (Get-Date).AddSeconds(90)
  while (-not $held -and (Get-Date) -lt $until) { $st = St; if ($st -and @($st.tickets | Where-Object { $_.resource -eq 'build:machine' -and $_.role -like 'HOLD*' }).Count) { $held = $true } else { Start-Sleep -Milliseconds 500 } }
  Check '2/3 setup: a holder occupies build:machine' $held $(if (Test-Path $hout) { Get-Content $hout -Raw } else { '(no output)' })

  # --- Case 2: the explicit opt-out still wins -----------------------------------------
  # Same saturated machine, but AGENTQ_WHERE=local: placement is decided locally and the run defects on
  # the busy LOCAL queue (exit 3) instead of calling the cloud stub.
  $env:AGENTQ_WHERE = 'local'
  $n = (Calls).Count
  $rc = RunNoWaitLocal $repo 'satlocal'
  Remove-Item Env:AGENTQ_WHERE
  Check '2 AGENTQ_WHERE=local keeps the run off the cloud stub while saturated' ((Calls).Count -eq $n) "calls=$((Calls).Count)"
  Check '2 ... and the busy LOCAL queue is the one it consulted (exit 3)' ($rc -eq 3) "rc=$rc"
  Check '2 ... journaled as a local placement' (@(Journal | Where-Object { $_.event -eq 'placement' -and $_.purpose -eq 'satlocal' -and $_.where -eq 'local' }).Count -ge 1) ''

  # --- Case 3: propose offers no useless burst while saturated -------------------------
  $ws = Join-Path $tmp 'waiter.ps1'; $wout = Join-Path $tmp 'waiter.out'
  [IO.File]::WriteAllText($ws, "`$env:AGENTQ_SESSION = 'sat-test'`n& pwsh -NoProfile -File '$Aq' run -Resource build:machine -Purpose 'sat waiter' -MinFreeGB 0 -TimeoutMin 5 -Repo '$repo' -- pwsh -NoProfile -Command 'exit 0' *> '$wout'`n")
  $hWaiter = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $ws -WindowStyle Hidden -PassThru
  $queued = $false; $until = (Get-Date).AddSeconds(90)
  while (-not $queued -and (Get-Date) -lt $until) { $st = St; if ($st -and @($st.tickets | Where-Object { $_.resource -eq 'build:machine' -and $_.session -eq 'sat-test' -and $_.role -like 'wait#*' }).Count) { $queued = $true } else { Start-Sleep -Milliseconds 500 } }
  Check '3 setup: this session has a WAITING build:machine ticket' $queued $(if (Test-Path $wout) { Get-Content $wout -Raw } else { '(no output)' })

  Remove-Item $burst -ErrorAction SilentlyContinue
  $o = AQ propose -Reason 'saturated placement test: burst would be useless'
  Check '3 propose creates no burst while saturated' (-not (Test-Path $burst)) ($o -split "`n" | Select-Object -Last 1)
  Check '3 propose says a burst cannot admit anything while saturated' ($o -match 'burst cannot admit anything') ($o -split "`n" | Select-Object -Last 1)
} finally {
  Pop-Location
  # Kill the holder/waiter launchers, then any process still naming this temp dir: under load the launcher
  # can exit before its synchronous `& pwsh` child, leaving the agentq run (and the slot it holds) orphaned.
  foreach ($pr in $hHolder, $hWaiter) { if ($pr) { & taskkill.exe /T /F /PID $pr.Id 2>&1 | Out-Null } }
  # A child killed a moment ago can still hold a file handle, and under heavy load a killed pwsh can take
  # seconds to actually exit: keep re-issuing the by-path kill and retry the removal until the dir is gone.
  for ($i = 0; $i -lt 30; $i++) {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($tmp) } | ForEach-Object { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    if (-not (Test-Path $tmp)) { break }
    Start-Sleep -Milliseconds 300
  }
  foreach ($v in 'AGENTQ_HOME', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_CLOUD_TOOL', 'AGENTQ_PROBE_FAKE', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_JOBOBJ', 'AGENTQ_WHERE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
