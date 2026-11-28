# sat-report.ps1 (2026-11-26) turns today's scattered saturation measurements into one read-only
# command: hook calls per hour split by execution path, resident-host service time, CPU hogs and the
# agentq queue snapshot. THIS suite proves the ONE thing a report can get silently wrong - the
# classifier - against a synthetic fixture, through the -CoordDir / -ResidentDir overrides the script
# exposes for exactly this purpose.
#
# The load-bearing case: a hook row whose startMs is the literal JSON null is "no measurement" and
# must NEVER be coerced to 0 (0 would land in the "served" bucket and turn an unmeasured call into a
# resident-host hit). The fixture puts one null row beside 3 served / 3 spawned / 3 junk rows and the
# assertions pin all five counts, so a class boundary that drifts fails LOUDLY.
#
# It is runnable two ways and both are used:
#   pwsh -NoProfile -File ps\tests\test-sat-report.ps1                    # the real script
#   pwsh -NoProfile -File ps\tests\test-sat-report.ps1 -Script <mutant>   # the mutation proof
# The mutation was performed by copying the script and inverting the served comparison
# (`-lt 50` -> `-ge 50`); the counts move and this suite goes red. See the report.
#
# Output contract (run-all.ps1 counts `^\s*(PASS|ok)\b` vs `^\s*(FAIL)\b`): one PASS/FAIL line per
# check, then `sat-report: checks=N pass=N fail=N`, exit 1 if anything failed.
param(
  [string]$Script = (Join-Path $PSScriptRoot '..\bin\sat-report.ps1'),
  [int]$SampleSec = 1,
  [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$Script = (Resolve-Path $Script).Path
$inv = [System.Globalization.CultureInfo]::InvariantCulture
$script:fail = 0
$script:pass = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "PASS $name"; $script:pass++ } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ }
}

# --- fixture: a synthetic day with rows in ALL FOUR classes -------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sat-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$coord = Join-Path $tmp 'coord'
$resident = Join-Path $tmp 'resident'
New-Item -ItemType Directory -Force (Join-Path $coord 'hooks') | Out-Null
New-Item -ItemType Directory -Force $resident | Out-Null
$date = '20260101'
$cost = Join-Path $coord ('hooks\cost-' + $date + '.jsonl')

# One JSON object per line, exactly the field order the real file uses (ts, ms, startMs, tool, verb,
# deny, session). 'null' is emitted UNQUOTED so it is the JSON literal null, not the string "null".
# -Verb is the agentq verb the call ran (round 4, 2026-11-28); empty for a call that ran none.
function CostRow([string]$ts, [string]$startMs, [string]$Verb = '') {
  return '{"ts":"' + $ts + '","ms":1,"startMs":' + $startMs + ',"tool":"t","verb":"' + $Verb + '","deny":false,"session":"s"}'
}
$rows = @(
  # hour 00 - served (<50): 4, 10, 49
  (CostRow '2026-01-01T00:00:01Z' '4' 'status'),
  (CostRow '2026-01-01T00:00:02Z' '10'),
  (CostRow '2026-01-01T00:00:03Z' '49'),
  # hour 00 - spawned (50..5000, boundaries included): 50, 500, 5000
  (CostRow '2026-01-01T00:05:00Z' '50' 'status'),
  (CostRow '2026-01-01T00:05:01Z' '500'),
  (CostRow '2026-01-01T00:05:02Z' '5000'),
  # hour 00 - junk (>5000): 5001, 9999, 104941927
  (CostRow '2026-01-01T00:06:00Z' '5001' 'status'),
  (CostRow '2026-01-01T00:06:01Z' '9999'),
  (CostRow '2026-01-01T00:06:02Z' '104941927'),
  # hour 01 - the load-bearing row: startMs is literal null -> no measurement, never 0
  (CostRow '2026-01-01T01:00:00Z' 'null' 'land')
)
[IO.File]::WriteAllLines($cost, $rows, [System.Text.UTF8Encoding]::new($false))

# server.log: a listening line (must be ignored) plus 5 requests whose totals 10..50 give
# p50=30 / p90=50 / p99=50 by nearest-rank, and reads 1..5 give p50=3.
$logLines = @(
  '08:15:31.691  listening on \\.\pipe\codai-hookc  mode=v6-subst  script=hook-pre.ps1 (14030 chars, parsed in 24 ms)  pid=47412',
  '08:15:34.461  req 1  total 10 ms (read 1, run 10)  exit 0 (SetShouldExit)  bin=True  stdout 0 B  stderr 0 B',
  '08:15:34.989  req 2  total 20 ms (read 2, run 20)  exit 0 (SetShouldExit)  bin=True  stdout 0 B  stderr 0 B',
  '08:15:35.709  req 3  total 30 ms (read 3, run 30)  exit 0 (SetShouldExit)  bin=True  stdout 0 B  stderr 0 B',
  '08:15:36.685  req 4  total 40 ms (read 4, run 40)  exit 0 (SetShouldExit)  bin=True  stdout 0 B  stderr 0 B',
  '08:15:37.685  req 5  total 50 ms (read 5, run 50)  exit 0 (SetShouldExit)  bin=True  stdout 0 B  stderr 0 B'
)
[IO.File]::WriteAllLines((Join-Path $resident 'server.log'), $logLines, [System.Text.UTF8Encoding]::new($false))

# A stub agentq so section 4 is hermetic - it only has to print recognisable lines.
$stub = Join-Path $tmp 'stub-aq.ps1'
[IO.File]::WriteAllLines($stub, @("Write-Output 'STUB-STATUS-ALPHA'", "Write-Output 'STUB-STATUS-BETA'"), [System.Text.UTF8Encoding]::new($false))

# --- read-only proof: hash both fixture trees before and after ----------------------------------
function Snapshot([string]$root) {
  $out = @()
  foreach ($e in @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)) {
    if ($e.PSIsContainer) { $out += ('D ' + $e.FullName.Substring($root.Length)) }
    else { $out += ('F ' + $e.FullName.Substring($root.Length) + ' ' + $e.Length + ' ' + (Get-FileHash -LiteralPath $e.FullName -Algorithm SHA256).Hash) }
  }
  return @($out)
}
$before = @(Snapshot $coord) + @(Snapshot $resident)

# --- run the report against the fixture ---------------------------------------------------------
$out = @(& pwsh -NoProfile -File $Script -CoordDir $coord -ResidentDir $resident -Date $date -Aq $stub -SampleSec $SampleSec -Top 3 2>&1 | ForEach-Object { [string]$_ })
$code = $LASTEXITCODE
$text = $out -join "`n"

$after = @(Snapshot $coord) + @(Snapshot $resident)
$drift = @(Compare-Object $before $after)

# --- assertions ---------------------------------------------------------------------------------
Check 'exits 0 against the fixture' ($code -eq 0) ("exit=" + $code)
Check 'day total: 10 calls = 3 served + 3 spawned + 3 junk + 1 no-measurement' `
  ($text -match 'DAY TOTAL calls=10 served=3 spawned=3 junk=3 no-measurement=1')
Check 'hour 00 = 9 calls: 3 served, 3 spawned, 3 junk, 0 no-measurement' `
  ($text -match '(?m)^00\s+9\s+3\s+3\s+3\s+0$')
# THE load-bearing assertion: the single null startMs is one "no-measurement", NOT a zero in served.
Check 'hour 01 = 1 call, counted no-measurement (null is not 0)' `
  ($text -match '(?m)^01\s+1\s+0\s+0\s+0\s+1$')
# Boundary check: 5000 is spawned, 5001 is junk. If a boundary drifts one of these counts moves.
Check 'classification boundaries hold (49<50, 5000 spawned, 5001 junk)' `
  (($text -match 'served=3 spawned=3 junk=3') -and ($text -notmatch 'served=4'))
Check 'resident host: 5 requests parsed' ($text -match '(?m)^requests=5$')
Check 'resident host: total p50=30 (nearest-rank over 10..50)' ($text -match 'total  p50=30')
Check 'resident host: 4th line (listening) ignored, read p50=3' ($text -match 'read   p50=3')
Check 'section 3 (processes) ran' ($text -match '== TOP PROCESSES BY CPU DELTA')
Check 'section 4 (agentq status) ran and shows the stub output' ($text -match 'STUB-STATUS-ALPHA')
Check 'CLASSIFY legend printed' ($text -match 'CLASSIFY served<50  spawned=50\.\.5000  junk>5000')
# --- 1b: the same file summed per agentq verb ---------------------------------------------------
# 'status' is on three rows of three DIFFERENT classes (served / spawned / junk), so a table that
# counted only one path, or that looked at a row's tool instead of its verb, moves here.
Check 'verb table: status = 3 calls, 1 served, 1 spawned, avg 1.0 ms' ($text -match '(?m)^status\s+3\s+1\s+1\s+1\.0$')
# The null-startMs row has no measurement and still belongs to its verb (a null must not drop it).
Check 'verb table: land = 1 call, counted none served/spawned (null is not 0)' ($text -match '(?m)^land\s+1\s+0\s+0\s+1\.0$')
Check 'verb coverage: 4 of the 10 rows name a verb' ($text -match 'VERB COVERAGE rows=10 with-verb=4 \(40\.0%\)')
Check 'verb section printed even though most rows name none' ($text -match '== AGENTQ VERB COST')
# R4-6: the read verbs are named whether or not they were called. 'status' has fixture rows, 'who' and
# 'since' do not - and the two must be DISTINGUISHABLE, because "absent from the table" reads as "not
# instrumented" as easily as "not called today", which is exactly how a stealth regression hides.
Check 'read verbs: status printed with its real numbers' ($text -match 'READ VERBS .*status calls=3 spawned=1 avg-ms=1\.0')
Check 'read verbs: an uncalled verb is named as no-call-today, not omitted' ($text -match 'who no-call-today')
Check 'read-only: neither fixture tree changed (hash, size, files)' ($drift.Count -eq 0) (($drift | Select-Object -First 5) -join ' ; ')

Write-Host ("sat-report: checks=" + ($script:pass + $script:fail) + " pass=" + $script:pass + " fail=" + $script:fail + " script=" + $Script)
if ($script:fail) {
  if (-not $KeepWork) { }
  exit 1
}
if (-not $KeepWork) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
exit 0
