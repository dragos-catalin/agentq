# Tests for agentq-jobobject.ps1. Prints PASS/FAIL per case, then ALL OK (exit 0) or FAILED (exit 1).
param([string]$Bin = (Join-Path $PSScriptRoot '..\bin'))
$ErrorActionPreference = 'Stop'
$helper = Join-Path $Bin 'agentq-jobobject.ps1'
$aqRun = Join-Path $Bin 'agentq.ps1'
$pwsh = (Get-Process -Id $PID).Path
$script:fails = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { "PASS $name $detail" } else { "FAIL $name $detail"; $script:fails++ }
}
function Run-Helper([string[]]$HelperArgs) {
  $out = & $pwsh -NoProfile -File $helper @HelperArgs 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Code = $LASTEXITCODE; Out = @($out); Text = ($out -join "`n") }
}
function Get-Children([int]$ParentId) {
  @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$ParentId")
}
function Find-PingUnder([int]$RootPid, [int]$TimeoutSec = 20) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    foreach ($c in Get-Children $RootPid) {
      if ($c.Name -eq 'PING.EXE' -or $c.Name -eq 'ping.exe') { return [int]$c.ProcessId }
      foreach ($g in Get-Children $c.ProcessId) { if ($g.Name -ieq 'ping.exe') { return [int]$g.ProcessId } }
    }
    Start-Sleep -Milliseconds 200
  }
  return 0
}
function Wait-Gone([int]$Id, [int]$TimeoutSec) {
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (-not (Get-Process -Id $Id -ErrorAction SilentlyContinue)) { return $true }
    Start-Sleep -Milliseconds 100
  }
  return $false
}

# 0) parse check
$t = $null; $e = $null
[System.Management.Automation.Language.Parser]::ParseFile($helper, [ref]$t, [ref]$e) | Out-Null
Check 'parse helper' ($e.Count -eq 0) "errors=$($e.Count)"

# 1) exit code propagates
$r = Run-Helper @('-Command', 'exit 7')
Check 'exit code 7 propagates' ($r.Code -eq 7) "rc=$($r.Code)"
$r = Run-Helper @('-Command', 'exit 0')
Check 'exit code 0 propagates' ($r.Code -eq 0) "rc=$($r.Code)"

# 2) child tree dies when the helper is killed
#    control first: WITHOUT a job object the same tree survives a parent kill (proves the test is not vacuous)
$ctl = Start-Process $pwsh -ArgumentList '-NoProfile', '-Command', 'cmd /d /c ping -n 60 127.0.0.1 >nul' -WindowStyle Hidden -PassThru
$ctlPing = Find-PingUnder $ctl.Id
Stop-Process -Id $ctl.Id -Force
$ctlSurvived = $ctlPing -gt 0 -and -not (Wait-Gone $ctlPing 3)
if ($ctlPing -gt 0) { Stop-Process -Id $ctlPing -Force -ErrorAction SilentlyContinue }
Check 'control: orphan ping survives without job object' $ctlSurvived "ping=$ctlPing"

$h = Start-Process $pwsh -ArgumentList '-NoProfile', '-File', "`"$helper`"", '-Command', '"ping -n 60 127.0.0.1 >nul"' -WindowStyle Hidden -PassThru
$ping = Find-PingUnder $h.Id
if ($ping -eq 0) {
  Check 'kill helper kills ping' $false 'ping never appeared under helper'
} else {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Stop-Process -Id $h.Id -Force          # TerminateProcess: no cleanup code in the helper runs
  $gone = Wait-Gone $ping 5
  Check 'kill helper kills ping within 5 s' $gone ("ping={0} goneAfterMs={1}" -f $ping, $sw.ElapsedMilliseconds)
  if (-not $gone) { Stop-Process -Id $ping -Force -ErrorAction SilentlyContinue }
}

# 3) memory cap: allocating more than -MemoryMB fails; same command without cap succeeds
$alloc = "`"$pwsh`" -NoProfile -Command `"`$ErrorActionPreference='Stop'; `$b=[byte[]]::new(700MB); [Array]::Fill(`$b,[byte]1); 'ALLOC_OK'`""
$r = Run-Helper @('-MemoryMB', '300', '-Command', $alloc)
Check 'memory cap 300 MB fails a 700 MB alloc' ($r.Code -ne 0 -and $r.Text -notmatch 'ALLOC_OK') "rc=$($r.Code)"
$r2 = Run-Helper @('-Command', $alloc)
$peak = if ($r2.Text -match 'peakMB=([0-9.]+)') { [double]$Matches[1] } else { 0 }
Check 'control: same alloc without cap succeeds' ($r2.Code -eq 0 -and $r2.Text -match 'ALLOC_OK' -and $peak -gt 700) "rc=$($r2.Code) peakMB=$peak"

# 4) accounting line with cpuSec > 0 for a CPU-bound command
$r = Run-Helper @('-Command', 'for /L %i in (1,1,400000) do @rem')
$line = $r.Out | Where-Object { $_ -match '^JOBOBJ cpuSec=' } | Select-Object -First 1
$cpu = if ($line -match 'cpuSec=([0-9.]+)') { [double]::Parse($Matches[1], [cultureinfo]::InvariantCulture) } else { 0 }
Check 'accounting line present, cpuSec > 0' ($null -ne $line -and $cpu -gt 0 -and $line -match 'peakMB=[0-9.]+') "$line"

# 5) weight accepted (SetInformationJobObject true + read back) for 9 and 1; out of range rejected
foreach ($w in 9, 1) {
  $r = Run-Helper @('-Weight', "$w", '-Command', 'exit 0')
  Check "weight $w applied" ($r.Code -eq 0 -and $r.Text -match "weightApplied=True weightReadback=$w ") (($r.Out | Select-Object -First 1))
}
$r = Run-Helper @('-Weight', '10', '-Command', 'exit 0')
Check 'weight 10 rejected by parameter validation' ($r.Code -ne 0 -and $r.Text -notmatch 'JOBOBJ start') "rc=$($r.Code)"

# 6) agentq run: the command runs inside a job object; an orphan child it leaves behind dies with the
#    holder (kill-on-close) and the journal 'done' event carries cpuSec/peakMB/cpuWeight.
$tmpA = Join-Path ([IO.Path]::GetTempPath()) ('aqjo-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmpA 'coord'; $env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'
New-Item -ItemType Directory -Force $tmpA | Out-Null
$env:AGENTQ_CONFIG = Join-Path $tmpA 'c.json'; '{"machineCap":2,"minFreeCommitGB":0}' | Set-Content $env:AGENTQ_CONFIG
$rp = Join-Path $tmpA 'repo'; git init -q -b main $rp; git -C $rp commit -q --allow-empty -m i 2>$null
$pidF = Join-Path $tmpA 'orphan.pid'
$spawn = "`$p = Start-Process ping -ArgumentList '-n','300','127.0.0.1' -WindowStyle Hidden -PassThru; [IO.File]::WriteAllText('$pidF', [string]`$p.Id); exit 0"
Push-Location $rp
& pwsh -NoProfile -File $aqRun run -Resource install -Purpose 'jobobj orphan' -- pwsh -NoProfile -Command $spawn *> $null
$rcA = $LASTEXITCODE; Pop-Location
$orphan = if (Test-Path $pidF) { [int](Get-Content $pidF) } else { 0 }
Start-Sleep -Milliseconds 800
$alive = $orphan -and (Get-Process -Id $orphan -ErrorAction SilentlyContinue)
Check 'agentq run: orphan child killed when the holder exits' ($rcA -eq 0 -and $orphan -gt 0 -and -not $alive) "rc=$rcA orphan=$orphan alive=$([bool]$alive)"
if ($alive) { Stop-Process -Id $orphan -Force -ErrorAction SilentlyContinue }
$jl = Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'done' } | Select-Object -Last 1
Check 'agentq run: done event has cpuSec + cpuWeight' ($jl -and $null -ne $jl.cpuSec -and $jl.cpuWeight -ge 1) ($jl | ConvertTo-Json -Compress)
# opt-out keeps the old behaviour (orphan survives)
Remove-Item $pidF -ErrorAction SilentlyContinue
$env:AGENTQ_NO_JOBOBJ = '1'
Push-Location $rp
& pwsh -NoProfile -File $aqRun run -Resource install -Purpose 'jobobj off' -- pwsh -NoProfile -Command $spawn *> $null
Pop-Location
Remove-Item Env:AGENTQ_NO_JOBOBJ
$orphan2 = if (Test-Path $pidF) { [int](Get-Content $pidF) } else { 0 }
Start-Sleep -Milliseconds 800
$alive2 = $orphan2 -and (Get-Process -Id $orphan2 -ErrorAction SilentlyContinue)
Check 'AGENTQ_NO_JOBOBJ=1: orphan survives (control)' ([bool]$alive2) "orphan=$orphan2"
if ($alive2) { Stop-Process -Id $orphan2 -Force -ErrorAction SilentlyContinue }
# 7) agentq run lowers the command's priority class by lane, so builds yield to terminals and the editor
$prF = Join-Path $tmpA 'prio.txt'
$probe = "[IO.File]::WriteAllText('$prF', [string](Get-Process -Id `$PID).PriorityClass)"
Push-Location $rp
& pwsh -NoProfile -File $aqRun run -Resource install -Purpose 'prio quick' -- pwsh -NoProfile -Command $probe *> $null
$pq = if (Test-Path $prF) { Get-Content $prF -Raw } else { '' }
Remove-Item $prF -ErrorAction SilentlyContinue
& pwsh -NoProfile -File $aqRun run -Resource build -Lane batch -Purpose 'prio batch' -- pwsh -NoProfile -Command $probe *> $null
$pb = if (Test-Path $prF) { Get-Content $prF -Raw } else { '' }
Pop-Location
Check 'agentq run (quick lane): command runs BelowNormal' ($pq -eq 'BelowNormal') "got '$pq'"
Check 'agentq run (batch lane): command runs Idle' ($pb -eq 'Idle') "got '$pb'"
$jl = Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'done' } | Select-Object -Last 1
Check 'agentq run: done event records the priority' ($jl.priority -eq 'Idle') ($jl | ConvertTo-Json -Compress)
Remove-Item Env:AGENTQ_HOME, Env:AGENTQ_CONFIG -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $tmpA -ErrorAction SilentlyContinue

if ($script:fails -eq 0) { 'ALL OK'; exit 0 } else { "FAILED ($script:fails)"; exit 1 }
