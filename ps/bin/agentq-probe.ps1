# agentq load probe (ADR 0009 stage 0, OQ-004). Dot-sourced by agentq.ps1 and by the agentq-sync loop
# (PowerShell 7); depends on neither.
#
# The probe is the start latency of a trivial process (`cmd /d /c exit`, `/bin/sh -c "exit 0"` elsewhere).
# CPU percent says little on a machine that is busy all day: at 100 % CPU a trivial process still started
# in about 100 ms (measured 2026-11-11), while the days when terminals needed 5 to 60 s to open are exactly
# the days this number climbs. One sample costs one process start.
#
#   <root>/load/probe.json             last sample + the last `keep` samples (shared by every caller)
#   <root>/load/probe-yyyyMMdd.jsonl   one line per sample, read by `agentq slo` (5-minute buckets)
#
# Callers: `agentq run` and `agentq lease` while they decide admission, and the agentq-sync loop once a
# minute so the number is fresh even when nothing queues. `agentq status` only READS the file.
# Test seam: AGENTQ_PROBE_FAKE = a file holding the number of milliseconds to report (no process starts).
#
# Owner presence (OQ-005): every sample also records `idleSec`, the seconds since the last keyboard or mouse
# input in this logon session (GetLastInputInfo). $null when it cannot be read (no interactive session, not
# Windows). The agent limit reads it from the shared record. Test seam: AGENTQ_IDLE_FAKE = a file holding seconds.

function Get-ProbeFile([string]$root) { Join-Path (Join-Path $root 'load') 'probe.json' }
function ConvertTo-ProbeUtc($v) {
  if ($null -eq $v -or "$v" -eq '') { return $null }
  if ($v -is [datetime]) { return $v.ToUniversalTime() }
  try { [DateTimeOffset]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime } catch { $null }
}
$script:AqIdleNative = $null
function Measure-InputIdleSec {
  if ($env:AGENTQ_IDLE_FAKE) {
    try { return [double]::Parse("$([IO.File]::ReadAllText($env:AGENTQ_IDLE_FAKE))".Trim(), [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
  }
  if (-not $IsWindows) { return $null }
  try {
    if (-not $script:AqIdleNative) {
      # A P/Invoke stub built with Reflection.Emit: no C# compile (Add-Type costs 0.3 to 1 s per process).
      $ab = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly([Reflection.AssemblyName]::new('AgentqIdle'), [Reflection.Emit.AssemblyBuilderAccess]::Run)
      $tb = $ab.DefineDynamicModule('AgentqIdle').DefineType('AgentqIdle.Native', [Reflection.TypeAttributes]'Public, Class')
      $mb = $tb.DefinePInvokeMethod('GetLastInputInfo', 'user32.dll', [Reflection.MethodAttributes]'Public, Static, PinvokeImpl', [Reflection.CallingConventions]::Standard, [bool], [Type[]]@([byte[]]), [Runtime.InteropServices.CallingConvention]::Winapi, [Runtime.InteropServices.CharSet]::Auto)
      $mb.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
      $script:AqIdleNative = $tb.CreateType()
    }
    # LASTINPUTINFO { UINT cbSize = 8; DWORD dwTime } as 8 bytes; dwTime is a 32-bit tick count that wraps.
    $buf = [byte[]]::new(8); $buf[0] = 8
    $native = $script:AqIdleNative
    if (-not $native::GetLastInputInfo($buf)) { return $null }
    $last = [long][BitConverter]::ToUInt32($buf, 4)
    $now = [long]([Environment]::TickCount64 -band 0xFFFFFFFFL)
    [math]::Round((($now - $last + 4294967296L) % 4294967296L) / 1000, 1)
  } catch { $null }
}
function Measure-ProcessStart {
  if ($env:AGENTQ_PROBE_FAKE) {
    try { return [double]::Parse("$([IO.File]::ReadAllText($env:AGENTQ_PROBE_FAKE))".Trim(), [Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
  }
  try {
    $psi = if ($IsWindows) { [Diagnostics.ProcessStartInfo]::new('cmd.exe', '/d /c exit') } else { [Diagnostics.ProcessStartInfo]::new('/bin/sh', '-c "exit 0"') }
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = [Diagnostics.Process]::Start($psi)
    # A machine where this takes 15 s is saturated beyond doubt: report the cap instead of waiting longer.
    if (-not $p.WaitForExit(15000)) { try { $p.Kill() } catch {}; $p.Dispose(); return 15000.0 }
    $sw.Stop(); $p.Dispose()
    [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
  } catch { $null }
}
# Read-only. $null when there is no sample yet or the file cannot be read.
function Read-LoadProbe([string]$root) {
  $f = Get-ProbeFile $root
  if (-not [IO.File]::Exists($f)) { return $null }
  for ($i = 0; $i -lt 3; $i++) {
    try { return ([IO.File]::ReadAllText($f) | ConvertFrom-Json -AsHashtable -DateKind String) } catch { Start-Sleep -Milliseconds 30 }
  }
  $null
}
# Takes a new sample when the shared one is older than $everySec, else returns the shared one. Never
# throws and never blocks on another caller: if someone else is sampling, the previous record comes back.
function Invoke-LoadProbe([string]$root, [double]$everySec = 20, [int]$keep = 12, [string]$src = 'agentq', $cpu = $null) {
  $prev = Read-LoadProbe $root
  if ($prev -and $prev['at']) {
    $at = ConvertTo-ProbeUtc $prev['at']
    if ($at -and ([DateTime]::UtcNow - $at).TotalSeconds -lt $everySec) { return $prev }
  }
  $m = [Threading.Mutex]::new($false, 'Global\agentq-probe-' + ($root.ToLowerInvariant() -replace '[^a-z0-9]', '_'))
  $got = $false
  try {
    try { $got = $m.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { return $prev }
    $ms = Measure-ProcessStart
    if ($null -eq $ms) { return $prev }
    $idle = Measure-InputIdleSec
    $now = [DateTime]::UtcNow
    $samples = [Collections.Generic.List[object]]::new()
    if ($prev -and $prev['samples']) { foreach ($s in @($prev['samples'])) { if ($s -and $null -ne $s['ms']) { $samples.Add([ordered]@{ t = "$($s['t'])"; ms = [double]$s['ms'] }) } } }
    $samples.Add([ordered]@{ t = $now.ToString('o'); ms = [double]$ms })
    while ($samples.Count -gt $keep) { $samples.RemoveAt(0) }
    $rec = [ordered]@{ v = 1; at = $now.ToString('o'); ms = [double]$ms; src = $src; cpu = $cpu; idleSec = $idle; samples = @($samples) }
    $dir = Join-Path $root 'load'
    [void][IO.Directory]::CreateDirectory($dir)
    $f = Get-ProbeFile $root
    $utf8 = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText("$f.$PID.tmp", ($rec | ConvertTo-Json -Compress -Depth 4), $utf8)
    [IO.File]::Move("$f.$PID.tmp", $f, $true)
    $line = ([ordered]@{ ts = $now.ToString('o'); ms = [double]$ms; cpu = $cpu; src = $src; idleSec = $idle } | ConvertTo-Json -Compress) + "`n"
    [IO.File]::AppendAllText((Join-Path $dir ("probe-{0}.jsonl" -f $now.ToString('yyyyMMdd'))), $line, $utf8)
    return (Read-LoadProbe $root)
  } catch { return $prev }
  finally { if ($got) { try { $m.ReleaseMutex() } catch {} }; $m.Dispose() }
}
# Saturated = the median of the last $window samples taken within $staleSec is above $probeMs, with at
# least 3 such samples. Fewer samples = unknown = not saturated (admission stays open).
function Get-LoadVerdict($probe, [double]$probeMs = 400, [int]$window = 5, [double]$staleSec = 300) {
  $r = @{ saturated = $false; median = $null; last = $null; ageSec = $null; n = 0; thresholdMs = $probeMs; src = '' }
  if (-not $probe) { return $r }
  $now = [DateTime]::UtcNow
  $at = ConvertTo-ProbeUtc $probe['at']
  if ($at) { $r.ageSec = [math]::Round(($now - $at).TotalSeconds) }
  if ($null -ne $probe['ms']) { $r.last = [double]$probe['ms'] }
  $r.src = "$($probe['src'])"
  $fresh = @(foreach ($s in @($probe['samples'])) {
      if (-not $s) { continue }
      $t = ConvertTo-ProbeUtc $s['t']
      if ($t -and ($now - $t).TotalSeconds -le $staleSec -and $null -ne $s['ms']) { [double]$s['ms'] }
    })
  if ($fresh.Count -gt $window) { $fresh = @($fresh | Select-Object -Last $window) }
  $r.n = $fresh.Count
  if ($fresh.Count) {
    $sorted = @($fresh | Sort-Object)
    $mid = [int][math]::Floor($sorted.Count / 2)
    $r.median = if ($sorted.Count % 2) { $sorted[$mid] } else { [math]::Round(($sorted[$mid - 1] + $sorted[$mid]) / 2, 1) }
    $r.saturated = ($fresh.Count -ge [math]::Min(3, $window)) -and ($r.median -gt $probeMs)
  }
  $r
}
