#requires -Version 5.1
<#
.SYNOPSIS
  One read-only saturation report: hook cost, resident-host service time, CPU hogs, queue state.

.DESCRIPTION
  Today's measurements live in four unrelated places and nobody reads them together, so the machine's
  OWN load stays invisible. This script prints all four in one pass, from data already on disk, and
  costs the machine nothing but two Get-Process snapshots and one `agentq status` call.

  SECTIONS

  1. HOOK CALLS PER HOUR, split by execution path. Source (JSON lines, one object per line):
      <CoordDir>\hooks\cost-<yyyyMMdd>.jsonl   fields: ts, ms, startMs, tool, verb, deny, session
     `startMs` is where the hook call actually started:
       startMs <  50        served by the RESIDENT host (in-process, no fresh spawn)
       startMs 50..5000     a FRESH process spawn
       startMs >  5000      junk (do NOT repair, just count)
     `startMs` can be the literal JSON null: that is "no measurement" and is NEVER coerced to 0 -
     an unmeasured call and a genuinely-zero one are different facts.
    The second table of this section sums the same file PER AGENTQ VERB (`verb`, added round 4,
    2026-11-28): the tool name alone cannot answer "what does one `status` cost beside one `land`",
    a measured day having held 10 463 run_in_terminal rows and no verb at all. Rows whose command ran
    no agentq carry an empty verb and are counted only in the coverage line.

  2. RESIDENT HOST SERVICE TIME. Source: <ResidentDir>\server.log, lines such as
       "23:05:12.381  req 18498  total 427 ms (read 0, run 422)  exit 0 ..."
     Request count and p50/p90/p99 (nearest-rank, ascending) of total, read and run.

  3. TOP PROCESSES BY CPU DELTA. Two Get-Process snapshots <SampleSec> apart, delta of the live
     `.CPU` property. `.CPU` is cheap and live - NEVER a WMI/CIM query inside a loop: a previous
     version of a probe did that and froze, and the CIM numbers are stale/cached anyway.

  4. AGENTQ QUEUE/LEASE SNAPSHOT. `agentq status`, first 25 lines, not parsed any further.

  NUMBERS are printed as RAW INTEGERS (and dotted decimals) built with InvariantCulture. NEVER
  {0:N0}: in this ro-RO locale it renders 1044 as "1,044" and has already caused mis-reads.

  READ-ONLY with respect to the system: nothing is deleted, and the only write is the optional
  markdown copy requested with -Out.

.PARAMETER CoordDir
  The .codai\coord root (default %USERPROFILE%\.codai\coord). Tests override it to point at a fixture.
.PARAMETER ResidentDir
  The resident hook directory holding server.log (default %USERPROFILE%\.copilot\hooks\resident).
.PARAMETER Date
  yyyyMMdd of the cost file to read (default today).
.PARAMETER Aq
  Path to agentq.ps1 (default the installed copy).
.PARAMETER SampleSec
  CPU-sampling window in seconds (default 10).
.PARAMETER Top
  How many processes to print (default 10).
.PARAMETER Out
  Optional path for a markdown copy of the report.
#>
[CmdletBinding()]
param(
  [string]$CoordDir = (Join-Path $env:USERPROFILE '.codai\coord'),
  [string]$ResidentDir = (Join-Path $env:USERPROFILE '.copilot\hooks\resident'),
  [string]$Date = (Get-Date).ToString('yyyyMMdd'),
  [string]$Aq = (Join-Path $env:USERPROFILE '.copilot\bin\agentq.ps1'),
  [int]$SampleSec = 10,
  [int]$Top = 10,
  [string]$Out
)
$ErrorActionPreference = 'Stop'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

# --- output plumbing ---------------------------------------------------------------------------
# Emit both writes to the console and accumulates the markdown body, so -Out is a free copy.
$script:md = New-Object 'System.Collections.Generic.List[string]'
function Emit([string]$line) { Write-Host $line; [void]$script:md.Add($line) }
# Raw integers, invariant. No group separators, ever.
function S([object]$v) { return [string]::Format($inv, '{0}', $v) }
# One-decimal percentage, invariant.
function Pct([int]$n, [int]$d) { if ($d -le 0) { return '0.0' } return (100.0 * $n / $d).ToString('0.0', $inv) }
# Value for ms figures: up to three decimals, invariant, '-' when absent.
function F([object]$v) { if ($null -eq $v) { return '-' } return ([double]$v).ToString('0.###', $inv) }
# Nearest-rank percentile over an ascending array; $null for an empty one.
function Percentile([object]$sorted, [double]$p) {
  $a = @($sorted)
  if ($a.Count -eq 0) { return $null }
  $idx = [int][math]::Ceiling($p / 100.0 * $a.Count) - 1
  if ($idx -lt 0) { $idx = 0 }
  if ($idx -ge $a.Count) { $idx = $a.Count - 1 }
  return $a[$idx]
}

# --- 1. hook calls per hour, split by execution path -------------------------------------------
Emit ''
Emit '== HOOK CALLS PER HOUR (UTC)'
$costFile = Join-Path (Join-Path $CoordDir 'hooks') ('cost-' + $Date + '.jsonl')
Emit ("source: " + $costFile)
$hours = @{}
# Per-verb totals, filled in the same pass - a second read of the file would be a second cost.
$verbs = @{}
$withVerb = 0
$tot = 0; $srv = 0; $spn = 0; $jnk = 0; $non = 0
if (Test-Path -LiteralPath $costFile) {
  foreach ($line in [System.IO.File]::ReadLines($costFile)) {
    $h = '??'
    if ($line -match '"ts":"\d{4}-\d{2}-\d{2}T(\d{2}):') { $h = $Matches[1] }
    # The verb first: the `ms` match below overwrites $Matches.
    $vb = ''
    if ($line -match '"verb":"([^"]{0,24})"') { $vb = $Matches[1] }
    $cls = 'none'
    if ($line -match '"startMs":\s*(null|-?\d+)') {
      $raw = $Matches[1]
      if ($raw -eq 'null') {
        $cls = 'none'                       # unmeasured: never 0
      } else {
        $v = [int64]$raw
        if ($v -lt 50) { $cls = 'served' }      # < 50 ms at call start = resident host
        elseif ($v -le 5000) { $cls = 'spawned' } # 50..5000 = a fresh process spawn
        else { $cls = 'junk' }                  # > 5000 = junk, counted not repaired
      }
    }
    if ($vb) {
      if (-not $verbs.ContainsKey($vb)) { $verbs[$vb] = @{ calls = 0; served = 0; spawned = 0; ms = [int64]0; msN = 0 } }
      $v = $verbs[$vb]
      $v.calls++
      if ($cls -eq 'served') { $v.served++ } elseif ($cls -eq 'spawned') { $v.spawned++ }
      if ($line -match '"ms":(\d+)') { $v.ms += [int64]$Matches[1]; $v.msN++ }
      $withVerb++
    }
    if (-not $hours.ContainsKey($h)) { $hours[$h] = @{ total = 0; served = 0; spawned = 0; junk = 0; none = 0 } }
    $c = $hours[$h]
    $c.total++
    switch ($cls) {
      'served' { $c.served++; $srv++ }
      'spawned' { $c.spawned++; $spn++ }
      'junk' { $c.junk++; $jnk++ }
      default { $c.none++; $non++ }
    }
    $tot++
  }
  Emit 'hour total served spawned junk no-meas'
  foreach ($h in ($hours.Keys | Sort-Object)) {
    $c = $hours[$h]
    Emit ($h + '   ' + (S $c.total) + '   ' + (S $c.served) + '   ' + (S $c.spawned) + '   ' + (S $c.junk) + '   ' + (S $c.none))
  }
  Emit ('DAY TOTAL calls=' + (S $tot) + ' served=' + (S $srv) + ' spawned=' + (S $spn) + ' junk=' + (S $jnk) + ' no-measurement=' + (S $non))
  Emit ('PERCENT served=' + (Pct $srv $tot) + '% spawned=' + (Pct $spn $tot) + '% junk=' + (Pct $jnk $tot) + '% no-measurement=' + (Pct $non $tot) + '%')
  Emit 'CLASSIFY served<50  spawned=50..5000  junk>5000  null=no-measurement'
  # --- 1b. the same day, per agentq verb ---------------------------------------------------------
  Emit ''
  Emit '== AGENTQ VERB COST (same file, same pass)'
  if ($verbs.Count -eq 0) {
    Emit '(no line names a verb: none of the calls ran agentq, or the hook predates 2026-11-28)'
  } else {
    Emit 'verb calls served spawned avg-ms'
    foreach ($k in ($verbs.Keys | Sort-Object { $verbs[$_].calls } -Descending)) {
      $v = $verbs[$k]
      $avg = if ($v.msN -gt 0) { ([double]$v.ms / $v.msN).ToString('0.0', $inv) } else { '-' }
      Emit ($k + '   ' + (S $v.calls) + '   ' + (S $v.served) + '   ' + (S $v.spawned) + '   ' + $avg)
    }
  }
  Emit ('VERB COVERAGE rows=' + (S $tot) + ' with-verb=' + (S $withVerb) + ' (' + (Pct $withVerb $tot) + '%)')
} else {
  Emit ("(no cost file for " + $Date + ")")
}

# --- 2. resident host service time --------------------------------------------------------------
Emit ''
Emit '== RESIDENT HOST SERVICE TIME'
$logFile = Join-Path $ResidentDir 'server.log'
Emit ("source: " + $logFile)
$tArr = New-Object 'System.Collections.Generic.List[double]'
$rArr = New-Object 'System.Collections.Generic.List[double]'
$nArr = New-Object 'System.Collections.Generic.List[double]'
if (Test-Path -LiteralPath $logFile) {
  foreach ($line in [System.IO.File]::ReadLines($logFile)) {
    if ($line -match 'req\s+\d+\s+total\s+([0-9.]+)\s+ms\s+\(read\s+([0-9.]+),\s*run\s+([0-9.]+)\)') {
      [void]$tArr.Add([double]::Parse($Matches[1], $inv))
      [void]$rArr.Add([double]::Parse($Matches[2], $inv))
      [void]$nArr.Add([double]::Parse($Matches[3], $inv))
    }
  }
}
Emit ('requests=' + (S $tArr.Count))
if ($tArr.Count -gt 0) {
  $st = @($tArr | Sort-Object); $sr = @($rArr | Sort-Object); $sn = @($nArr | Sort-Object)
  Emit ('total  p50=' + (F (Percentile $st 50)) + '  p90=' + (F (Percentile $st 90)) + '  p99=' + (F (Percentile $st 99)) + '  max=' + (F $st[-1]))
  Emit ('read   p50=' + (F (Percentile $sr 50)) + '  p90=' + (F (Percentile $sr 90)) + '  p99=' + (F (Percentile $sr 99)) + '  max=' + (F $sr[-1]))
  Emit ('run    p50=' + (F (Percentile $sn 50)) + '  p90=' + (F (Percentile $sn 90)) + '  p99=' + (F (Percentile $sn 99)) + '  max=' + (F $sn[-1]))
} else {
  Emit '(no measurements)'
}

# --- 3. top processes by CPU delta --------------------------------------------------------------
Emit ''
Emit ('== TOP PROCESSES BY CPU DELTA (window ' + (S $SampleSec) + ' s)')
# A snapshot map keyed by pid: name, live .CPU (processor seconds), start time. No WMI/CIM here.
function Get-Snap {
  $m = @{}
  foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    try { $m[[int]$p.Id] = [pscustomobject]@{ Name = $p.ProcessName; CPU = $p.CPU; Start = $p.StartTime } }
    catch { }  # some system processes deny StartTime; they simply drop out of the delta
  }
  return $m
}
$snapA = Get-Snap
Start-Sleep -Seconds $SampleSec
$snapB = Get-Snap
$rows = foreach ($procId in $snapB.Keys) {
  if (-not $snapA.ContainsKey($procId)) { continue }  # started within the window: no before
  $pa = $snapA[$procId]; $pb = $snapB[$procId]
  if ($null -eq $pa.CPU -or $null -eq $pb.CPU) { continue }
  [pscustomobject]@{ Id = $procId; Name = $pb.Name; Delta = ([double]$pb.CPU - [double]$pa.CPU); Start = $pb.Start }
}
# NOTE: the local must NOT be named $top - PowerShell variables are case-insensitive, so `$top`
# IS the [int]$Top parameter and assigning this array to it throws
# "Cannot convert System.Object[] to System.Int32". Hence $topRows.
$topRows = @($rows | Where-Object { $_.Delta -gt 0 } | Sort-Object Delta -Descending | Select-Object -First $Top)
Emit 'pid      name                 cpu-delta-s   started'
foreach ($r in $topRows) {
  $stStr = '-'
  if ($null -ne $r.Start) { $stStr = $r.Start.ToString('yyyy-MM-dd HH:mm:ss', $inv) }
  Emit ($r.Id.ToString($inv).PadRight(8) + ' ' + ([string]$r.Name).PadRight(20) + ' ' + $r.Delta.ToString('0.00', $inv).PadRight(13) + ' ' + $stStr)
}
Emit ('processes with a positive delta in window: ' + (S $topRows.Count))

# --- 4. agentq queue/lease snapshot -------------------------------------------------------------
Emit ''
Emit '== AGENTQ STATUS (first 25 lines)'
if (Test-Path -LiteralPath $Aq) {
  $statusOut = @(& pwsh -NoProfile -File $Aq status 2>&1 | ForEach-Object { [string]$_ })
  $shown = 0
  foreach ($l in $statusOut) {
    if ($shown -ge 25) { break }
    Emit $l
    $shown++
  }
  if ($statusOut.Count -gt 25) { Emit ('... (' + (S ($statusOut.Count - 25)) + ' more lines truncated)') }
} else {
  Emit ('(agentq.ps1 not found at ' + $Aq + ')')
}

# --- optional markdown copy --------------------------------------------------------------------
if ($Out) {
  $dir = Split-Path -Parent $Out
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  # Careful: at script scope `$md` IS `$script:md`, so a local named $md would overwrite the
  # accumulated body and then "add to the collection it is enumerating". Use a distinct name.
  $mdLines = New-Object 'System.Collections.Generic.List[string]'
  $mdLines.Add('# Saturation report ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $inv))
  $mdLines.Add('')
  $mdLines.Add('```text')
  foreach ($l in @($script:md)) { $mdLines.Add($l) }
  $mdLines.Add('```')
  [System.IO.File]::WriteAllText($Out, ($mdLines -join "`r`n") + "`r`n", [System.Text.UTF8Encoding]::new($false))
  Write-Host ('wrote markdown: ' + $Out)
}
