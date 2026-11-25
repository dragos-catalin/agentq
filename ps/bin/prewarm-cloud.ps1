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
    * -MaxResumesPerDay caps the day, and one file turns it off entirely.

  It never creates, stops or suspends a VM. The only write is `gcloud compute instances resume`, and
  only for a suspended workspace that is under its cap.

  Exit codes: 0 = nothing to do, or resumed; 3 = resumed but not RUNNING inside -WaitSec; 1 = error.
  Every tick prints its reason, so "no activity" in a log is a claim you can check against the journal.

.PARAMETER Ws
  Workspace to keep warm, for example vitals-win. Default: what agentq-config.json maps -Repo to.

.PARAMETER Repo
  Repository whose activity justifies the resume (default vitals), and where -Ws comes from when -Ws
  is not given.

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
  New-Item -ItemType File "$HOME\.codai\coord\prewarm\off"    # stop it, now and later
#>
[CmdletBinding()]
param(
    [string]$Ws,
    [string]$Repo = 'vitals',
    [int]$MaxResumesPerDay = 6,
    [int]$ActivityMin = 10,
    [int]$WaitSec = 0,
    [int]$MaxJournalLines = 600,
    [string]$VmState,
    [string]$Gcloud = 'gcloud',
    [string]$Root,
    [string]$ConfigPath,
    [string]$TickLog,
    [switch]$Off,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

if (-not $Root) { $Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' } }
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'agentq-config.json' }
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
Say "tick ws=$(if ($Ws) { $Ws } else { "repo:$Repo" })"

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
if (-not $state) {
    if (-not (Get-Command $Gcloud -ErrorAction SilentlyContinue)) { Say "gcloud not found; nothing measured, nothing done"; exit 0 }
    # The filter is quoted on purpose: argument mode parses the parenthesis in `--format=value(status)`
    # as a subexpression and dies with "The term 'status' is not recognized", so the measurement never
    # happens and every tick looks like a machine that cannot be measured (measured 2026-11-25).
    $out = & $Gcloud compute instances describe $vm --project $reg.project --zone $reg.zone --format 'value(status)' 2>$null
    if ($LASTEXITCODE -ne 0 -or -not "$out".Trim()) { Say "could not measure $vm (describe exit $LASTEXITCODE); doing nothing"; exit 0 }
    $state = "$out".Trim()
}
Say "$vm is $state"
if ($state -eq 'RUNNING') { Say 'already running; left to the idle self-suspend'; exit 0 }
if ($state -ne 'SUSPENDED') { Say "state '$state' is not SUSPENDED; not mine to change"; exit 0 }

# ---- the daily cap ------------------------------------------------------------------------------
$today = [DateTime]::UtcNow.ToString('yyyy-MM-dd')
$used = 0
$capLogged = $false
foreach ($line in Read-Lines $records 400) {
    if (-not "$line".Trim()) { continue }
    try { $e = $line | ConvertFrom-Json } catch { continue }
    $ts = To-UtcInstant $e.ts
    if (-not $ts -or $ts.ToString('yyyy-MM-dd') -ne $today) { continue }
    if ("$($e.action)" -eq 'resume') { $used++ }
    if ("$($e.action)" -eq 'cap') { $capLogged = $true }
}
if ($used -ge $MaxResumesPerDay) {
    Say "daily cap reached ($used/$MaxResumesPerDay)"
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
    if ("$s".Trim() -eq 'RUNNING') { Say "RUNNING after $([int]$sw.Elapsed.TotalSeconds)s"; exit 0 }
}
Say "still not RUNNING after ${WaitSec}s"; exit 3
