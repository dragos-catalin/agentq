# After every cloud run the evidence belongs in the TARGET repo, not only in the job bucket and a terminal
# buffer: runs\<jobid>.log plus ONE row in the repo's own run journal (docs\RUNS.md or RUNS.md). Three
# things this suite proves, because each of them fails silently:
#   * the row follows the repo's EXISTING table columns (arc-prize-2027 and hadamard-next both use
#     `| date | job id | region | expected cost | actual | state | purpose |`);
#   * the row still carries the job id, the exit code, the total seconds and the log path under a header
#     that names none of them, and the row is actually inside the first table (never at end-of-file, where
#     a repo's prose or a second table lives);
#   * a second invocation for the same job id changes NOTHING (a re-run must not grow the journal), and a
#     repo without a journal is never handed a new file (.gitignore is never edited either).
#
# The helpers live in bin\agentq-cloud.ps1 - so the installed tree needs no new file to carry - and are
# extracted from it by AST: the suite drives the PRODUCTION definitions (a rename or a reference to the
# caller's script scope fails here), not a copy of them.
param([string]$Source = (Join-Path (Split-Path $PSScriptRoot) 'bin\agentq-cloud.ps1'))
$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name - $Detail"; $script:fail++ }
}

# ---- the helpers, straight out of the production file ---------------------------------------------
$tok = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tok, [ref]$errs)
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match '(?i)CloudEvidence|RunJournal' }, $true))
Check 'the evidence helpers are defined in agentq-cloud.ps1' ($fns.Count -ge 4) "found $($fns.Count) in $Source"
if ($fns.Count) { . ([scriptblock]::Create((($fns | ForEach-Object { $_.Extent.Text }) -join "`n"))) }
if (-not (Get-Command Save-CloudEvidence -ErrorAction SilentlyContinue)) {
  Write-Host "$([math]::Max($fail, 1)) FAILED (Save-CloudEvidence is not in $Source - nothing to drive)"
  exit 1
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aq-evidence-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$enc = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
function New-FakeRepo([string]$Name, [string]$JournalRel, [string[]]$Header) {
  $r = Join-Path $tmp $Name
  New-Item -ItemType Directory -Force $r | Out-Null
  if ($JournalRel) {
    $j = Join-Path $r $JournalRel
    New-Item -ItemType Directory -Force (Split-Path $j -Parent) | Out-Null
    $lines = @('# Compute runs', '', ('| ' + ($Header -join ' | ') + ' |'), ('|' + (@($Header | ForEach-Object { '---' }) -join '|') + '|'),
      '| 2026-11-24 | local | workstation | 0 EUR | 0 EUR | DONE | the row before mine |', '', 'Prose below the table that must survive.', '')
    [IO.File]::WriteAllText($j, ($lines -join "`n"), $enc)
  }
  $r
}
function Get-JournalLines([string]$Path) { @([IO.File]::ReadAllText($Path) -split "`r?`n") }
function Get-RowIndex([string[]]$Lines, [string]$JobId) {
  for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i].Contains($JobId)) { return $i } }
  -1
}
function Get-RowCells([string]$Row) { @((($Row -replace '\\\|', '') -split '\|').Count - 2) }

# ---- A: the real column set, in docs\RUNS.md, with runs/ already gitignored -----------------------
$repoA = New-FakeRepo 'repo-a' 'docs\RUNS.md' @('date', 'job id', 'region', 'expected cost', 'actual', 'state', 'purpose')
& git -C $repoA init -q -b main 2>$null | Out-Null
Set-Content -LiteralPath (Join-Path $repoA '.gitignore') -Value '/runs/' -NoNewline -Encoding ascii
$job = '20261125-070828-26acaa'
$log = @('+ bash scripts/cloud-gate.sh', 'ruff check . -> All checks passed!', 'pytest -q -> 65 passed in 8.00 s') -join "`n"
$r1 = Save-CloudEvidence -RepoDir $repoA -JobId $job -Log $log -ExitCode 0 -TotalSec 1713.24 -Purpose 'stage-2 cloud gate' -Lane 'gate' -Region 'ws-frontiers, codai-training europe-west4-a' -Command 'bash scripts/cloud-gate.sh'
$logPath = Join-Path $repoA ('runs\' + $job + '.log')
Check '(a) the full log landed at runs\<jobid>.log, byte for byte' ((Test-Path -LiteralPath $logPath) -and ([IO.File]::ReadAllText($logPath) -ceq $log)) $logPath
Check '(a) the result names the repo-relative log path' ($r1.logRelative -eq "runs/$job.log") $r1.logRelative
Check 'a gitignored runs/ is REPORTED, not fixed' ($r1.runsIgnored -eq $true) "runsIgnored=$($r1.runsIgnored)"
Check 'the repo .gitignore was not touched' ((Get-Content -LiteralPath (Join-Path $repoA '.gitignore') -Raw).Trim() -eq '/runs/') 'edited'

$journalA = Join-Path $repoA 'docs\RUNS.md'
$lines = Get-JournalLines $journalA
$idx = Get-RowIndex $lines $job
$row = if ($idx -ge 0) { $lines[$idx] } else { '' }
Check '(c) one row was appended inside the first table (after its last row, before the prose)' ($r1.journalAdded -and $idx -gt 0 -and $lines[$idx - 1] -match '^\| 2026-11-24 \|' -and $lines[$idx + 1] -eq '') "added=$($r1.journalAdded) idx=$idx"
Check '(c) the row follows the table columns exactly (7 cells, header order kept)' ((Get-RowCells $row) -eq 7 -and $lines[2] -match '^\| date \| job id \|') "cells=$(Get-RowCells $row)"
Check '(c) the row carries date, purpose, job id, exit code, total seconds and the log path' ($row -match '^\| 2026-\d\d-\d\d \| ' -and $row.Contains($job) -and $row.Contains('exit 0') -and $row.Contains('total 1713.2 s') -and $row.Contains("runs/$job.log") -and $row.Contains('stage-2 cloud gate')) $row
Check '(c) the row says how it ran (lane + command, pipe-safe cells)' ($row.Contains('(lane gate)') -and $row.Contains('`bash scripts/cloud-gate.sh`')) $row
Check 'the prose below the table survived' ((Get-JournalLines $journalA) -contains 'Prose below the table that must survive.') ''

# ---- D: a re-run of the SAME job id must change nothing -------------------------------------------
$r2 = Save-CloudEvidence -RepoDir $repoA -JobId $job -Log $log -ExitCode 0 -TotalSec 1713.24 -Purpose 'stage-2 cloud gate' -Lane 'gate' -Region 'ws-frontiers, codai-training europe-west4-a' -Command 'bash scripts/cloud-gate.sh'
$lines2 = Get-JournalLines $journalA
$dupes = @($lines2 | Where-Object { $_.Contains($job) })
Check '(d) the second invocation does NOT duplicate the row' ((-not $r2.journalAdded) -and $dupes.Count -eq 1 -and $lines2.Count -eq $lines.Count) "rows=$($dupes.Count) lines=$($lines2.Count)/$($lines.Count)"
Check '(d) the skip is explained, not silent' ("$($r2.journalSkipped)" -match 'already rowed') $r2.journalSkipped

# ---- B: RUNS.md at the repo root, and a FAILING run --------------------------------------------------
$repoB = New-FakeRepo 'repo-b' 'RUNS.md' @('date', 'job id', 'region', 'expected cost', 'actual', 'state', 'purpose')
$jobB = '20261125-064602-502026'
$rB = Save-CloudEvidence -RepoDir $repoB -JobId $jobB -Log 'gate failed' -ExitCode 1 -TotalSec 350.75 -Purpose 'census smoke' -Lane 'gate' -Region 'ws-frontiers' -Command 'bash scripts/cloud-gate.sh census'
Check 'RUNS.md at the repo root is used when docs\RUNS.md is absent' ($rB.journalPath -eq (Join-Path $repoB 'RUNS.md') -and $rB.journalAdded) "$($rB.journalPath)"
$rowB = @(Get-JournalLines (Join-Path $repoB 'RUNS.md') | Where-Object { $_.Contains($jobB) })[0]
Check 'a failing run is stated as FAILED with its exit code and duration' ($rowB -match '\| FAILED, exit 1, total 350\.8 s \|') $rowB

# ---- C: no journal file at all -> the log only, and no file invented ---------------------------------
$repoC = New-FakeRepo 'repo-c' '' @()
$jobC = '20261125-053948-88fa9c'
$rC = Save-CloudEvidence -RepoDir $repoC -JobId $jobC -Log 'only the log' -ExitCode 0 -TotalSec 12.5 -Purpose 'no journal in this repo'
Check 'no journal file -> nothing is created and the skip is announced' ((-not $rC.journalAdded) -and "$($rC.journalSkipped)" -match 'no docs' -and -not (Test-Path -LiteralPath (Join-Path $repoC 'docs\RUNS.md')) -and -not (Test-Path -LiteralPath (Join-Path $repoC 'RUNS.md'))) "$($rC.journalSkipped)"
Check 'the log still lands without a journal' (Test-Path -LiteralPath (Join-Path $repoC "runs\$jobC.log")) ''
Check 'the skip is not fatal: the caller still gets the result object' ($rC.job -eq $jobC -and $rC.logWritten) ''

# ---- E: a header that names none of the required facts ------------------------------------------------
$repoD = New-FakeRepo 'repo-d' 'docs\RUNS.md' @('when', 'what')
$jobD = '20261125-064918-07f7cf'
$rD = Save-CloudEvidence -RepoDir $repoD -JobId $jobD -Log 'y' -ExitCode 2 -TotalSec 60.04 -Purpose 'unfamiliar header'
$linesD = Get-JournalLines (Join-Path $repoD 'docs\RUNS.md')
$idxD = Get-RowIndex $linesD $jobD
$rowD = if ($idxD -ge 0) { $linesD[$idxD] } else { '' }
Check 'an unfamiliar header still yields a row carrying the job id, exit code, total and the log path' ($rowD.Contains($jobD) -and $rowD.Contains('exit 2') -and $rowD.Contains('total 60.0 s') -and $rowD.Contains("runs/$jobD.log")) $rowD
Check 'its cell count is the table''s (2 cells), not a fixed shape' ((Get-RowCells $rowD) -eq 2) $rowD
Check 'it is still inside that table (after the old last row), before the prose' ($idxD -gt 0 -and $linesD[$idxD - 1] -match '^\| 2026-11-24 \|' -and $linesD[$idxD + 1] -eq '' -and $linesD[$linesD.Count - 2] -eq 'Prose below the table that must survive.') "idx=$idxD"
Check 'a value containing a pipe cannot split the row open' ($(Save-CloudEvidence -RepoDir $repoD -JobId '20261125-000000-pipe' -Log 'z' -ExitCode 0 -TotalSec 1 -Purpose 'left | right').journalRow.Contains('left \| right')) 'pipe not escaped'

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL OK'; exit 0 }
