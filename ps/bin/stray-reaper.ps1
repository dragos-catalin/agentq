<#
.SYNOPSIS
  Reap the scratch folders and temp files agents (and their tools) leave scattered on this machine.

.WHY THIS EXISTS
  Agents that cannot get an agentq slot clone a repo by hand "somewhere convenient" - in practice a
  drive root (D:\dsc0065, D:\gwlazy, ...) or a temp dir. Tool defaults litter C:\temp, C:\tmp,
  C:\symcache and %TEMP%. Nothing ever cleaned them.

  Measured 2026-11-26 before the first run:
    - D:\ root ........ 18 hand-cloned scratch dirs, 12.3 GB (+ D:\.pnpm-store 2.4 GB, orphaned
                       because pnpm keeps ONE STORE PER DRIVE and no project lives on D: any more)
    - %TEMP% .......... 86 GB / 86 857 children, of which
                          35.5 GB = own_DEFAULT_<pid>.db   (session-store index copies, ~1 GB each)
                          11.1 GB = pytest-of-vladu
                          10.4 GB = brivio-lockcheck-*
                          10.3 GB = one GUID installer-extraction dir
      This is the standing remedy, modelled on dead-lease-reaper.ps1 and registered as the daily
      scheduled task codai-stray-reaper (04:50, launched through hidden-run.vbs so no console flashes).

.WHAT IT DELETES
  Only paths that are (a) matched by an explicit rule below, (b) older than that rule's age, and
  (c) not referenced by a live process (command line) and not blocked by a live process name.
  Everything else is reported, never touched.

  - Drive-root agent scratch dirs matching ^(dsc|gwlazy|scratch-) on EVERY fixed drive -> whole dir
  - Orphan pnpm stores at the roots listed in $pnpmStoreDrives                   -> whole dir
    (E:\.pnpm-store is the ACTIVE store and is never listed - see $pnpmStoreDrives)
  - C:\memories, C:\temp, C:\symcache                                        -> contents
  - E:\gh\.scratch (what scratch-dir.ps1 hands out), older than 3 days        -> whole entry
  - %TEMP% dirs and files by name pattern                                    -> whole entry
  - %TEMP% anything else older than -TempDays (default 2)                    -> whole entry

.WHAT IT ONLY NAMES (never deletes, in either mode)
  - A drive-root directory holding a .git and a package.json / pnpm-workspace.yaml (a hand-clone).
    Printed as a NOTE line; the drive list is derived, so H: and any drive added later are covered.

.PARAMETER Report
  List what would go, delete nothing. Safe to run any time.

.PARAMETER MinAgeHours
  Age floor for the named %TEMP% rules and the C:\ temp roots. Default 24.

.PARAMETER FastAgeHours
  Age floor for patterns that are certainly agent leaks and never hold live state. Default 12.

.PARAMETER TempDays
  Age floor for the generic %TEMP% catch-all, in days. Default 2. 0 disables the catch-all.

.EXAMPLE
  pwsh -NoProfile -File "$env:USERPROFILE\.copilot\bin\stray-reaper.ps1" -Report
#>
[CmdletBinding()]
param(
  [switch]$Report,
  [int]$MinAgeHours = 24,
  [int]$FastAgeHours = 12,
  [int]$TempDays = 2,
  [string]$Log = (Join-Path $env:USERPROFILE '.codai\coord\stray-reaper.log')
)

$ErrorActionPreference = 'Continue'
$now = Get-Date
$cutMin = $now.AddHours(-$MinAgeHours)
$cutFast = $now.AddHours(-$FastAgeHours)
$cutTemp = $now.AddDays(-$TempDays)

# The pnpm store is PER DRIVE. E:\.pnpm-store\v11 is the live one (`pnpm store path`); a store left
# on another drive root is orphaned only while no project lives there, so it is allowed but age-gated.
$pnpmStoreDrives = @('C:', 'D:')

$logDir = Split-Path -Parent $Log
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }
if ((Test-Path -LiteralPath $Log) -and ((Get-Item -LiteralPath $Log).Length -gt 2MB)) {
  # Best-effort on purpose. A reader holding the log - a tail, another agent's Get-Content, a
  # concurrent -Report run - makes Move-Item fail with "being used by another process"; that must
  # never abort a sweep on its way to deleting anything, and the only cost is the log keeping its
  # history one more day. Seen live 2026-11-27 (the sweep ran and freed 108.8 MB anyway).
  Move-Item -Force -LiteralPath $Log -Destination "$Log.1" -ErrorAction SilentlyContinue
}
$stamp = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssK'
Add-Content -LiteralPath $Log -Value "=== $stamp reaper start (pid $PID) mode=$(if ($Report) { 'report' } else { 'apply' }) minAge=${MinAgeHours}h fastAge=${FastAgeHours}h tempDays=${TempDays}"

# Live command lines ONCE, so we never delete a folder a process is sitting in. CIM is used only for
# the one-shot snapshot (its numbers are stale but the CommandLine text is what we need).
$liveCmd = @(
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine } | ForEach-Object { $_.CommandLine }
)
$liveTempCmd = @($liveCmd | Where-Object { $_ -match '(?i)temp' })
# Live process NAMES, for the few rules where a process uses a temp dir it never names on its own
# command line (pytest indexes into pytest-of-<user>, node maps node-compile-cache, ...).
$liveNames = @(Get-Process -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty ProcessName -Unique | ForEach-Object { $_.ToLowerInvariant() })

# One escaped alternation per pool. Matching each of %TEMP%'s 86 821 entries against every command
# line with -like cost minutes of CPU (measured 2026-11-26); a single compiled Regex is one pass over
# the pool instead of N -like calls, and building it once takes milliseconds.
function New-CmdRegex([string[]]$cmds) {
  if (-not $cmds -or $cmds.Count -eq 0) { return $null }
  $sb = [System.Text.StringBuilder]::new()
  foreach ($c in $cmds) {
    if ($sb.Length -gt 0) { [void]$sb.Append('|') }
    [void]$sb.Append([regex]::Escape($c))
  }
  try { return [regex]::new($sb.ToString()) } catch { return $null }
}
$rxLiveCmd = New-CmdRegex $liveCmd
$rxLiveTempCmd = New-CmdRegex $liveTempCmd

function Test-InUse([string]$path) {
  $needle = $path.TrimEnd('\')
  # Only the temp pool for a %TEMP% path: a command line that never mentions "temp" cannot be
  # sitting in one, and the full pool is hundreds of entries wide.
  $rx = if ($needle -match '(?i)\\temp\\') { $rxLiveTempCmd } else { $rxLiveCmd }
  if (-not $rx) { return $false }
  return $rx.IsMatch($needle)
}

# A rule blocks itself while any of these process names is live: the process owns the temp entry in a
# way its command line does not reveal, so age alone is not evidence enough.
function Test-Blocked([string[]]$blockedBy) {
  if (-not $blockedBy) { return $false }
  foreach ($b in $blockedBy) { if ($liveNames -contains $b.ToLowerInvariant()) { return $true } }
  return $false
}

# The owner of an own_DEFAULT_<pid>.db is written into its NAME, and its command line does not contain
# the path - so the in-use scan cannot tell a dead copy from the one the extension host is writing
# right now. Ask the OS about that pid instead of guessing: deleting the live copy would break the
# session that is running this reaper.
function Test-OwnerPidLive([string]$name) {
  if ($name -notmatch '_(\d+)\.db') { return $false }
  return [bool](Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue)
}

$script:freed = [long]0
$script:actions = New-Object System.Collections.Generic.List[string]
# Counted apart from the actions: a note is a sighting, not something this run did.
$script:notes = 0

# $Item is the FileSystemInfo the caller ALREADY has from its Get-ChildItem. Passing it avoids a
# second Get-Item syscall per entry, which on 86 821 entries is another ~90 s of the run.
function Remove-Junk([string]$path, [datetime]$cutoff, [string[]]$blockedBy, $Item) {
  $item = $Item
  if (-not $item) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
  }
  if (-not $item) { return }
  if ($item.LastWriteTime -gt $cutoff) { $script:actions.Add("SKIP   (recent)   $path"); return }
  if (Test-Blocked $blockedBy) { $script:actions.Add("SKIP   (proc live) $path"); return }
  if (Test-InUse $path) { $script:actions.Add("SKIP   (in use)   $path"); return }
  # Size with the .NET enumerator, not `Get-ChildItem -Recurse | Measure-Object`. %TEMP% holds 86 821
  # entries on this machine and the cmdlet pipeline costs ~3 ms per call, i.e. ~8 minutes of CPU per
  # run for numbers nobody reads twice (measured 2026-11-26). EnumerateFiles hands back FileInfo
  # objects whose Length is already filled in from the directory entry, so no per-file stat happens.
  $sz = 0
  if ($item.PSIsContainer) {
    try {
      $di = [System.IO.DirectoryInfo]::new($item.FullName)
      foreach ($f in $di.EnumerateFiles('*', [System.IO.SearchOption]::AllDirectories)) { $sz += $f.Length }
    } catch {}
  } else { $sz = $item.Length }
  if ($null -eq $sz) { $sz = 0 }
  if ($Report) { $script:actions.Add(("WOULD  {0,10:N1} MB  {1}" -f ($sz / 1MB), $path)) }
  else {
    try {
      Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
      # $script: is required: a bare $freed here would be a function-local copy and the summary
      # would always report 0 MB freed (observed on the first live run, 381 actions, "0,0 MB").
      $script:freed += $sz
      $script:actions.Add(("DEL    {0,10:N1} MB  {1}" -f ($sz / 1MB), $path))
    } catch { $script:actions.Add("FAIL              $path  :: $($_.Exception.Message)") }
  }
}

# Every fixed drive, not a hardcoded three: H: exists on this machine and a hand-clone parked there
# was simply invisible to this tool. Derived from the filesystem provider, so a drive added later is
# covered without anyone remembering to edit a list (the drive-root scans below share it).
$driveRoots = @(
  Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
    Where-Object { $_.Root -match '^[A-Za-z]:\\$' } |
    Select-Object -ExpandProperty Root
)
if (-not $driveRoots) { $driveRoots = @('C:\', 'D:\', 'E:\') }

# ---------------------------------------------------------------------------------------------
# 1. Drive-root scratch: agent hand-clones, orphan pnpm stores.
# ---------------------------------------------------------------------------------------------
foreach ($root in $driveRoots) {
  $drive = $root.TrimEnd('\')
  if (-not (Test-Path -LiteralPath $root)) { continue }
  Get-ChildItem -LiteralPath $root -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object {
      if ($_.Name -match '^(dsc|gwlazy|scratch-)') { return $true }
      if ($_.Name -eq '.pnpm-store') { return ($pnpmStoreDrives -contains $drive) }
      return $false
    } | ForEach-Object { Remove-Junk $_.FullName $cutMin @() $_ }
}

# 1b. Drive-root VISIBILITY. The matcher above knows three name prefixes, and widening it so that it
# can DELETE would put a real folder at a drive root at risk - so a hand-clone called anything else is
# invisible to this tool: 18 of them sat at D:\ on 2026-11-26 and were found by hand, not here. This
# pass only names them (never deletes, in either mode): a line in the log costs nothing, a stray
# 12 GB clone nobody knows about costs an hour of somebody's day.
foreach ($root in $driveRoots) {
  $drive = $root.TrimEnd('\')
  if (-not (Test-Path -LiteralPath $root)) { continue }
  Get-ChildItem -LiteralPath $root -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(dsc|gwlazy|scratch-)' -and $_.Name -ne '.pnpm-store' } |
    ForEach-Object {
      if ((Test-Path -LiteralPath (Join-Path $_.FullName '.git')) -and
        ((Test-Path -LiteralPath (Join-Path $_.FullName 'package.json')) -or
          (Test-Path -LiteralPath (Join-Path $_.FullName 'pnpm-workspace.yaml')))) {
        $script:notes++
        $script:actions.Add("NOTE   (looks like a hand-clone at the $drive root - NOT deleted) $($_.FullName)")
      }
    }
}

# 2. Known stray roots - delete their CONTENTS, not the dir itself (the dir may be a real tool default).
# E:\scratch is NOT the sanctioned E:\gh\.scratch (scratch-dir.ps1's): it is where an agent put a
# hand-clone of codai plus 15 990 gate files on 2026-11-25, 258 MB at a drive root. Contents only, so a
# recreated one is swept instead of accumulating.
foreach ($parent in @('C:\memories', 'C:\temp', 'C:\symcache', 'E:\scratch')) {
  if (-not (Test-Path -LiteralPath $parent)) { continue }
  Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Junk $_.FullName $cutMin @() $_ }
}

# 2b. The sanctioned scratch root handed out by scratch-dir.ps1. One predictable place instead of a
#     new folder per drive root; anything a session still needs is younger than the keep window.
if (Test-Path -LiteralPath 'E:\gh\.scratch') {
  Get-ChildItem -LiteralPath 'E:\gh\.scratch' -Force -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Junk $_.FullName $now.AddDays(-3) @() $_ }
}

# 2c. Worktree bookkeeping under E:\gh\.wt (measured 2026-11-27).
#     _orphans\ and _bundles\ are where agentq parks a slot's contents before it frees the slot: five
#     entries, 795 MB on 2026-11-27, the oldest from 23.11, none of which anything reads again. They
#     are deliberate backups, so the window is longer than the fast cut but not a week: the owner
#     chose three days on 2026-11-27 to let space come back sooner (the 519 MB mmo pair then ages out
#     on 29.11 instead of 03.12). Anything a live session still needs is younger than three days.
#     The second pass only NAMES a slot directory that is not a git worktree, and must never delete
#     one. E:\gh\.wt\codai\scratch-6 had no .git at all, 3 426 entries, and its newest file had been
#     written seconds earlier by a sibling chat staging a checkout into it. "git rev-parse fails" is
#     NOT evidence that a directory is dead - only an unanswered age is, and a directory that someone
#     is writing to has no age. The same lesson applies to a lease agentq refuses to release because
#     the worktree has "no valid HEAD": inspect the contents before calling it stale.
$wtRoot = 'E:\gh\.wt'
if (Test-Path -LiteralPath $wtRoot) {
  foreach ($sub in @('_orphans', '_bundles')) {
    $p = Join-Path $wtRoot $sub
    if (-not (Test-Path -LiteralPath $p)) { continue }
    Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue |
      ForEach-Object { Remove-Junk $_.FullName $now.AddDays(-3) @() $_ }
  }
  Get-ChildItem -LiteralPath $wtRoot -Force -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @('_orphans', '_bundles') } |
    ForEach-Object {
      $repo = $_.Name
      Get-ChildItem -LiteralPath $_.FullName -Force -Directory -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $_.FullName '.git')) } |
        ForEach-Object {
          # The directory's OWN LastWriteTime, never a recursive walk: a leased slot holds a full
          # working tree (node_modules and target/), so one -Recurse per slot would cost minutes a
          # night for a note nobody deletes anything from. NTFS moves the parent's stamp when a direct
          # child is added or removed, which is all this pass needs as a liveness proxy - and a false
          # NOTE costs one log line, which is why the pass is not allowed to delete.
          if ($_.LastWriteTime -lt $now.AddHours(-6)) {
            $script:notes++
            $script:actions.Add("NOTE   (not a git worktree, dir untouched for 6 h - a dead slot directory, NOT deleted) $repo\$($_.Name)")
          }
        }
    }
}

# ---------------------------------------------------------------------------------------------
# 3. %TEMP%: named rules first, then a generic age catch-all for everything else.
#    Every named rule records WHY it exists; do not add one without that reason.
# ---------------------------------------------------------------------------------------------
$tempDirRules = @(
  # whole-tree git archive / lock-check / store leaks from the brivio gates (1-2 GB each)
  @{ P = '^brivio-head-'; H = $cutFast }
  @{ P = '^brivio-lockcheck-'; H = $cutFast }
  @{ P = '^brivio-clean-'; H = $cutFast }
  @{ P = '^brivio-store-'; H = $cutFast }
  # git pre-commit format-staged fixtures (hundreds per day, ~0 MB each)
  @{ P = '^pfs-'; H = $cutFast }
  # pytest session dirs: python holds a live one while it runs, hence the process guard
  @{ P = '^pytest-of-'; H = $cutMin; B = @('python', 'python3', 'pythonw', 'py', 'pytest', 'uv') }
  # per-repo agent scratch seen on this machine (frontiers c003, k2 waves, brivio dg-head, misc)
  @{ P = '^c003-'; H = $cutMin }
  @{ P = '^aqdbg-'; H = $cutMin }
  @{ P = '^k2'; H = $cutMin }
  @{ P = '^dg-head'; H = $cutMin }
  @{ P = '^fos-'; H = $cutMin }
  @{ P = '^caelia-tf-'; H = $cutMin }
  @{ P = '^tu-main-'; H = $cutMin }
  @{ P = '^wtv2-'; H = $cutMin }
  @{ P = '^depbump-'; H = $cutMin }
  @{ P = '^robolectric-'; H = $cutMin }
  # the Stop-hook unit suite (test-no-permission-stop.ps1) creates one dir per run and never removes
  # it: %TEMP% gained 1 115 empty `codai-stop-state-test-*` / `stoptest-*` dirs in 48 h (~250 runs a
  # day, because the config-integrity gate runs the suite inside every land/install gate). The suite
  # cleaning up after itself is the real fix; this rule stops the pile growing without bound until it
  # lands. A run lasts ~40 s, so 12 h cannot catch a live one.
  @{ P = '^codai-stop-state-test-\d+$'; H = $cutFast }
  @{ P = '^stoptest-\d+$'; H = $cutFast }
  # agentq's own install gate leaves one per run (test-agentq-prewarm-verb.ps1), same shape.
  @{ P = '^prewarm-verb-test-'; H = $cutFast }
  # every cloud placement writes its bundle/patch/spec under %TEMP%\agentq-cloud-<stamp>-<id> and
  # removes it at the end of the run (agentq-cloud.ps1:667), so a run killed by an exception, a
  # timeout or Ctrl+C leaves one behind: 64 dirs on 2026-11-27, 47 of them older than 12 h. The wait
  # loop keeps the directory for as long as the job runs, hence 24 h and not the fast cut. The real
  # fix belongs in the generator, which another session had modified within the same hour.
  @{ P = '^agentq-cloud-([0-9a-f]{6}|\d{8}-\d{6}-[0-9a-f]{6})$'; H = $cutMin }
  # the config-integrity gate's mutation harness (test-stop-mutations.ps1) copies itself, the
  # classifier and the hook into %TEMP%\stop-mutations-<8hex> and removes the sandbox at the end:
  # a run killed early leaves it (2026-11-27: two, both mine, while measuring the section's cost).
  # It sweeps its OWN leftovers only on entry and only older than 30 min, so a machine that stops
  # running the gate keeps them forever. 12 h cannot catch a live one: the whole suite is ~15 min.
  @{ P = '^stop-mutations-[0-9a-f]{8}$'; H = $cutFast }
  # codai's rl-guard mutation test (scripts/training/rl-guard/stop-rules.test.mjs:100) mkdtempSync's
  # one dir per run and never removes it: 21 dirs / ~700 files on 2026-11-27, one per local or CI
  # run of `node --test scripts/training/rl-guard/`. The real fix is one rmSync in an after() hook;
  # 12 h so a test run in flight is never touched.
  @{ P = '^stop-rules-mutant-'; H = $cutFast }
  @{ P = '^namirialsign$'; H = $cutMin }
  @{ P = '^ksmoke$'; H = $cutMin }
  @{ P = '^DiagOutputDir$'; H = $cutMin }
  # regenerated on demand, but a live node/java process maps them, so guard by name
  @{ P = '^node-compile-cache$'; H = $now.AddDays(-7); B = @('node', 'nodejs') }
  @{ P = '^hsperfdata_'; H = $now.AddDays(-7); B = @('java', 'javaw', 'jshell', 'gradle') }
  # installer / updater extraction caches
  # 7 days, not 3: a pending VS Code / Copilot update keeps its payload here for minutes, and the
  # current one cannot be told apart from an old one by name (only by age).
  @{ P = '^(GitHub Copilot-|vscode-insider-user-)'; H = $now.AddDays(-7) }
  @{ P = '^DockerDesktop'; H = $now.AddDays(-3); B = @('Docker Desktop', 'com.docker.backend', 'dockerd') }
  # bare GUID dirs are installer extractions (10.3 GB seen for one). 2 days, not 7: the contents are
  # never reused, and the 7-day window left 10.3 GB resident on a machine that needed the space.
  # Owner decision 2026-11-26.
  @{ P = '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-'; H = $now.AddDays(-2) }
)

# The session-store index is written to %TEMP% as own_DEFAULT_<pid>.db, ~1 GB per copy, and never
# removed: 35.5 GB in 43 files on 2026-11-26. The live index is in the extension's storage, not here.
$tempFileRules = @(
  @{ P = '^own_[A-Za-z0-9]+_\d+\.db(-wal|-shm)?$'; H = $cutFast; OwnerPid = $true }
  @{ P = '\.(cpuprofile|heapsnapshot)$'; H = $cutMin }
)

$covered = New-Object System.Collections.Generic.List[string]
$temp = $env:TEMP
if ($temp -and (Test-Path -LiteralPath $temp)) {
  $entries = Get-ChildItem -LiteralPath $temp -Force -ErrorAction SilentlyContinue
  foreach ($e in $entries) {
    $rules = if ($e.PSIsContainer) { $tempDirRules } else { $tempFileRules }
    $hit = $rules | Where-Object { $e.Name -match $_.P } | Select-Object -First 1
    if ($hit) {
      $covered.Add($e.Name)
      if ($hit.OwnerPid -and (Test-OwnerPidLive $e.Name)) {
        $script:actions.Add("SKIP   (owner pid live) $($e.Name)")
        continue
      }
      Remove-Junk $e.FullName $hit.H $hit.B $e
    } elseif ($TempDays -gt 0) {
      # Generic catch-all: nothing legitimate needs a >N-day-old temp entry, and this is the rule
      # that catches the NEXT agent's arbitrary folder name. Live-process guards still apply.
      $covered.Add($e.Name)
      Remove-Junk $e.FullName $cutTemp @() $e
    }
  }
}

# ---------------------------------------------------------------------------------------------
# 4. Repo-level .copilot-tmp scratch. This reaper only knew drive roots and %TEMP%, so 26 stale
#    trees totalling 3.8 GB sat inside E:\gh\<repo>\.copilot-tmp and were invisible to it (measured
#    2026-11-26; every agent leaves one there and few come back). Directories only, 14 days, and
#    never the five names that are state rather than scratch: jobs / build-logs / run-logs carry
#    job ids and the evidence for a run, and leases / space are the coordination and rescue roots.
#    Leased worktree slots are skipped entirely: agentq owns their lifetime, not this script.
# ---------------------------------------------------------------------------------------------
$keepTmp = @('jobs', 'build-logs', 'run-logs', 'lease', 'leases', 'space')
$cutRepo = $now.AddDays(-14)
Get-ChildItem -LiteralPath 'E:\gh' -Directory -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.Name -ne '.copilot-tmp' -and $_.Name -ne '.wt' -and $_.Name -ne '.scratch' } |
  ForEach-Object {
    $tmp = Join-Path $_.FullName '.copilot-tmp'
    if (-not (Test-Path -LiteralPath $tmp)) { return }
    Get-ChildItem -LiteralPath $tmp -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.Name -in $keepTmp) { return }
      if (Test-InUse $_.FullName) { $script:actions.Add("SKIP   (in use)      $($_.FullName)"); return }
      Remove-Junk $_.FullName $cutRepo @() $_
    }
  }

$script:actions | ForEach-Object { Add-Content -LiteralPath $Log -Value $_ }
$summary = "=== $stamp done: {0} action(s), {1:N1} MB freed ({2} temp entries considered); {3} drive-root note(s)" -f `
  ($script:actions.Count - $script:notes), ($script:freed / 1MB), $covered.Count, $script:notes
Add-Content -LiteralPath $Log -Value $summary
if ($Report) { $script:actions + $summary } else { $summary }
