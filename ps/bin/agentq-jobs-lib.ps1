# Shared helpers for the background-job registry (job-start / job-run / jobs / wait-job / agentq-sync).
# Dot-source it. Registry = <coord>/jobs/<id>.json, <coord> = $env:AGENTQ_HOME or ~/.codai/coord, so the
# agentq-sync daemon mirrors it next to tickets/leases. Every write is mutex-guarded and atomic.
# Function names are prefixed (Job*) so dot-sourcing never shadows a caller's own helpers.

function Get-JobCoordRoot { if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path (Join-Path $HOME '.codai') 'coord' } }
function Get-JobDir {
  $d = Join-Path (Get-JobCoordRoot) 'jobs'
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  $d
}
function Get-JobFile([string]$id) { Join-Path (Get-JobDir) ("$id.json") }
function Get-JobIso([datetime]$d) { $d.ToUniversalTime().ToString('o') }
function ConvertTo-JobUtc($s) {
  if ($null -eq $s -or "$s" -eq '') { return $null }
  if ($s -is [datetime]) { return $s.ToUniversalTime() }
  [DateTimeOffset]::Parse("$s", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}
function New-JobId { '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'), [guid]::NewGuid().ToString('N').Substring(0, 4) }

function Invoke-JobLocked([string]$id, [scriptblock]$body) {
  $m = [Threading.Mutex]::new($false, "Global\agentq-job-$($id -replace '[^A-Za-z0-9_-]', '_')$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  $got = $false
  try {
    try { $got = $m.WaitOne(10000) } catch [Threading.AbandonedMutexException] { $got = $true }
    & $body
  } finally { if ($got) { try { $m.ReleaseMutex() } catch {} }; $m.Dispose() }
}
function Read-Job([string]$id) {
  $f = Get-JobFile $id
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  for ($i = 0; $i -lt 5; $i++) {
    try { return (Get-Content -LiteralPath $f -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -DateKind String) } catch { Start-Sleep -Milliseconds 60 }
  }
  $null
}
function Write-JobRaw([hashtable]$job) {
  $f = Get-JobFile $job.id
  [IO.File]::WriteAllText("$f.tmp", ($job | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move("$f.tmp", $f, $true)
}
function Save-Job([hashtable]$job) { Invoke-JobLocked $job.id { Write-JobRaw $job } }
# Read-modify-write under the job mutex (job-start writes pid while job-run may already be finishing).
function Update-Job([string]$id, [hashtable]$set) {
  Invoke-JobLocked $id {
    $j = Read-Job $id
    if (-not $j) { $j = @{ id = $id } }
    foreach ($k in $set.Keys) { $j[$k] = $set[$k] }
    Write-JobRaw $j
  }
}
function Get-AllJobs {
  @(Get-ChildItem -LiteralPath (Get-JobDir) -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
      Read-Job $_.BaseName } | Where-Object { $_ })
}

# Same process as recorded? pidStart = StartTime UTC ticks; PIDs are recycled.
function Test-JobPidAlive([int]$procId, $startTicks) {
  if ($procId -le 0) { return $false }
  try { $p = Get-Process -Id $procId -ErrorAction Stop } catch { return $false }
  if ($startTicks) {
    try { return ([math]::Abs($p.StartTime.ToUniversalTime().Ticks - [long]$startTicks) -lt 30000000) } catch { return $true }
  }
  $true
}

function Open-JobShared([string]$path) {
  [IO.FileStream]::new($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
}
function Get-JobLogSize([string]$path) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return -1L }
  try { $fs = Open-JobShared $path; try { $fs.Length } finally { $fs.Dispose() } } catch { (Get-Item -LiteralPath $path).Length }
}
# Bytes [from, end) decoded as UTF-8 (a locked log is still readable: FileShare.ReadWrite).
function Read-JobLogFrom([string]$path, [long]$from) {
  if (-not (Test-Path -LiteralPath $path)) { return @{ text = ''; end = $from } }
  $fs = Open-JobShared $path
  try {
    if ($from -gt $fs.Length) { $from = 0 }
    $fs.Position = $from
    $n = [int][math]::Min($fs.Length - $from, 64MB)
    $buf = [byte[]]::new($n); $read = 0
    while ($read -lt $n) { $r = $fs.Read($buf, $read, $n - $read); if ($r -le 0) { break }; $read += $r }
    @{ text = [Text.Encoding]::UTF8.GetString($buf, 0, $read); end = $from + $read }
  } finally { $fs.Dispose() }
}
function Read-JobTail([string]$path, [int]$lines = 30) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return @() }
  $size = Get-JobLogSize $path
  $from = [math]::Max(0L, $size - 65536)
  $t = (Read-JobLogFrom $path $from).text
  $all = @($t -split "`r?`n")
  if ($all.Count -and $all[-1] -eq '') { $all = @($all | Select-Object -First ($all.Count - 1)) }
  @($all | Select-Object -Last $lines)
}
function Get-JobLogExit([string]$path) {
  $tail = Read-JobTail $path 20
  $hit = @($tail | Where-Object { $_ -match '^EXIT=(-?\d+)\s*$' } | Select-Object -Last 1)
  if ($hit.Count -and $hit[0] -match '^EXIT=(-?\d+)') { return [int]$Matches[1] }
  $null
}

# Computed view: state running|suspect|done|failed|killed|dead + runtime/lastOutput.
function Get-JobView([hashtable]$j, [double]$stallMin = 5) {
  $now = [DateTime]::UtcNow
  $started = ConvertTo-JobUtc $j['startedAt']
  $ended = ConvertTo-JobUtc $j['endedAt']
  $log = "$($j['log'])"
  $lastOut = $null
  if ($log -and (Test-Path -LiteralPath $log)) { $lastOut = (Get-Item -LiteralPath $log).LastWriteTimeUtc }
  $state = "$($j['state'])"
  $exit = $j['exitCode']
  if ($state -in 'running', 'starting') {
    $alive = Test-JobPidAlive ([int]$j['pid']) $j['pidStart']
    if (-not $alive) {
      $le = Get-JobLogExit $log
      if ($null -ne $le) { $exit = $le; $state = $(if ($le -eq 0) { 'done' } else { 'failed' }) }
      elseif ($state -eq 'starting' -and $started -and ($now - $started).TotalSeconds -lt 30) { $state = 'starting' }
      else { $state = 'dead' }
    } else {
      $exp = [double]$j['expectedMin']
      $runMin = if ($started) { ($now - $started).TotalMinutes } else { 0 }
      $quietMin = if ($lastOut) { ($now - $lastOut).TotalMinutes } elseif ($started) { $runMin } else { 0 }
      $state = if (($exp -gt 0 -and $runMin -gt 2 * $exp) -or $quietMin -gt $stallMin) { 'suspect' } else { 'running' }
    }
  }
  $endFor = if ($ended) { $ended } elseif ($state -in 'running', 'suspect', 'starting') { $now } elseif ($lastOut) { $lastOut } else { $now }
  [ordered]@{
    id = "$($j['id'])"; label = "$($j['label'])"; state = $state; exitCode = $exit
    runtimeMin = $(if ($started) { [math]::Round(($endFor - $started).TotalMinutes, 1) } else { $null })
    expectedMin = $j['expectedMin']; lastOutputAt = $(if ($lastOut) { Get-JobIso $lastOut } else { $null })
    lastOutputAgeMin = $(if ($lastOut) { [math]::Round(($now - $lastOut).TotalMinutes, 1) } else { $null })
    log = $log; pid = $j['pid']; startedAt = $j['startedAt']; endedAt = $j['endedAt']
  }
}

# Process table once (pid -> object) + children map; used for trees and ancestry walks.
function Get-JobProcTable {
  $all = @(if ($IsWindows) { Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, KernelModeTime, UserModeTime, WorkingSetSize, CreationDate -ErrorAction SilentlyContinue }
  else {
    # same field names as Win32_Process (times in 100 ns units) so every reader stays OS-agnostic
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $pp = try { [int]$_.Parent.Id } catch { 0 }
        $k = try { [double]$_.PrivilegedProcessorTime.Ticks } catch { 0 }; $u = try { [double]$_.UserProcessorTime.Ticks } catch { 0 }
        [pscustomobject]@{ ProcessId = $_.Id; ParentProcessId = $pp; Name = $_.ProcessName; CommandLine = $_.CommandLine; KernelModeTime = $k; UserModeTime = $u; WorkingSetSize = $_.WorkingSet64; CreationDate = $(try { $_.StartTime } catch { $null }) }
      }
  })
  $byId = @{}; $kids = @{}
  foreach ($p in $all) {
    $byId[[int]$p.ProcessId] = $p
    $pp = [int]$p.ParentProcessId
    if (-not $kids.ContainsKey($pp)) { $kids[$pp] = [Collections.Generic.List[object]]::new() }
    $kids[$pp].Add($p)
  }
  @{ byId = $byId; kids = $kids }
}
function Get-JobDescendants([int]$root, $table) {
  $out = [Collections.Generic.List[object]]::new()
  $stack = [Collections.Generic.Stack[object]]::new(); $stack.Push(@($root, 0)); $seen = @{}
  while ($stack.Count) {
    $e = $stack.Pop(); $id = [int]$e[0]; $depth = [int]$e[1]
    if ($seen.ContainsKey($id)) { continue }; $seen[$id] = 1
    $p = $table.byId[$id]
    if ($p) { $out.Add([pscustomobject]@{ depth = $depth; proc = $p }) }
    if ($table.kids.ContainsKey($id)) { foreach ($c in $table.kids[$id]) { if ([int]$c.ProcessId -ne $id) { $stack.Push(@([int]$c.ProcessId, ($depth + 1))) } } }
  }
  $out
}
function Format-JobTree([int]$root) {
  $t = Get-JobProcTable
  if (-not $t.byId.ContainsKey($root)) { return @("  (pid $root is not running)") }
  @(Get-JobDescendants $root $t | ForEach-Object {
      $p = $_.proc
      $cpu = [math]::Round(([double]$p.KernelModeTime + [double]$p.UserModeTime) / 1e7, 1)
      $ws = [math]::Round([double]$p.WorkingSetSize / 1MB)
      $cl = "$($p.CommandLine)"; if ($cl.Length -gt 140) { $cl = $cl.Substring(0, 140) + '...' }
      [string]::Format([Globalization.CultureInfo]::InvariantCulture, '  {0}{1} {2} cpu={3}s ws={4}MB  {5}', ('  ' * $_.depth), $p.ProcessId, $p.Name, $cpu, $ws, $cl)
    })
}

# Shape mirrored to the hub (contract: id,label,command,cwd,repo,host,pid,state,exitCode,expectedMin,
# startedAt,endedAt,lastOutputAt,log). command <= 500 chars; never env values.
function Get-JobsForSync([int]$days = 7) {
  $cut = [DateTime]::UtcNow.AddDays(-$days)
  @(foreach ($j in Get-AllJobs) {
      $st = ConvertTo-JobUtc $j['startedAt']
      if ($st -and $st -lt $cut) { continue }
      $v = Get-JobView $j
      $cmd = "$($j['command'])"; if ($cmd.Length -gt 500) { $cmd = $cmd.Substring(0, 500) }
      [ordered]@{
        id = "$($j['id'])"; label = "$($j['label'])"; command = $cmd; cwd = "$($j['cwd'])"; repo = "$($j['repo'])"; host = "$($j['host'])"
        pid = [int]$j['pid']; state = $v.state; exitCode = $v.exitCode; expectedMin = $j['expectedMin']
        startedAt = $j['startedAt']; endedAt = $j['endedAt']; lastOutputAt = $v.lastOutputAt; log = "$($j['log'])"
      }
    })
}
