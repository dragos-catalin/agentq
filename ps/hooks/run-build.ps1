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
    run-build.ps1 -Class scripts -Command 'node scripts/check-x.mjs'  # own resource, quick lane
    run-build.ps1 -Plan -Class scripts -Command 'pnpm exec eslint .'   # print the class plan, run nothing
    run-build.ps1 -Status          # who holds the lock, where is the log
    run-build.ps1 -Wait            # block until free, then run
    run-build.ps1 -Where cloud -Command 'pnpm build'   # place in the cloud (forwarded to agentq run)

.OUTPUTS
  Exit code of the build, or 3 if the lock was held and -Wait was not given.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
  [Parameter(ParameterSetName = 'Run', Mandatory)][string]$Command,
  [Parameter(ParameterSetName = 'Run')][switch]$Wait,
  # 240 (was 25): 58 of 71 agentq timeouts in 15 days were this default giving up on a busy queue
  # and dropping the place already earned (devcloud DC-014).
  [Parameter(ParameterSetName = 'Run')][int]$TimeoutMin = 240,
  # Node's default old-space is ~4 GB, and the heaviest project here (apps/web,
  # 5620 files) needs ~6 GB — so the DEFAULT is the real hazard, not generosity.
  # 8 GB clears that with margin while still bounding a runaway process; the
  # lock already prevents several of these existing at once.
  [Parameter(ParameterSetName = 'Run')][int]$HeapMb = 8192,
  # Shown to every other agent in `agentq status` / the journal. Default = the command.
  [Parameter(ParameterSetName = 'Run')][string]$Purpose,
  # agentq v3 lane: interactive|quick|gate|heavy|batch (default gate). batch runs at Idle CPU
  # priority, so higher lanes may run beside it (soft preemption).
  [Parameter(ParameterSetName = 'Run')][ValidateSet('interactive', 'quick', 'gate', 'heavy', 'batch')][string]$Lane = 'gate',
  # Second build RESOURCE (2026-11-21). `web` (default) = exactly today's behaviour: resource `build`,
  # the given -Lane. `scripts` = its own per-repo resource `build:<repo>:scripts` in the `quick` lane,
  # so a script-only change (lint / format / a check-*.mjs) does not sit behind a multi-minute web
  # build. A LANE cannot achieve that: a lane is priority only, and two tickets on `build:<repo>`
  # still serialise at capacity 1.
  # Concurrency safety rests ENTIRELY on the command allow-list checked below: the two classes may be
  # in one worktree at the same time, so a scripts build must never touch the outputs a web build owns.
  # Deliberately NOT in a parameter set, so `-Status -Class scripts` also works.
  [ValidateSet('web', 'scripts')][string]$Class = 'web',
  [Parameter(ParameterSetName = 'Run')][int]$Priority = 0,
  # Cloud placement (devcloud F2, DC-037): local|cloud|auto, forwarded verbatim to
  # `agentq run -Where`. Unset ($null) forwards NOTHING, so agentq run keeps its own default
  # ($env:AGENTQ_WHERE, else local). When unset but AGENTQ_WHERE is present, that value is
  # forwarded instead, so a caller's placement intent survives run-build's re-entry into the queue.
  # A cloud run's real work is on a VM: it emits no LOCAL CPU and no output while it waits, so the
  # wedge watch below is disabled for it (a 0-output cloud wait is correct, not a wedge).
  [Parameter(ParameterSetName = 'Run')][ValidateSet('local', 'cloud', 'auto')][string]$Where,
  # Build log silent this long -> WEDGED marker on the agentq ticket (shown by `agentq status`) and
  # a console warning. Cleared when output resumes. 0 disables.
  [Parameter(ParameterSetName = 'Run')][double]$WedgeMin = 10,
  [Parameter(ParameterSetName = 'Status')][switch]$Status,
  # Print the class plan (resource / lane / lock / mutex) and exit 0 WITHOUT taking a ticket, locking
  # or running anything. Read-only: the suite asserts the class mapping through this rather than
  # queueing a real build:* ticket (which would block other agents).
  [switch]$Plan,
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

# The repo leaf agentq itself would use, so `build:<name>:scripts` names the same repo in every
# worktree of it (agentq's Get-RepoInfo derives the name the same way: the leaf of the parent of the
# git COMMON dir). A plain `Split-Path -Leaf $root` would name a leased slot `task-1` instead of
# `brivio`, giving each worktree a private queue and a journal entry outside the repo's group file.
function Get-RepoLeafName {
  param([string]$Root)
  $common = & git -C $Root rev-parse --path-format=absolute --git-common-dir 2>$null
  $common = "$common".Trim()
  if ($LASTEXITCODE -eq 0 -and $common -and (Test-Path -LiteralPath $common)) {
    $n = Split-Path (Split-Path ($common -replace '/', '\') -Parent) -Leaf
    if ($n) { return $n.ToLowerInvariant() }
  }
  # Not a git repo, an old git without --path-format, or a relative answer: the directory leaf.
  (Split-Path -Leaf $Root).ToLowerInvariant()
}

$root = Get-RepoRoot -Explicit $Root
$dir = Join-Path $root '.copilot-tmp'
$null = New-Item -ItemType Directory -Force -Path $dir -EA SilentlyContinue

# --- effective placement (devcloud DC-037) --------------------------------------------------------
# An explicit -Where wins; otherwise a caller's AGENTQ_WHERE is honoured (and forwarded on re-entry,
# so the intent survives). Neither set -> agentq run keeps its own default (env, else local).
$whereEff = if ($Where) { $Where } elseif ($env:AGENTQ_WHERE) { $env:AGENTQ_WHERE } else { $null }
# A cloud-bound run does its real work on a VM: it emits no LOCAL CPU and no output while it waits, so
# the wedge watch below would be a false positive by construction (measured 2026-11-26: a land
# pre-gate waited 10 min with 0 local output and was marked WEDGED while the cloud VM did the work).
# Skip the marker when placement is (or was requested as) cloud, or when agentq run resolved the child
# to cloud and exported AGENTQ_PLACEMENT. Env names are case-insensitive in PowerShell's -eq.
$cloudBound = ($whereEff -eq 'cloud') -or ($env:AGENTQ_PLACEMENT -eq 'cloud')

# --- build class -> resource / lane / lock / mutex (2026-11-21) --------------------------------
# `web` (the default) keeps TODAY'S behaviour name for name: resource `build`, lock `build.lock` and
# the very same mutex -- so nothing about an in-flight or habitual web build changes.
# `scripts` runs on its OWN per-repo resource `build:<repo>:scripts` in the `quick` lane, with its own
# lock file and its own mutex, so a script-only change no longer queues behind a multi-minute web
# build and the two classes cannot block each other inside one worktree.
# No agentq change is needed for the resource name: Resolve-Resource returns a 2+-colon string
# literally and Get-Capacity falls back to 1 for an unknown resource. Honest limit: agentq's
# Expand-Resources still adds `build:machine` to every `build:*` ticket, so a scripts build does count
# against the machine-wide cap -- the win is at the REPO level, where `build:<repo>` (cap 1) no longer
# serialises it against a web build.
$repoName = Get-RepoLeafName $root
$isScripts = ($Class -eq 'scripts')
$resource = if ($isScripts) { "build:$($repoName):scripts" } else { 'build' }
$laneEff = if ($isScripts) { 'quick' } else { $Lane }
$lockPath = Join-Path $dir $(if ($isScripts) { 'build-scripts.lock' } else { 'build.lock' })
# Per-repo, Global\ so it spans sessions, terminals and users -- not just this
# desktop. Name must be filesystem-independent, hence the character scrub.
$mutexName = "Global\brivio-build-$(($root -replace '[^A-Za-z0-9]', '_'))"
# Web keeps the mutex name it has always had; scripts gets its own so the two classes never serialise.
if ($isScripts) { $mutexName += '-scripts' }
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
  $sfx = if ($isScripts) { ' [scripts]' } else { '' }
  $l = Read-Lock
  if (-not (Test-LockAlive $l)) {
    if ($l) { Write-Host "STALE-LOCK    previous build (pid $($l.pid)) died; lock will be reclaimed" }
    else { Write-Host "FREE          no build running in $root$sfx" }
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
  Write-Host "BUSY          a build is running in $root$sfx"
  Write-Host "  command     $($l.command)"
  Write-Host "  session     $($l.session)"
  Write-Host "  pid         $($l.pid)   started $age min ago"
  Write-Host "  log         $($l.log)"
  Write-Host "Tail it instead of starting your own: Get-Content '$($l.log)' -Tail 40"
  return 3
}

if ($Status) { exit (Show-Status) }

# --- class plan and the scripts allow-list (2026-11-21) --------------------------------------------
# `-Class scripts` may run CONCURRENTLY with a web build in the SAME worktree -- that is the whole
# point of a second resource -- and the ONLY thing that makes that safe is this allow-list: a scripts
# build must never write `.next`, `.turbo` or `*.tsbuildinfo`, the build outputs a web build owns and
# mutates. So it takes a command that starts with `node` (a check script such as scripts/check-*.mjs)
# or a formatter/linter through pnpm (`pnpm exec prettier|eslint|oxlint`). Anything else is refused
# HERE, before a ticket is taken: a queued build that must not run is worse than a refusal.
if ($isScripts -and -not ($Command -match '^\s*node(\s|$)' -or $Command -match '^\s*pnpm\s+exec\s+(prettier|eslint|oxlint)(\s|$)')) {
  [Console]::Error.WriteLine("run-build.ps1 -Class scripts REFUSES this command: $Command")
  [Console]::Error.WriteLine('  A scripts-class build runs BESIDE a web build in the same repo, so it must not touch the')
  [Console]::Error.WriteLine('  outputs a web build owns (.next, .turbo, *.tsbuildinfo). Allowed: a command starting with')
  [Console]::Error.WriteLine("  'node', or 'pnpm exec prettier|eslint|oxlint'. Use -Class web (the default) for anything else.")
  exit 2
}
# -Plan: print the class mapping and exit 0 -- no ticket, no lock, no build. The suite asserts the
# mapping through this instead of queueing a real build:* ticket behind other agents.
if ($Plan) {
  Write-Host "plan: class=$Class resource=$resource lane=$laneEff"
  Write-Host "      lock=$lockPath"
  Write-Host "      mutex=$mutexName"
  Write-Host "      where=$(if ($whereEff) { $whereEff } else { 'default' })$(if ($cloudBound) { ' (cloud-bound: wedge watch disabled)' } else { '' })"
  exit 0
}

# ADR 0001: a build in a leased slot is activity for that lease (a queued 2 h build must not let
# the slot go stale). Cheap: one lease-dir scan, no agentq process.
$leaseDir = Join-Path $(if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }) 'leases'
foreach ($lf in Get-ChildItem $leaseDir -Recurse -Filter '*.json' -File -EA SilentlyContinue) {
  try { $lp = (Get-Content -LiteralPath $lf.FullName -Raw | ConvertFrom-Json).path; if ($lp -and ($root.TrimEnd('\') + '\').StartsWith($lp.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { [IO.File]::SetLastWriteTimeUtc("$($lf.FullName).hb", [DateTime]::UtcNow) } } catch { }
}

$sessionId = if ($env:AGENTQ_SESSION) { $env:AGENTQ_SESSION } elseif ($env:COPILOT_SESSION_ID) { $env:COPILOT_SESSION_ID.Substring(0, [Math]::Min(8, $env:COPILOT_SESSION_ID.Length)) } elseif ($env:COPILOT_AGENT_SESSION_ID) { $env:COPILOT_AGENT_SESSION_ID.Substring(0, [Math]::Min(8, $env:COPILOT_AGENT_SESSION_ID.Length)) } else { 'unknown' }

# --- agentq queue (2026-09-27) ------------------------------------------------
# Re-enter this script under `agentq run -Resource <class resource>` (`build` for web, or
# `build:<repo>:scripts` for scripts), unless we already hold it or agentq is missing (then fall back
# to the legacy lock only). AGENTQ_HELD is matched on the `build:` prefix, which covers both resources.
$agentq = Join-Path $env:USERPROFILE '.copilot\bin\agentq.ps1'
if ((Test-Path $agentq) -and ("$env:AGENTQ_HELD" -notmatch '(^|,)build:') -and -not $env:RUN_BUILD_NO_AGENTQ) {
  $why = if ($Purpose) { $Purpose } else { "build: $Command" }
  $self = @('-NoProfile', '-File', $PSCommandPath, '-Command', $Command, '-TimeoutMin', "$TimeoutMin", '-HeapMb', "$HeapMb", '-Wait', '-Lane', $laneEff, '-WedgeMin', "$WedgeMin", '-Class', $Class)
  if ($Root) { $self += @('-Root', $Root) }
  $aqArgs = @('-NoProfile', '-File', $agentq, 'run', '-Resource', $resource, '-Purpose', $why, '-TimeoutMin', "$TimeoutMin", '-Repo', $root, '-Lane', $laneEff, '-Priority', "$Priority")
  # Forward the caller's placement intent (explicit -Where, else AGENTQ_WHERE) so agentq run resolves
  # the queue placement instead of falling back to the `local` default.
  if ($whereEff) { $aqArgs += @('-Where', $whereEff) }
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
  # devcloud DC-032: self-hosted turbo remote cache (E:\gh\vmui\docs\devcloud\turbo-cache.md).
  # Only for turbo repos, never over a caller's own TURBO_TOKEN, off with RUN_BUILD_NO_REMOTE_CACHE=1.
  # The token is DPAPI-encrypted per user; it is never printed or written to the log.
  $rcCfg = Join-Path $HOME '.codai\turbo-remote.json'; $rcKey = Join-Path $HOME '.codai\turbo-remote.key'
  if (-not $env:TURBO_TOKEN -and -not $env:RUN_BUILD_NO_REMOTE_CACHE -and (Test-Path (Join-Path $root 'turbo.json')) -and (Test-Path $rcCfg) -and (Test-Path $rcKey)) {
    try {
      $rc = Get-Content $rcCfg -Raw | ConvertFrom-Json
      $sec = ConvertTo-SecureString ([IO.File]::ReadAllText($rcKey).Trim())
      $env:TURBO_TOKEN = [Net.NetworkCredential]::new('', $sec).Password
      $env:TURBO_API = $rc.api; $env:TURBO_TEAM = $rc.team
      Write-Host "turbo remote cache: $($rc.api) (team $($rc.team))" -ForegroundColor DarkGray
      "=== turbo remote cache $($rc.api)" | Add-Content $logPath -Encoding UTF8
    } catch { Write-Host "turbo remote cache skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow }
  }
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
  # $cpuClass, not $priority: PowerShell names are case-insensitive and [int]$Priority (agentq lane
  # priority) is a parameter, so assigning 'BelowNormal' to $priority threw a conversion error.
  $cpuClass = if ($env:RUN_BUILD_PRIORITY) { $env:RUN_BUILD_PRIORITY } elseif ($Lane -eq 'batch' -or $env:AGENTQ_LANE -eq 'batch') { 'Idle' } else { 'BelowNormal' }
  try { (Get-Process -Id $PID).PriorityClass = $cpuClass } catch { Write-Host "could not set priority $cpuClass : $_" -ForegroundColor DarkYellow }
  # 2>&1 keeps compiler diagnostics, which are the whole reason to read a log.
  # Wait on the PROCESS, not on its stdout pipe: a build that cold-starts a daemon
  # (Gradle, Kotlin, sccache) hands it the inherited pipe handle, so `| Tee-Object`
  # never sees EOF and run-build hung 3 h after a 103 s gate (titi, 2026-09-29).
  # cmd writes to a file; we stream that file to the console until cmd exits.
  $outFile = "$logPath.out"
  # Isolation (2026-10-12): -NoNewWindow shared the caller's console, so a Ctrl+C sent into a shared
  # VS Code terminal (another agent, a timed-out tool) reached cmd, which then hung forever at
  # "Terminate batch job (Y/N)?" holding the build queue. -WindowStyle Hidden gives the child its OWN
  # console (no foreign Ctrl+C), and stdin from an empty file means no prompt can ever block it.
  $stdinEmpty = Join-Path $dir 'stdin-empty.txt'
  if (-not (Test-Path -LiteralPath $stdinEmpty)) { [IO.File]::WriteAllText($stdinEmpty, '') }
  $proc = Start-Process -FilePath $env:ComSpec -ArgumentList '/d', '/s', '/c', "`"$Command 2>&1`"" -WindowStyle Hidden -PassThru -RedirectStandardOutput $outFile -RedirectStandardInput $stdinEmpty -WorkingDirectory (Get-Location).Path
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
  # Wedge watch: no new output for -WedgeMin -> <ticket>.wedged beside each agentq ticket we run
  # under (AGENTQ_TICKET_FILES, set by `agentq run`), so `agentq status` shows WEDGED for this holder.
  # Cloud-bound runs are exempt: a VM-side run legitimately emits no LOCAL output, so 0 output is not
  # a wedge. The marker is still written (and cleared on resume) for every local run.
  #
  # Silence alone is not a wedge for a LOCAL run either: one long compile (a single rustc/tsc
  # invocation) prints nothing for minutes while it burns CPU. So the watch also samples the child
  # process TREE and treats CPU progress as activity -- a wedge now needs silence AND a tree that has
  # burned no CPU since the previous sample. (Measured 2026-11-26.)
  $ticketFiles = @("$env:AGENTQ_TICKET_FILES" -split ';' | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
  # NOT set here: the silence clock starts AFTER the init tree discovery below. The FIRST
  # `Get-Process` sweep is the expensive one (measured 218 ms idle, 5-12 s under load) and it used to
  # run inside the clock, so a fresh, silent child started the loop with a quiet age of 5-30 s and the
  # verdict fired on the first iteration. (Measured 2026-11-26 on the wedge fixture.)
  $lastPos = 0L; $wedged = $false
  # CPU probe. Three measured traps (2026-11-26), each fatal if ignored:
  #  1. CIM is used NOWHERE. `Get-CimInstance Win32_Process ...KernelModeTime,UserModeTime` costs
  #     ~1190 ms AND returned FROZEN values for 3 consecutive probes while a child burned a core
  #     (0.484 -> 2.547 -> 2.547 -> 2.547). Worse, calling it from inside the watch blocked the wedge
  #     CLOCK itself: one loop iteration then took longer than -WedgeMin, so a burn child was falsely
  #     marked ('=== WEDGED' in the log, then 'quiet but working' 1.5 s later). `Process.Parent` is
  #     present on `Get-Process` objects, so the parent map needs no CIM at all.
  #  2. Sampling and DISCOVERY are separated, because their costs differ by three orders of magnitude
  #     and only one of them runs per probe:
  #       * CPU sample = `Get-Process -Id <pid>` over the handful of tree pids (1-4 ms).
  #       * Discovery = one `Get-Process` sweep (1352 processes: 218 ms idle, SECONDS under load).
  #     A sweep on EVERY probe stretched the loop to ~3 s per iteration and pushed the verdict from 3 s
  #     to ~7.5 s (measured: marker appeared at 7.5 s, `quietMin 0.1`), which is how a 13 s poll window
  #     failed. Discovery therefore runs at init and only when the sample looks flat -- never on a
  #     growing tree, where the verdict clock must stay tight.
  #  3. Clock shape: the baseline is taken BEFORE the loop; the interval is clamped to a THIRD of
  #     -WedgeMin (two windows always precede the verdict, else a 30 s probe with -WedgeMin 0.05 (3 s)
  #     never runs first); the FIRST window is discarded (a child's own startup burst is real CPU and
  #     read as 'working'); and the threshold is a RATIO of the window, not an absolute 0.25 s (which
  #     broke the moment the clamp shrank the window).
  # Env overrides exist so a fixture can drive both branches in seconds.
  $CpuProbeSec = if ($env:RUN_BUILD_CPU_PROBE_SEC) { [double]$env:RUN_BUILD_CPU_PROBE_SEC } else { 30 }
  if ($WedgeMin -gt 0) { $CpuProbeSec = [Math]::Min($CpuProbeSec, $WedgeMin * 60.0 / 3.0) }
  # 0.25 = 25 % of one core over the WHOLE window (a single-core spin reports ~0.5-1.0 of that ratio
  # on a box other builds are starving; an idle child ~0). The 0.2 floor keeps a very short window
  # from flagging ordinary timer noise.
  $CpuActiveRatio = if ($env:RUN_BUILD_CPU_ACTIVE_SEC) { [double]$env:RUN_BUILD_CPU_ACTIVE_SEC } else { 0.25 }
  # A discovery that is merely slow is worth a line in the build log: it is the only step that can
  # hide output, and a verdict that later needs explaining must be explainable from the log alone.
  $DiscoveryNoteMs = 250
  $tree = @{}
  $cpuPrimed = $false
  $quietNotedAt = [DateTime]::MinValue
  $windowSec = $CpuProbeSec
  # NOT $pId: PowerShell variable names are case-INsensitive and $PID is read-only, so
  # `foreach ($pId in ...)` aborts the whole script ("Cannot overwrite variable PID").
  function Update-TreePids {
    param([int]$Root, [hashtable]$Tree)
    # EXPENSIVE (a full get-Process sweep). Discovery only: call it on a flat sample, never on a
    # growing one, so the verdict clock stays tight exactly when it matters.
    $kids = @{}
    foreach ($x in @(Get-Process -ErrorAction SilentlyContinue)) {
      $xid = [int]$x.Id
      try { $par = $x.Parent; if ($par) { $parId = [int]$par.Id; if (-not $kids.ContainsKey($parId)) { $kids[$parId] = @() }; $kids[$parId] += $xid } } catch { }
    }
    $seen = @{}; $frontier = @($Root)
    for ($d = 0; $d -lt 6 -and $frontier.Count -gt 0; $d++) {
      $next = @()
      foreach ($procId in $frontier) {
        if ($seen.ContainsKey($procId)) { continue }
        $seen[$procId] = $true
        if (-not $Tree.ContainsKey($procId)) { $Tree[$procId] = 0.0 }
        if ($kids.ContainsKey($procId)) { $next += $kids[$procId] }
      }
      $frontier = $next
    }
  }
  function Get-TreeCpu {
    param([hashtable]$Tree)
    # CHEAP (1-4 ms): one Get-Process per tree pid. MONOTONIC per pid, so a pid never loses the CPU it
    # already burned and one that has disappeared keeps its last value instead of dropping the sum.
    $sum = 0.0
    foreach ($procId in @($Tree.Keys)) {
      $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
      if ($p) { try { $v = [double]$p.CPU; if ($v -gt $Tree[$procId]) { $Tree[$procId] = $v } } catch { } }
      $sum += $Tree[$procId]
    }
    return $sum
  }
  $treeSw = [Diagnostics.Stopwatch]::StartNew()
  Update-TreePids -Root ([int]$proc.Id) -Tree $tree
  $treeSw.Stop()
  $lastCpu = Get-TreeCpu -Tree $tree                         # baseline BEFORE the loop
  if ($treeSw.ElapsedMilliseconds -ge $DiscoveryNoteMs) { "=== tree discovery took $($treeSw.ElapsedMilliseconds) ms ($($tree.Count) pids)" | Add-Content $logPath -Encoding UTF8 }
  # The clock starts here: silence is only silence we actually watched for.
  # The sweep above is not watched time and is not counted. `$blindMs` keeps the same rule inside the
  # loop: a discovery is time the loop cannot see output, so it is SUBTRACTED from the silence instead
  # of resetting it. Resetting was the 2026-11-26 bug -- with a slow box the sweep outlasts the 5 s
  # spacing, discovery ran on EVERY flat probe, `lastGrowth` jumped on every one and the silence could
  # never reach `$WedgeMin`: no marker was ever written for an idle child (suite run 1: w5 Seen=False).
  $lastGrowth = [DateTime]::UtcNow
  $blindMs = 0L                                              # discovery time, excluded from the silence
  $lastCpuAt = [DateTime]::UtcNow                            # window 1 starts with the loop
  $nextDiscoveryAt = [DateTime]::UtcNow                      # first flat probe may discover
  while (-not $proc.WaitForExit(500)) {
    Send-NewOutput $outFile $logPath $pos
    $outGrew = $false; $cpuGrew = $false
    if ($pos.Value -ne $lastPos) { $lastPos = $pos.Value; $outGrew = $true }
    if (([DateTime]::UtcNow - $lastCpuAt).TotalSeconds -ge $CpuProbeSec) {
      $cpuSum = Get-TreeCpu -Tree $tree
      $cpuDelta = $cpuSum - $lastCpu
      $windowSec = ([DateTime]::UtcNow - $lastCpuAt).TotalSeconds
      # Window 1 is the child's own startup burst: take the delta, discard the verdict.
      if ($cpuPrimed) {
        if ($cpuDelta -ge [Math]::Max(0.2, $CpuActiveRatio * $windowSec)) { $cpuGrew = $true }
        else {
          # Flat sample: pay for discovery (a full sweep) -- but AT MOST one every 5 s, because the
          # sweep is the only expensive step left and running it on every flat probe pushed the verdict
          # from WedgeMin (3 s) to ~7.5 s, past the poll window of a loaded box.
          # A pid that appears mid-run must NOT count as growth. `.CPU` is LIFETIME cpu, so adding a
          # newly spawned child to the sum looks like a jump in this window -- but a spawn is
          # instantaneous and proves nothing. Treating it as growth REFRESHED lastGrowth and postponed
          # the verdict by seconds for a child that was genuinely idle: measured, an idle `node` child
          # was marked at +7.7 s instead of +3 s and the log carried the giveaway
          # `quiet but working (child CPU +0,0s in 1,1s)` -- a "growth" line with a zero delta.
          # Re-baseline instead: the NEXT window measures the new pid's real CPU, so a burning
          # grandchild is still caught (one window later), and a silent one is not excused.
          $nowDt = [DateTime]::UtcNow
          if ($nowDt -ge $nextDiscoveryAt) {
            $before = $tree.Count
            $discSw = [Diagnostics.Stopwatch]::StartNew()
            Update-TreePids -Root ([int]$proc.Id) -Tree $tree
            $discSw.Stop()
            # Spaced from the END of the sweep: a sweep that outlasts the spacing (measured 380-13 000 ms
            # under load) otherwise re-fires on the very next flat probe, back to back.
            $nextDiscoveryAt = [DateTime]::UtcNow.AddSeconds(5)
            if ($tree.Count -ne $before) { $cpuSum = Get-TreeCpu -Tree $tree }
            # A discovery is WORK, not silence: it takes 380-968 ms under load (measured), the loop is
            # blind to output while it runs, and on a fixture threshold (3 s) the sweep alone could push
            # quietAge past the limit and write '=== WEDGED' for a child that never stopped. So SUBTRACT
            # the blind time from the silence. Never reset the clock: resetting lets a slow box postpone
            # the verdict forever. The NEXT window still measures the new pids' real CPU, so a burning
            # grandchild is caught (one window later) and a silent one is not excused.
            $blindMs += $discSw.ElapsedMilliseconds
            if ($discSw.ElapsedMilliseconds -ge $DiscoveryNoteMs) { "=== tree discovery took $($discSw.ElapsedMilliseconds) ms ($($tree.Count) pids)" | Add-Content $logPath -Encoding UTF8 }
          }
        }
      } else { $cpuPrimed = $true }
      $lastCpu = $cpuSum; $lastCpuAt = [DateTime]::UtcNow
    }
    # Watched silence: wall time since the last growth, minus the time the loop spent blind in a
    # discovery. Computed before every verdict so the branch below reads exactly one number.
    $silentSec = ([DateTime]::UtcNow - $lastGrowth).TotalSeconds - ($blindMs / 1000.0)
    if ($outGrew -or $cpuGrew) {
      $lastGrowth = [DateTime]::UtcNow
      $blindMs = 0L
      if ($wedged) { $wedged = $false; foreach ($tf in $ticketFiles) { Remove-Item -LiteralPath "$tf.wedged" -Force -ErrorAction SilentlyContinue }; Write-Host 'build output resumed (WEDGED cleared)' -ForegroundColor DarkGray }
      elseif ($cpuGrew -and $WedgeMin -gt 0 -and ([DateTime]::UtcNow - $quietNotedAt).TotalMinutes -ge 2) {
        $quietNotedAt = [DateTime]::UtcNow
        # BOTH sinks, like the WEDGED line: the fixture and any log reader look at the FILE, a human
        # watches the console. A Write-Host alone is invisible to every log-based check.
        $msg = ("quiet but working (child CPU +{0:N1}s in {1:N1}s) - no output, not a wedge" -f $cpuDelta, $windowSec)
        Add-Content -LiteralPath $logPath -Value "$msg $(Get-Date -Format o)" -Encoding UTF8
        Write-Host $msg -ForegroundColor DarkGray
      }
    } elseif (-not $cloudBound -and -not $wedged -and $WedgeMin -gt 0 -and $silentSec -ge ($WedgeMin * 60.0)) {
      $wedged = $true
      $quiet = [math]::Round($silentSec / 60.0, 1)
      $w = @{ since = [DateTime]::UtcNow.ToString('o'); quietMin = $quiet; log = $logPath; pid = $proc.Id } | ConvertTo-Json -Compress
      foreach ($tf in $ticketFiles) { try { [IO.File]::WriteAllText("$tf.wedged", $w) } catch { } }
      "=== WEDGED: no output AND no child CPU for $quiet min (pid $($proc.Id)) $(Get-Date -Format o)" | Add-Content $logPath -Encoding UTF8
      Write-Host "WEDGED: build output silent AND the process tree idle for $quiet min (pid $($proc.Id)). Inspect: wait-job.ps1 -Log '$logPath' -Pid $($proc.Id)" -ForegroundColor Yellow
    }
  }
  Send-NewOutput $outFile $logPath $pos
  foreach ($tf in $ticketFiles) { Remove-Item -LiteralPath "$tf.wedged" -Force -ErrorAction SilentlyContinue }
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
