<#
.SYNOPSIS
  Run a build under a cross-session lock, with output captured to a file.

.DESCRIPTION
  Measured on this machine: 231 pairs of sessions were active in brivio within
  5 minutes of each other (metu 97, mmo 93). Two turbo/tsc runs in one clone
  fight over the same .next, .turbo and tsbuildinfo, which produces corrupted
  incremental state and phantom errors that the second agent then "fixes".

  This serialises them. The lock is a file, so every session and every harness
  sees it -- an in-memory guard would not.

  Output always goes to a file. That is the point of the design: a later
  session can read the previous result instead of rebuilding, and a waiting
  session can tail the running build rather than guessing.

  Usage:
    run-build.ps1 -Command 'pnpm typecheck'
    run-build.ps1 -Command 'pnpm build' -TimeoutMin 30
    run-build.ps1 -Status          # who holds the lock, where is the log
    run-build.ps1 -Wait            # block until free, then run

.OUTPUTS
  Exit code of the build, or 3 if the lock was held and -Wait was not given.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
  [Parameter(ParameterSetName = 'Run', Mandatory)][string]$Command,
  [Parameter(ParameterSetName = 'Run')][switch]$Wait,
  [Parameter(ParameterSetName = 'Run')][int]$TimeoutMin = 25,
  # Node's default old-space is ~4 GB, and the heaviest project here (apps/web,
  # 5620 files) needs ~6 GB — so the DEFAULT is the real hazard, not generosity.
  # 8 GB clears that with margin while still bounding a runaway process; the
  # lock already prevents several of these existing at once.
  [Parameter(ParameterSetName = 'Run')][int]$HeapMb = 8192,
  # Shown to every other agent in `agentq status` / the journal. Default = the command.
  [Parameter(ParameterSetName = 'Run')][string]$Purpose,
  [Parameter(ParameterSetName = 'Status')][switch]$Status,
  [string]$Root
)

$ErrorActionPreference = 'Stop'

<#
  Two layers, deliberately:

  * the LOCK FILE is the readable one -- it records who, what and which log,
    so -Status can tell you where to look instead of just "busy";
  * the NAMED MUTEX is the enforceable one. The file only binds callers that
    route through this wrapper, and a command typed straight into a terminal
    ignores it. That is how two 8 GB typechecks on apps/web ended up running
    side by side and killed the extension host with a worker heap OOM.

  Global\ scope so it spans sessions and terminals, not just one desktop.
#>
function Get-RepoRoot {
  param([string]$Explicit)
  if ($Explicit) { return (Resolve-Path $Explicit).Path }
  $top = git rev-parse --show-toplevel 2>$null
  if ($LASTEXITCODE -eq 0 -and $top) { return $top.Replace('/', '\') }
  return (Get-Location).Path
}

$root = Get-RepoRoot -Explicit $Root
$dir = Join-Path $root '.copilot-tmp'
$null = New-Item -ItemType Directory -Force -Path $dir -EA SilentlyContinue
$lockPath = Join-Path $dir 'build.lock'
# Per-repo, Global\ so it spans sessions, terminals and users -- not just this
# desktop. Name must be filesystem-independent, hence the character scrub.
$mutexName = "Global\brivio-build-$(($root -replace '[^A-Za-z0-9]', '_'))"
$script:mutex = $null
$logDir = Join-Path $dir 'build-logs'
$null = New-Item -ItemType Directory -Force -Path $logDir -EA SilentlyContinue

function Read-Lock {
  if (-not (Test-Path $lockPath)) { return $null }
  try { return Get-Content $lockPath -Raw | ConvertFrom-Json } catch { return $null }
}

# ConvertFrom-Json revives an ISO-8601 string as a DateTime, and interpolating
# that back into a string yields the current culture's format, which
# [datetime]::Parse then rejects. Handle both shapes, culture-invariantly.
function ConvertTo-Utc {
  param($Value)
  if ($null -eq $Value) { return $null }
  if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
  $dt = [datetime]::MinValue
  $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
  if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt)) { return $dt }
  if ([datetime]::TryParse("$Value", [Globalization.CultureInfo]::CurrentCulture, $styles, [ref]$dt)) { return $dt }
  return $null
}

# A crashed build leaves the file behind, so liveness is decided by the PID,
# never by the file's existence.
function Test-LockAlive {
  param($Lock)
  if (-not $Lock) { return $false }
  if (-not $Lock.pid) { return $false }
  $p = Get-Process -Id $Lock.pid -EA SilentlyContinue
  if (-not $p) { return $false }
  # PIDs are recycled; the start time proves it is the same process.
  # ConvertFrom-Json revives an ISO-8601 string as a DateTime, so both sides
  # must be compared as DateTime -- string comparison here is always false and
  # silently declares every live build stale.
  if ($Lock.procStart) {
    try {
      $lockStart = ConvertTo-Utc $Lock.procStart
      # Sub-second jitter across serialisation round-trips; seconds is enough
      # to distinguish a recycled PID.
      if ($lockStart -and [math]::Abs(($p.StartTime.ToUniversalTime() - $lockStart).TotalSeconds) -gt 2) { return $false }
    } catch { }
  }
  return $true
}

function Show-Status {
  $l = Read-Lock
  if (-not (Test-LockAlive $l)) {
    if ($l) { Write-Host "STALE-LOCK    previous build (pid $($l.pid)) died; lock will be reclaimed" }
    else { Write-Host "FREE          no build running in $root" }
    $last = Get-ChildItem $logDir -Filter '*.log' -EA SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($last) {
      Write-Host "last log      $($last.FullName)"
      Write-Host "              finished $([math]::Round(((Get-Date) - $last.LastWriteTime).TotalMinutes,1)) min ago"
    }
    return 0
  }
  $started = ConvertTo-Utc $l.startedUtc
  $age = if ($started) { [math]::Round(((Get-Date).ToUniversalTime() - $started).TotalMinutes, 1) } else { '?' }
  Write-Host "BUSY          a build is running in $root"
  Write-Host "  command     $($l.command)"
  Write-Host "  session     $($l.session)"
  Write-Host "  pid         $($l.pid)   started $age min ago"
  Write-Host "  log         $($l.log)"
  Write-Host "Tail it instead of starting your own: Get-Content '$($l.log)' -Tail 40"
  return 3
}

if ($Status) { exit (Show-Status) }

$sessionId = if ($env:AGENTQ_SESSION) { $env:AGENTQ_SESSION } elseif ($env:COPILOT_SESSION_ID) { $env:COPILOT_SESSION_ID.Substring(0, [Math]::Min(8, $env:COPILOT_SESSION_ID.Length)) } else { 'unknown' }

# --- agentq queue (2026-09-27) ------------------------------------------------
# Re-enter this script under `agentq run -Resource build`, unless we already hold it
# (AGENTQ_HELD) or agentq is missing (then fall back to the legacy lock only).
$agentq = Join-Path $env:USERPROFILE '.copilot\bin\agentq.ps1'
if ((Test-Path $agentq) -and ("$env:AGENTQ_HELD" -notmatch '(^|,)build:') -and -not $env:RUN_BUILD_NO_AGENTQ) {
  $why = if ($Purpose) { $Purpose } else { "build: $Command" }
  $self = @('-NoProfile', '-File', $PSCommandPath, '-Command', $Command, '-TimeoutMin', "$TimeoutMin", '-HeapMb', "$HeapMb", '-Wait')
  if ($Root) { $self += @('-Root', $Root) }
  $aqArgs = @('-NoProfile', '-File', $agentq, 'run', '-Resource', 'build', '-Purpose', $why, '-TimeoutMin', "$TimeoutMin", '-Repo', $root)
  if (-not $Wait) { $aqArgs += '-NoWait' }
  & pwsh @aqArgs -- pwsh @self
  exit $LASTEXITCODE
}

# --- acquire -----------------------------------------------------------------
$deadline = (Get-Date).AddMinutes($TimeoutMin)
while ($true) {
  $existing = Read-Lock
  if (-not (Test-LockAlive $existing)) {
    if ($existing) { Write-Host "reclaiming stale lock from dead pid $($existing.pid)" -ForegroundColor DarkYellow }
    break
  }
  if (-not $Wait) {
    $null = Show-Status
    Write-Host ''
    Write-Host "Not starting a second build. Either wait (-Wait) or read the log above." -ForegroundColor Yellow
    exit 3
  }
  if ((Get-Date) -gt $deadline) {
    Write-Host "timed out after $TimeoutMin min waiting for the build lock" -ForegroundColor Red
    exit 3
  }
  Start-Sleep -Seconds 5
}

# The file check above is advisory. This is the part the OS enforces: a build
# started from a bare terminal holds the same mutex, so it cannot be raced.
$script:mutex = [System.Threading.Mutex]::new($false, $mutexName)
$waitMs = if ($Wait) { $TimeoutMin * 60 * 1000 } else { 0 }
try { $acquired = $script:mutex.WaitOne($waitMs) }
catch [System.Threading.AbandonedMutexException] {
  # Previous holder died without releasing. We now own it; that is recovery,
  # not an error.
  Write-Host 'recovered an abandoned build mutex' -ForegroundColor DarkYellow
  $acquired = $true
}
if (-not $acquired) {
  Write-Host 'Another build holds the system-wide lock for this repo.' -ForegroundColor Yellow
  Write-Host 'It may have been started outside this wrapper (a bare terminal).' -ForegroundColor DarkGray
  Write-Host "Wait for it, or re-run with -Wait." -ForegroundColor DarkGray
  $script:mutex.Dispose()
  exit 3
}

$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$slug = ($Command -replace '[^\w]+', '-').Trim('-')
if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40) }
$logPath = Join-Path $logDir "$stamp-$slug.log"

$me = Get-Process -Id $PID
@{
  pid        = $PID
  procStart  = $me.StartTime.ToUniversalTime().ToString('o')
  session    = $sessionId
  command    = $Command
  cwd        = $root
  log        = $logPath
  startedUtc = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Set-Content $lockPath -Encoding UTF8

# --- run ---------------------------------------------------------------------
$sw = [Diagnostics.Stopwatch]::StartNew()
try {
  Write-Host "build lock acquired  ->  $logPath" -ForegroundColor Green
  "=== $Command" | Set-Content $logPath -Encoding UTF8
  "=== cwd $root" | Add-Content $logPath -Encoding UTF8
  "=== session $sessionId  started $(Get-Date -Format o)" | Add-Content $logPath -Encoding UTF8
  "" | Add-Content $logPath -Encoding UTF8

  Push-Location $root
  # apps/web typechecks at ~6 GB. Left unbounded, V8 grows until the machine
  # (or a sibling worker thread) runs out, which is how the extension host was
  # killed with "Worker terminated ... JS heap out of memory". The lock keeps
  # builds sequential; this keeps a single one from taking everything.
  # Only set when the caller has not chosen a value.
  $prevNodeOptions = $env:NODE_OPTIONS
  if ($Command -notmatch 'max-old-space-size' -and $env:NODE_OPTIONS -notmatch 'max-old-space-size') {
    $env:NODE_OPTIONS = ("$($env:NODE_OPTIONS) --max-old-space-size=$HeapMb").Trim()
    Write-Host "heap capped at ${HeapMb} MB" -ForegroundColor DarkGray
  }
  # 2026-09-28: Gradle + tsc + cargo from several agents held all 32 cores at
  # 95 % at Normal priority -- the same class as explorer and the input path --
  # and the mouse cursor lagged until VS Code (and so its terminals) was killed.
  # Windows hands BELOW_NORMAL down to every child CreateProcess starts, so one
  # line here covers cmd, gradle, its Kotlin daemon, node, tsc, rustc. Builds
  # still use every idle cycle; they just lose to anything interactive.
  # RUN_BUILD_PRIORITY=Normal opts out (e.g. a timing measurement).
  $priority = if ($env:RUN_BUILD_PRIORITY) { $env:RUN_BUILD_PRIORITY } else { 'BelowNormal' }
  try { (Get-Process -Id $PID).PriorityClass = $priority } catch { Write-Host "could not set priority $priority : $_" -ForegroundColor DarkYellow }
  # 2>&1 keeps compiler diagnostics, which are the whole reason to read a log.
  # Wait on the PROCESS, not on its stdout pipe: a build that cold-starts a daemon
  # (Gradle, Kotlin, sccache) hands it the inherited pipe handle, so `| Tee-Object`
  # never sees EOF and run-build hung 3 h after a 103 s gate (titi, 2026-09-29).
  # cmd writes to a file; we stream that file to the console until cmd exits.
  $outFile = "$logPath.out"
  $proc = Start-Process -FilePath $env:ComSpec -ArgumentList '/d', '/s', '/c', "`"$Command 2>&1`"" -NoNewWindow -PassThru -RedirectStandardOutput $outFile -WorkingDirectory (Get-Location).Path
  $null = $proc.Handle # keep the handle so ExitCode is readable after exit
  $pos = [ref] 0L
  function Send-NewOutput([string] $src, [string] $dst, [ref] $at) {
    if (-not (Test-Path $src)) { return }
    $fs = [IO.File]::Open($src, 'Open', 'Read', 'ReadWrite')
    try {
      if ($fs.Length -le $at.Value) { return }
      $fs.Position = $at.Value
      $buf = New-Object byte[] ($fs.Length - $at.Value)
      $n = $fs.Read($buf, 0, $buf.Length)
      $at.Value += $n
      $chunk = [Text.Encoding]::UTF8.GetString($buf, 0, $n)
      [Console]::Out.Write($chunk); [IO.File]::AppendAllText($dst, $chunk)
    } finally { $fs.Dispose() }
  }
  while (-not $proc.WaitForExit(500)) { Send-NewOutput $outFile $logPath $pos }
  Send-NewOutput $outFile $logPath $pos
  Remove-Item $outFile -ErrorAction SilentlyContinue
  $code = $proc.ExitCode
  $env:NODE_OPTIONS = $prevNodeOptions
  Pop-Location

  $sw.Stop()
  "" | Add-Content $logPath -Encoding UTF8
  "=== exit $code after $([math]::Round($sw.Elapsed.TotalSeconds,1))s" | Add-Content $logPath -Encoding UTF8

  Write-Host ''
  if ($code -eq 0) {
    Write-Host "BUILD OK   $([math]::Round($sw.Elapsed.TotalSeconds,1))s   log: $logPath" -ForegroundColor Green
  } else {
    Write-Host "BUILD FAILED (exit $code)   log: $logPath" -ForegroundColor Red
    # Physical signal (yellow flash on the room bulb, card on the desk screen).
    $f = 'E:\gh\vmui\.private\credentials.env'
    if (Test-Path $f) {
      $tok = (Get-Content $f | Where-Object { $_ -match '^ESP_DISPLAY_TOKEN=' }) -replace '^ESP_DISPLAY_TOKEN=', ''
      $b = @{ event = 'failed'; text = "build exit $code"; source = 'build' } | ConvertTo-Json -Compress
      if ($tok) { try { Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:3737/api/copilot/event?k=$tok" -ContentType 'application/json' -Body $b -TimeoutSec 2 | Out-Null } catch { } }
    }
  }
  exit $code
}
finally {
  # Release even on Ctrl+C, or the next session inherits a phantom lock.
  Remove-Item $lockPath -Force -EA SilentlyContinue
  if ($script:mutex) {
    try { $script:mutex.ReleaseMutex() } catch { }
    $script:mutex.Dispose()
  }
}
