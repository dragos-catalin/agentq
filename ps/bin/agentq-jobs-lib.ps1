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
  # The label is display-only and the hub schema caps it at 200 (`agentqJobSchema.label`). A 220-char
  # label from a `run-all -Only <long list>` job rejected the WHOLE hub push with HTTP 400 and, because
  # the journal offset only advances on a successful push, the same row kept re-sending itself and froze
  # the mirror for hours (2026-11-22 16:57Z -> 22:33Z). Clamp at the one place every record passes through.
  if ($job['label'] -is [string] -and $job['label'].Length -gt 200) { $job['label'] = $job['label'].Substring(0, 200) }
  # expectedMin is a nullable INT in the hub schema (nullableInt(0, 100_000)): a fractional value from
  # 'job-start -ExpectedMin 0.1' 400s the whole push. Keep the record integral (a sub-minute estimate -> 1).
  $em = $job['expectedMin']
  if ($em -is [double] -or $em -is [decimal] -or $em -is [single]) { $job['expectedMin'] = [int][Math]::Ceiling([double]$em) }
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
# Parsed jobs are cached per file (mtime ticks + length) for the life of the dot-sourcing process: the
# resident agentq-sync loop re-read and re-parsed all ~600 registry files twice per 15 s tick (reap +
# mirror), ~8 s CPU per tick = 0.6 of a core forever (2026-11-20). Writes are atomic renames, so a changed
# job always changes the stamp. Callers get a shallow clone, so mutating a returned job never poisons the cache.
$script:JobParseCache = @{}
$script:JobRowCache = @{}
function Get-AllJobs {
  $files = @([IO.DirectoryInfo]::new((Get-JobDir)).GetFiles('*.json') | Sort-Object Name)
  $seen = [Collections.Generic.HashSet[string]]::new()
  $out = [Collections.Generic.List[object]]::new()
  foreach ($f in $files) {
    $k = $f.FullName; [void]$seen.Add($k)
    $stamp = "$($f.LastWriteTimeUtc.Ticks):$($f.Length)"
    $c = $script:JobParseCache[$k]
    if (-not $c -or $c.stamp -ne $stamp) {
      $j = Read-Job $f.BaseName
      if (-not $j) { $script:JobParseCache.Remove($k); continue }
      $c = @{ stamp = $stamp; job = $j }
      $script:JobParseCache[$k] = $c
    }
    $out.Add($c.job.Clone())
  }
  foreach ($k in @($script:JobParseCache.Keys)) { if (-not $seen.Contains($k)) { $script:JobParseCache.Remove($k) } }
  @($out)
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
  # A stored state outside this vocabulary - a hand-written 'stopped' in jobs/*.json, an older tool's
  # name - used to flow out verbatim. agentq-sync pushes jobs[].state into the gateway's
  # agentqPushSchema, which accepts exactly these six and rejects the WHOLE push with HTTP 400; the
  # sync offset only advances on success, so those rows re-sent forever and the hub mirror stayed dead
  # for 24 h on 2026-11-24/25 over five 'stopped' rows (gateway body: jobs[].state "Invalid option:
  # expected one of running|done|failed|killed|suspect|dead"). Normalise from the evidence already in
  # the row: 'starting' is a live job (the gateway's name for it is 'running'); a recorded, real exit
  # code decides done/failed; anything else never produced an outcome, and 'killed' still shows up as
  # needing attention in the hub, where a wrong 'done' would hide it.
  if ($state -eq 'starting') { $state = 'running' }
  elseif ($state -notin 'running', 'suspect', 'done', 'failed', 'killed', 'dead') {
    $state = if ($null -ne $exit -and [int]$exit -ge 0) { if ([int]$exit -eq 0) { 'done' } else { 'failed' } } else { 'killed' }
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

# Shape mirrored to the hub (contract: id,label,command,cwd,repo,host,placement,pid,state,exitCode,
# expectedMin,startedAt,endedAt,lastOutputAt,log). command <= 500 chars; never env values.
# placement = `cloud:<ws>` | `local` | `` and is written by the job that ran, never inferred: an empty
# value means unknown, so it must NOT be read as local, or a job that ran on a cloud workspace becomes
# indistinguishable from one that ran here (which is what /ops/agentq could not tell apart).
# The mirror is a WINDOW, not an archive: a 7-day backlog reached ~3000 rows on this machine and the
# gateway's schema rejected the WHOLE push (400 jobs>500) for a full day (2026-11-13), so the hub
# mirrored nothing. Keep every non-terminal job (the ones the hub can act on) and the newest
# terminal ones up to -max.
function Get-JobsForSync([int]$days = 7, [int]$max = 500) {
  $cut = [DateTime]::UtcNow.AddDays(-$days)
  $rows = [Collections.Generic.List[object]]::new()
  $keep = @{}
  foreach ($j in Get-AllJobs) {
    $st = ConvertTo-JobUtc $j['startedAt']
    if ($st -and $st -lt $cut) { continue }
    # A terminal job's view is fixed (no pid probe, log no longer written), so reuse it.
    $terminal = "$($j['state'])" -notin 'running', 'starting'
    $ck = "$($j['id'])|$($j['state'])|$($j['endedAt'])|$($j['exitCode'])|$($j['log'])"
    if ($terminal -and $script:JobRowCache.ContainsKey($ck)) { $rows.Add($script:JobRowCache[$ck]); $keep[$ck] = $script:JobRowCache[$ck]; continue }
    $v = Get-JobView $j
    $cmd = "$($j['command'])"; if ($cmd.Length -gt 500) { $cmd = $cmd.Substring(0, 500) }
    $entry = [pscustomobject]@{
      active  = ($v.state -in 'running', 'suspect', 'starting')
      started = $(if ($st) { $st } else { [DateTime]::MinValue })
      row     = [ordered]@{
        id = "$($j['id'])"; label = "$($j['label'])"; command = $cmd; cwd = "$($j['cwd'])"; repo = "$($j['repo'])"; host = "$($j['host'])"
        placement = "$($j['placement'])"; pid = [int]$j['pid']; state = $v.state; exitCode = $v.exitCode; expectedMin = $j['expectedMin']
        startedAt = $j['startedAt']; endedAt = $j['endedAt']; lastOutputAt = $v.lastOutputAt; log = "$($j['log'])"
      }
    }
    $rows.Add($entry)
    if ($terminal) { $keep[$ck] = $entry }
  }
  $script:JobRowCache = $keep
  $ordered = @($rows | Sort-Object -Property @{ Expression = 'active'; Descending = $true }, @{ Expression = 'started'; Descending = $true })
  if ($max -gt 0 -and $ordered.Count -gt $max) { $ordered = @($ordered[0..($max - 1)]) }
  @($ordered | ForEach-Object { $_.row })
}

# ---- prewarm hint (2026-11-25) ---------------------------------------------------------------------
# A cloud job submitted while its workspace is suspended pays the ~41 s `gcloud resume` at the worst
# moment: while an agent is already blocked on the queue, and with no warning anywhere in the job list.
# `jobs list` and `wait-job` are where an agent looks at cloud work just before submitting, so both print
# one line about it. Silent while the workspace is RUNNING - a hint that fires when everything is healthy
# is a hint agents learn to skip, and that silence is what makes the SUSPENDED case readable.
# One `gcloud describe` per workspace per 5 minutes, cached in the file the prewarm tool itself writes, so
# the two never hold different opinions about the same machine. No config or no gcloud on PATH = silent.
function Get-JobPrewarmConfig {
  $path = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $PSScriptRoot 'agentq-config.json' }
  $map = @{}; $reg = @{}
  try {
    if (Test-Path -LiteralPath $path) {
      $c = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
      if ($c.PSObject.Properties['cloudWorkspaces']) {
        foreach ($p in $c.cloudWorkspaces.PSObject.Properties) { $map["$($p.Name)"] = "$($p.Value)" }
      }
      if ($c.PSObject.Properties['cloudRegistry']) {
        foreach ($p in $c.cloudRegistry.PSObject.Properties) {
          $pv = $p.Value
          $reg["$($p.Name)"] = @{ project = "$($pv.project)"; zone = "$($pv.zone)" }
        }
      }
    }
  } catch { }
  @{ workspaces = $map; registry = $reg }
}
function Get-JobPrewarmVmStatus([string]$ws) {
  if (-not $ws) { return $null }
  $f = Join-Path (Join-Path (Get-JobCoordRoot) 'prewarm') "vmstate-$ws.json"
  $nowSec = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  # CACHE ONLY - see Get-PrewarmVmStatus in agentq.ps1 for the measurement behind this: a live
  # `gcloud instances describe` on this path made one suite run take 6 minutes instead of 52 seconds
  # (2026-11-25). prewarm-cloud.ps1 rewrites the file for every workspace on each tick; anything older
  # than 30 minutes is unknown, and unknown prints nothing.
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try {
    $c = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    $pa = $c.PSObject.Properties['atSec']; $ps = $c.PSObject.Properties['status']
    # StrictMode 3 makes a missing property an error, hence the property bag rather than $c.atSec.
    if ($pa -and $ps -and "$($ps.Value)" -and ($nowSec - [int64]$pa.Value) -lt 1800) { return "$($ps.Value)" }
  } catch { }
  $null
}
function Show-JobPrewarmHint([string]$repoName) {
  if (-not $repoName) { return }
  $ws = "$((Get-JobPrewarmConfig).workspaces[$repoName])"
  if (-not $ws) { return }
  if ((Get-JobPrewarmVmStatus $ws) -ne 'SUSPENDED') { return }
  Write-Output ''
  Write-Output "note: ws-$ws (where $repoName runs in the cloud) is SUSPENDED - the next cloud job pays ~41 s"
  Write-Output "      to resume it. Warm it now: agentq prewarm -Ws $ws"
}
