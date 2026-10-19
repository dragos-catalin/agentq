<#
agentq — cross-agent coordination for builds, deploys, installs and commits on this machine.

WHY: many agents share one clone (and its worktrees). Before this, every lock was
poll-and-race, per worktree, with no reason field and no shared history, so builds
corrupted each other's .next/.turbo, deploys raced, a commit swept another agent's
staged files, and nobody could see who held what or why (incidents 2026-09-03..27).

MODEL
  * A RESOURCE is a string: build:<repo>, build:machine (capacity 2), install:<repo>,
    commit:<repo>, deploy:<repo>:<target>, or anything you name. <repo> is the name of
    the COMMON git dir's parent, so every worktree of one repo shares its resources.
  * A TICKET is a waiter/holder: one JSON file per ticket in
    ~/.codai/coord/queues/<resource>/<seq>-<id>.json. FIFO order = seq, allocated under a
    named OS mutex (Global\agentq-<resource>) so two processes never get the same seq.
  * The first <capacity> live tickets in seq order HOLD the resource. The rest wait.
  * Liveness: holder pid + its process start time (PID-reuse safe) + a heartbeat file
    touched every 20 s by `run`. A dead pid is reaped at once; a heartbeat older than
    -StaleMin (default 10) marks the ticket STALE (visible in status, reason recorded);
    `agentq break` removes it with a reason.
  * A resource can be MARKED frozen|blocked with a reason (~/.codai/coord/marks/). `run`
    and `acquire` refuse a frozen/blocked resource and print who froze it and why.
  * Everything is appended to ~/.codai/coord/journal.jsonl (one JSON per line):
    queued, start, done(exit,dur), fail, break, mark, unmark, note, commit(sha,paths).
    `status`, `log`, `since` read it — this is how agents learn what others did.

COMMANDS (all accept -Repo <path>; default = current dir's repo. -ExpectRepo <path> or
          env AGENTQ_EXPECT_REPO refuses (exit 3) when the resolved repo differs — X-02)
  agentq run     -Resource build -Purpose "why" -- <command...>   queue, hold, run, release
                  -Resource may be a short kind (build|install|deploy:<target>|commit) —
                  expanded to <kind>:<repo>; build also takes build:machine (cap 2) and
                  waits for >= -MinFreeGB RAM (default 6).
  agentq commit  -Purpose "why" -Message "type(scope): msg" -Paths a,b [-NoPush]
                  under commit:<repo>: add+commit ONLY those paths, trailers
                  Agent-Session / Agent-Purpose, then fetch+merge+push with retry.
  agentq status  [-All]            holders, waiters, stale, marks (this repo or all)
  agentq log     [-Last 30] [-All] recent journal entries
  agentq since   [-Hours 12]       what changed in this repo: journal + git log
  agentq mark    -Resource R -State frozen|blocked -Reason "..."   (unmark: -State clear)
  agentq break   -Resource R [-Id <ticket>] -Reason "..."          remove a stale/stuck ticket
  agentq note    -Message "..."    free-form journal entry (handoffs, "don't touch X")
  agentq acquire / release         low-level (scripts): acquire prints the ticket id

v3 SCHEDULER (devcloud F1, 2026-10-11)
  -Lane interactive|quick|gate|heavy|batch  (build default gate, others quick); -Priority -50..50.
  Waiters are ranked by lane base + priority + bumps + aging (+5 per agingMin waited), not FIFO.
  All tickets of one run are granted ATOMICALLY: nothing is held while any part still waits, so
  waiting for build:machine no longer blocks build:<repo>. Soft slots on build:machine:
  quick/interactive get `quickBurst` extra slots; non-batch jobs may run beside batch holders
  (batch runs at Idle CPU). Idle-yield: a holder whose process tree burned < idleCpuSec over
  idleYieldMin stops counting against the machine cap until CPU returns.
  agentq bump    [-Id t] -By 20 -Reason "..."            raise my waiting ticket (cap bumpMax)
  agentq burst   [-Resource build:machine] -By 1 -Minutes 30 -Reason "..."  temporary extra slot
                  (refused when RAM/commit headroom < 2x the gate; cap burstMax/burstMaxMin)
  agentq propose [-Reason "..."]  diagnose my wait and APPLY safe remedies (break dead/STALE >2x
                  holders, bump my long waits, short burst when RAM allows); prints the rest
  Overrides need -Reason (>= 8 chars), are journaled and limited to overridesPerHour per session.
  agentq metrics [-Hours 24] [-Json]   wait/hold p50/p90 per resource x lane x kind
  agentq rotate                        archive journal now (sweep does it above journalRotateMB)
  Knobs: bin/agentq-config.json (machineCap quickBurst agingMin idleYieldMin idleCpuSec bumpMax
  burstMax burstMaxMin overridesPerHour journalRotateMB). Plan: E:\gh\vmui\docs\devcloud\PLAN.md

CLOUD PLACEMENT (devcloud F2, DC-037)
  agentq run -Resource build -Where local|cloud|auto [-Ws <name>] -Purpose x -- <cmd>
  cloud = run on the repo's warm workspace through agentq-cloud.ps1 (git delta upload, log stream,
  remote exit code; contract E:\gh\agentq\spec\job.md). No local tickets are taken.
  auto  = cloud when the repo has a workspace (config cloudWorkspaces) AND the command is a
  build/typecheck/test/lint kind AND (local build:machine is full, or free RAM/commit is below
  the gate, or the kind's local p50 hold >= cloudAutoMinSec). Otherwise local.
  Default = env AGENTQ_WHERE, else local. AGENTQ_WHERE=local is the opt-out everywhere.
  Journal: cloud-queued / cloud-done / cloud-fail (resource cloud:<ws>) + placement(where, why).

EXIT CODES: 0 ok; command's own exit code for `run`; 3 = frozen/blocked or timed out;
2 = usage error.
#>
# Hand-rolled argument parsing: `pwsh -File agentq.ps1 run ... -- cmd -x` passes `--` and
# the command's own dashed flags to the script, which PowerShell's binder rejects
# ("parameter name '' is ambiguous"). Everything after the first `--` is the command.
$Verb = 'status'; $Resource = $null; $Purpose = $null; $Message = $null; $Paths = @()
$Repo = $null; $ExpectRepo = $null; $State = $null; $Reason = $null; $Id = $null
$Capacity = 1; $TimeoutMin = 60; $StaleMin = 10; $Last = 30; $Hours = 12; $MinFreeGB = 6
$All = $false; $NoPush = $false; $NoWait = $false; $Json = $false; $CapacityGiven = $false
# v2 (ADR 0001): slots/leases, release runs, landing (implemented in agentq-v2.ps1).
$Slot = $null; $Role = $null; $WtPath = $null; $Branch = $null; $Onto = $null; $Gate = $null
$Phase = $null; $Unsafe = $false; $Target = $null; $Sha = $null; $Ref = $null; $Follow = $null
$RunId = $null; $OwnerPid = 0; $LeaseId = $null; $Also = @(); $Base = $null; $DoLand = $false; $Force = $false
# v3 (devcloud F1): lanes, priority, overrides, watchdog, metrics.
$Lane = $null; $Priority = 0; $By = 0; $Minutes = 30; $TimeoutGiven = $false
# devcloud F2: placement.
$Where = $null; $Ws = $null
$script:PreemptNote = ''; $script:WaitSec = 0; $script:CommitDone = $false
$Rest = @()
$argv = @($args)
$dd = [array]::IndexOf($argv, '--')
if ($dd -ge 0) { $Rest = @($argv | Select-Object -Skip ($dd + 1)); $argv = @($argv | Select-Object -First $dd) }
$i = 0
if ($argv.Count -and "$($argv[0])" -notlike '-*') { $Verb = "$($argv[0])"; $i = 1 }
while ($i -lt $argv.Count) {
  $a = "$($argv[$i])"
  $name = $a.TrimStart('-').ToLowerInvariant()
  $next = { if ($i + 1 -ge $argv.Count) { throw "agentq: $a needs a value" }; $script:i++; "$($argv[$script:i])" }
  switch ($name) {
    'resource' { $Resource = & $next }
    'purpose' { $Purpose = & $next }
    'message' { $Message = & $next }
    'paths' {
      # In-process '& agentq.ps1 -Paths $arr' delivers ONE arg "a b c" (or the array itself); a .ps1
      # wrapper with -File delivers "a,b". Accept all: commas first, then whitespace when no comma.
      $raw = @($argv[$i + 1]); if ($i + 1 -ge $argv.Count) { throw "agentq: $a needs a value" }; $script:i++
      $vals = @(); foreach ($r in $raw) { $vals += @("$r") }
      while ($i + 1 -lt $argv.Count -and "$($argv[$i + 1])" -notlike '-*') { $script:i++; $vals += "$($argv[$i])" }
      $Paths = @($vals | ForEach-Object { if ($_ -match ',') { $_ -split ',' } elseif ($_ -match '\s' -and -not (Test-Path -LiteralPath $_)) { $_ -split '\s+' } else { $_ } } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    'repo' { $Repo = & $next }
    'expectrepo' { $ExpectRepo = & $next }
    'state' { $State = & $next }
    'reason' { $Reason = & $next }
    'id' { $Id = & $next }
    'capacity' { $Capacity = [int](& $next); $CapacityGiven = $true }
    'timeoutmin' { $TimeoutMin = [int](& $next); $TimeoutGiven = $true }
    'stalemin' { $StaleMin = [int](& $next) }
    'last' { $Last = [int](& $next) }
    'hours' { $Hours = [double](& $next) }
    'minfreegb' { $MinFreeGB = [double](& $next) }
    'all' { $All = $true }
    'nopush' { $NoPush = $true }
    'nowait' { $NoWait = $true }
    'json' { $Json = $true }
    'slot' { $Slot = & $next }
    'role' { $Role = & $next }
    'path' { $WtPath = & $next }
    'branch' { $Branch = & $next }
    'onto' { $Onto = & $next }
    'gate' { $Gate = & $next }
    'phase' { $Phase = & $next }
    'unsafe' { $Unsafe = $true }
    'target' { $Target = & $next }
    'sha' { $Sha = & $next }
    'ref' { $Ref = & $next }
    'follow' { $Follow = & $next }
    'runid' { $RunId = & $next }
    'ownerpid' { $OwnerPid = [int](& $next) }
    'leaseid' { $LeaseId = & $next }
    'also' { $Also = @((& $next) -split ',' | Where-Object { $_ }) }
    'lane' { $Lane = (& $next).ToLowerInvariant() }
    'priority' { $Priority = [int](& $next) }
    'by' { $By = [int](& $next) }
    'minutes' { $Minutes = [int](& $next) }
    'where' { $Where = (& $next).ToLowerInvariant() }
    'base' { $Base = & $next }
    'land' { $DoLand = $true }
    'force' { $Force = $true }
    'ws' { $Ws = & $next }
    default {
      if ($Verb -and $Verb.ToLowerInvariant() -eq 'run' -and $a -notlike '-*') {
        throw "agentq: unknown argument '$a' - the command must follow '--'. In-process calls (& agentq.ps1 ... -- cmd) lose a bare -- in PowerShell: quote it as '--' or call 'pwsh -NoProfile -File agentq.ps1 ... -- cmd'."
      }
      throw "agentq: unknown argument '$a' (put the command after --)"
    }
  }
  $i++
}$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
$QDir = Join-Path $Root 'queues'
$MDir = Join-Path $Root 'marks'
$Journal = Join-Path $Root 'journal.jsonl'
foreach ($d in $Root, $QDir, $MDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }

# Machine-wide capacities for named resources (override with -Capacity on first use).
$DefaultCapacity = @{ 'build:machine' = 2 }

function Now { [DateTime]::UtcNow }
function Iso([datetime]$d) { $d.ToUniversalTime().ToString('o') }
# ISO strings from our own files are UTC; a bare [datetime] cast converts them to LOCAL time
# (3 h off here), which made every holder look dead/stale. Always parse through this.
function ParseUtc($s) { if ($s -is [datetime]) { return $s.ToUniversalTime() }; [DateTimeOffset]::Parse("$s", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }

function Get-SessionId {
  foreach ($v in $env:AGENTQ_SESSION, $env:COPILOT_SESSION_ID, $env:CLAUDE_SESSION_ID) { if ($v) { return $v } }
  # Stable per terminal: the parent shell pid. Get-Process .Parent costs ~20 ms; the CIM query it
  # replaced cost ~570 ms on EVERY agentq call (measured 2026-10-06).
  $pp = try { (Get-Process -Id $PID).Parent.Id } catch { 0 }
  "term-$pp"
}
$Session = Get-SessionId

function Get-RepoInfo([string]$path) {
  $p = if ($path) { $path } else { (Get-Location).Path }
  $top = (& git -C $p rev-parse --show-toplevel 2>$null)
  if (-not $top) { return $null }
  $common = (& git -C $p rev-parse --path-format=absolute --git-common-dir 2>$null)
  $name = Split-Path (Split-Path $common -Parent) -Leaf
  [pscustomobject]@{ Top = ($top -replace '/', '\'); Common = ($common -replace '/', '\'); Name = $name.ToLowerInvariant() }
}

# X-02 (2026-10-05): run_in_terminal sometimes DROPS a leading Set-Location, so a commit/build
# meant for a worktree ran in the shared clone (twice: brivio SW-0302, codai). -ExpectRepo <dir>
# (or env AGENTQ_EXPECT_REPO) refuses unless the resolved repo top equals it.
function Assert-ExpectedRepo($repo) {
  $want = if ($ExpectRepo) { $ExpectRepo } elseif ($env:AGENTQ_EXPECT_REPO) { $env:AGENTQ_EXPECT_REPO } else { $null }
  if (-not $want) { return }
  $w = (Get-RepoInfo $want)
  $wTop = if ($w) { $w.Top } else { $want }
  $norm = { param($p) ([IO.Path]::GetFullPath("$p").TrimEnd('\', '/')).ToLowerInvariant() }
  if (-not $repo -or (& $norm $repo.Top) -ne (& $norm $wTop)) {
    $got = if ($repo) { $repo.Top } else { '(no repo)' }
    [Console]::Error.WriteLine("agentq: REFUSED - expected repo '$wTop' but this runs in '$got' (cwd $((Get-Location).Path)). A dropped Set-Location? Pass -Repo '$wTop'.")
    exit 3
  }
}

function Resolve-Resource([string]$r, $repo) {
  if (-not $r) { throw 'agentq: -Resource is required' }
  if ($r -match ':') {
    # deploy:<target> (no repo) -> deploy:<repo>:<target>; anything with 2+ colons is literal.
    if ($r -match '^(deploy):([^:]+)$' -and $repo) { return "deploy:$($repo.Name):$($Matches[2])" }
    return $r.ToLowerInvariant()
  }
  if (-not $repo) { throw "agentq: '$r' needs a repo (run inside a git repo or pass -Repo)" }
  "$($r.ToLowerInvariant()):$($repo.Name)"
}

function Safe([string]$s) { ($s -replace '[^A-Za-z0-9._-]', '_') }
function QPath([string]$res) { Join-Path $QDir (Safe $res) }

function Write-Journal([hashtable]$e) {
  $e.ts = Iso (Now); if (-not $e.ContainsKey('session')) { $e.session = $Session }
  $line = ($e | ConvertTo-Json -Compress -Depth 6)
  $m = [Threading.Mutex]::new($false, "Global\agentq-journal$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  try { [void]$m.WaitOne(5000); [IO.File]::AppendAllText($Journal, $line + "`n", [Text.UTF8Encoding]::new($false)) }
  finally { try { $m.ReleaseMutex() } catch {} ; $m.Dispose() }
}

function Get-ProcStart([int]$procId) {
  try { (Get-Process -Id $procId -ErrorAction Stop).StartTime.ToUniversalTime() } catch { $null }
}

function Test-Alive($t) {
  $st = Get-ProcStart ([int]$t.pid)
  if (-not $st) { return $false }
  if ($t.procStart) { return ([math]::Abs(($st - (ParseUtc $t.procStart)).TotalSeconds) -lt 3) }
  $true
}

function Read-Tickets([string]$res) {
  $dir = QPath $res
  if (-not (Test-Path $dir)) { return @() }
  @(Get-ChildItem $dir -Filter '*.json' -File | Where-Object Name -ne 'adaptive.json' | Sort-Object Name | ForEach-Object {
      try {
        $raw = $null
        for ($r = 0; $r -lt 5; $r++) {
          try { $raw = Get-Content $_.FullName -Raw -ErrorAction Stop; if ($raw) { $raw | ConvertFrom-Json | Out-Null; break } } catch { $raw = $null }
          Start-Sleep -Milliseconds 50
        }
        if (-not $raw) {
          if (-not (Test-Path $_.FullName)) { return }  # released meanwhile
          # Fail closed: hold the slot with a placeholder that looks alive (pid = us).
          [pscustomobject]@{ id = "unreadable-$($_.BaseName)"; resource = $res; pid = $PID; procStart = $null; session = '?'; purpose = 'unreadable ticket'; created = (Iso (Now)); file = $_.FullName; beat = (Now) }
          return
        }
        $t = $raw | ConvertFrom-Json -DateKind String
        $t | Add-Member -NotePropertyName file -NotePropertyValue $_.FullName -Force
        $hb = "$($_.FullName).hb"
        $beat = if (Test-Path $hb) { (Get-Item $hb).LastWriteTimeUtc } else { (ParseUtc $t.created) }
        $t | Add-Member -NotePropertyName beat -NotePropertyValue $beat -Force
        $t
      } catch { $null }
    } | Where-Object { $_ })
}

function Remove-Ticket($t, [string]$why, [string]$kind = 'reap') {
  Remove-Item -LiteralPath $t.file, "$($t.file).hb", "$($t.file).wedged" -Force -ErrorAction SilentlyContinue
  Write-Journal @{ event = $kind; resource = $t.resource; ticket = $t.id; holderSession = $t.session; purpose = $t.purpose; reason = $why }
}

# Reap dead holders; flag stale ones. Returns live tickets in FIFO order.
function Get-Live([string]$res) {
  $out = @()
  foreach ($t in Read-Tickets $res) {
    if (-not (Test-Alive $t)) { Remove-Ticket $t "holder pid $($t.pid) is gone"; continue }
    $age = ((Now) - (ParseUtc $t.beat)).TotalMinutes
    $t | Add-Member -NotePropertyName stale -NotePropertyValue ($age -gt $StaleMin) -Force
    $t | Add-Member -NotePropertyName beatAgeMin -NotePropertyValue ([math]::Round($age, 1)) -Force
    $out += $t
  }
  $out
}

function Get-Capacity([string]$res) {
  # build:machine: config machineCap (+ an active, unexpired burst) wins over the sticky capacity
  # file, which is rewritten so the hub/sync readers see the effective value (DC-014).
  if ($res -eq 'build:machine') {
    $cap = (Get-AdaptiveMachineCap) + (Get-BurstExtra $res)
    $f = Join-Path (QPath $res) 'capacity'
    try { if (-not (Test-Path $f) -or [int](Get-Content $f -Raw) -ne $cap) { New-Item -ItemType Directory -Force (QPath $res) | Out-Null; [IO.File]::WriteAllText($f, "$cap") } } catch {}
    return $cap
  }
  $f = Join-Path (QPath $res) 'capacity'
  $base = if (Test-Path $f) { [int](Get-Content $f -Raw) } elseif ($DefaultCapacity.ContainsKey($res)) { $DefaultCapacity[$res] } else { 1 }
  $base + (Get-BurstExtra $res)
}

# Adaptive machine cap (S18-08, 2026-10-17). A fixed 2 left the i9 idle at night and saturated it
# during the day. Config `machineCapAdaptive` = { min, max, cpuHigh, cpuLow, minFreeRamGB,
# minFreeCommitGB, everySec }; absent -> the fixed machineCap. The decision is shared by every agentq
# process through queues/build_machine/adaptive.json and refreshed at most every `everySec`, because
# Get-Capacity runs on every 1.5 s poll. CPU is the AVERAGE since the previous refresh
# (raw perf-counter deltas), so a one-second spike cannot flap the cap. One step per refresh.
# Raw counter, not Add-Type GetSystemTimes: compiling the P/Invoke cost ~730 ms per agentq process
# and PerfFormattedData ~14 s under load (measured 2026-10-17); PerfRawData answers in ~33 ms.
# Raw PercentProcessorTime for _Total is cumulative IDLE time in 100 ns units.
function Get-SysTimes {
  $r = Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'" -Property PercentProcessorTime, Timestamp_Sys100NS
  @{ idle = [long]$r.PercentProcessorTime; total = [long]$r.Timestamp_Sys100NS }
}
function Get-AdaptiveMachineCap {
  $cfg = Get-Config
  $fixed = [int]$cfg.machineCap
  $a = if ($cfg.ContainsKey('machineCapAdaptive')) { $cfg['machineCapAdaptive'] } else { $null }
  if (-not $a) { return $fixed }
  # config is read -AsHashtable, and P() only sees object properties
  $H = { param($k, $d) if ($a.ContainsKey($k) -and $null -ne $a[$k]) { $a[$k] } else { $d } }
  function P($o, $k, $d) { & $H $k $d }
  $min = [int](P $a 'min' $fixed); $max = [int](P $a 'max' $fixed)
  if ($max -le $min) { return $min }
  $every = [double](P $a 'everySec' 15)
  $f = Join-Path (QPath 'build:machine') 'adaptive.json'
  $prev = $null
  try { if (Test-Path -LiteralPath $f) { $prev = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } } catch {}
  $now = Now
  $prevAt = $null
  if ($prev -and $prev.at) {
    $prevAt = if ($prev.at -is [datetime]) { $prev.at.ToUniversalTime() } else { try { [DateTime]::Parse("$($prev.at)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $null } }
  }
  if ($prevAt -and ($now - $prevAt).TotalSeconds -lt $every) {
    return [math]::Max($min, [math]::Min($max, [int]$prev.cap))
  }
  $m = [Threading.Mutex]::new($false, "Global\agentq-adaptive$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  $got = $false
  try {
    try { $got = $m.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { return $(if ($prev) { [math]::Max($min, [math]::Min($max, [int]$prev.cap)) } else { $min }) }
    $t = Get-SysTimes
    $cpu = $null
    if ($prev -and $prev.total -and ([long]$t.total - [long]$prev.total) -gt 0) {
      $dt = [double]([long]$t.total - [long]$prev.total); $di = [double]([long]$t.idle - [long]$prev.idle)
      $cpu = [math]::Round(100 * (1 - $di / $dt), 1)
    }
    $os = Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory, FreeVirtualMemory
    $ram = [math]::Round($os.FreePhysicalMemory / 1MB, 1); $commit = [math]::Round($os.FreeVirtualMemory / 1MB, 1)
    $cap = if ($prev -and $prev.cap) { [int]$prev.cap } else { $min }
    $why = 'hold'
    $memLow = ($ram -lt [double](P $a 'minFreeRamGB' 24)) -or ($commit -lt [double](P $a 'minFreeCommitGB' 24))
    if ($memLow) { $cap--; $why = "memory low (ram ${ram} GB, commit ${commit} GB)" }
    elseif ($null -ne $cpu -and $cpu -ge [double](P $a 'cpuHigh' 85)) { $cap--; $why = "cpu ${cpu}% >= high" }
    elseif ($null -ne $cpu -and $cpu -le [double](P $a 'cpuLow' 55)) { $cap++; $why = "cpu ${cpu}% <= low" }
    $cap = [math]::Max($min, [math]::Min($max, $cap))
    $rec = [ordered]@{ at = Iso $now; cap = $cap; cpu = $cpu; freeRamGB = $ram; freeCommitGB = $commit; why = $why; idle = $t.idle; total = $t.total; min = $min; max = $max }
    New-Item -ItemType Directory -Force (QPath 'build:machine') | Out-Null
    [IO.File]::WriteAllText("$f.tmp", ($rec | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)); Move-Item -Force "$f.tmp" $f
    if ($prev -and [int]$prev.cap -ne $cap) { Write-Journal @{ event = 'cap'; resource = 'build:machine'; from = [int]$prev.cap; to = $cap; reason = $why; cpu = $cpu; freeRamGB = $ram; freeCommitGB = $commit } }
    return $cap
  } catch { return $(if ($prev -and $prev.cap) { [int]$prev.cap } else { $fixed }) }
  finally { if ($got) { try { $m.ReleaseMutex() } catch {} }; $m.Dispose() }
}

# ---- v3 scheduling helpers (devcloud F1, DC-010..013) -----------------------------------
# P (property-or-default) is defined in agentq-v2.ps1, dot-sourced before any of this runs.
$LaneBase = [ordered]@{ interactive = 100; quick = 80; gate = 50; heavy = 30; batch = 10 }
function Resolve-Lane([string]$res, [string]$lane) {
  if ($lane) {
    if (-not $LaneBase.Contains($lane)) { throw "agentq: -Lane must be one of $($LaneBase.Keys -join '|')" }
    return $lane
  }
  if ($res -like 'build:*') { return 'gate' }
  'quick'
}
function BurstFile([string]$res) { Join-Path (QPath $res) 'burst.json' }
function Get-BurstExtra([string]$res) {
  $f = BurstFile $res
  if (-not (Test-Path $f)) { return 0 }
  try {
    $b = Get-Content $f -Raw | ConvertFrom-Json -DateKind String
    if ((ParseUtc $b.until) -gt (Now)) { return [int]$b.by }
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    Write-Journal @{ event = 'burst-expired'; resource = $res; reason = "$($b.reason)" }
  } catch {}
  0
}
# Effective priority = lane base + explicit -Priority + bumps + aging (+5 per AgingMin waited).
function Get-EffPrio($t) {
  $lane = "$(P $t 'lane' 'gate')"
  $base = if ($LaneBase.Contains($lane)) { $LaneBase[$lane] } else { 50 }
  $aging = [int](Get-Config).agingMin
  $waited = ((Now) - (ParseUtc $t.created)).TotalMinutes
  $age = if ($aging -gt 0) { 5 * [math]::Floor($waited / $aging) } else { 0 }
  $base + [int](P $t 'prio' 0) + [int](P $t 'bump' 0) + $age
}
# Legacy tickets (no `v`, written by agentq <= 0.2 during an install transition) hold by position.
function Test-Held($t, [object[]]$live, [int]$cap) {
  if (P $t 'v') { return [bool](P $t 'held' $false) }
  $legacy = @($live | Where-Object { -not (P $_ 'v') })
  [array]::IndexOf(@($legacy | ForEach-Object id), $t.id) -lt $cap
}
function Update-Ticket($t, [hashtable]$set) {
  $raw = Get-Content -LiteralPath $t.file -Raw | ConvertFrom-Json -AsHashtable
  foreach ($k in $set.Keys) { $raw[$k] = $set[$k] }
  [IO.File]::WriteAllText("$($t.file).tmp", ($raw | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move("$($t.file).tmp", $t.file, $true)
}
# Can ticket $t take a slot on its resource NOW? Returns @{ ok; why }.
function Test-Admissible($t, [scriptblock]$gate) {
  $live = @(Get-Live $t.resource)
  if (-not ($live | Where-Object id -eq $t.id)) { throw "agentq: ticket $($t.id) vanished from $($t.resource) (broken by another agent? see agentq log)" }
  $cap = Get-Capacity $t.resource
  # A holder whose process tree has been idle (idle-yield, DC-012) does not occupy a machine slot.
  $held = @($live | Where-Object { (Test-Held $_ $live $cap) -and -not ($t.resource -eq 'build:machine' -and (P $_ 'yielded' $false)) })
  $heldIds = @($live | Where-Object { Test-Held $_ $live $cap } | ForEach-Object { $_.id })
  # Waiters that cannot start anyway (blocked on another resource of the same run: ready=false)
  # do not reserve a slot here — backfill lets the next ready waiter use it (DC-013).
  $waiting = @($live | Where-Object { ($heldIds -notcontains $_.id) -and ($_.id -eq $t.id -or (P $_ 'ready' $true)) } |
      Sort-Object @{ e = { Get-EffPrio $_ }; Descending = $true }, @{ e = { [long]$_.seq } })
  $lane = "$(P $t 'lane' 'gate')"
  $rank = [array]::IndexOf(@($waiting | ForEach-Object id), $t.id)
  $ok = ($rank -ge 0 -and $rank -lt ($cap - $held.Count))
  if (-not $ok -and $t.resource -eq 'build:machine') {
    # Soft slots (DC-011): quick/interactive jobs get `quickBurst` extra slots so a 5 s lint never
    # waits behind two 30 min gates; any non-batch job may run beside a batch holder (batch runs at
    # Idle CPU priority, so it yields — that is the preemption). Ranked only among their peers.
    $c = Get-Config
    $heldBatch = @($held | Where-Object { "$(P $_ 'lane' 'gate')" -eq 'batch' }).Count
    if ($lane -in 'interactive', 'quick') {
      $peers = @($waiting | Where-Object { "$(P $_ 'lane' 'gate')" -in 'interactive', 'quick' })
      $r = [array]::IndexOf(@($peers | ForEach-Object id), $t.id)
      $burstUsed = [math]::Max(0, $held.Count - $cap)
      $ok = ($r -ge 0 -and $r -lt ([int]$c.quickBurst - $burstUsed))
      if ($ok) { $script:PreemptNote = 'quick burst slot' }
    }
    if (-not $ok -and $lane -ne 'batch' -and $heldBatch -gt 0) {
      $peers = @($waiting | Where-Object { "$(P $_ 'lane' 'gate')" -ne 'batch' })
      $r = [array]::IndexOf(@($peers | ForEach-Object id), $t.id)
      $ok = ($r -ge 0 -and ($held.Count - $heldBatch + $r) -lt $cap)
      if ($ok) { $script:PreemptNote = "beside $heldBatch batch holder(s)" }
    }
  }
  if (-not $ok) { return @{ ok = $false; why = 'queue'; live = $live; held = $held; cap = $cap; rank = $rank } }
  if ($gate -and -not (& $gate)) { return @{ ok = $false; why = 'ram'; live = $live; held = $held; cap = $cap; rank = $rank } }
  @{ ok = $true; why = ''; live = $live; held = $held; cap = $cap; rank = $rank }
}

function Get-Mark([string]$res) {
  $f = Join-Path $MDir ((Safe $res) + '.json')
  if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json -DateKind String } else { $null }
}

function Assert-NotMarked([string]$res) {
  $m = Get-Mark $res
  if ($m) {
    [Console]::Error.WriteLine("agentq: $res is $($m.state.ToUpper()) since $($m.at) by $($m.session): $($m.reason)")
    [Console]::Error.WriteLine("        clear it (only if the reason no longer holds): agentq mark -Resource $res -State clear -Reason '<why>'")
    exit 3
  }
}

function New-Ticket([string]$res, [string]$purpose, [string]$cmd, [string]$repoTop) {
  $dir = QPath $res
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  if ($script:CapacityGiven -or -not (Test-Path (Join-Path $dir 'capacity'))) {
    $cap = if ($script:Capacity -gt 1) { $script:Capacity } else { Get-Capacity $res }
    [IO.File]::WriteAllText((Join-Path $dir 'capacity'), "$cap")
  }
  $m = [Threading.Mutex]::new($false, "Global\agentq-$(Safe $res)$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  try {
    [void]$m.WaitOne(10000)
    $seqFile = Join-Path $dir 'seq'
    $seq = if (Test-Path $seqFile) { [long](Get-Content $seqFile -Raw) + 1 } else { 1 }
    # NOT `Set-Content -NoNewline <path> <v>`: in pwsh 7.6 that positional form writes NOTHING,
    # so seq never advanced, every ticket got seq 1 and two holders ran at once.
    [IO.File]::WriteAllText($seqFile, "$seq")
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    # The holder is the long-lived process: this pwsh running `agentq run` (it spawns and
    # waits for the command). For acquire/release from a script, pass the owning PID via
    # $env:AGENTQ_OWNER_PID.
    $owner = if ($env:AGENTQ_OWNER_PID) { [int]$env:AGENTQ_OWNER_PID } else { $PID }
    $t = [ordered]@{
      id = $id; seq = $seq; resource = $res; pid = $owner; procStart = (Iso (Get-ProcStart $owner))
      session = $Session; purpose = $purpose; cmd = $cmd; repo = $repoTop; host = $env:COMPUTERNAME
      created = (Iso (Now))
      # v3: priority scheduling. held flips true when the scheduler grants the slot; ready=false
      # while the same run is still blocked on another resource (backfill skips it).
      v = 3; lane = (Resolve-Lane $res $script:Lane); prio = [math]::Max(-50, [math]::Min(50, $script:Priority)); bump = 0
      held = $false; ready = $true
    }
    $file = Join-Path $dir ('{0:D8}-{1}.json' -f $seq, $id)
    # Atomic publish: a reader must never see a half-written ticket (it would parse-fail,
    # be skipped, and the next waiter would think it is first — observed as an overlap).
    [IO.File]::WriteAllText("$file.hb", '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText("$file.tmp", ($t | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move("$file.tmp", $file)
    [pscustomobject]$t | Add-Member -NotePropertyName file -NotePropertyValue $file -PassThru
  } finally { try { $m.ReleaseMutex() } catch {} ; $m.Dispose() }
}

# Acquire ALL tickets of one run atomically (DC-013): nothing is held while any part waits, so a
# run waiting for build:machine no longer blocks build:<repo> (96.5 h measured in 15 days).
# Check+grant happens under one machine-wide mutex so two runs never both take the last slot.
function Wait-All([object[]]$tickets, [hashtable]$gates, [int]$timeoutMin) {
  $deadline = (Now).AddMinutes($timeoutMin)
  $announced = [DateTime]::MinValue
  $ready = @{}; foreach ($t in $tickets) { $ready[$t.id] = $true }
  while ($true) {
    foreach ($t in $tickets) { Assert-NotMarked $t.resource; [IO.File]::SetLastWriteTimeUtc("$($t.file).hb", (Now)) }
    $m = [Threading.Mutex]::new($false, "Global\agentq-sched$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
    $granted = $false; $res = @{}
    try {
      try { [void]$m.WaitOne(15000) } catch [Threading.AbandonedMutexException] {}
      foreach ($t in $tickets) { $res[$t.id] = Test-Admissible $t $gates[$t.id] }
      $allOk = -not ($tickets | Where-Object { -not $res[$_.id].ok })
      if ($allOk) {
        foreach ($t in $tickets) { Update-Ticket $t @{ held = $true; ready = $true; acquired = (Iso (Now)) } }
        $granted = $true
      } else {
        # A ticket whose sibling is blocked is not ready: let others backfill past it.
        foreach ($t in $tickets) {
          $sib = @($tickets | Where-Object { $_.id -ne $t.id -and -not $res[$_.id].ok })
          $r = ($sib.Count -eq 0)
          if ($ready[$t.id] -ne $r) { Update-Ticket $t @{ ready = $r }; $ready[$t.id] = $r }
        }
      }
    } finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
    if ($granted) {
      $wait = [math]::Round(((Now) - (ParseUtc $tickets[0].created)).TotalSeconds)
      Write-Journal @{ event = 'acquired'; resource = (($tickets | ForEach-Object resource) -join ','); tickets = @($tickets | ForEach-Object id); lane = $tickets[0].lane; waitSec = $wait; purpose = $tickets[0].purpose; note = "$script:PreemptNote" }
      $script:WaitSec = $wait
      return
    }
    if (((Now) - $announced).TotalSeconds -ge 30) {
      $msgs = foreach ($t in $tickets) {
        $r = $res[$t.id]; if ($r.ok) { continue }
        $who = ($r.held | ForEach-Object { "$($_.session) '$($_.purpose)' [$(P $_ 'lane' '?')] $([math]::Round(((Now) - (ParseUtc $_.created)).TotalMinutes,1))m$(if ($_.stale) { ' STALE' })" }) -join '; '
        $why = if ($r.why -eq 'ram') { 'waiting for free RAM/commit' } else { "rank $($r.rank + 1) by priority, cap $($r.cap)" }
        "$($t.resource) [$($t.lane)] $why; held by: $who"
      }
      [Console]::Error.WriteLine("agentq: waiting — $($msgs -join ' | ')")
      [Console]::Error.WriteLine("        stuck? agentq propose -Reason '...' | agentq bump -By 20 -Reason '...' | agentq burst -Resource build:machine -Reason '...'")
      $announced = Now
    }
    if ((Now) -gt $deadline) {
      foreach ($t in $tickets) { Remove-Ticket $t "timed out after $timeoutMin min" 'timeout' }
      [Console]::Error.WriteLine("agentq: gave up waiting for $(($tickets | ForEach-Object resource) -join ',') after $timeoutMin min")
      exit 3
    }
    Start-Sleep -Milliseconds 1500
  }
}

function Wait-Turn($ticket, [int]$timeoutMin, [scriptblock]$extraGate, [object[]]$heldTickets = @()) {
  # Kept for single-resource callers (commit, land, acquire): now priority-aware via Wait-All.
  Wait-All @($ticket) @{ $ticket.id = $extraGate } $timeoutMin
}

function Test-FreeRam([double]$gb) {
  $os = Get-CimInstance Win32_OperatingSystem
  # Commit charge too: 2026-09-30 "memory allocation failed" with 50 GB RAM free because the commit
  # limit was exhausted (vmmemWSL). FreeVirtualMemory = commit limit - committed (KB).
  $commitGb = [double](Get-Config).minFreeCommitGB
  (($os.FreePhysicalMemory / 1MB) -ge $gb) -and ($gb -le 0 -or $commitGb -le 0 -or ($os.FreeVirtualMemory / 1MB) -ge $commitGb)
}

function Expand-Resources([string]$kind, $repo) {
  $primary = Resolve-Resource $kind $repo
  $list = @($primary)
  if ($primary -like 'build:*' -and $primary -ne 'build:machine') { $list += 'build:machine' }
  foreach ($a in $Also) { $list += (Resolve-Resource $a $repo) }
  $list
}

function Get-SignalUrl { 'http://127.0.0.1:3737/api/copilot/event' }

function Get-CmdKind([string]$c) {
  $s = "$c".ToLowerInvariant()
  switch -Regex ($s) {
    'playwright|e2e' { return 'e2e' }
    'gradle' { return 'gradle' }
    'cargo|rustc|clippy' { return 'cargo' }
    'next build' { return 'next-build' }
    'vitest|jest|pytest|\btest\b' { return 'test' }
    'typecheck|\btsc\b|tsgo' { return 'typecheck' }
    'lint|eslint|oxlint|biome|knip' { return 'lint' }
    '\.ps1' { return 'gate-script' }
    'build|tsdown|vite' { return 'build' }
    default { return 'other' }
  }
}

# ---- overrides (DC-011): every one needs -Reason, is journaled, capped and rate-limited ----
function Assert-OverrideBudget([string]$verb) {
  if (-not $Reason -or $Reason.Trim().Length -lt 8) { throw "agentq ${verb}: -Reason '<why, >= 8 chars>' is required (journaled; other agents read it)" }
  $limit = [int](Get-Config).overridesPerHour
  $mine = @(Read-Journal 400 ((Now).AddHours(-1)) $null | Where-Object { $_.event -in 'bump', 'burst', 'propose-applied' -and $_.session -eq $Session })
  if ($limit -gt 0 -and $mine.Count -ge $limit) { [Console]::Error.WriteLine("agentq: override budget spent ($($mine.Count)/$limit per hour for $Session). Ask the user, or wait."); exit 3 }
}
function Find-MyTickets {
  $out = @()
  foreach ($d in @(Get-ChildItem $QDir -Directory -ErrorAction SilentlyContinue)) {
    $sample = Get-ChildItem $d.FullName -Filter '*.json' -File | Where-Object Name -ne 'adaptive.json' | Select-Object -First 1
    if (-not $sample) { continue }
    $res = (Get-Content $sample.FullName -Raw | ConvertFrom-Json -DateKind String).resource
    $out += @(Get-Live $res | Where-Object { (-not $Id -and $_.session -eq $Session) -or ($Id -and $_.id -eq $Id) })
  }
  $out
}
function Invoke-Bump {
  Assert-OverrideBudget 'bump'
  $by = if ($By) { $By } else { 20 }
  $max = [int](Get-Config).bumpMax
  $mine = @(Find-MyTickets | Where-Object { -not (P $_ 'held' $false) })
  if (-not $mine) { [Console]::Error.WriteLine("agentq bump: no waiting ticket for session $Session$(if ($Id) { " / id $Id" }) (pass -Id <ticket>)"); exit 2 }
  foreach ($t in $mine) {
    $nb = [math]::Min($max, [int](P $t 'bump' 0) + $by)
    Update-Ticket $t @{ bump = $nb; bumpReason = $Reason }
    Write-Journal @{ event = 'bump'; resource = $t.resource; ticket = $t.id; by = $by; bump = $nb; reason = $Reason; purpose = $t.purpose }
    Write-Output "bumped $($t.id) on $($t.resource) to +$nb ($Reason)"
  }
}
function Invoke-Burst {
  Assert-OverrideBudget 'burst'
  if (-not $Resource) { $Resource = 'build:machine' }
  $res = Resolve-Resource $Resource (Get-RepoInfo $Repo)
  $c = Get-Config
  $by = [math]::Max(1, [math]::Min([int]$c.burstMax, $(if ($By) { $By } else { 1 })))
  $min = [math]::Max(1, [math]::Min([int]$c.burstMaxMin, $Minutes))
  if ($res -eq 'build:machine' -and -not (Test-FreeRam ([double]$MinFreeGB * 2))) {
    [Console]::Error.WriteLine("agentq burst: refused - less than $([double]$MinFreeGB * 2) GB RAM (or commit headroom) free; a burst would OOM the machine. Use -Where cloud when available."); exit 3
  }
  New-Item -ItemType Directory -Force (QPath $res) | Out-Null
  $b = [ordered]@{ resource = $res; by = $by; until = (Iso ((Now).AddMinutes($min))); reason = $Reason; session = $Session; at = (Iso (Now)) }
  [IO.File]::WriteAllText((BurstFile $res), ($b | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  Write-Journal @{ event = 'burst'; resource = $res; by = $by; minutes = $min; reason = $Reason }
  Write-Output "burst $res +$by for $min min ($Reason)"
}
# propose: diagnose why the caller waits and APPLY the safe remedy (break a dead/hung holder,
# bump a long waiter, or open a short burst when RAM allows). Unsafe remedies are printed only.
function Invoke-Propose {
  if (-not $Reason) { $Reason = 'propose: auto-remedy for a long wait' }
  $repo = Get-RepoInfo $Repo
  $c = Get-Config
  $actions = @()
  foreach ($res in @('build:machine') + @(if ($repo) { "build:$($repo.Name)", "commit:$($repo.Name)", "install:$($repo.Name)" })) {
    $live = @(Get-Live $res); if (-not $live) { continue }
    $cap = Get-Capacity $res
    foreach ($h in @($live | Where-Object { Test-Held $_ $live $cap })) {
      if ($h.stale -and $h.beatAgeMin -gt (2 * $StaleMin)) {
        Remove-Ticket $h "propose: heartbeat stale $($h.beatAgeMin) min ($Reason)" 'break'
        $actions += "broke STALE holder $($h.id) on $res ($($h.beatAgeMin) min)"
      }
    }
    $waiters = @($live | Where-Object { -not (Test-Held $_ $live $cap) })
    $mine = @($waiters | Where-Object session -eq $Session)
    foreach ($w in $mine) {
      $waitedMin = ((Now) - (ParseUtc $w.created)).TotalMinutes
      if ($waitedMin -ge 10 -and [int](P $w 'bump' 0) -lt 20) {
        Update-Ticket $w @{ bump = 20; bumpReason = "propose: waited $([math]::Round($waitedMin)) min" }
        $actions += "bumped own ticket $($w.id) on $res (+20, waited $([math]::Round($waitedMin)) min)"
      }
    }
    if ($res -eq 'build:machine' -and $mine -and -not (Test-Path (BurstFile $res)) -and (Test-FreeRam ([double]$MinFreeGB * 2))) {
      $b = [ordered]@{ resource = $res; by = 1; until = (Iso ((Now).AddMinutes(20))); reason = "propose: $Reason"; session = $Session; at = (Iso (Now)) }
      [IO.File]::WriteAllText((BurstFile $res), ($b | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
      $actions += 'opened burst build:machine +1 for 20 min (RAM headroom >= 2x gate)'
    }
  }
  if ($actions) {
    Write-Journal @{ event = 'propose-applied'; resource = 'agentq'; reason = $Reason; message = ($actions -join '; ') }
    $actions | ForEach-Object { Write-Output "applied: $_" }
  } else { Write-Output 'propose: nothing safe to apply (holders healthy, RAM below 2x gate, or no long wait). Consider -Where cloud or agentq bump -Reason.' }
}

# ---- metrics (DC-017): wait/hold distributions from the journal --------------------------
function Show-Metrics {
  $from = (Now).AddHours(-$Hours)
  $items = @(Read-Journal 0 $from $null | Where-Object { $_.event -in 'done', 'fail', 'cloud-done', 'cloud-fail' -and $_.PSObject.Properties['holdSec'] })
  $q = { param($a, [double]$p) if (-not $a) { return 0 }; $s = @($a | Sort-Object); $s[[math]::Min($s.Count - 1, [math]::Floor($p * $s.Count))] }
  $rows = $items | Group-Object { "{0}|{1}|{2}" -f ("$($_.resource)" -replace ',build:machine', ''), "$(P $_ 'lane' '?')", "$(P $_ 'kind' '?')" } | ForEach-Object {
    $w = @($_.Group | ForEach-Object { [double](P $_ 'waitSec' 0) }); $h = @($_.Group | ForEach-Object { [double]$_.holdSec })
    $k = $_.Name -split '\|'
    [pscustomobject]@{ resource = $k[0]; lane = $k[1]; kind = $k[2]; runs = $_.Count; fail = @($_.Group | Where-Object event -in 'fail', 'cloud-fail').Count
      waitP50 = (& $q $w 0.5); waitP90 = (& $q $w 0.9); holdP50 = (& $q $h 0.5); holdP90 = (& $q $h 0.9); holdMin = [math]::Round(($h | Measure-Object -Sum).Sum / 60, 1) }
  } | Sort-Object holdMin -Descending
  $ev = @(Read-Journal 0 $from $null | Where-Object { $_.event -in 'idle-yield', 'bump', 'burst', 'propose-applied', 'timeout', 'reap', 'break' } | Group-Object event | ForEach-Object { "$($_.Name)=$($_.Count)" })
  $res = @($items | Where-Object { $_.event -like 'cloud-*' -and $_.PSObject.Properties['resumeSec'] } | ForEach-Object { [double]$_.resumeSec })
  $cloud = if ($res) { "resumes=$($res.Count) resumeP50=$(& $q $res 0.5)s resumeMax=$(($res | Measure-Object -Maximum).Maximum)s" } else { 'resumes=0' }
  if ($Json) { @{ hours = $Hours; rows = @($rows); events = $ev; cloud = $cloud } | ConvertTo-Json -Depth 4; return }
  Write-Output "== agentq metrics, last $Hours h (seconds; v3 runs only)"
  if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output } else { Write-Output '(no v3 runs yet)' }
  Write-Output "== scheduler events: $(if ($ev) { $ev -join ' ' } else { 'none' })"
  Write-Output "== cloud: $cloud"
}

# ---- journal rotation (DC-016): archive when > journalRotateMB; agentq-sync resets its offset
# when the file shrinks (Get-NewLines: offset > length -> 0) and dedupes on line hash server-side.
function Invoke-RotateJournal([switch]$Force) {
  if (-not (Test-Path $Journal)) { return }
  $mb = (Get-Item $Journal).Length / 1MB
  if (-not $Force -and $mb -lt [double](Get-Config).journalRotateMB) { return }
  $arch = Join-Path $Root 'journal-archive'; New-Item -ItemType Directory -Force $arch | Out-Null
  $m = [Threading.Mutex]::new($false, "Global\agentq-journal$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  try {
    try { [void]$m.WaitOne(10000) } catch [Threading.AbandonedMutexException] {}
    $dst = Join-Path $arch ("journal-{0}.jsonl" -f (Now).ToString('yyyyMMdd-HHmmss'))
    [IO.File]::Move($Journal, $dst)
    [IO.File]::WriteAllText($Journal, '', [Text.UTF8Encoding]::new($false))
  } finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
  Write-Journal @{ event = 'rotate'; resource = 'agentq'; reason = "archived $([math]::Round($mb,1)) MB -> $(Split-Path $dst -Leaf)" }
  Write-Output "rotated journal ($([math]::Round($mb,1)) MB) -> $dst"
}
function Send-Signal([string]$ev, [string]$text) {
  if ($env:AGENTQ_NO_SIGNAL) { return }
  try {
    $body = @{ event = $ev; source = 'agentq'; message = $text } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri (Get-SignalUrl) -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 1 | Out-Null
  } catch {}
}

# ---------------------------------------------------------------------------------------
# devcloud F2 (DC-037): decide local vs cloud. Returns @{ where; ws; why }.
function Resolve-Placement($repo, [string]$res, [string]$cmdLine) {
  $want = if ($Where) { $Where } elseif ($env:AGENTQ_WHERE) { $env:AGENTQ_WHERE.ToLowerInvariant() } else { 'local' }
  if ($want -notin 'local', 'cloud', 'auto') { throw "agentq: -Where must be local|cloud|auto (got '$want')" }
  $cfg = Get-Config
  $map = if ($cfg.ContainsKey('cloudWorkspaces') -and $cfg['cloudWorkspaces']) { $cfg['cloudWorkspaces'] } else { @{} }
  $ws = if ($Ws) { $Ws } elseif ($repo -and $map.ContainsKey($repo.Name)) { $map[$repo.Name] } else { $null }
  if ($want -eq 'local') { return @{ where = 'local'; ws = $ws; why = $(if ($Where) { '-Where local' } elseif ($env:AGENTQ_WHERE) { 'AGENTQ_WHERE=local' } else { 'default' }) } }
  if (-not $ws) {
    if ($want -eq 'cloud') { throw "agentq: no cloud workspace for repo '$($repo.Name)' (config cloudWorkspaces or -Ws)" }
    return @{ where = 'local'; ws = $null; why = "auto: no workspace for $($repo.Name)" }
  }
  $down = Get-CloudDown $ws
  if ($down -and $env:AGENTQ_CLOUD_STRICT -ne '1') { return @{ where = 'local'; ws = $ws; why = "cloud:$ws down until $($down.until) ($($down.reason))" } }
  if ($want -eq 'cloud') { return @{ where = 'cloud'; ws = $ws; why = '-Where cloud' } }
  # auto
  $kind = Get-CmdKind $cmdLine
  if ($res -notlike 'build:*' -or $kind -notin 'typecheck', 'test', 'lint', 'build', 'next-build', 'gate-script') { return @{ where = 'local'; ws = $ws; why = "auto: kind $kind / $res stays local" } }
  $live = @(Get-Live 'build:machine' | Where-Object { (P $_ 'held' $false) -and -not (P $_ 'yielded' $false) })
  if ($live.Count -ge (Get-Capacity 'build:machine')) { return @{ where = 'cloud'; ws = $ws; why = "auto: build:machine full ($($live.Count) held)" } }
  if (-not (Test-FreeRam $MinFreeGB)) { return @{ where = 'cloud'; ws = $ws; why = 'auto: local RAM/commit below the gate' } }
  $minSec = if ($cfg.ContainsKey('cloudAutoMinSec')) { [double]$cfg['cloudAutoMinSec'] } else { 240.0 }
  $holds = @(Read-Journal 0 ((Now).AddDays(-7)) $repo.Name | Where-Object { $_.event -in 'done', 'fail' -and $_.PSObject.Properties['holdSec'] -and (P $_ 'kind' '') -eq $kind } | ForEach-Object { [double]$_.holdSec } | Sort-Object)
  if ($holds.Count -ge 3) {
    $p50 = $holds[[math]::Floor($holds.Count / 2)]
    if ($p50 -ge $minSec) { return @{ where = 'cloud'; ws = $ws; why = "auto: local $kind p50 ${p50}s >= ${minSec}s" } }
    return @{ where = 'local'; ws = $ws; why = "auto: local $kind p50 ${p50}s < ${minSec}s, machine free" }
  }
  @{ where = 'local'; ws = $ws; why = 'auto: machine free, no history' }
}

# cloud-down/<ws>.json is written by agentq-cloud when a run could not even be submitted (VM gone,
# auth, quota). Returns the record while it is unexpired, else $null (and removes a stale file).
function Get-CloudDown([string]$ws) {
  $f = Join-Path (Join-Path $Root 'cloud-down') "$ws.json"
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try {
    $d = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    # pwsh 7 ConvertFrom-Json already turns ISO strings into DateTime; re-parsing its culture
    # string (ro-RO here) threw and silently disabled the breaker.
    $until = if ($d.until -is [datetime]) { $d.until } else { [DateTime]::Parse("$($d.until)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    if ($until.ToUniversalTime() -gt (Now)) { return $d }
    Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue
  } catch {}
  $null
}

function Invoke-CloudRun($repo, [string[]]$cmdArgs, $placement) {
  $tool = if ($env:AGENTQ_CLOUD_TOOL) { $env:AGENTQ_CLOUD_TOOL } else { Join-Path $PSScriptRoot 'agentq-cloud.ps1' }
  if (-not (Test-Path $tool)) { throw "agentq: $tool missing (install agentq cloud)" }
  $a = @('-Ws', $placement.ws, '-Purpose', $Purpose, '-Repo', $repo.Top, '-Lane', $(if ($Lane) { $Lane } else { 'gate' }))
  if ($TimeoutGiven) { $a += @('-TimeoutMin', "$TimeoutMin") }
  $all = @($a) + @('--') + @($cmdArgs)
  & $tool @all
  $rc = $LASTEXITCODE
  # 4 = nothing was submitted: run it here instead of failing the caller's hook/commit.
  if ($rc -eq 4 -and $env:AGENTQ_CLOUD_STRICT -ne '1') {
    [Console]::Error.WriteLine("agentq: cloud:$($placement.ws) unavailable, running locally")
    Write-Journal @{ event = 'placement'; resource = 'cloud-fallback'; repo = $(if ($repo) { $repo.Name } else { '' }); where = 'local'; ws = "$($placement.ws)"; reason = 'cloud unavailable (exit 4), fell back to local'; purpose = $Purpose }
    return
  }
  exit $rc
}

function Invoke-Run {
  $repo = Get-RepoInfo $Repo
  Assert-ExpectedRepo $repo
  if (-not $Resource) { throw 'agentq run: -Resource build|install|commit|deploy:<target>|<literal> is required' }
  if (-not $Purpose) { throw 'agentq run: -Purpose "<why>" is required (other agents read it)' }
  # only agentq's own separator is consumed (line ~94); a later '--' belongs to the command (turbo/pnpm/vitest)
  $cmdArgs = @($Rest)
  if (-not $cmdArgs) { throw 'agentq run: nothing to run (agentq run -Resource build -Purpose x -- <command>)' }
  $cmdLine = ($cmdArgs -join ' ')
  $resList = @(Expand-Resources $Resource $repo)
  foreach ($r in $resList) { Assert-NotMarked $r }
  $pl = Resolve-Placement $repo $resList[0] $cmdLine
  if ($Where -or $env:AGENTQ_WHERE) { Write-Journal @{ event = 'placement'; resource = $resList[0]; repo = $(if ($repo) { $repo.Name } else { '' }); where = $pl.where; ws = "$($pl.ws)"; reason = $pl.why; purpose = $Purpose; cmd = $cmdLine } }
  if ($pl.where -eq 'cloud') { [Console]::Error.WriteLine("agentq: placement cloud:$($pl.ws) ($($pl.why))"); Invoke-CloudRun $repo $cmdArgs $pl }
  $tickets = @()
  $started = Now
  try {
    # v3 (DC-013): all tickets exist from the start but NONE is held until every one is
    # admissible; the grant is atomic (Wait-All). Held is an explicit flag, so the 2026-09-30
    # phantom-hold (position = hold) cannot recur.
    $gates = @{}
    foreach ($r in $resList) {
      $t = New-Ticket $r $Purpose $cmdLine ($repo.Top)
      $tickets += $t   # before waiting, so the finally below removes it on Ctrl+C or an exception
      Write-Journal @{ event = 'queued'; resource = $r; ticket = $t.id; purpose = $Purpose; cmd = $cmdLine; repo = $repo.Name; lane = $t.lane }
      $gates[$t.id] = if ($t.resource -eq 'build:machine' -and $MinFreeGB -gt 0) { { Test-FreeRam $MinFreeGB } } else { $null }
    }
    if ($NoWait) {
      $busy = @($tickets | Where-Object { -not (Test-Admissible $_ $gates[$_.id]).ok })
      if ($busy) {
        $h = @(Get-Live $busy[0].resource)[0]
        foreach ($t in $tickets) { Remove-Ticket $t 'busy (-NoWait)' 'giveup' }
        [Console]::Error.WriteLine("agentq: $($busy[0].resource) is busy: $($h.session) '$($h.purpose)' since $($h.created)")
        exit 3
      }
      foreach ($t in $tickets) { Update-Ticket $t @{ held = $true; acquired = (Iso (Now)) } }
      $script:WaitSec = 0
    } else { Wait-All $tickets $gates $TimeoutMin }
    $acquiredAt = Now
    $held = ($resList -join ',')
    Write-Journal @{ event = 'start'; resource = $held; tickets = @($tickets | ForEach-Object id); purpose = $Purpose; cmd = $cmdLine; repo = $repo.Name; lane = $tickets[0].lane; waitSec = $script:WaitSec }
    Send-Signal 'agentq-start' "$held — $Purpose"
    $env:AGENTQ_HELD = (@($env:AGENTQ_HELD, $held) | Where-Object { $_ }) -join ','
    $env:AGENTQ_PURPOSE = $Purpose
    $env:AGENTQ_SESSION = $Session
    $env:AGENTQ_LANE = "$($tickets[0].lane)"
    # run-build writes <ticket>.wedged beside these when its build log stops growing (WEDGED in status).
    $env:AGENTQ_TICKET_FILES = (@($env:AGENTQ_TICKET_FILES) + @($tickets | ForEach-Object file) | Where-Object { $_ }) -join ';'

    # Heartbeat: a background job touches every ticket's .hb file every 20 s.
    # Idle watchdog (DC-012): every 60 s it sums the CPU time of this run's process tree. A tree
    # that burned < idleCpuSec over idleYieldMin minutes is doing nothing locally (waiting on a
    # cloud VM, network, a hung child): its build:machine ticket YIELDS (does not count against
    # the machine cap) until CPU comes back. The repo ticket stays held (correctness).
    $hbFiles = @($tickets | ForEach-Object { "$($_.file).hb" })
    $machineFile = @($tickets | Where-Object resource -eq 'build:machine' | ForEach-Object file) | Select-Object -First 1
    $cfg = Get-Config
    $hb = Start-ThreadJob -ArgumentList $hbFiles, $machineFile, $PID, ([int]$cfg.idleYieldMin), ([double]$cfg.idleCpuSec), $Journal, $Session -ScriptBlock {
      param($files, $mfile, $rootPid, $yieldMin, $cpuSec, $journal, $session)
      $samples = [Collections.Generic.List[object]]::new(); $tick = 0; $yielded = $false
      function TreeCpu([int]$root) {
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, KernelModeTime, UserModeTime)
        $kids = @{}; foreach ($p in $all) { $k = [int]$p.ParentProcessId; if (-not $kids[$k]) { $kids[$k] = [Collections.Generic.List[object]]::new() }; $kids[$k].Add($p) }
        $sum = 0.0; $stack = [Collections.Generic.Stack[int]]::new(); $stack.Push($root); $seen = @{}
        while ($stack.Count) { $id = $stack.Pop(); if ($seen[$id]) { continue }; $seen[$id] = 1
          foreach ($c in @($kids[$id])) { if ($c) { $sum += ([double]$c.KernelModeTime + [double]$c.UserModeTime) / 1e7; $stack.Push([int]$c.ProcessId) } } }
        $sum
      }
      function SetFlag([string]$f, [bool]$v) {
        try { $raw = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable; $raw['yielded'] = $v; $raw['yieldAt'] = [DateTime]::UtcNow.ToString('o')
          [IO.File]::WriteAllText("$f.tmp", ($raw | ConvertTo-Json -Depth 4)); [IO.File]::Move("$f.tmp", $f, $true) } catch {}
      }
      while ($true) {
        foreach ($f in $files) { try { [IO.File]::SetLastWriteTimeUtc($f, [DateTime]::UtcNow) } catch {} }
        if ($mfile -and $yieldMin -gt 0 -and ($tick % 3) -eq 0) {
          try {
            $samples.Add(@{ t = [DateTime]::UtcNow; cpu = (TreeCpu $rootPid) })
            # Drop the oldest only while the NEXT one still covers the whole window.
            while ($samples.Count -gt 2 -and ([DateTime]::UtcNow - $samples[1].t).TotalMinutes -ge $yieldMin) { $samples.RemoveAt(0) }
            $span = ([DateTime]::UtcNow - $samples[0].t).TotalMinutes
            $burn = $samples[$samples.Count - 1].cpu - $samples[0].cpu
            $idle = ($span -ge ($yieldMin - 0.5)) -and ($burn -lt $cpuSec)
            $busyAgain = $yielded -and $samples.Count -ge 2 -and (($samples[$samples.Count - 1].cpu - $samples[$samples.Count - 2].cpu) -ge $cpuSec)
            if ($idle -and -not $yielded) { $yielded = $true; SetFlag $mfile $true
              [IO.File]::AppendAllText($journal, (@{ ts = [DateTime]::UtcNow.ToString('o'); event = 'idle-yield'; resource = 'build:machine'; session = $session; reason = "cpu $([math]::Round($burn,1))s in $([math]::Round($span,1)) min" } | ConvertTo-Json -Compress) + "`n") }
            elseif ($busyAgain) { $yielded = $false; SetFlag $mfile $false
              [IO.File]::AppendAllText($journal, (@{ ts = [DateTime]::UtcNow.ToString('o'); event = 'idle-resume'; resource = 'build:machine'; session = $session } | ConvertTo-Json -Compress) + "`n") }
          } catch {}
        }
        $tick++; Start-Sleep -Seconds 20
      }
    }
    # ADR 0003 W2-4: this process (and every child it starts) runs in a job object: leftover children die
    # with the holder (kill-on-close) and CPU is shared by lane weight when the machine is saturated.
    # Best effort: any failure runs the command exactly as before. AGENTQ_NO_JOBOBJ=1 disables it.
    $jobInfo = $null
    if ($env:AGENTQ_NO_JOBOBJ -ne '1') {
      $libJ = Join-Path $PSScriptRoot 'agentq-jobobject-lib.ps1'
      if (Test-Path -LiteralPath $libJ) {
        . $libJ
        $wByLane = @{ interactive = 9; quick = 8; gate = 7; heavy = 4; batch = 2 }
        $lw = "$($tickets[0].lane)"; $wt = if ($wByLane.ContainsKey($lw)) { $wByLane[$lw] } else { 5 }
        if ($held -like 'land:*' -or $Purpose -match '^land gate') { $wt = 9 }
        $jobInfo = Enter-AgentqJob $wt
        if ($jobInfo.error) { Write-Journal @{ event = 'jobobj-failed'; resource = $held; reason = $jobInfo.error; repo = $repo.Name } }
        else { $jobInfo.weight = $wt }
      }
    }
    try {
      $exe = $cmdArgs[0]; $argv = @($cmdArgs | Select-Object -Skip 1)
      & $exe @argv
      $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    } finally { Stop-Job $hb -ErrorAction SilentlyContinue; Remove-Job $hb -Force -ErrorAction SilentlyContinue }
    $jstat = if ($jobInfo -and $jobInfo.job -ne [IntPtr]::Zero) { Get-AgentqJobStats $jobInfo.job } else { $null }
    $dur = [math]::Round(((Now) - $started).TotalSeconds)
    $holdSec = [math]::Round(((Now) - $acquiredAt).TotalSeconds)
    $je = @{ event = $(if ($code -eq 0) { 'done' } else { 'fail' }); resource = $held; exit = $code; durSec = $dur; holdSec = $holdSec; waitSec = $script:WaitSec; lane = $tickets[0].lane; kind = (Get-CmdKind $cmdLine); purpose = $Purpose; cmd = $cmdLine; repo = $repo.Name }
    if ($jstat) { $je.cpuSec = $jstat.cpuSec; $je.peakMB = $jstat.peakMB; $je.procs = $jstat.procs; $je.cpuWeight = $jobInfo.weight }
    Write-Journal $je
    if ($code -ne 0) { Send-Signal 'agentq-fail' "$held failed ($code) — $Purpose" }
    exit $code
  } finally {
    foreach ($t in $tickets) { Remove-Item -LiteralPath $t.file, "$($t.file).hb", "$($t.file).wedged" -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-Commit {
  $repo = Get-RepoInfo $Repo
  Assert-ExpectedRepo $repo
  if (-not $repo) { throw 'agentq commit: not in a git repo' }
  if (-not $Purpose) { throw 'agentq commit: -Purpose is required' }
  if (-not $Message) { throw 'agentq commit: -Message is required' }
  $plist = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if (-not $plist) { throw 'agentq commit: -Paths a,b,c is required (explicit paths only — never the whole index)' }
  $outside = @($plist | Where-Object { [IO.Path]::IsPathRooted($_) -and -not ([IO.Path]::GetFullPath($_).ToLowerInvariant().StartsWith($repo.Top.ToLowerInvariant() + '\')) })
  if ($outside) { [Console]::Error.WriteLine("agentq: REFUSED - paths outside $($repo.Top): $($outside -join ', ')"); exit 3 }
  $res = "commit:$($repo.Name)"
  Assert-NotMarked $res
  $t = New-Ticket $res $Purpose "commit $($plist -join ' ')" $repo.Top
  Write-Journal @{ event = 'queued'; resource = $res; ticket = $t.id; purpose = $Purpose; paths = $plist; repo = $repo.Name }
  $script:CommitDone = $false
  try {
    Wait-Turn $t $TimeoutMin $null
    $env:AGENTQ_HELD = (@($env:AGENTQ_HELD, $res) | Where-Object { $_ }) -join ','
    $env:AGENTQ_PURPOSE = $Purpose; $env:AGENTQ_SESSION = $Session
    Push-Location $repo.Top
    try {
      # A worktree installed with `pnpm install --ignore-scripts` has core.hooksPath=.husky/_ but no
      # .husky/_/pre-commit: git then runs NO hook, silently (brivio 2026-09-29, three times). Refuse
      # instead of committing ungated; the fix is one command.
      $hp = (& git config --get core.hooksPath 2>$null)
      if ($hp -and -not $env:SKIP_HOOKS -and -not $env:FAST_COMMIT) {
        $hookDir = if ([IO.Path]::IsPathRooted($hp)) { $hp } else { Join-Path $repo.Top $hp }
        $hpParent = Split-Path $hp -Parent
        # Single-segment hooksPath (e.g. '.githooks'): parent is '' and Join-Path would throw.
        $declared = if ($hpParent) { Join-Path $repo.Top (Join-Path $hpParent 'pre-commit') } else { Join-Path $repo.Top 'pre-commit' }
        if ((Test-Path -LiteralPath $declared) -and -not (Test-Path -LiteralPath (Join-Path $hookDir 'pre-commit'))) {
          throw "agentq commit: core.hooksPath='$hp' has no pre-commit (hooks would be skipped silently). Run 'pnpm exec husky' in $($repo.Top) first."
        }
      }
      # Stage and commit in ONE critical section, pathspec-limited: a commit without a
      # pathspec takes EVERYTHING staged, including other agents' files (7cc672f7).
      # Deleted paths cannot be `git add`-ed ("pathspec did not match", 2026-09-28):
      # stage those with `git rm --cached`, still limited to @plist.
      # X-03 (2026-10-05): remember what was staged BEFORE we touch the index, so a rejected
      # commit can unstage exactly the paths we added (a later amend swallowed them, 2026-10-02).
      $preStaged = @(& git diff --cached --name-only -- @plist)
      $gone = @($plist | Where-Object { -not (Test-Path -LiteralPath $_) })
      $live = @($plist | Where-Object { Test-Path -LiteralPath $_ })
      if ($live.Count) { & git add -- @live; if ($LASTEXITCODE) { throw "git add failed ($LASTEXITCODE)" } }
      if ($gone.Count) { & git rm -q --cached --ignore-unmatch -- @gone; if ($LASTEXITCODE) { throw "git rm failed ($LASTEXITCODE)" } }
      $msg = "$Message`n`nAgent-Session: $Session`nAgent-Purpose: $Purpose"
      $tmp = [IO.Path]::GetTempFileName()
      [IO.File]::WriteAllText($tmp, $msg, [Text.UTF8Encoding]::new($false))
      & git commit -q -F $tmp -- @plist
      $cc = $LASTEXITCODE; Remove-Item $tmp -Force
      if ($cc) {
        $ours = @(& git diff --cached --name-only -- @plist | Where-Object { $preStaged -notcontains $_ })
        if ($ours.Count) { & git reset -q -- @ours 2>$null }
        throw "git commit failed ($cc) — nothing committed; unstaged $($ours.Count) path(s) agentq had staged"
      }
      $sha = (& git rev-parse --short HEAD).Trim()
      $script:CommitDone = $true
      $files = @(& git show --name-only --format= HEAD)
      $foreign = @($files | Where-Object { $f = $_; -not ($plist | Where-Object { $f -like "$($_ -replace '\\','/')*" }) })
      Write-Journal @{ event = 'commit'; resource = $res; sha = $sha; purpose = $Purpose; message = $Message; paths = $files; foreign = $foreign; repo = $repo.Name }
      if ($foreign) { [Console]::Error.WriteLine("agentq: WARNING commit $sha also contains files outside -Paths: $($foreign -join ', ')") }
      Write-Output "committed $sha ($($files.Count) files)"
      if (-not $NoPush) {
        $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
        $pushed = $false
        for ($i = 1; $i -le 4 -and -not $pushed; $i++) {
          $pushOut = @(& git push -q origin "HEAD:$branch" 2>&1 | ForEach-Object { "$_" })
          if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
          # Only a lost race (remote moved) is worth fetch+merge+retry. A pre-push hook
          # rejection (failing gates) would re-run the gates 4x in silence and look frozen.
          if (-not ($pushOut -match 'non-fast-forward|fetch first|rejected .*\(stale|Updates were rejected')) {
            $pushOut | Select-Object -Last 25 | ForEach-Object { [Console]::Error.WriteLine($_) }
            Write-Journal @{ event = 'push-failed'; resource = $res; sha = $sha; branch = $branch; repo = $repo.Name }
            throw "push failed (not a race: pre-push hook or remote refused; output above). Commit $sha is local - fix and push again."
          }
          & git fetch -q origin $branch
          # A merge in a shared clone must never touch another agent's uncommitted files.
          # Distinguish a real content conflict from "incoming change overlaps a dirty file".
          $incoming = @(& git diff --name-only "HEAD...origin/$branch")
          $dirtyNow = @(& git status --porcelain | ForEach-Object { $_.Substring(3).Trim('"') })
          $overlap = @($incoming | Where-Object { $dirtyNow -contains $_ })
          if ($overlap) {
            Write-Journal @{ event = 'push-deferred'; resource = $res; sha = $sha; branch = $branch; overlap = $overlap; repo = $repo.Name }
            throw "push deferred: origin/$branch changes files with UNCOMMITTED local edits (other agents'): $($overlap -join ', '). Commit $sha stays local and rides the next push from this clone; do NOT stash/reset them."
          }
          & git merge-tree --write-tree HEAD "origin/$branch" *> $null
          if ($LASTEXITCODE) { throw "push rejected: merge of origin/$branch has content conflicts — resolve by hand (commit $sha is local)" }
          $mergeOut = @(& git merge -q --no-edit "origin/$branch" 2>&1 | ForEach-Object { "$_" })
          $mergeCode = $LASTEXITCODE
          if ($mergeCode) {
            if (Test-Path (Join-Path (& git rev-parse --git-dir) 'MERGE_HEAD')) { & git merge --abort 2>$null }
            $mergeOut | Select-Object -Last 15 | ForEach-Object { [Console]::Error.WriteLine($_) }
            throw "push rejected: git merge origin/$branch failed ($mergeCode) — commit $sha is local"
          }
        }
        if (-not $pushed) { throw "push failed after 4 attempts (commit $sha is local)" }
        $head = (& git rev-parse --short HEAD).Trim()
        Write-Journal @{ event = 'push'; resource = $res; sha = $head; branch = $branch; repo = $repo.Name }
        Write-Output "pushed $head -> origin/$branch"
        $acts = @(Notify-Landing $repo.Name $branch "$(& git rev-parse HEAD)".Trim() '')
        if ($acts) { Write-Output "releases following origin/${branch}: $($acts -join ', ')" }
      }
    } finally { Pop-Location }
  } catch {
    # DC-015: ~30 % of commit tickets ended with no commit and no journaled reason. Record it.
    $msg = "$($_.Exception.Message)"
    Write-Journal @{ event = $(if ($script:CommitDone) { 'push-failed' } else { 'commit-failed' }); resource = $res; purpose = $Purpose; reason = $msg.Substring(0, [math]::Min(400, $msg.Length)); paths = $plist; repo = $repo.Name }
    throw
  } finally { Remove-Item -LiteralPath $t.file, "$($t.file).hb" -Force -ErrorAction SilentlyContinue }
}

function Show-Status {
  $repo = Get-RepoInfo $Repo
  $dirs = @(Get-ChildItem $QDir -Directory -ErrorAction SilentlyContinue)
  $rows = @()
  foreach ($d in $dirs) {
    $sample = Get-ChildItem $d.FullName -Filter '*.json' -File | Where-Object Name -ne 'adaptive.json' | Select-Object -First 1
    if (-not $sample) { continue }
    $res = (Get-Content $sample.FullName -Raw | ConvertFrom-Json -DateKind String).resource
    if (-not $All -and $repo -and $res -notmatch "(^|:)$([regex]::Escape($repo.Name))(:|$)" -and $res -ne 'build:machine') { continue }
    $live = @(Get-Live $res)
    $cap = Get-Capacity $res
    $wq = @($live | Where-Object { -not (Test-Held $_ $live $cap) } | Sort-Object @{ e = { Get-EffPrio $_ }; Descending = $true }, @{ e = { [long]$_.seq } })
    foreach ($t in $live) {
      $isHeld = Test-Held $t $live $cap
      $role = if ($isHeld) { if (P $t 'yielded' $false) { 'HOLD(idle)' } else { 'HOLD' } } else { "wait#$([array]::IndexOf(@($wq | ForEach-Object id), $t.id) + 1)$(if (-not (P $t 'ready' $true)) { '~' })" }
      # WEDGED: run-build saw its build log silent for -WedgeMin (sidecar <ticket>.wedged, JSON {since,quietMin,log,pid}).
      $wedgeTxt = $null
      if (Test-Path -LiteralPath "$($t.file).wedged") {
        $wm = '?'
        try {
          $w = Get-Content -LiteralPath "$($t.file).wedged" -Raw | ConvertFrom-Json -DateKind String
          if ($w.PSObject.Properties['since'] -and $w.since) { $q = if ($w.PSObject.Properties['quietMin']) { [double]$w.quietMin } else { 0 }; $wm = [math]::Round(((Now) - (ParseUtc $w.since)).TotalMinutes + $q, 0) }
        } catch { }
        $wedgeTxt = "WEDGED(${wm}m)"
      }
      $rows += [pscustomobject]@{
        resource = $res; role = $role; lane = "$(P $t 'lane' '-')"; prio = $(if (P $t 'v') { Get-EffPrio $t } else { '-' })
        state = $(if ($t.stale -and $wedgeTxt) { "STALE($($t.beatAgeMin)m),$wedgeTxt" } elseif ($t.stale) { "STALE($($t.beatAgeMin)m)" } elseif ($wedgeTxt) { $wedgeTxt } else { 'ok' })
        ageMin = [math]::Round(((Now) - (ParseUtc $t.created)).TotalMinutes, 1)
        session = $t.session; purpose = $t.purpose; id = $t.id
      }
    }
  }
  $marks = @(Get-ChildItem $MDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -DateKind String })
  $v2 = Get-V2Status $(if (-not $All -and $repo) { $repo.Name } else { $null })
  if ($Json) { $o = ConvertTo-V2Json $v2; $o.tickets = $rows; $o.marks = $marks; $o | ConvertTo-Json -Depth 5; return }
  if ($marks) {
    Write-Output '== MARKS'
    $marks | ForEach-Object { Write-Output ("{0,-34} {1,-8} since {2} by {3}: {4}" -f $_.resource, $_.state.ToUpper(), $_.at, $_.session, $_.reason) }
  }
  Format-V2Status $v2
  if ($rows) {
    Write-Output '== QUEUES'
    $rows | Format-Table resource, role, lane, prio, state, ageMin, session, purpose, id -AutoSize | Out-String -Width 240 | Write-Output
  } else { Write-Output "== QUEUES: idle$(if (-not $All -and $repo) { " for $($repo.Name) (use -All for every repo)" })" }
  $bursts = @(Get-ChildItem $QDir -Recurse -Filter 'burst.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -DateKind String } | Where-Object { (ParseUtc $_.until) -gt (Now) })
  foreach ($b in $bursts) { Write-Output ("== BURST {0} +{1} until {2} by {3}: {4}" -f $b.resource, $b.by, $b.until, $b.session, $b.reason) }
}

function Read-Journal([int]$n, $since, [string]$repoName) {
  if (-not (Test-Path $Journal)) { return @() }
  $lines = if ($n -gt 0) { Get-Content $Journal -Tail ([math]::Max($n * 8, 400)) } else { Get-Content $Journal }
  $items = @($lines | ForEach-Object { try { $_ | ConvertFrom-Json -DateKind String } catch { $null } } | Where-Object { $_ })
  if ($since) { $items = @($items | Where-Object { (ParseUtc $_.ts) -ge $since }) }
  if ($repoName) { $items = @($items | Where-Object { ($_.PSObject.Properties.Name -contains 'repo' -and $_.repo -eq $repoName) -or ("$($_.resource)" -match "(^|:)$([regex]::Escape($repoName))(:|$)") }) }
  if ($n -gt 0) { $items = @($items | Select-Object -Last $n) }
  $items
}

function Format-Entry($e) {
  $extra = @()
  foreach ($k in 'exit', 'durSec', 'sha', 'reason', 'state') { if ($e.PSObject.Properties.Name -contains $k -and "$($e.$k)") { $extra += "$k=$($e.$k)" } }
  $what = if ($e.PSObject.Properties.Name -contains 'purpose' -and $e.purpose) { $e.purpose } elseif ($e.PSObject.Properties.Name -contains 'message') { $e.message } else { '' }
  '{0} {1,-8} {2,-30} {3,-14} {4} {5}' -f ((ParseUtc $e.ts)).ToLocalTime().ToString('MM-dd HH:mm'), $e.event, "$($e.resource)", "$($e.session)".Substring(0, [math]::Min(14, "$($e.session)".Length)), $what, ($extra -join ' ')
}

function Show-Log {
  $repo = Get-RepoInfo $Repo
  $name = if ($All -or -not $repo) { $null } else { $repo.Name }
  $items = @(Read-Journal $Last $null $name)
  if ($Json) { $items | ConvertTo-Json -Depth 5; return }
  $items | ForEach-Object { Format-Entry $_ }
}

function Show-Since {
  $repo = Get-RepoInfo $Repo
  if (-not $repo) { throw 'agentq since: not in a git repo' }
  $from = (Now).AddHours(-$Hours)
  Write-Output "== agentq journal for $($repo.Name), last $Hours h"
  $items = @(Read-Journal 0 $from $repo.Name) | Where-Object { $_.event -notin 'queued', 'reap' }
  if ($items) { $items | ForEach-Object { Format-Entry $_ } } else { Write-Output '(no entries)' }
  Write-Output "== git log origin (last $Hours h)"
  & git -C $repo.Top fetch -q 2>$null
  $up = (& git -C $repo.Top rev-parse --abbrev-ref '@{u}' 2>$null)
  $ref = if ($up) { $up } else { 'HEAD' }
  & git -C $repo.Top log $ref --since="$([int]($Hours * 60)) minutes ago" --format='%h %ad %an %s' --date=format:'%m-%d %H:%M' -n 60
  Write-Output '== live queues'
  Show-Status
}

function Set-Mark {
  if (-not $Resource -or -not $State) { throw 'agentq mark -Resource <r> -State frozen|blocked|clear -Reason "..."' }
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  $f = Join-Path $MDir ((Safe $res) + '.json')
  if ($State -eq 'clear') {
    if (-not $Reason) { throw 'agentq mark -State clear needs -Reason (why it is safe again)' }
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    Write-Journal @{ event = 'unmark'; resource = $res; reason = $Reason }
    Write-Output "cleared $res"; return
  }
  if ($State -notin 'frozen', 'blocked') { throw '-State must be frozen, blocked or clear' }
  if (-not $Reason) { throw 'agentq mark needs -Reason (other agents will read it)' }
  $m = [ordered]@{ resource = $res; state = $State; reason = $Reason; session = $Session; at = (Iso (Now)) }
  [IO.File]::WriteAllText($f, ($m | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  Write-Journal @{ event = 'mark'; resource = $res; state = $State; reason = $Reason }
  Write-Output "$res marked $State"
}

function Invoke-Break {
  if (-not $Resource -or -not $Reason) { throw 'agentq break -Resource <r> [-Id <ticket>] -Reason "..."' }
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  $targets = @(Read-Tickets $res | Where-Object { -not $Id -or $_.id -eq $Id })
  # Without -Id, break only when the choice is unambiguous. "First ticket" once removed a live,
  # healthy holder instead of the STALE one next to it (2026-09-30).
  if (-not $Id -and $targets.Count -gt 1) {
    $list = ($targets | ForEach-Object { "$($_.id) $($_.session) '$($_.purpose)'" }) -join '; '
    [Console]::Error.WriteLine("agentq: $res has $($targets.Count) tickets - pass -Id <ticket>: $list")
    exit 2
  }
  if (-not $targets) { Write-Output "nothing to break on $res"; return }
  foreach ($t in $targets) {
    $alive = Test-Alive $t
    Remove-Ticket $t "$Reason$(if ($alive) { " (holder pid $($t.pid) was still ALIVE)" })" 'break'
    Write-Output "broke ticket $($t.id) on $res (held by $($t.session) '$($t.purpose)', alive=$alive)"
  }
}

function Invoke-Acquire {
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  if (-not $Purpose) { throw 'agentq acquire: -Purpose is required' }
  Assert-NotMarked $res
  $t = New-Ticket $res $Purpose "$($Rest -join ' ')" ($repo.Top)
  Write-Journal @{ event = 'queued'; resource = $res; ticket = $t.id; purpose = $Purpose }
  if ($NoWait) {
    $live = @(Get-Live $res)
    if ([array]::IndexOf(@($live | ForEach-Object id), $t.id) -ge (Get-Capacity $res)) { Remove-Ticket $t 'busy (-NoWait)' 'giveup'; exit 3 }
  } else { Wait-Turn $t $TimeoutMin $null }
  Write-Journal @{ event = 'start'; resource = $res; tickets = @($t.id); purpose = $Purpose }
  Write-Output $t.id
}

function Invoke-Release {
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  $t = @(Read-Tickets $res | Where-Object { $_.id -eq $Id })
  foreach ($x in $t) { Remove-Item -LiteralPath $x.file, "$($x.file).hb" -Force -ErrorAction SilentlyContinue }
  Write-Journal @{ event = 'done'; resource = $res; ticket = $Id; exit = 0 }
}

. (Join-Path $PSScriptRoot 'agentq-v2.ps1')
if ($Verb.ToLowerInvariant() -notin 'status', 'log', 'renew', 'lease-check') { Renew-ForCwd }
# Session renewal only for verbs that mean "this agent is working"; maintenance verbs (sweep, break,
# unlease, metrics, rotate) from the same session must not keep a lease alive they are judging.
if ($Verb.ToLowerInvariant() -in 'run', 'commit', 'publish', 'land', 'note', 'acquire', 'release', 'bump', 'propose', 'lease', 'backup', 'since') { Renew-ForSession }
if ($Verb.ToLowerInvariant() -notin 'lease-check') { Show-LeaseNotices }

# Agent registry (S18-09, 2026-10-17). Every agentq call records WHO called: the session, the AI
# client (from env + the process ancestry), the app that owns the shell, the repo and the last
# purpose, in coord/agents/<session>.json. Readers (Vitals, the hub) join it with tickets and
# leases by `session`, so "this build belongs to that Copilot Chat in that VS Code window" is a
# lookup, not a guess. Hooks are the trust surface and not ours to edit; this path is.
function Get-AgentClient {
  if ($env:AGENTQ_CLIENT) { return $env:AGENTQ_CLIENT }
  if ($env:CLAUDECODE -or $env:CLAUDE_CODE_ENTRYPOINT) { return 'claude-code' }
  if ($env:CODEX_SANDBOX -or $env:CODEX_HOME -or $env:CODEX_MANAGED_BY_NPM) { return 'codex' }
  if ($env:CODAI_AGENT -or $env:CODAI_SESSION_ID) { return 'codai' }
  if ($env:COPILOT_AGENT -and $env:TERM_PROGRAM -eq 'vscode') { return 'vscode-copilot' }
  if ($env:COPILOT_AGENT -or $env:COPILOT_SESSION_ID) { return 'copilot-cli' }
  if ($env:TERM_PROGRAM -eq 'vscode') { return 'vscode' }
  $null
}
function Register-Agent {
  if ($env:AGENTQ_NO_REGISTRY -eq '1') { return }
  try {
    $dir = Join-Path $Root 'agents'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $f = Join-Path $dir ((Safe $Session) + '.json')
    # ancestry: shell = our parent; app = first ancestor that is a known AI host (<= 8 hops, ~20 ms each)
    $me = Get-Process -Id $PID -ErrorAction Stop
    $shell = $me.Parent; $app = $null; $p = $shell; $hops = 0
    $hosts = '^(Code - Insiders|Code|codai-desktop|copilot|copilot-runtime|claude|Claude|codex|Cursor|Windsurf|WindowsTerminal)$'
    while ($p -and $hops -lt 8) { if ($p.ProcessName -match $hosts) { $app = $p; break }; $p = $p.Parent; $hops++ }
    $prev = $null
    if (Test-Path -LiteralPath $f) { try { $prev = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } catch {} }
    $repoName = try { (Get-RepoInfo $Repo).Name } catch { $null }
    $client = Get-AgentClient
    if (-not $client -and $app) { $client = switch -regex ($app.ProcessName) { '^codai' { 'codai' } '^copilot' { 'copilot-cli' } '^(claude|Claude)$' { 'claude-code' } '^codex$' { 'codex' } '^Code' { 'vscode' } default { $null } } }
    $rec = [ordered]@{
      v = 1; session = $Session; client = $client
      app = $(if ($app) { $app.ProcessName } else { $null }); appPid = $(if ($app) { $app.Id } else { $null })
      appStart = $(if ($app) { Iso $app.StartTime } else { $null })
      shellPid = $(if ($shell) { $shell.Id } else { $null }); shellStart = $(if ($shell) { Iso $shell.StartTime } else { $null })
      model = $(if ($env:COPILOT_MODEL) { $env:COPILOT_MODEL } elseif ($env:COPILOT_PROVIDER_WIRE_MODEL) { $env:COPILOT_PROVIDER_WIRE_MODEL } else { $null })
      cwd = (Get-Location).Path; repo = $repoName
      firstSeen = $(if ($prev -and $prev.firstSeen) { "$($prev.firstSeen)" } else { Iso (Now) }); lastSeen = Iso (Now)
      calls = $(if ($prev -and $prev.calls) { [int]$prev.calls + 1 } else { 1 })
      lastVerb = $Verb.ToLowerInvariant(); lastPurpose = $(if ($Purpose) { $Purpose } elseif ($prev) { $prev.lastPurpose } else { $null })
      host = $env:COMPUTERNAME
    }
    $tmp = "$f.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($rec | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)); Move-Item -Force -LiteralPath $tmp -Destination $f
  } catch {}
}
if ($Verb.ToLowerInvariant() -notin 'status', 'log', 'metrics', 'since', 'help') { Register-Agent }

switch ($Verb.ToLowerInvariant()) {
  'run' { Invoke-Run }
  'commit' { Invoke-Commit }
  'status' { Show-Status }
  'log' { Show-Log }
  'since' { Show-Since }
  'mark' { Set-Mark }
  'break' { Invoke-Break }
  'note' {
    if (-not $Message) { throw 'agentq note -Message "..."' }
    $repo = Get-RepoInfo $Repo
    Write-Journal @{ event = 'note'; resource = $(if ($repo) { "note:$($repo.Name)" } else { 'note' }); message = $Message; repo = $(if ($repo) { $repo.Name } else { '' }) }
    Write-Output 'noted'
  }
  'acquire' { Invoke-Acquire }
  'release' { Invoke-Release }
  'bump' { Invoke-Bump }
  'burst' { Invoke-Burst }
  'propose' { Invoke-Propose }
  'metrics' { Show-Metrics }
  'rotate' { Invoke-RotateJournal -Force }
  'lease' { Invoke-Lease }
  'unlease' { Invoke-Unlease }
  'renew' { Invoke-Renew }
  'sweep' { Invoke-Sweep }
  'lease-check' { Invoke-LeaseCheck }
  'backup' { Invoke-Backup }
  'release-begin' { Invoke-ReleaseBegin }
  'release-phase' { Invoke-ReleasePhase }
  'release-end' { Invoke-ReleaseEnd }
  'release-cancel' { Invoke-ReleaseCancel }
  'notify-landing' { Invoke-NotifyLanding }
  'land' { Invoke-Land; exit $script:LandExit }
  'publish' { Invoke-Publish; if ($DoLand) { exit $script:LandExit } }
  # ADR 0003 W4-4: SLO report from the journal (ready->landed p90, flake rate, lost work, queue waits, bypass).
  'flakes' { Invoke-FlakesVerb }
  'slo' { $sa = @((Join-Path $PSScriptRoot 'agentq-slo.mjs'), '--journal', $Journal, '--days', "$([math]::Max(1, [math]::Round($Hours / 24)))"); if ($Json) { $sa += '--json' }; & node @sa; exit $LASTEXITCODE }
  default { Get-Help $PSCommandPath; exit 2 }
}
