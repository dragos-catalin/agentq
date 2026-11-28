#requires -Version 5.1
<#
.SYNOPSIS
  Turn the recorded agentq land-gate timings into a table, ordered slowest-first (by the LAST run).

.DESCRIPTION
  Nobody can see which gate suite costs what. This module reads the sources that actually exist
  (verified on this machine, 2026-11-26 - the field names below were read, not assumed) and prints one
  row per suite: last wall time, median of the last N runs, run count, exit code of the last run and
  the total time.

  WHERE THE NUMBERS COME FROM

  1. THE BUILD LOGS - the ONLY source that carries PER-SUITE times.
       <slot>\.copilot-tmp\build-logs\<yyyyMMdd-HHmmss>-<cmd>.log
     run-build.ps1 writes the trailer (ps/hooks/run-build.ps1):
       === exit 0 after 572.6s
     The suite lines are written by run-all.ps1 Report-Suite:
       "{0,-15} exit={1} pass={2} fail={3} sec={4}"
         guard           exit=0 pass=20 fail=0 sec=10
         land default gate exit=0 pass=12 fail=0 sec=20
     (A name longer than 15 chars overflows the pad, so the separator is exactly ONE space - the name
     itself never contains ' exit=', which is what the parser keys on.)  The trailer's TOTAL line is
     'TOTAL sec=542 suites=27 failed=0 skipped=0'; it is recognised and ignored (it is not a suite).
     A gate log that ran through codai's own gate-run driver uses a second, recognised shape:
         gate-run:      0.17s  gate:distill-objective   pass
     'gate-run: slowest member: ..', 'gate-run: total wall ..' and 'gate-run: OK' are noise and are
     NOT rows - only '<sec>s <name> <verdict>' is.

  2. <root>\.copilot-tmp\last-green.json - written by run-all.ps1 on a fully green run:
       {"hash":"..","at":"2026-11-26T18:34:22","suites":74,"sec":1924,"psver":"7.6.10","machine":"DRAGOS"}
     AGGREGATE ONLY: a suite COUNT and a total, no per-suite time. It is printed as context and can
     never produce a row.

  3. ~/.codai/coord/journal.jsonl - JSON lines. Gate work is event "gate-script" with
     durSec/exit/cmd/purpose/resource/ts; a failure adds event "land-gate-failed" with `members` -
     the NAMES of the failing gate members, e.g. ["gate:ci-crosscheck"] - and NO durations.
     So the journal knows WHO failed and how long the WHOLE gate took, never what one suite cost.

  SEMANTICS
    LastSec    the seconds of that suite's most recent run (the ordering key, descending)
    MedianSec  the median of the LAST N runs' seconds (N = -Last, default 5): the window is taken by
               run order, sorted ascending, then the middle value (the mean of the two middle values
               when the window has an even size). It is computed FROM THE VALUES - never from the
               run count.
    Runs       how many runs of that suite were recorded
    BadRuns    how many of them did not exit 0
    LastExit   the exit code of the most recent run
    TotalSec   the SUM of every recorded run's seconds (all runs, not just the window)
    LastAt     the start timestamp of the most recent run, ISO sortable; '' when the file name carries
               no timestamp and the file has none
    Shape      'suite' (run-all.ps1) or 'gate-run' (codai's driver) - which line shape matched
    Source     the log file leaf name of the most recent run

  ORDER  LastSec descending, then Suite ascending (ordinal). A tie is broken by NAME, never by
  whatever order the filesystem returned.

  DEGRADING  With nothing to read it prints `agentq-timings: no timings recorded (...)` and exits 3.
  It never throws and never prints an empty table as if it were healthy - an empty table is exactly
  the failure this tool exists to make visible.

    A RESULT LINE WITH NO `sec=` (an older run-all.ps1 printed 'agentq v1  exit=0 pass=30 fail=0'; 5 of
    them exist in the 2026-10-06 land log) is REPORTED on stderr and SKIPPED, never counted as a run: a
    run with no duration would enter the median as a zero and make a slow suite look fast. Same for the
    naming of a suite the line does not carry. Reporting it is what keeps the skip visible.

  Examples:
    pwsh -NoProfile -File ps/bin/agentq-timings.ps1
    pwsh -NoProfile -File ps/bin/agentq-timings.ps1 -LogDir 'E:\gh\.wt\agentq\task-2\.copilot-tmp\build-logs'
    pwsh -NoProfile -File ps/bin/agentq-timings.ps1 -AllSlots -WorktreeRoot 'E:\gh\.wt\agentq' -Top 10
    pwsh -NoProfile -File ps/bin/agentq-timings.ps1 -Json -Last 3

  Exit: 0 a table (or JSON) was produced, 3 nothing was recorded, 2 bad arguments.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # Build-log directories to read. Default: <root>\.copilot-tmp\build-logs. A single comma-joined
    # value is tolerated ONLY when the raw value is not itself an existing path (pwsh -File binds a
    # comma list as ONE string - see the repo's own note about that trap).
    [string[]]$LogDir,
    # Repository root used for the default log directory and for last-green.json.
    [string]$Root,
    # Size of the median window (the LAST N runs). 1 = the last run only.
    [int]$Last = 5,
    # Print only the first N rows (0 = all).
    [int]$Top = 0,
    # Emit a clean JSON array of row objects instead of the table.
    [switch]$Json,
    # Also scan <WorktreeRoot>\*\ .copilot-tmp\build-logs (leased slots). Off by default: this must
    # never depend on the real lease state.
    [switch]$AllSlots,
    # Parent of the worktree slots (default E:\gh\.wt\<repo leaf> when it exists).
    [string]$WorktreeRoot,
    # Count only runs whose suite exited 0. A failed or aborted run attributes the whole remaining wall
    # clock to whichever member was in flight when it died (measured: gate:knip 1045.98s, gate:docs
    # 336.58s in runs that aborted), so a suite that takes 11s green reads as a 68s MEDIAN once a
    # handful of such runs fall inside the window. Green-only is the window that answers "what does
    # this suite cost", which is the question the report exists for.
    [switch]$GreenOnly,
    # Skip the last-green.json context line.
    [switch]$NoLastGreen,
    [switch]$Help
)

$ErrorActionPreference = 'Continue'
# A native command's stderr is not an error here; keep it from becoming one under Stop defaults.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

$script:Inv = [Globalization.CultureInfo]::InvariantCulture
# Every number printed by this module is formatted with the INVARIANT culture: a report read by an
# agent must not say '68,45' on a ro-RO machine.
# NB [string]::Format(provider, '0.0', $v) is WRONG here: '0.0' is a composite format with NO {0}
# placeholder, so it returns the literal '0.0' for every value. The standard numeric format '0.0' is
# for Double.ToString(format, provider) - that is the one that substitutes.
function Format-AgentqTimingNum([double]$v, [string]$fmt = '0.0') {
    try { $v.ToString($fmt, $script:Inv) } catch { "$v" }
}

# One log, read with a SHARED handle: a suite the previous run left behind may still hold the file open
# (same reason run-all.ps1's Read-LogLines does it).
function Read-AgentqLogText([string]$Path) {
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $sr = New-Object IO.StreamReader($fs)
        try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
}

# --- the two recognised line shapes -----------------------------------------------------------------
# run-all.ps1: "{0,-15} exit={1} pass={2} fail={3} sec={4}"  ->  name exit exit=N pass=N fail=N sec=N
$script:SuiteRx = [regex]::new('^\s*(?<name>.+?)\s+exit=(?<exit>-?\d+)\s+pass=(?<pass>\d+)\s+fail=(?<fail>\d+)\s+sec=(?<sec>\d+(?:[.,]\d+)?)\s*$')
# codai's gate-run driver: 'gate-run:      0.17s  gate:distill-objective   pass'
$script:GateRunRx = [regex]::new('^gate-run:\s+(?<sec>\d+(?:[.,]\d+)?)s\s+(?<name>\S+)\s+(?<verdict>\S+)\s*$')
# run-build.ps1's trailer: '=== exit 0 after 572.6s'
$script:TrailerRx = [regex]::new('^===\s+exit\s+(?<exit>-?\d+)\s+after\s+(?<sec>\d+(?:[.,]\d+)?)s\s*$')

function ConvertTo-AgentqSec([string]$s) {
    if (-not $s) { return 0.0 }
    try { [double]::Parse(($s -replace ',', '.'), $script:Inv) } catch { 0.0 }
}

# The start timestamp of a run, from the log FILE NAME ('20261126-011540-...') - never from the
# filesystem clock, which a later touch rewrites.
function Get-AgentqLogStamp([string]$FileName, [datetime]$Fallback) {
    $m = [regex]::Match($FileName, '^(?<d>\d{8})-(?<t>\d{6})-')
    if ($m.Success) {
        $dt = [datetime]::MinValue
        if ([datetime]::TryParseExact("$($m.Groups['d'].Value)-$($m.Groups['t'].Value)", 'yyyyMMdd-HHmmss', $script:Inv, [Globalization.DateTimeStyles]::None, [ref]$dt)) { return $dt }
    }
    $Fallback
}

# The run-level exit code / wall time of ONE log, from its trailer. Used only to make the degraded
# message honest ('the newest log says === exit 64 after 14s and carries no suite line').
function Get-AgentqLogRunInfo([string[]]$Lines) {
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $m = $script:TrailerRx.Match("$($Lines[$i])")
        if ($m.Success) {
            return [pscustomobject]@{ Exit = [int]$m.Groups['exit'].Value; Sec = (ConvertTo-AgentqSec $m.Groups['sec'].Value); Raw = "$($Lines[$i])".Trim() }
        }
    }
    $null
}

# --- parsing ----------------------------------------------------------------------------------------
# Returns every (suite, sec, exit, at, shape) observation in ONE log. Malformed lines are COUNTED and
# skipped, never thrown on: a log the runner mid-wrote must not take the whole report down with it.
function Read-AgentqLogObservations([string]$Path) {
    $obs = @(); $bad = 0; $name = Split-Path -Leaf $Path; $lines = @()
    try { $lines = @(($raw = Read-AgentqLogText $Path) -split "`r?`n") } catch { return [pscustomobject]@{ Observations = @(); Bad = 0; Run = $null; Error = "$($_.Exception.Message)" } }
    $at = Get-AgentqLogStamp $name ([datetime](Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue).LastWriteTime)
    foreach ($line in $lines) {
        if (-not $line) { continue }
        $t = "$line".Trim()
        if (-not $t) { continue }
        $m = $script:SuiteRx.Match($t)
        if ($m.Success) {
            $obs += [pscustomobject]@{
                Suite = $m.Groups['name'].Value.Trim(); Sec = (ConvertTo-AgentqSec $m.Groups['sec'].Value)
                Exit = [int]$m.Groups['exit'].Value; At = $at; Shape = 'suite'; Source = $name
            }
            continue
        }
        $g = $script:GateRunRx.Match($t)
        if ($g.Success) {
            $obs += [pscustomobject]@{
                Suite = $g.Groups['name'].Value; Sec = (ConvertTo-AgentqSec $g.Groups['sec'].Value)
                Exit = $(if ("$($g.Groups['verdict'].Value)" -eq 'pass') { 0 } else { 1 }); At = $at; Shape = 'gate-run'; Source = $name
            }
            continue
        }
        # A line that LOOKS like a suite result but could not be parsed (a truncated write, a name with
        # a stray character) is worth reporting. `[agentq-cloud] <id> exit=0 total 551,2s ...` carries
        # an exit= too but is a log line, not a result: the `pass=` is what tells them apart.
        if ($t -match '\bexit=-?\d+' -and $t -match '\bpass=\d+') { $bad++ }
    }
    [pscustomobject]@{ Observations = @($obs); Bad = $bad; Run = (Get-AgentqLogRunInfo $lines); Error = '' }
}

# The median of a set of values, computed FROM THE VALUES. Integer-sized windows average the two middle
# values. Empty input is 0.0 (there is nothing to be the median of).
function Get-AgentqMedian([double[]]$Values) {
    $a = @($Values | Sort-Object)
    $n = $a.Count
    if ($n -eq 0) { return 0.0 }
    $h = [int][math]::Floor($n / 2)
    if ($n % 2 -eq 1) { return [double]$a[$h] }
    ([double]$a[$h - 1] + [double]$a[$h]) / 2.0
}

# --- the table --------------------------------------------------------------------------------------
function Get-AgentqSuiteTimings {
    [CmdletBinding()]
    param(
        [string[]]$LogDir,
        [int]$Last = 5,
        [bool]$GreenOnly = $false
    )
    $result = [pscustomobject]@{ Rows = @(); Logs = @(); BadLines = @(); NewestRun = $null; Errors = @() }
    $dirs = @($LogDir | Where-Object { $_ })
    $files = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { $result.Errors += "no such directory: $d"; continue }
        $files += @(Get-ChildItem -LiteralPath $d -File -Filter '*.log' -ErrorAction SilentlyContinue)
    }
    $result.Logs = @($files)
    if (-not $files.Count) { return $result }

    $all = @()
    foreach ($f in ($files | Sort-Object LastWriteTime, Name)) {
        $r = Read-AgentqLogObservations $f.FullName
        if ($r.Error) { $result.Errors += "$($f.Name): $($r.Error)"; continue }
        if ($r.Bad -gt 0) { $result.BadLines += "$($f.Name): $($r.Bad)" }
        $all += $r.Observations
        if ($r.Run) { $result.NewestRun = [pscustomobject]@{ Source = $f.Name; Exit = $r.Run.Exit; Sec = $r.Run.Sec; Raw = $r.Run.Raw; At = $f.LastWriteTime } }
    }
    if (-not $all.Count) { return $result }
    if ($GreenOnly) { $all = @($all | Where-Object { $_.Exit -eq 0 }); if (-not $all.Count) { return $result } }

    $window = $(if ($Last -lt 1) { 1 } else { $Last })
    $byName = @{}
    foreach ($o in $all) {
        if (-not $byName.ContainsKey($o.Suite)) { $byName[$o.Suite] = New-Object System.Collections.ArrayList }
        [void]$byName[$o.Suite].Add($o)
    }

    $rows = @()
    foreach ($k in ($byName.Keys | Sort-Object)) {
        $runs = @($byName[$k] | Sort-Object At, Source)
        # NOT `$last`: PowerShell variable names are CASE-INSENSITIVE, so `$last` would BE the typed
        # parameter `[int]$Last` (the median window) and the assignment would throw
        # 'Cannot convert the "..." value of type "PSCustomObject" to type "System.Int32"'.
        $newest = $runs[$runs.Count - 1]
        $secs = @($runs | ForEach-Object { [double]$_.Sec })
        $tail = @($secs)
        if ($tail.Count -gt $window) { $tail = @($secs[($tail.Count - $window)..($tail.Count - 1)]) }
        $med = Get-AgentqMedian -Values $tail
        $rows += [pscustomobject]@{
            Suite     = $k
            LastSec   = [double]$newest.Sec
            MedianSec = [double]$med
            Runs      = $runs.Count
            BadRuns   = @($runs | Where-Object { $_.Exit -ne 0 }).Count
            LastExit  = [int]$newest.Exit
            TotalSec  = [double](($secs | Measure-Object -Sum).Sum)
            LastAt    = $newest.At.ToString('s')
            Shape     = $newest.Shape
            Source    = $newest.Source
        }
    }
    # ORDER: slowest LAST time first; a tie is broken by NAME. (mutation anchor: LastSec Descending)
    $rows = @($rows | Sort-Object -Property @{ Expression = { $_.LastSec }; Descending = $true }, @{ Expression = { $_.Suite } })
    $result.Rows = @($rows)
    $result
}

# last-green.json is AGGREGATE ONLY - context, never a row.
function Read-AgentqLastGreen([string]$Root) {
    if (-not $Root) { return $null }
    $p = Join-Path $Root '.copilot-tmp\last-green.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $o = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json; if ($o) { $o | Add-Member -NotePropertyName file -NotePropertyValue $p -Force }; $o } catch { $null }
}

function Format-AgentqTimingsTable($Rows) {
    $rows = @($Rows)
    $w = 15
    foreach ($r in $rows) { if ("$($r.Suite)".Length -gt $w) { $w = "$($r.Suite)".Length } }
    $out = New-Object System.Collections.ArrayList
    [void]$out.Add(('{0}  {1}  {2}  {3}  {4}  {5}  {6}' -f 'Suite'.PadRight($w), 'Last'.PadLeft(8), 'Median'.PadLeft(8), 'Runs'.PadLeft(4), 'Bad'.PadLeft(4), 'Exit'.PadLeft(4), 'Total'.PadLeft(8)))
    [void]$out.Add(('{0}  {1}  {2}  {3}  {4}  {5}  {6}' -f ('-' * $w), ('-' * 8), ('-' * 8), ('-' * 4), ('-' * 4), ('-' * 4), ('-' * 8)))
    foreach ($r in $rows) {
        [void]$out.Add(('{0}  {1}  {2}  {3}  {4}  {5}  {6}  {7}' -f
            "$($r.Suite)".PadRight($w),
            (Format-AgentqTimingNum $r.LastSec).PadLeft(8),
            (Format-AgentqTimingNum $r.MedianSec).PadLeft(8),
            "$($r.Runs)".PadLeft(4),
            "$($r.BadRuns)".PadLeft(4),
            "$($r.LastExit)".PadLeft(4),
            (Format-AgentqTimingNum $r.TotalSec).PadLeft(8),
            $r.LastAt))
    }
    @($out)
}

# Split one comma-joined argument ONLY when the raw value is not itself an existing path: `pwsh -File`
# binds `-LogDir a,b` as ONE string, and silently reading nothing is the failure mode to avoid.
function Resolve-AgentqLogDir([string[]]$Dirs) {
    $res = @()
    foreach ($d in @($Dirs | Where-Object { $_ })) {
        if (Test-Path -LiteralPath $d) { $res += $d; continue }
        foreach ($part in ("$d" -split ',' | Where-Object { $_.Trim() })) { $res += $part.Trim() }
    }
    @($res | Select-Object -Unique)
}

function Invoke-AgentqTimingsMain {
    param($LogDir, $Root, [int]$Last, [int]$Top, [bool]$Json, [bool]$AllSlots, $WorktreeRoot, [bool]$NoLastGreen, [bool]$GreenOnly)

    # Default root = the repo the CALLER is working in, not the directory this installed script happens
    # to live in. The old derivation (<bin>\..\.. = $HOME) made a bare `agentq timings` read
    # $HOME\.copilot-tmp\build-logs - a directory that does not exist - so it answered "nothing recorded
    # (scanned 0 log file(s))" while the repo's own gate logs sat in <repo>\.copilot-tmp\build-logs.
    # A caller outside any repo keeps the old behaviour, which is the correct fallback there.
    $repoRoot = $Root
    if (-not $repoRoot) {
        $gitTop = $null
        try { $gitTop = (& git -C $PWD.Path rev-parse --show-toplevel 2>$null) } catch { $gitTop = $null }
        if ($gitTop) { $gitTop = ("$gitTop").Trim() }
        if (-not $gitTop -or -not (Test-Path -LiteralPath "$gitTop")) {
            $gitTop = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        }
        $repoRoot = "$gitTop"
    }
    $dirs = @()
    if ($LogDir) { $dirs = Resolve-AgentqLogDir $LogDir }
    else {
        $dirs = @(Join-Path $repoRoot '.copilot-tmp\build-logs')
        if ($AllSlots) {
            $wt = $WorktreeRoot
            # The slots of a repo live next to it: <parent of the repo>\.wt\<repo leaf>
            # (E:\gh\agentq -> E:\gh\.wt\agentq). No '..' - that pointed at E:\.wt\agentq, which does
            # not exist, and -AllSlots then silently read nothing but the repo's own log.
            if (-not $wt) { $wt = Join-Path (Split-Path -Parent $repoRoot) ('.wt\' + (Split-Path -Leaf $repoRoot)) }
            if ($wt -and (Test-Path -LiteralPath $wt)) {
                foreach ($slot in (Get-ChildItem -LiteralPath $wt -Directory -ErrorAction SilentlyContinue)) {
                    $sd = Join-Path $slot.FullName '.copilot-tmp\build-logs'
                    if (Test-Path -LiteralPath $sd) { $dirs += $sd }
                }
            }
        }
    }

    $out = New-Object System.Collections.ArrayList
    $t = Get-AgentqSuiteTimings -LogDir $dirs -Last $Last -GreenOnly $GreenOnly
    $rows = @($t.Rows)
    foreach ($b in @($t.BadLines)) { [Console]::Error.WriteLine("agentq-timings: skipped unparsable result line(s) - $b") }
    foreach ($e in @($t.Errors)) { [Console]::Error.WriteLine("agentq-timings: $e") }

    if ($Top -gt 0 -and $rows.Count -gt $Top) { $rows = @($rows[0..($Top - 1)]) }

    # NOTHING RECORDED is a distinct, named outcome - never an empty table that reads as healthy.
    if (-not @($t.Rows).Count) {
        $wit = @($dirs) -join '; '
        $run = $t.NewestRun
        $why = $(if ($run) { "; the newest log says '$($run.Raw)' and carries no suite result line" } else { '' })
        if ($GreenOnly) { $why += ' (note: -GreenOnly was set, so every run that failed was excluded)' }
        $msg = "agentq-timings: no timings recorded (scanned $(@($t.Logs).Count) log file(s) under: $wit$why). Run a gate (run-all.ps1 / ps/devcloud/gate.ps1) or pass -LogDir."
        if ($Json) {
            [Console]::Error.WriteLine($msg)
            [void]$out.Add('[]')
        } else { [void]$out.Add($msg) }
        # Everything the caller should see travels in Output; the exit code travels alone in Code. A
        # function that also WRITES its lines would return them glued to the code and `exit` would fail.
        return [pscustomobject]@{ Code = 3; Output = @($out) }
    }

    if ($Json) {
        # -InputObject, not a pipe: a pipeline of ONE object serialises as an object, not as an array.
        [void]$out.Add((ConvertTo-Json -InputObject @($rows) -Depth 4))
        return [pscustomobject]@{ Code = 0; Output = @($out) }
    }

    foreach ($line in (Format-AgentqTimingsTable $rows)) { [void]$out.Add($line) }
    $s = $(if (@($rows).Count -eq 1) { '' } else { 's' })
    [void]$out.Add('')
    [void]$out.Add("agentq-timings: $($rows.Count) suite$s from $(@($t.Logs).Count) log file(s), ordered slowest last-run first. Median window: last $Last run(s).")
    if ($dirs.Count -le 4) { foreach ($d in $dirs) { [void]$out.Add("  read: $d") } }
    if (-not $NoLastGreen) {
        $lg = Read-AgentqLastGreen $repoRoot
        if ($lg) { [void]$out.Add(("  last green full run: {0}  {1} suites  {2} s  psver {3}  machine {4}  (aggregate only - no per-suite times)" -f $lg.at, $lg.suites, $lg.sec, $lg.psver, $lg.machine)) }
    }
    [pscustomobject]@{ Code = 0; Output = @($out) }
}

if ($Help) {
    @'
ps/bin/agentq-timings.ps1 - which gate suite costs what (read from the build logs)

  pwsh -NoProfile -File ps/bin/agentq-timings.ps1
  pwsh -NoProfile -File ps/bin/agentq-timings.ps1 -Json -Last 3
  pwsh -NoProfile -File ps/bin/agentq-timings.ps1 -LogDir '<dir>' [-Top 10]
  pwsh -NoProfile -File ps/bin/agentq-timings.ps1 -AllSlots -WorktreeRoot '<parent of the slots>'

  -LogDir      build-log directories to read (default <root>\.copilot-tmp\build-logs); repeatable
  -Root        repository root used for the default dir and for last-green.json
  -Last n      median window: the LAST n runs (default 5); 1 = the last run only
  -Top n       print only the first n rows (0 = all)
  -Json        emit a clean JSON array of rows instead of the table
  -AllSlots    also scan <WorktreeRoot>\*\.copilot-tmp\build-logs
    -GreenOnly   count only runs whose suite exited 0 (a failed/aborted run attributes the remaining wall
                             clock to the member in flight, so it must not sit in the median of a green suite)
  -NoLastGreen skip the last-green.json context line

  Exit 0 = a table/JSON was produced, 3 = nothing was recorded, 2 = bad arguments.
  Sources: <slot>\.copilot-tmp\build-logs\*.log (per-suite lines + the '=== exit N after Ss' trailer),
  <root>\.copilot-tmp\last-green.json (aggregate), ~/.codai/coord/journal.jsonl (whole-gate only).
'@
    exit 0
}

# Dot-sourcing defines the functions and runs nothing.
if ($MyInvocation.InvocationName -eq '.') { return }

if ($Last -lt 1) { Write-Output 'agentq-timings: -Last must be 1 or more (it is the median window, in runs)'; exit 2 }
if ($Top -lt 0) { Write-Output 'agentq-timings: -Top must be 0 (all) or more'; exit 2 }

try {
    $res = Invoke-AgentqTimingsMain -LogDir $LogDir -Root $Root -Last $Last -Top $Top -Json:$Json -AllSlots:$AllSlots -WorktreeRoot $WorktreeRoot -NoLastGreen:$NoLastGreen -GreenOnly:$GreenOnly
} catch {
    # Never throw out of a reporting tool.
    Write-Output "agentq-timings: failed to read the recorded timings: $($_.Exception.Message)"
    exit 1
}
foreach ($line in @($res.Output)) { Write-Output $line }
exit ([int]$res.Code)
