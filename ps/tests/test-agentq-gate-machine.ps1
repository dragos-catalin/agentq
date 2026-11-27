# 2026-11-27: the MACHINE-WIDE gate bound (`gate:machine`). A heavy land pre-gate used to take only
# `verify:<repo>` (cap 1 PER REPO), so N repos ran N ~90-fork gates at once - 13 concurrent gates were
# measured on this machine on 2026-11-26. The fix is a SECOND capacity class, taken by a heavy
# gate/heavy/batch run on a `verify:*` resource, whose cap is read from CONFIG on every call
# (gateMachineCap, default 3, floor 1) because a sticky capacity file must never be able to raise a
# machine-wide bound.
#
# A capacity bound is easy to write and easy to fake: a version that always returns 3, or one that reads
# the queue's own `capacity` file, or one that also gates plain builds, would look fine in `status` and
# would not be caught by the existing suites. So each property here is pinned with the outcome a broken
# version produces:
#   * the class exists and is OBSERVABLE: a heavy `verify:*` run holds a `gate:machine` ticket, and it
#     does NOT take a `build:machine` one (that is Expand-Resources choosing the class, not the caller);
#   * at the cap, one gate holds and a second is refused with -NoWait (exit 3);
#   * the cap is read from CONFIG: raising gateMachineCap admits the SAME second gate - this is the
#     discriminating case, and with the `gate:machine` branch removed from Get-Capacity it is the one
#     that goes red - while gateMachineCap 0 still admits exactly one (the progress guarantee) and a
#     hand-written `queues\gate_machine\capacity` of 9 is ignored;
#   * a plain `build:machine` run is NOT gated by it - the whole point of a separate class.
# The load probe is faked (AGENTQ_PROBE_FAKE), so the admission hold is never what decides a case.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqgm-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_JOBOBJ = '1'
$env:AGENTQ_SESSION = 'test-gm'
# run-all turns admission off for every suite (it needs a stable machine); this one measures the queue,
# so it wants admission ON and OPEN.
Remove-Item Env:AGENTQ_NO_ADMISSION -ErrorAction SilentlyContinue
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fake = Join-Path $tmp 'probe-ms.txt'
$env:AGENTQ_PROBE_FAKE = $fake
$cfg = Join-Path $tmp 'cfg.json'; $env:AGENTQ_CONFIG = $cfg
# gateCap is the knob under test; $omitGate drops the key entirely (the default path).
function Cfg([int]$gateCap, [bool]$omitGate = $false) {
  $h = @{ taskSlotsPerRepo = 3; taskSlotsMachine = 5; minFreeCommitGB = 0; machineCap = 2; quickBurst = 0; agingMin = 0; idleYieldMin = 0
    scratchSlots = 3; holdDefaultMin = 180
    admission = @{ enabled = $true; probeMs = 400; window = 3; everySec = 0; staleSec = 300; maxHoldMin = 60 }
  }
  if (-not $omitGate) { $h.gateMachineCap = $gateCap }
  $h | ConvertTo-Json -Depth 5 | Set-Content $cfg
}
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
# admission OPEN: the shared record says 50 ms for the whole window (3 forced samples).
function Load([int]$ms = 50) { [IO.File]::WriteAllText($fake, "$ms"); foreach ($i in 1..3) { $null = AQ probe -Force } }
function Tickets([string]$res) { $st = AQ status -Json | ConvertFrom-Json; @($st.tickets | Where-Object { $_.resource -eq $res }) }
function Holds([string]$purpose) { @(Tickets 'gate:machine' | Where-Object { $_.role -like 'HOLD*' -and $_.purpose -eq $purpose }).Count }
function WaitHold([string]$purpose, [int]$sec = 90) {
  $until = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $until) { if ((Holds $purpose) -gt 0) { return $true }; Start-Sleep -Milliseconds 400 }
  return ((Holds $purpose) -gt 0)
}
# A long-lived holder: a heavy run on a verify:* resource whose child sleeps until its stop file exists.
# A fixed sleep ended too early on a busy machine (every agentq call below starts a process), and the
# checks then ran with no holder at all - the same trap the admission suite records.
$holdScript = Join-Path $tmp 'hold.ps1'
[IO.File]::WriteAllText($holdScript, "param([string]`$Stop)`n`$end = (Get-Date).AddMinutes(15)`nwhile (-not (Test-Path -LiteralPath `$Stop) -and (Get-Date) -lt `$end) { Start-Sleep -Milliseconds 300 }`n")
function StartHolder([string]$purpose, [string]$res) {
  $stop = Join-Path $tmp ("stop-" + ($purpose -replace '[^a-z0-9]', '') + '.txt')
  $w = Join-Path $tmp ("w-" + ($purpose -replace '[^a-z0-9]', '') + '.ps1')
  $body = "`$env:AGENTQ_SESSION = 'gm-holder'`n" +
    "& pwsh -NoProfile -File '$Aq' run -Resource '$res' -Lane heavy -MinFreeGB 0 -Purpose '$purpose' -TimeoutMin 5 -Repo '$repo' -- pwsh -NoProfile -File '$holdScript' -Stop '$stop'`n"
  [IO.File]::WriteAllText($w, $body)
  $p = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $w -WindowStyle Hidden -PassThru
  return [pscustomobject]@{ Proc = $p; Stop = $stop; Purpose = $purpose }
}
function StopHolder($h) { if ($h) { [IO.File]::WriteAllText($h.Stop, ''); $null = $h.Proc.WaitForExit(30000); if (-not $h.Proc.HasExited) { & taskkill.exe /T /F /PID $h.Proc.Id 2>&1 | Out-Null } } }
# -NoWait: 0 when the run started, 3 when the resource was busy (that is the verdict under test).
function RunAt([string]$res, [string]$purpose) { AQ run -Resource $res -Lane heavy -MinFreeGB 0 -Repo $repo -Purpose $purpose -NoWait '--' pwsh -NoProfile -Command 'exit 0' }
function RunBuild([string]$purpose) { AQ run -Resource 'build:machine' -MinFreeGB 0 -Repo $repo -Purpose $purpose -NoWait '--' pwsh -NoProfile -Command 'exit 0' }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
$holders = New-Object System.Collections.ArrayList
Push-Location $repo
try {
  # 1. the class exists, is taken by a heavy verify run, and is a class of its OWN
  Cfg 1
  Load 50
  $hA = StartHolder 'gate a' 'verify:gm1'; $null = $holders.Add($hA)
  Check '1 setup: a heavy verify run on a verify:* resource holds a gate:machine ticket' (WaitHold 'gate a') ((Tickets 'gate:machine' | ConvertTo-Json -Compress))
  Check '1 ... with the purpose it was given (the holder is the run, not a leftover)' ((Holds 'gate a') -eq 1)
  Check '1 ... and it does NOT take a build:machine ticket (the caller names verify:*, Expand-Resources adds the gate)' ((Tickets 'build:machine').Count -eq 0) ((Tickets 'build:machine' | ConvertTo-Json -Compress))

  # 2. at the cap the second gate is refused
  $o = RunAt 'verify:gm2' 'gate b'
  Check '2 gateMachineCap 1 with one holder: a second heavy gate is refused (exit 3)' ($code -eq 3) "$code | $o"
  Check '2 ... and no second gate ticket holds' ((Holds 'gate b') -eq 0)

  # 3. the cap comes from CONFIG, read on every call: the SAME command now fits
  Cfg 2
  $o = RunAt 'verify:gm2' 'gate b'
  Check '3 raising gateMachineCap to 2 admits the SAME second gate (exit 0) - the cap is config, not a file' ($code -eq 0) "$code | $o"
  $hB = StartHolder 'gate b' 'verify:gm2'; $null = $holders.Add($hB)
  Check '3 ... and both gates hold at once (cap 2)' ((WaitHold 'gate b') -and ((Holds 'gate a') -eq 1))

  # 4. the point of a separate class: the gate bound does not gate a build
  $o = RunBuild 'build x'
  Check '4 two heavy gates are holding and a build:machine run is still admitted (exit 0)' ($code -eq 0) "$code | $o"
  Check '4 ... and it did not have to take a gate ticket to do it' ((Holds 'build x') -eq 0)

  # 5. never below one: the progress guarantee
  foreach ($h in $holders) { StopHolder $h }
  $holders.Clear()
  Cfg 0
  Load 50
  $hC = StartHolder 'gate c' 'verify:gm3'; $null = $holders.Add($hC)
  Check '5 gateMachineCap 0: the first gate still starts (floor 1 - a bound that stops all work is not a bound)' (WaitHold 'gate c')
  $o = RunAt 'verify:gm4' 'gate d'
  Check '5 ... and it is still exactly one (exit 3)' ($code -eq 3) "$code | $o"

  # 6. a sticky capacity file must not be able to raise a machine-wide bound
  Cfg 1
  $capFile = Join-Path (Join-Path $env:AGENTQ_HOME 'queues') 'gate_machine\capacity'
  [IO.File]::WriteAllText($capFile, '9')
  $o = RunAt 'verify:gm5' 'gate e'
  Check '6 a hand-written queues\gate_machine\capacity of 9 is ignored (exit 3)' ($code -eq 3) "$code | $o"
  Check '6 ... and agentq did not adopt the file as the effective cap' ((Get-Content $capFile -Raw).Trim() -eq '9')

  # 7. the default path: no gateMachineCap key at all
  foreach ($h in $holders) { StopHolder $h }
  $holders.Clear()
  Cfg 3 $true
  Load 50
  $hD = StartHolder 'gate f' 'verify:gm6'; $null = $holders.Add($hD)
  Check '7 no gateMachineCap key: the first heavy gate still holds (the class exists by default)' (WaitHold 'gate f')
  $hE = StartHolder 'gate g' 'verify:gm7'; $null = $holders.Add($hE)
  Check '7 ... and a second one holds too, so the default is not an accidental cap 1' (WaitHold 'gate g')
} finally {
  Pop-Location
  foreach ($h in $holders) { if ($h -and $h.Proc) { & taskkill.exe /T /F /PID $h.Proc.Id 2>&1 | Out-Null } }
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_PROBE_FAKE', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_JOBOBJ') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
