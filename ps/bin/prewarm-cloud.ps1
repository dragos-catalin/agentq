<#
.SYNOPSIS
  Bring a suspended devcloud workspace up before an agent needs it, within bounds.

.DESCRIPTION
  A suspended workspace resumes in 12-17 s, and a job submitted while it is suspended pays 41.2 s
  (measured 2026-11-25), which lands exactly when an agent is already blocked on the land or gate
  queue. This moves that wait earlier - and only when there is an agent to wait for.

  It is bounded by construction rather than by discipline:

    * SUSPENDED is the only state it acts on. Anything else is left alone.
    * It never fights the idle self-suspend. A RUNNING workspace is a no-op, because the CPU-idle
      suspend (45 min on Windows, 15 on macOS) IS the cost policy: a prewarm that keeps a VM up pays
      roughly 1.14 USD/h for a machine nobody is using.
    * It resumes only when the agentq journal shows the repo working. A scheduled tick with nothing
      to warm for does nothing AND writes nothing, so the log stays readable.
    * -MaxResumesPerDay caps the day PER WORKSPACE (it was one shared counter until 2026-11-25: the
      measurement says ~25 legitimate wakes a day across five workspaces, so a single global budget of
      6 either throttled three quarters of the useful wakes or let one busy repo starve the rest).
      One file turns the whole tool off.

  It never creates, stops or suspends a VM. The only write is `gcloud compute instances resume`, and
  only for a suspended workspace that is under its cap.

  Exit codes: 0 = nothing to do, or resumed; 3 = resumed but not RUNNING inside -WaitSec; 1 = error.
  Every tick prints its reason, so "no activity" in a log is a claim you can check against the journal.

.PARAMETER Ws
  Workspace to keep warm, for example vitals-win. Default: what agentq-config.json maps -Repo to.

.PARAMETER Repo
  Repository whose activity justifies the resume (default vitals), and where -Ws comes from when -Ws
  is not given.

.PARAMETER All
  One tick per workspace in cloudRegistry, so every heavy workspace on the machine is covered rather
  than the one repo that happened to be configured first. Each workspace is ticked by the same body
  below (re-invoked with -Ws), so the bounds are identical per workspace. The day cap is per workspace
  too (it was one shared counter until 2026-11-25, which let one busy repo starve the rest).
  Exit: 0 all clear, 3 some workspace resumed but did not come up inside -WaitSec, 1 a tick failed.

.PARAMETER MaxTickSec
  Wall-clock bound for one -All tick. Measured 2026-11-25: eight workspaces cost eight `describe`
  calls, and a slow gcloud took the tick past two minutes, which risks overlapping the next one
  (IgnoreNew would then skip it silently). 0 = unbounded.

.PARAMETER Report
  Print what the last -ReportDays of ticks cost and bought, then do nothing else: wakes per workspace,
  how many were followed by a real cloud job inside the 45 minutes the VM stays up, the measured wake
  latency, cap hits and the idle exposure in USD. Read-only by construction - it never measures a VM
  and never resumes one. This is what makes the window, the cadence and the cap reviewable on data
  instead of on a replay script.

.PARAMETER VmState
  Skip the measurement and act as if the VM were in this state. For tests, and for a caller that has
  already measured it; without it the state comes from `gcloud compute instances describe`.

.PARAMETER TickLog
  Append the narration to this file as well, for a tick with no terminal: a no-op still leaves a line
  saying why. Trimmed to its last 300 lines once it passes 256 KB. (Not `-Log`: PowerShell ignores
  case, so `-Log` and this file's own record of resumes were one variable, and the first run wrote
  every narration line into the counter it was supposed to keep clean - measured 2026-11-25.)

.PARAMETER VerifyTask
  Check that the scheduled task runs THIS copy, without measuring or resuming anything. Exit 0 when it
  does, or when no such task is registered (then nothing points at any copy); exit 1 when it runs a
  different file, naming the one-line fix. Run it after an install, and from the task's own command
  line when a tick behaves like code nobody committed.

.PARAMETER RepairTask
  Re-register the task's action against this file. The host's Execute is preserved (this machine wraps
  the command in wscript + hidden-run.vbs so no console flashes) and every argument except the -File
  value is kept verbatim, so -All and the knob values survive. The task is read back afterwards and the
  exit code is its verdict, not the repair's. Refused from -TaskFile: a fake reading must not rewrite a
  real task.

.PARAMETER TaskName
  Scheduled task to check or repair. Default codai-workspace-prewarm, the name this tool is registered
  under by default.

.PARAMETER TaskFile
  Path to compare the task's -File against, instead of this script's own. For tests: it lets the guard
  be proven against a known wrong value with no scheduled task involved, and -RepairTask refuses to run
  with it.

.EXAMPLE
  pwsh -NoProfile -File prewarm-cloud.ps1 -Repo vitals
  pwsh -NoProfile -File prewarm-cloud.ps1 -Ws vitals-win -ActivityMin 30 -WaitSec 90
  agentq prewarm -All                                     # the form a scheduled task runs
  New-Item -ItemType File "$HOME\.codai\coord\prewarm\off"    # stop it, now and later

.NOTES
  Root, ConfigPath and Gcloud fall back to AGENTQ_HOME, AGENTQ_CONFIG and AGENTQ_GCLOUD, so a caller can
  redirect the whole tool through the environment instead of every flag. Until 2026-11-25 Gcloud did not:
  its default was the literal 'gcloud' while agentq - the only caller - reads AGENTQ_GCLOUD for its own
  measurement, so a test that exported the variable measured the fake and RESUMED REAL VMs. Same for
  ConfigPath, which silently ignored a redirected config and used the registry of the installed copy.
#>
[CmdletBinding()]
param(
    [string]$Ws,
    [string]$Repo = 'vitals',
    [int]$MaxResumesPerDay = 6,
  # Must exceed the scheduled task's interval (PT20M) by a margin. The journal is only read when the
  # tick fires, so activity starting just after a tick is invisible to a window shorter than the
  # cadence: measured with -ActivityMin 10 against PT20M, activity in the 25 min before the tick but
  # not in the 10 min before it was missed on 76 of 409 (workspace, tick) pairs - 19% of the ticks
  # that had something to warm ran blind. -VerifyTask fails when this is below the task's interval.
  [int]$ActivityMin = 25,
  # The ceiling for the self-sized window (see the gate below): twice the cadence plus margin, so a
  # skipped tick is still covered but a long outage is not. Past this the warm is pointless anyway -
  # the whole job of a prewarm is to hide a ~41 s resume behind an imminent gate, and work submitted
  # more than 45 min before the tick runs has already been waiting on a machine that never came up.
  # It caps the window, not the number of resumes: -MaxResumesPerDay does that.
  [int]$MaxWindowMin = 45,
    [int]$WaitSec = 0,
    [int]$MaxJournalLines = 600,
    [int]$MaxTickSec = 0,
    [int]$ReportDays = 7,
    [string]$VmState,
    [string]$Gcloud,
    [string]$Root,
    [string]$ConfigPath,
    [string]$TickLog,
    [switch]$All,
    [switch]$Report,
    [switch]$Off,
    [switch]$Quiet,
    # The scheduled-task guard (see -VerifyTask). It lives on this script rather than only on the agentq
    # verb because the verb forwards a whitelist of flags: an operator debugging a broken task has to be
    # able to run the task's OWN recorded command line against the copy it names.
    [string]$TaskName = 'codai-workspace-prewarm',
    [string]$TaskFile,
    # A second test seam: the cadence a real scheduled task would report. Kept apart from -TaskFile so a
    # test can exercise the window-vs-cadence guard without reading, or rewriting, a real task.
    [int]$TaskCadenceMin = 0,
    [switch]$VerifyTask,
    [switch]$RepairTask
)
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' } }
if (-not $ConfigPath) { $ConfigPath = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $PSScriptRoot 'agentq-config.json' } }
if (-not $Gcloud) { $Gcloud = if ($env:AGENTQ_GCLOUD) { $env:AGENTQ_GCLOUD } else { 'gcloud' } }

# ---- the scheduled task must run the INSTALLED copy ----------------------------------------------
# A task's action records a path, and a path recorded by hand points wherever it was typed: on
# 2026-11-25 this machine's task named E:\gh\agentq\ps\bin\prewarm-cloud.ps1 - the source checkout - so
# every unattended tick ran whatever was uncommitted in the tree that was being edited. A checkout-named
# task also survives an install as a silent second copy, and a tick that runs the wrong file still
# leaves a healthy-looking log, so nothing else reports it. install.ps1 re-points the task on install;
# this is the check that makes the state visible in between, and after any hand edit of the task.
# It runs before the kill switch and before anything is written: a verdict must be readable even when
# the tool is switched off.
$self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
if ($VerifyTask -or $RepairTask) {
    $tn = if ($TaskName) { $TaskName } else { 'codai-workspace-prewarm' }
    $action = $null
    $cadences = @()
    if ($TaskFile) {
        # A test seam: no scheduled task is read, and -RepairTask is refused below, because a value a
        # test supplied must never rewrite a real task.
        $action = [pscustomobject]@{ Execute = 'pwsh.exe'; Arguments = ('-NoProfile -File "' + $TaskFile + '"') }
      if ($TaskCadenceMin -gt 0) { $cadences = @([TimeSpan]::FromMinutes($TaskCadenceMin)) }
    } else {
        $task = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
        if (-not $task) { Write-Output ("task '{0}' is not registered on this host - nothing points at any copy" -f $tn); exit 0 }
        $action = @($task.Actions)[0]
      # ISO 8601 (PT20M), which is what a ScheduledTasks repetition interval holds - TimeSpan.Parse
      # does not read that form, XmlConvert does. A trigger without a repetition has no cadence to
      # compare against, and the guard then stays silent rather than guessing one.
      foreach ($tr in @($task.Triggers)) {
        $iv = "$($tr.Repetition.Interval)"
        if ($iv) { try { $cadences += [Xml.XmlConvert]::ToTimeSpan($iv) } catch { } }
      }
    }
    $argLine = "$($action.Arguments)"
    $found = [regex]::Match($argLine, '-File\s+"?([^"]+?)"?(\s|$)')
    $runs = if ($found.Success) { $found.Groups[1].Value.Trim() } else { '' }
    $same = $runs -and ($runs.TrimEnd('\') -ieq "$self".TrimEnd('\'))
    if ($RepairTask) {
        if ($TaskFile) { Write-Output 'refused: -RepairTask cannot run from -TaskFile (a test seam must not rewrite a real scheduled task)'; exit 2 }
        if (-not $found.Success) { Write-Output ("refused: the action of '{0}' names no -File to re-point: {1}" -f $tn, $argLine); exit 2 }
        $fixed = $argLine.Remove($found.Groups[1].Index, $found.Groups[1].Length).Insert($found.Groups[1].Index, $self)
        $exe = if ("$($action.Execute)") { "$($action.Execute)" } else { 'pwsh.exe' }
        try { Set-ScheduledTask -TaskName $tn -Action (New-ScheduledTaskAction -Execute $exe -Argument $fixed) | Out-Null }
        catch { Write-Output ("could not re-point '{0}': {1}" -f $tn, $_.Exception.Message); exit 1 }
        # Read the task back: the repair is a state change, so the state is the proof, not the Set call.
        $after = [regex]::Match("$(@((Get-ScheduledTask -TaskName $tn).Actions)[0].Arguments)", '-File\s+"?([^"]+?)"?(\s|$)')
        $now = if ($after.Success) { $after.Groups[1].Value.Trim() } else { '' }
        if ($now.TrimEnd('\') -ieq "$self".TrimEnd('\')) { Write-Output ("task '{0}' -> {1} (via {2})" -f $tn, $self, $exe); exit 0 }
        Write-Output ("re-pointed '{0}' but it now names '{1}' - read it back by hand" -f $tn, $now)
        exit 1
    }
    if (-not $same) {
      Write-Output ("task '{0}' runs a DIFFERENT copy: '{1}'" -f $tn, $runs)
      Write-Output ('fix: pwsh -NoProfile -File "' + $self + '" -RepairTask')
      exit 1
    }
    # The window is an argument of the action, not a property of the path, so it is read from the same
    # line the path came from: -VerifyTask must judge what the tick will actually use, not this file's
    # default. A path-only repair cannot fix a wrong window, which is why this is a separate verdict.
    $window = $ActivityMin
    $fromAction = [regex]::Match($argLine, '-ActivityMin\s+(\d+)')
    if ($fromAction.Success) { $window = [int]$fromAction.Groups[1].Value }
    if ($cadences.Count) {
      $cad = ($cadences | Measure-Object -Minimum).Minimum
      $margin = [TimeSpan]::FromMinutes(5)
      if ([TimeSpan]::FromMinutes($window) -lt $cad + $margin) {
        Write-Output ("task '{0}' runs this copy ({1}) but its window is TOO NARROW: -ActivityMin {2} against a cadence of {3:hh\:mm} - the journal is read only when the tick fires, so activity that starts just after a tick is invisible to the window and the tick skips a machine it had something to warm" -f $tn, $self, $window, $cad)
        Write-Output ('fix: run the task with -ActivityMin {0} or more (cadence + 5 min), and put the same number in this file''s default' -f [int]($cad.TotalMinutes + 5))
        exit 1
      }
      Write-Output ("task '{0}' runs this copy ({1}); window {2} min against a cadence of {3:hh\:mm}" -f $tn, $self, $window, $cad)
      exit 0
    }
    Write-Output ("task '{0}' runs this copy ({1})" -f $tn, $self)
    exit 0
}

$dir = Join-Path $Root 'prewarm'
if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Force -Path $dir }
$records = Join-Path $dir 'resumes.jsonl'
$kill = Join-Path $dir 'off'
$journal = Join-Path $Root 'journal.jsonl'
$Session = ''
foreach ($v in $env:AGENTQ_SESSION, $env:COPILOT_SESSION_ID, $env:COPILOT_AGENT_SESSION_ID, $env:CLAUDE_SESSION_ID) { if ($v) { $Session = $v; break } }

function Say([string]$s) {
    $line = "prewarm: $s"
    if (-not $Quiet) { Write-Output $line }
    if ($script:LogPath) { [IO.File]::AppendAllText($script:LogPath, "$([DateTime]::UtcNow.ToString('o')) $line`n", [Text.UTF8Encoding]::new($false)) }}

# One line per decision that matters. A tick that has nothing to do writes nothing on purpose: the
# file is read by the cap below, and a refusal per tick would drown the resumes it exists to count.
function Note([hashtable]$e) {
    $e.ts = [DateTime]::UtcNow.ToString('o')
    if ($Session) { $e.session = $Session }
    [IO.File]::AppendAllText($records, (($e | ConvertTo-Json -Compress -Depth 4) + "`n"), [Text.UTF8Encoding]::new($false))
}

function Read-Lines([string]$path, [int]$tail) {
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { return @(Get-Content -LiteralPath $path -Tail $tail) } catch { return @() }
}

# A timestamp read back from JSON is a [DateTime], not a string: ConvertFrom-Json converts the ISO
# form, and its printed shape is culture-dependent ("11/25/2026 22:41:00"). Comparing that against
# 'yyyy-MM-dd' is false for every record ever written, which is how the daily cap first counted zero
# and would never have stopped - found by the suite, 2026-11-25. Compare instants instead.
function To-UtcInstant($value) {
    if ($value -is [DateTime]) {
        $d = [DateTime]$value
        if ($d.Kind -eq [DateTimeKind]::Unspecified) { return [DateTime]::SpecifyKind($d, [DateTimeKind]::Utc) }
        return $d.ToUniversalTime()
    }
    $parsed = [DateTime]::MinValue
    if ([DateTime]::TryParse("$value", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed }
    return $null
}

# An unattended tick has no terminal, so -Log is where a quiet no-op becomes visible. The file is
# trimmed rather than left to grow: a tick every 20 minutes is 26,000 lines a year, and the useful
# part of that record is the end of it.
$script:LogPath = ''
if ($TickLog) {
    $logDir = Split-Path -Parent $TickLog
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) { $null = New-Item -ItemType Directory -Force -Path $logDir }
    if ((Test-Path -LiteralPath $TickLog) -and ((Get-Item -LiteralPath $TickLog).Length -gt 262144)) {
      $keep = @(Get-Content -LiteralPath $TickLog -Tail 300) -join "`n"
      # Then a byte cap as well, because "the last 300 lines" bounds nothing when one line is huge -
      # the line trim alone left a 600 KB single-line file at 600 KB (suite, 2026-11-25). A cut in
      # the middle of a line is acceptable here: this is a tick log, not a record that is parsed.
      if ($keep.Length -gt 65536) { $keep = $keep.Substring($keep.Length - 65536) }
      [IO.File]::WriteAllText($TickLog, ($keep + "`n"), [Text.UTF8Encoding]::new($false))
    }
    $script:LogPath = $TickLog
}

if ($Off -or (Test-Path -LiteralPath $kill)) { Say "disabled (kill switch $kill)"; exit 0 }

# A heartbeat the moment a tick starts, before anything can fail. Without it a tick that dies early
# leaves an empty log, and an empty log is indistinguishable from a task that never fired - which is
# how the unquoted --format below stayed invisible through the first scheduled run (measured live
# 2026-11-25: the task reported success because wscript's own exit code says nothing about the child).
# `-All` has no workspace of its own yet: naming one repo here read as "every workspace is gated on
# the repo the caller happened to be standing in" in the owner's tick log (seen 2026-11-25).
Say "tick $(if ($Ws) { "ws=$Ws" } elseif ($Report) { 'report' } elseif ($All) { 'all' } else { "ws=repo:$Repo" })"

# ---- configuration ------------------------------------------------------------------------------
# cloudWorkspaces maps a repo to the workspace that serves it; cloudRegistry maps a workspace to the
# project and zone it lives in. Both are read rather than duplicated here, so a moved workspace is
# moved once.
$registry = @{}
$map = @{}
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
        if ($cfg.PSObject.Properties['cloudRegistry'] -and $cfg.cloudRegistry) {
            foreach ($p in $cfg.cloudRegistry.PSObject.Properties) { $registry[$p.Name] = @{ project = "$($p.Value.project)"; zone = "$($p.Value.zone)" } }
        }
        if ($cfg.PSObject.Properties['cloudWorkspaces'] -and $cfg.cloudWorkspaces) {
            foreach ($p in $cfg.cloudWorkspaces.PSObject.Properties) { $map[$p.Name] = @($p.Value) }
        }
    } catch { Say "could not read $ConfigPath ($($_.Exception.Message))" }
}

# ---- what the last days cost ---------------------------------------------------------------------
# The window, the cadence and the cap are money decisions, and a money decision needs a number rather
# than an argument. This prints what the last -ReportDays of ticks actually did: how many wakes per
# workspace, how many of them were followed by a real cloud job inside the 45 minutes the VM stays up,
# the measured wake latency, and the idle exposure in USD. Read-only by construction - it never runs a
# gcloud command, so it is safe from any context, including a tick that is mid-run.
if ($Report) {
  $since = [DateTime]::UtcNow.AddDays(-$ReportDays)
  $idleUsdPerHour = 1.14
  # The CPU-idle self-suspend is the cost policy: a wake nobody uses inside it is the whole waste.
  $usableMin = 45
  $keys = @($registry.Keys)
  $wakes = @{}
  $latencies = @{}
  $failed = @{}
  $caps = @{}
  foreach ($w in $keys) {
    $wakes[$w] = [Collections.Generic.List[object]]::new()
    $latencies[$w] = [Collections.Generic.List[double]]::new()
    $failed[$w] = 0
    $caps[$w] = 0
  }
  $seen = 0
  foreach ($line in Read-Lines $records 5000) {
    if (-not "$line".Trim()) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    $ws = "$($e.ws)"
    if (-not $ws -or -not $wakes.ContainsKey($ws)) { continue }
    $ts = To-UtcInstant $e.ts
    if (-not $ts -or $ts -lt $since) { continue }
    $seen++
    switch ("$($e.action)") {
      'resume' { $wakes[$ws].Add($ts) }
      'resume-failed' { $failed[$ws]++ }
      'cap' { $caps[$ws]++ }
      'prewarm-verified' { if ($null -ne $e.prewarmSec) { $latencies[$ws].Add([double]$e.prewarmSec) } }
    }
  }
  # Usefulness is judged against the journal, not against the tick's own narration: a wake bought
  # something only if a cloud job for that workspace followed inside the window the VM stays up. The
  # tail is deliberately generous - a 7-day window needs tens of thousands of lines, and a report that
  # reads too little would report a wake as wasted simply because it could not see the job.
  $jobs = @{}
  foreach ($line in Read-Lines $journal ([Math]::Max($MaxJournalLines, 80000))) {
    if (-not "$line".Trim()) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    if ("$($e.event)" -ne 'cloud-queued') { continue }
    $r = "$($e.repo)"
    if (-not $r) { continue }
    $ts = To-UtcInstant $e.ts
    if (-not $ts) { continue }
    if (-not $jobs.ContainsKey($r)) { $jobs[$r] = [Collections.Generic.List[object]]::new() }
    $jobs[$r].Add($ts)
  }
  $days = if ($ReportDays -gt 0) { $ReportDays } else { 1 }
  "prewarm report: last $days day(s), since $($since.ToString('yyyy-MM-dd HH:mm'))Z, $seen record(s)"
  '{0,-16} {1,6} {2,7} {3,5} {4,7} {5,7} {6,7}' -f 'ws', 'wakes', 'failed', 'cap', 'useful', 'wasted', 'median'
  $totWakes = 0; $totUseful = 0; $totWasted = 0; $totFailed = 0; $totCaps = 0
  $allLat = [Collections.Generic.List[double]]::new()
  foreach ($w in @($keys | Sort-Object)) {
    $serves = @($map.Keys | Where-Object { @($map[$_]) -contains "$w" })
    $useful = 0; $wasted = 0
    foreach ($t in $wakes[$w]) {
      $hit = $false
      foreach ($r in $serves) {
        if (-not $jobs.ContainsKey($r)) { continue }
        foreach ($jt in $jobs[$r]) {
          if ($jt -ge $t -and ($jt - $t).TotalMinutes -le $usableMin) { $hit = $true; break }
        }
        if ($hit) { break }
      }
      if ($hit) { $useful++ } else { $wasted++ }
    }
    $median = ''
    if ($latencies[$w].Count) {
      $sorted = @($latencies[$w] | Sort-Object)
      $median = '{0:N1}s' -f $sorted[[int][Math]::Floor($sorted.Count / 2)]
      foreach ($v in $latencies[$w]) { $allLat.Add($v) }
    }
    $totWakes += $wakes[$w].Count; $totUseful += $useful; $totWasted += $wasted
    $totFailed += $failed[$w]; $totCaps += $caps[$w]
    if ($wakes[$w].Count -or $caps[$w]) {
      '{0,-16} {1,6} {2,7} {3,5} {4,7} {5,7} {6,7}' -f $w, $wakes[$w].Count, $failed[$w], $caps[$w], $useful, $wasted, $median
    }
  }
  $pct = if ($totWakes) { [math]::Round(100 * $totUseful / $totWakes) } else { 0 }
  $usd = [math]::Round($totWasted * ($usableMin / 60) * $idleUsdPerHour, 2)
  "totals          : $totWakes wake(s) in $days day(s) = $([math]::Round($totWakes / $days, 1))/day; useful $totUseful ($pct%), wasted $totWasted, failed $totFailed, cap hits $totCaps"
  "exposure        : at most $usd USD of idle VM time (every wasted wake x $usableMin min x $idleUsdPerHour USD/h)"
  if ($allLat.Count) {
    $s = @($allLat | Sort-Object)
    "latency         : measured on $($allLat.Count) of $totWakes wake(s); median $('{0:N1}s' -f $s[[int][Math]::Floor($s.Count / 2)])"
  } else {
    'latency         : unmeasured - no wake in this window waited for RUNNING (-WaitSec 0)'
  }
  "settings        : -ActivityMin $ActivityMin, -MaxResumesPerDay $MaxResumesPerDay per workspace; the cadence is the scheduled task's"
  exit 0
}

# -All: every registered workspace, not just the one this repo maps to. Each workspace is ticked by
# RE-INVOKING this script with -Ws set, so there is exactly one implementation of the bounds and a
# failure in one workspace cannot stop the rest. The child's `exit` returns here (script semantics).
if ($All -and -not $Ws) {
    if ($registry.Count -eq 0) { Say "no workspaces in $ConfigPath cloudRegistry; nothing to warm"; exit 0 }
  # -Repo is deliberately NOT forwarded: each child derives the repos that map to its own workspace,
  # and an inherited one silently became the activity gate of every unmapped workspace - ws-brivio and
  # ws-caelia-android were warming on VITALS activity (measured 2026-11-25), i.e. waking a machine for
  # another machine's work. A workspace no repo maps to is skipped below instead.
  $fwd = @{ Root = $Root; ConfigPath = $ConfigPath; ActivityMin = $ActivityMin
              MaxResumesPerDay = $MaxResumesPerDay; WaitSec = $WaitSec; MaxJournalLines = $MaxJournalLines; Gcloud = $Gcloud }
    # Only when set, or an empty -TickLog would turn the child's log off and an empty -VmState is a no-op
    # that reads like a measurement was passed in. Splatted as a HASHTABLE: an array splat is positional,
    # so `'-Root','C:\...'` bound "-Root" to the next parameter's int and every child died on the argument
    # conversion instead of ticking (found by test-agentq-prewarm-verb.ps1, which is why -All is tested).
    if ($VmState) { $fwd['VmState'] = $VmState }
    if ($TickLog) { $fwd['TickLog'] = $TickLog }
    if ($Quiet) { $fwd['Quiet'] = $true }
    # Most recently active first. A tick is bounded and the day cap can truncate it, so the wakes that
    # survive should be the ones an agent is most likely to use: an idle workspace only costs money.
    $lastAt = @{}
    foreach ($line in Read-Lines $journal $MaxJournalLines) {
      if (-not "$line".Trim()) { continue }
      try { $e = $line | ConvertFrom-Json } catch { continue }
      $ts = To-UtcInstant $e.ts
      $r = "$($e.repo)"
      if (-not $ts -or -not $r) { continue }
      if (-not $lastAt.ContainsKey($r) -or $ts -gt $lastAt[$r]) { $lastAt[$r] = $ts }
    }
    $plan = foreach ($w in @($registry.Keys)) {
      # A workspace with no repo mapped to it has no signal to gate on: ticking it would warm it on
      # whatever -Repo said, i.e. wake a machine for another machine's work. Skip is the only honest
      # option - and it is recorded, so a workspace that silently never warms is visible.
      $serves = @($map.Keys | Where-Object { @($map[$_]) -contains "$w" })
      $last = [DateTime]::MinValue
      foreach ($r in $serves) { if ($lastAt.ContainsKey($r) -and $lastAt[$r] -gt $last) { $last = $lastAt[$r] } }
      [pscustomobject]@{ Ws = "$w"; Serves = $serves; Last = $last }
    }
    $plan = @($plan | Sort-Object -Property @{ Expression = 'Last'; Descending = $true }, @{ Expression = 'Ws' })
    Say "order: $(@($plan | ForEach-Object { $_.Ws }) -join ' > ')"

    $worst = 0
    $skipped = @()
    $tick = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $plan.Count; $i++) {
      $p = $plan[$i]
      if ($MaxTickSec -gt 0 -and $tick.Elapsed.TotalSeconds -ge $MaxTickSec) {
        Say "stopping at $([int]$tick.Elapsed.TotalSeconds)s (-MaxTickSec $MaxTickSec); $($plan.Count - $i) workspace(s) wait for the next tick"
        break
      }
      if ($p.Serves.Count -eq 0) {
        $skipped += $p.Ws
        Say "skip ws-$($p.Ws) (no repo maps to it in cloudWorkspaces; nothing to gate a wake on)"
        continue
      }
      & $PSCommandPath -Ws "$($p.Ws)" @fwd
        if ($LASTEXITCODE -eq 1) { $worst = 1 }
        elseif ($LASTEXITCODE -eq 3 -and $worst -eq 0) { $worst = 3 }
    }
    $ticked = $registry.Count - $skipped.Count
    $skipNote = ''
    if ($skipped.Count) { $skipNote = '; skipped ' + ((@($skipped) | Sort-Object) -join ', ') + ' (no mapped repo)' }
    Say "all: $ticked of $($registry.Count) workspace(s) ticked$skipNote"
    exit $worst
}

if (-not $Ws) {
    if (-not $map.ContainsKey($Repo)) { Say "no workspace mapped for '$Repo' in $ConfigPath; pass -Ws"; exit 1 }
    $list = @($map[$Repo])
    $Ws = "$($list[0])"
}
if (-not $registry.ContainsKey($Ws)) { Say "workspace '$Ws' is not in cloudRegistry; refusing to guess its project and zone"; exit 1 }

# Which repos justify warming this workspace: every repo that maps to it, so the activity gate is
# about the machine rather than about the one repo the caller happened to name.
$served = @($map.Keys | Where-Object { @($map[$_]) -contains $Ws })
if ($served.Count -eq 0) { $served = @($Repo) }

$reg = $registry[$Ws]
$vm = "ws-$Ws"

# ---- how far back the activity gate must look ---------------------------------------------------
# A fixed window cannot see work that began just after a tick, and the trigger does not always fire on
# time: measured 2026-11-27 over 105 tick intervals, 10 exceeded the 20 min cadence and 3 exceeded
# 25 min (worst 99.8 min), each of them while the machine was heavily loaded - so ticks are skipped
# exactly when there is work to warm for. The window is therefore at least -ActivityMin and at least
# the interval since this machine was last decided on, which makes coverage independent of punctuality.
# The stamp is written when the round STARTS, so it records when the machine was last looked at rather
# than what was found, and it is advanced even by a round that decides to do nothing. It is PER
# WORKSPACE: a targeted `agentq prewarm -Ws x` says only that x was looked at, and letting it shrink
# every other machine's window would recreate the hole this exists to close.
$windowMin = $ActivityMin
$gapMin = $null
$stamp = Join-Path $dir "last-tick-$Ws"
if (Test-Path -LiteralPath $stamp) {
  $prev = To-UtcInstant (Get-Content -LiteralPath $stamp -Raw -ErrorAction SilentlyContinue)
  if ($prev) {
    # +1 min: the round's own duration and scheduler jitter must not leave a sliver no tick covers.
    $gapMin = [Math]::Round(([DateTime]::UtcNow - $prev).TotalMinutes, 1) + 1
    if ($gapMin -gt $windowMin) { $windowMin = [int][Math]::Min($gapMin, [Math]::Max($MaxWindowMin, $ActivityMin)) }
  }
}
try { [IO.File]::WriteAllText($stamp, [DateTime]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false)) } catch { }

# ---- state -------------------------------------------------------------------------------------
$state = $VmState
$measured = $false
if (-not $state) {
    if (-not (Get-Command $Gcloud -ErrorAction SilentlyContinue)) { Say "gcloud not found; nothing measured, nothing done"; exit 0 }
    # The filter is quoted on purpose: argument mode parses the parenthesis in `--format=value(status)`
    # as a subexpression and dies with "The term 'status' is not recognized", so the measurement never
    # happens and every tick looks like a machine that cannot be measured (measured 2026-11-25).
    $out = & $Gcloud compute instances describe $vm --project $reg.project --zone $reg.zone --format 'value(status)' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not "$out".Trim()) { Say "could not measure $vm (describe exit $LASTEXITCODE); doing nothing"; exit 0 }
    $state = "$out".Trim()
    $measured = $true
}
Say "$vm is $state"
# What was just measured is written down, because the hint at first contact reads this record instead of
# calling gcloud (Get-PrewarmVmStatus in agentq.ps1): that hint runs inside `agentq since`, an agent's
# first command, and a live describe there made one suite run take 6 minutes instead of 52 seconds
# (2026-11-25). Every measurement counts, RUNNING included - a fresh RUNNING is what keeps the hint
# quiet, and silence on the healthy path is what keeps the hint readable. This is the only writer.
if ($measured) {
  try {
    $rec = @{ atSec = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); status = $state }
    [IO.File]::WriteAllText((Join-Path $dir "vmstate-$Ws.json"), ($rec | ConvertTo-Json -Compress))
  } catch { }
}
if ($state -eq 'RUNNING') { Say 'already running; left to the idle self-suspend'; exit 0 }
if ($state -ne 'SUSPENDED') { Say "state '$state' is not SUSPENDED; not mine to change"; exit 0 }

# ---- the daily cap ------------------------------------------------------------------------------
# PER WORKSPACE: the counter is filtered by ws below. A single shared budget looked equivalent until the
# replay said otherwise (2026-11-25: ~25 legitimate wakes a day over five workspaces, so 6 shared either
# throttled three quarters of them or let ws-codai - 215 of the 354 paid resumes - eat the whole day).
$today = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
$used = 0
$capLogged = $false
foreach ($line in Read-Lines $records 400) {
    if (-not "$line".Trim()) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    $ts = To-UtcInstant $e.ts
    if (-not $ts -or $ts.ToString('yyyy-MM-dd') -ne $today) { continue }
  if ("$($e.ws)" -ne $Ws) { continue }
  if ("$($e.action)" -eq 'resume') { $used++ }
    if ("$($e.action)" -eq 'cap') { $capLogged = $true }
}
if ($used -ge $MaxResumesPerDay) {
  Say "daily cap reached for ws-$Ws ($used/$MaxResumesPerDay today)"
    if (-not $capLogged) { Note @{ ws = $Ws; vm = $vm; action = 'cap'; state = $state; cap = $MaxResumesPerDay } }
    exit 0
}

# ---- is anyone working? -------------------------------------------------------------------------
# The journal is the record of what agents actually did (agentq writes one line per acquisition, start
# and finish). Activity on the repos this workspace serves, inside the window, is the whole signal: no
# entries means nothing to warm for, and the tick costs one file read.
# The sentence keeps the -ActivityMin number as the floor a caller asked for, and names the extension
# separately when the window had to grow: a reader who set 25 and sees "47 min" would otherwise think
# the tool ignored the flag.
$ext = if ($windowMin -ne $ActivityMin) { " (extended to ${windowMin} min: the previous tick was $($gapMin - 1) min ago)" } else { '' }
$since = [DateTime]::UtcNow.AddMinutes(-$windowMin)
$active = 0
$newest = $null
foreach ($line in Read-Lines $journal $MaxJournalLines) {
    if (-not "$line".Trim()) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    $ts = To-UtcInstant $e.ts
    if (-not $ts -or $ts -lt $since) { continue }
    if ($served -contains "$($e.repo)") { $active++; if (-not $newest -or $ts -gt $newest) { $newest = $ts } }
}
if ($active -eq 0) {
  Say "no $($served -join '/') activity in the last ${ActivityMin} min$ext (last $MaxJournalLines journal lines); nothing to warm for"
    exit 0
}
Say "$active journal entr$(if ($active -eq 1) { 'y' } else { 'ies' }) in the last ${ActivityMin} min$ext (newest $($newest.ToString('HH:mm:ss'))Z); warming"

# ---- resume -------------------------------------------------------------------------------------
Say "resuming $vm ($($used + 1)/$MaxResumesPerDay today)"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $Gcloud compute instances resume $vm --project $reg.project --zone $reg.zone --quiet | Out-Null
$rc = $LASTEXITCODE
Note @{ ws = $Ws; vm = $vm; action = $(if ($rc -eq 0) { 'resume' } else { 'resume-failed' }); state = $state; reason = "activity:$active/${windowMin}min"; exit = $rc }
if ($rc -ne 0) { Say "resume failed (exit $rc)"; exit 1 }
if ($WaitSec -le 0) { Say 'resumed; not waiting (-WaitSec 0)'; exit 0 }

# Waiting is bounded and optional: a caller that only wanted the clock started should not hold a
# terminal, and one that needs the machine says so with -WaitSec.
while ($sw.Elapsed.TotalSeconds -lt $WaitSec) {
    Start-Sleep -Seconds 5
    $s = & $Gcloud compute instances describe $vm --project $reg.project --zone $reg.zone --format 'value(status)' 2>$null
  if ("$s".Trim() -eq 'RUNNING') {
    # The measured wake latency, recorded so the next decision about the window and the cadence uses
    # a measurement instead of a replay estimate (owner, 2026-11-25). It is only written when RUNNING
    # was actually seen: an unmeasured latency is absent, never 0 - a 0 s wake and a wake nobody
    # watched are different facts, and averaging them together is how a budget lies.
    $sec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    Say "RUNNING after ${sec}s"
    Note @{ ws = $Ws; vm = $vm; action = 'prewarm-verified'; prewarmSec = $sec }
    exit 0
  }
}
Say "still not RUNNING after ${WaitSec}s"
Note @{ ws = $Ws; vm = $vm; action = 'prewarm-unmeasured'; waited = $WaitSec }
exit 3
