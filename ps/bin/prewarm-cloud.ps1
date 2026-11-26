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
  below (re-invoked with -Ws), so the bounds are identical per workspace and the day cap is shared.
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
    [int]$ActivityMin = 10,
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
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' } }
if (-not $ConfigPath) { $ConfigPath = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $PSScriptRoot 'agentq-config.json' } }
if (-not $Gcloud) { $Gcloud = if ($env:AGENTQ_GCLOUD) { $env:AGENTQ_GCLOUD } else { 'gcloud' } }
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
$since = [DateTime]::UtcNow.AddMinutes(-$ActivityMin)
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
    Say "no $($served -join '/') activity in the last ${ActivityMin} min (last $MaxJournalLines journal lines); nothing to warm for"
    exit 0
}
Say "$active journal entr$(if ($active -eq 1) { 'y' } else { 'ies' }) in the last ${ActivityMin} min (newest $($newest.ToString('HH:mm:ss'))Z); warming"

# ---- resume -------------------------------------------------------------------------------------
Say "resuming $vm ($($used + 1)/$MaxResumesPerDay today)"
$sw = [System.Diagnostics.Stopwatch]::StartNew()
& $Gcloud compute instances resume $vm --project $reg.project --zone $reg.zone --quiet | Out-Null
$rc = $LASTEXITCODE
Note @{ ws = $Ws; vm = $vm; action = $(if ($rc -eq 0) { 'resume' } else { 'resume-failed' }); state = $state; reason = "activity:$active/${ActivityMin}min"; exit = $rc }
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
