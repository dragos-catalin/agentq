# 2026-11-26: the suite for ps/bin/agentq-timings.ps1.
#
# The module exists because nobody could see which gate suite costs what: the land gate's numbers are
# written into <slot>\.copilot-tmp\build-logs\*.log one line per suite, and nothing read them back.
# A reader of recorded timings is only useful if its numbers are TRUE, so this suite pins the four
# things that can silently lie:
#   * the ORDER (slowest LAST run first - not the median, not the file order);
#   * the MEDIAN (computed from the values in the window, never from the run count);
#   * the DEGRADED path (nothing recorded must say so and exit 3 - never an empty table that reads
#     as healthy);
#   * the RENDERING (the numbers must actually reach the table/JSON - a formatter that swallows them
#     prints a convincing 0.0 row for every suite).
#
# It is hermetic: everything runs in a temp fixture (3 synthetic runs of 2 suites + a 4th log in
# codai's `gate-run:` shape). Non-vacuity is proven by THREE mutations of the module itself - the
# ordering, the median and the number rendering are each broken in a temp copy and the corresponding
# assertion must go RED. A mutation whose anchor is not found FAILS (fail-closed): if the module is
# refactored, the ratchet must say so instead of passing quietly.
#
# Exit: 0 all checks pass, 1 otherwise. Summary line `agentq-timings: pass=N fail=N`.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Module = (Join-Path $PSScriptRoot '..\bin\agentq-timings.ps1')
)
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Output "PASS $Name" } else { $script:fail++; Write-Output "FAIL $Name$(if ($Detail) { ' - ' + $Detail })" }
}
function Note([string]$Text) { Write-Output "note: $Text" }

$module = (Resolve-Path -LiteralPath $Module).Path
Check 'the module exists' (Test-Path -LiteralPath $module) $module

# --- the fixture -----------------------------------------------------------------------------------
$fx = Join-Path ([IO.Path]::GetTempPath()) ('aq-timings-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$work = Join-Path $fx 'scratch'
$logs = Join-Path $fx 'repo\.copilot-tmp\build-logs'
$logs2 = Join-Path $fx 'codai\.copilot-tmp\build-logs'
$logs3 = Join-Path $fx 'empty\.copilot-tmp\build-logs'
New-Item -ItemType Directory -Force -Path $work, $logs, $logs2, $logs3 | Out-Null
Note "fixture: $fx"

# Three synthetic runs. The two suites are deliberately CROSSED: `guard forms` is slower on its LAST
# run (30 s vs 25 s) but has the LOWER median (20 s vs 25 s), so an implementation that orders by the
# median emits the opposite first row - and the ordering check below is not vacuous.
$run1 = @(
    'guard forms     exit=0 pass=61 fail=0 sec=10'
    'deploy guard    exit=0 pass=12 fail=0 sec=30'
    'TOTAL sec=40 suites=2 failed=0 skipped=0'
    '=== exit 0 after 40s'
)
$run2 = @(
    'guard forms     exit=0 pass=61 fail=0 sec=20'
    'deploy guard    exit=0 pass=12 fail=0 sec=20'
    '=== exit 0 after 40s'
)
$run3 = @(
    # a TRUNCATED result line: it names a suite and carries no sec=. It must be counted as suspicious
    # and skipped - never a run, never a reason to lose the suites around it.
    'guard forms     exit=0 pass=61'
    'guard forms     exit=0 pass=61 fail=0 sec=30'
    '[devcloud] exit 0 total 12,4s (pool)'          # log noise with an exit but no '=': not a result
    'brk exit=x pass=y fail=z sec=1'                # garbage: not a result, not suspicious either
    'deploy guard    exit=1 pass=11 fail=1 sec=25'
    '=== exit 1 after 41s'
)
Set-Content -LiteralPath (Join-Path $logs '20261101-100000-pwsh-NoProfile-File-ps-devcloud-gate-ps1.log') -Value $run1 -Encoding ascii
Set-Content -LiteralPath (Join-Path $logs '20261102-100000-pwsh-NoProfile-File-ps-devcloud-gate-ps1.log') -Value $run2 -Encoding ascii
Set-Content -LiteralPath (Join-Path $logs '20261103-100000-pwsh-NoProfile-File-ps-devcloud-gate-ps1.log') -Value $run3 -Encoding ascii

# codai's own gate-run driver shape, plus the three noise lines that must NOT become rows.
Set-Content -LiteralPath (Join-Path $logs2 '20261104-100000-pwsh-NoProfile-File-scripts-ci-gate-run-mjs.log') -Encoding ascii -Value @(
    'gate-run:      0.17s  gate:distill-objective   pass'
    'gate-run: slowest member: gate:distill-objective 0.17s'
    'gate-run: total wall 42.0s (41 members)'
    'gate-run: OK'
    '=== exit 0 after 42s'
)

function Invoke-Timings([string]$Script, [string[]]$Cli) {
    $so = Join-Path $work 'so.txt'
    $se = Join-Path $work 'se.txt'
    Remove-Item -LiteralPath $so, $se -Force -ErrorAction SilentlyContinue
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $Script @Cli 1> $so 2> $se
    [pscustomobject]@{
        Exit = $LASTEXITCODE
        Out  = $(if (Test-Path -LiteralPath $so) { Get-Content -LiteralPath $so -Raw } else { '' })
        Err  = $(if (Test-Path -LiteralPath $se) { Get-Content -LiteralPath $se -Raw } else { '' })
    }
}
function Get-Rows([string]$Script, [string[]]$Extra = @()) {
    $r = Invoke-Timings $Script (@('-LogDir', $logs, '-Json', '-NoLastGreen') + $Extra)
    $rows = @()
    try { $rows = @(ConvertFrom-Json -InputObject $r.Out) } catch { $rows = @() }
    [pscustomobject]@{ Exit = $r.Exit; Raw = $r.Out; Err = $r.Err; Rows = $rows; BySuite = @{} }
}
function Row([string]$Suite, $Res) { @($Res.Rows | Where-Object { $_.Suite -eq $Suite })[0] }

# --- 1. the numbers --------------------------------------------------------------------------------
$full = Get-Rows $module
Check 'the table/JSON run exits 0' ($full.Exit -eq 0) "exit=$($full.Exit) err=$($full.Err)"
Check 'exactly the two fixture suites are read (the TOTAL line is not a suite)' (@($full.Rows).Count -eq 2) "suites=$(($full.Rows | ForEach-Object { $_.Suite }) -join '|')"

$gf = Row 'guard forms' $full
$dg = Row 'deploy guard' $full
Check 'guard forms: last=30 runs=3 median=20 total=60 exit=0' ($gf.LastSec -eq 30 -and $gf.Runs -eq 3 -and $gf.MedianSec -eq 20 -and $gf.TotalSec -eq 60 -and $gf.LastExit -eq 0) "last=$($gf.LastSec) runs=$($gf.Runs) med=$($gf.MedianSec) total=$($gf.TotalSec) exit=$($gf.LastExit)"
Check 'deploy guard: last=25 runs=3 median=25 total=75 exit=1 bad=1' ($dg.LastSec -eq 25 -and $dg.Runs -eq 3 -and $dg.MedianSec -eq 25 -and $dg.TotalSec -eq 75 -and $dg.LastExit -eq 1 -and $dg.BadRuns -eq 1) "last=$($dg.LastSec) runs=$($dg.Runs) med=$($dg.MedianSec) total=$($dg.TotalSec) exit=$($dg.LastExit) bad=$($dg.BadRuns)"
# The median must be a VALUE from the window, not the run count and not the last run.
Check 'the median is NOT the run count (median comes from the values)' ($gf.MedianSec -ne $gf.Runs -and $dg.MedianSec -ne $dg.Runs) "gf.med=$($gf.MedianSec) gf.runs=$($gf.Runs)"
Check 'the truncation did not invent a 4th run for guard forms' ($gf.Runs -eq 3) "runs=$($gf.Runs)"
Check 'the result shape and the source file are reported' ($gf.Shape -eq 'suite' -and "$($gf.Source)" -match '20261103-100000' -and $gf.LastAt -eq '2026-11-03T10:00:00') "shape=$($gf.Shape) src=$($gf.Source) at=$($gf.LastAt)"

# --- 2. the ordering ------------------------------------------------------------------------------
# Non-vacuity: the two suites really are crossed (last-run order != median order).
Check 'the fixture is genuinely crossed (last-run order is the opposite of the median order)' ($gf.LastSec -gt $dg.LastSec -and $gf.MedianSec -lt $dg.MedianSec) "gf.last=$($gf.LastSec) dg.last=$($dg.LastSec) gf.med=$($gf.MedianSec) dg.med=$($dg.MedianSec)"
Check 'the rows come back slowest LAST run first' ("$($full.Rows[0].Suite)" -eq 'guard forms' -and "$($full.Rows[1].Suite)" -eq 'deploy guard') "order=$(($full.Rows | ForEach-Object { "$($_.Suite):$($_.LastSec)" }) -join ' > ')"

$tbl = Invoke-Timings $module @('-LogDir', $logs, '-Top', '1', '-NoLastGreen')
$tblBody = @($tbl.Out -split "`r?`n" | Where-Object { $_ -match '^\S' -and $_ -notmatch '^Suite' -and $_ -notmatch '^--' -and $_ -notmatch '^agentq-timings' -and $_ -notmatch '^\s' })
Check 'the table prints the numbers, not a literal 0.0' ("$($tbl.Out)" -match '30\.0' -and "$($tbl.Out)" -notmatch '^agentq v') "out=$($tbl.Out -replace "`r?`n", ' / ')"
Check '-Top 1 prints the slowest suite and its numbers' ("$($tblBody[0])" -match 'guard forms' -and "$($tblBody[0])" -match '30\.0' -and "$($tblBody[0])" -match '20\.0') "row=$($tblBody[0])"

# --- 3. the window ---------------------------------------------------------------------------------
$win2 = Get-Rows $module @('-Last', '2')
$gf2 = Row 'guard forms' $win2
$dg2 = Row 'deploy guard' $win2
Check '-Last 2 medians the last two runs (even window averages the two middle values)' ($gf2.MedianSec -eq 25 -and $dg2.MedianSec -eq 22.5) "gf=$($gf2.MedianSec) dg=$($dg2.MedianSec)"
Check '-Last 2 does not shrink the run count or the total (only the median window)' ($gf2.Runs -eq 3 -and $gf2.TotalSec -eq 60 -and $gf2.LastSec -eq 30) "runs=$($gf2.Runs) total=$($gf2.TotalSec) last=$($gf2.LastSec)"

# --- 4. the JSON contract ---------------------------------------------------------------------------
$raw = $full.Raw.Trim()
Check 'the JSON payload is an ARRAY' ($raw.StartsWith('[') -and $raw.EndsWith(']')) "raw starts: $($raw.Substring(0, [math]::Min(40, $raw.Length)))"
$docKeys = @('Suite', 'LastSec', 'MedianSec', 'Runs', 'BadRuns', 'LastExit', 'TotalSec', 'LastAt', 'Shape', 'Source')
$gotKeys = @($gf.PSObject.Properties.Name)
Check 'a JSON row carries exactly the documented keys' (@(Compare-Object -ReferenceObject $docKeys -DifferenceObject $gotKeys).Count -eq 0) "got=$($gotKeys -join ',')"

# --- 5. the second line shape, and the noise that must not become a row ------------------------------
$run = Invoke-Timings $module @('-LogDir', $logs2, '-Json', '-NoLastGreen')
$rows2 = @()
try { $rows2 = @(ConvertFrom-Json -InputObject $run.Out) } catch { }
Check 'codai gate-run lines parse (one row, shape gate-run)' (@($rows2).Count -eq 1 -and "$($rows2[0].Suite)" -eq 'gate:distill-objective' -and $rows2[0].LastSec -eq 0.17 -and "$($rows2[0].Shape)" -eq 'gate-run') "rows=$(($rows2 | ForEach-Object { "$($_.Suite)=$($_.LastSec)" }) -join '|')"
Check 'gate-run noise (slowest member / total wall / OK) makes no row' (@(Compare-Object -ReferenceObject @('gate:distill-objective') -DifferenceObject @($rows2 | ForEach-Object { "$($_.Suite)" })).Count -eq 0) "suites=$(($rows2 | ForEach-Object { $_.Suite }) -join ',')"
Check 'a truncated result line is REPORTED, not silently dropped, and does not take the run down' ($full.Exit -eq 0 -and "$($full.Err)" -match 'unparsable result line' -and "$($full.Err)" -match ': 1') "exit=$($full.Exit) err=$($full.Err)"

# --- 6. degrading ------------------------------------------------------------------------------------
$empty = Invoke-Timings $module @('-LogDir', $logs3, '-NoLastGreen')
Check 'an empty log directory says so and exits 3' ($empty.Exit -eq 3 -and "$($empty.Out)" -match 'no timings recorded') "exit=$($empty.Exit) out=$($empty.Out)"
Check 'the degraded path does NOT print an empty table header' ("$($empty.Out)" -notmatch 'Median') "out=$($empty.Out)"
$nope = Invoke-Timings $module @('-LogDir', (Join-Path $fx 'no-such-dir'), '-NoLastGreen')
# Diagnostics (this one) go to stderr; the report goes to stdout. Asserting each on its own stream is
# what keeps the two separable by a caller that only wants the table.
Check 'a missing directory says so and exits 3 (never throws)' ($nope.Exit -eq 3 -and "$($nope.Out)" -match 'no timings recorded') "exit=$($nope.Exit) out=$($nope.Out)"
Check 'the missing directory is named on stderr' ("$($nope.Err)" -match 'no such directory') "err=$($nope.Err)"
$jdeg = Invoke-Timings $module @('-LogDir', $logs3, '-Json', '-NoLastGreen')
Check 'the degraded path still emits parseable JSON ([]) on stdout' ($jdeg.Exit -eq 3 -and "$($jdeg.Out)".Trim() -eq '[]') "exit=$($jdeg.Exit) out=$($jdeg.Out.Trim())"

# --- 7. the argument contract -------------------------------------------------------------------------
$badLast = Invoke-Timings $module @('-LogDir', $logs, '-Last', '0')
Check '-Last 0 is refused with exit 2' ($badLast.Exit -eq 2 -and "$($badLast.Out)" -match '-Last must be 1 or more') "exit=$($badLast.Exit) out=$($badLast.Out)"
$help = Invoke-Timings $module @('-Help')
Check '-Help prints the usage and exits 0' ($help.Exit -eq 0 -and "$($help.Out)" -match 'which gate suite costs what') "exit=$($help.Exit)"

# --- 8. the mutations (the ratchet) --------------------------------------------------------------------
# A mutant is a temp copy of the module with ONE anchor replaced. If the anchor is not found the check
# FAILS: a mutation that changed nothing would "prove" the assertion by passing on good code.
function New-Mutant([string]$From, [string]$To, [string]$Name) {
    $text = Get-Content -LiteralPath $module -Raw
    $mut = $text.Replace($From, $To)
    Check "MUTATION anchor found: $Name" ($mut -cne $text) 'the anchor text is not in the module - the mutation would be vacuous'
    $p = Join-Path $work "mutant-$Name.ps1"
    Set-Content -LiteralPath $p -Value $mut -Encoding UTF8
    $p
}

$mOrder = New-Mutant '{ $_.LastSec }; Descending = $true }' '{ $_.LastSec }; Descending = $false }' 'order'
$orderRes = Get-Rows $mOrder
Check 'MUTATION: ordering by the last run (ascending) is DETECTED (the first row flips)' ("$($orderRes.Rows[0].Suite)" -ne 'guard forms') "mutant order=$(($orderRes.Rows | ForEach-Object { "$($_.Suite):$($_.LastSec)" }) -join ' > ')"

$mMedian = New-Mutant '$med = Get-AgentqMedian -Values $tail' '$med = [double]$tail.Count' 'median'
$medRes = Get-Rows $mMedian
Check 'MUTATION: a median taken from the count is DETECTED' ((Row 'guard forms' $medRes).MedianSec -ne 20) "mutant median=$((Row 'guard forms' $medRes).MedianSec)"

$mFmt = New-Mutant '$v.ToString($fmt, $script:Inv)' "[string]::Format(`$script:Inv, `$fmt, `$v)" 'render'
$fmtRes = Get-Rows $mFmt
Check 'MUTATION: a formatter that swallows the value (every row 0.0) is DETECTED' ((Row 'guard forms' $fmtRes).LastSec -ne 30) "mutant lastSec=$((Row 'guard forms' $fmtRes).LastSec)"

# --- done ----------------------------------------------------------------------------------------------
Write-Output "agentq-timings: pass=$pass fail=$fail"
if ($fail) { Note "fixture kept for inspection: $fx"; exit 1 }
Remove-Item -LiteralPath $fx -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'ALL PASS'
exit 0
