<#
run-tests-job - run ps/tests/run-all.ps1 as a REGISTERED BACKGROUND JOB, so a long, quiet suite can
never again be killed by the terminal reaper. That reaper (reap-terminals.ps1) closes idle VS Code
terminals; a suite that prints nothing for ~20 min looks exactly like an idle terminal. Launched
through job-start.ps1 the suite gets its OWN hidden console (ShellExecute + Hidden, empty stdin, no
inherited handles), so no terminal - the caller's or anyone else's - can reach it. The caller still
gets the REAL exit code and can watch a live log.

WHY A JOB AND NOT A LONG FOREGROUND CALL (the incident, 2026-11-21)
  ps/install.ps1 ran its gate `ps/tests/run-all.ps1 -Parallel 4` in a VS Code terminal. It printed 24
  of 45 suites, all green, then the terminal went quiet and the shell came back free - no footer, no
  process, and NOTHING had been installed. A terminal silent for ~20 min WAS reaped. "The shell is
  free again" is not evidence a job finished.

USAGE
  run-tests-job.ps1 -Only 'cwd,build class' -Parallel 4     # the gate, as a detached job
  run-tests-job.ps1 -Foreground -Only args                  # old behaviour: run in THIS console

Every argument is forwarded to run-all.ps1 unchanged ( -Only / -Skip / -List / -LogDir / -TimeoutMin /
-Parallel ). Run with no arguments it runs every suite, one after another, exactly as run-all.ps1 does.

HOW IT WAITS (bounded, honest, and it never mistakes a timeout for success)
  * job-start.ps1 launches the suite; its id and log path are printed at once.
  * wait-job.ps1 watches it in BOUNDED chunks (-MaxMin per chunk, <= 10 min): on each chunk it prints
    whatever the log gained, so the caller is not silent either.
  * a chunk that reaches its bound is NOT success - the loop keeps watching (a full gate is ~30 min).
  * STALLED (the log went quiet while the process is alive) and any non-zero suite exit are refusals;
    the caller is told the job id and log path so it can look.
  * -MaxTotalMin (optional) is a hard cap on the whole wait; 0 = keep watching while it makes progress.

EXIT CODES (a red suite is never dressed up as a pass)
  0   the suite finished GREEN (run-all exit 0)
  1   the suite finished RED, or its job DIED without an EXIT marker
  2   STALLED - the job's log went quiet while the process was still alive (wedged)
  3   still running after -MaxTotalMin (0 = no total cap) - the caller must NOT treat this as success
  4   usage / launch error (the job did not register)
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  # Everything not claimed by a named parameter below goes straight to run-all.ps1.
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$RunAllArgs = @(),
  [switch]$Foreground,
  [double]$MaxMin = 10,        # per-chunk bounded wait (wait-job caps this at 10)
  [double]$StallMin = 20,      # a log quiet this long while the process is alive = STALLED
  [double]$MaxTotalMin = 0,    # hard cap on the whole wait; 0 = no cap (watch while it progresses)
  [double]$ExpectedMin = 30,   # only a hint for `jobs list` (SUSPECT uses 2x)
  [string]$RunAll,             # path to run-all.ps1 (default: the sibling checkout); a seam for tests
  [string]$Cwd,                # where <cwd>\.copilot-tmp\jobs\ lives (default: this directory)
  # test-only fine-grained overrides (seconds); mirror wait-job.ps1's own test overrides
  [double]$MaxSec = 0, [double]$StallSec = 0, [double]$EveryS = 0
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

function Say([string]$m) { Write-Output $m }

$bin = $PSScriptRoot
$jobStart = Join-Path $bin 'job-start.ps1'
$wait = Join-Path $bin 'wait-job.ps1'
if (-not $RunAll) { $RunAll = Join-Path (Split-Path $PSScriptRoot) 'tests\run-all.ps1' }
if (-not (Test-Path -LiteralPath $RunAll)) { [Console]::Error.WriteLine("run-tests-job: run-all.ps1 not found: $RunAll"); exit 4 }
$RunAll = (Resolve-Path -LiteralPath $RunAll).Path
if (-not (Test-Path -LiteralPath $jobStart)) { [Console]::Error.WriteLine("run-tests-job: job-start.ps1 not found: $jobStart"); exit 4 }
if (-not (Test-Path -LiteralPath $wait)) { [Console]::Error.WriteLine("run-tests-job: wait-job.ps1 not found: $wait"); exit 4 }

$argsText = (@($RunAllArgs) -join ' ').Trim()
$label = if ($argsText) { "tests run-all $argsText" } else { 'tests run-all (all suites)' }

# --- Foreground: the old behaviour, kept on purpose (some callers want the stream in their console) ---
if ($Foreground) {
  Say "run-tests-job: FOREGROUND run of $RunAll $argsText (no job: this console can be reaped)"
  & pwsh -NoProfile -ExecutionPolicy Bypass -File $RunAll @RunAllArgs
  exit $LASTEXITCODE
}

if (-not $Cwd) { $Cwd = (Get-Location).Path }
$Cwd = (Resolve-Path -LiteralPath $Cwd).Path

# --- launch the suite as a registered background job (own hidden console; immune to the reaper) -----
# Any argument left over after job-start's named parameters is passed to the -File script (run-all.ps1).
$launch = @('-NoProfile', '-File', $jobStart, '-Label', $label, '-File', $RunAll, '-Cwd', $Cwd, '-ExpectedMin', "$ExpectedMin", '-Json')
if ($RunAllArgs.Count) { $launch += @($RunAllArgs) }
$launchOut = @(& pwsh @launch)
if ($LASTEXITCODE -ne 0 -or -not $launchOut.Count) {
  [Console]::Error.WriteLine("run-tests-job: could not register the job (job-start exit $LASTEXITCODE): $($launchOut -join ' ')")
  exit 4
}
$job = $null
try { $job = ($launchOut | Select-Object -Last 1) | ConvertFrom-Json } catch { $job = $null }
if (-not $job -or -not $job.id) { [Console]::Error.WriteLine("run-tests-job: job-start did not return a job id: $($launchOut -join ' ')"); exit 4 }
$id = "$($job.id)"; $log = "$($job.log)"

Say "run-tests-job: gate running as a background job - it survives a terminal reaper (this shell may not)"
Say "  job  $id"
Say "  log  $log"
Say "  watch  pwsh -NoProfile -File `"$wait`" -JobId $id"

# --- bounded, honest wait: only DONE is success; a timeout is NOT ------------------------------------
$total = [Diagnostics.Stopwatch]::StartNew()
while ($true) {
  $w = @('-NoProfile', '-File', $wait, '-JobId', $id, '-MaxMin', "$MaxMin")
  if ($StallMin -gt 0) { $w += @('-StallMin', "$StallMin") }
  if ($MaxSec -gt 0) { $w += @('-MaxSec', "$MaxSec") }
  if ($StallSec -gt 0) { $w += @('-StallSec', "$StallSec") }
  if ($EveryS -gt 0) { $w += @('-EveryS', "$EveryS") }
  & pwsh @w
  $wc = $LASTEXITCODE
  switch ($wc) {
    0 { Say "run-tests-job: gate GREEN (job $id)"; exit 0 }
    1 { [Console]::Error.WriteLine("run-tests-job: gate RED or DEAD (job $id) - the caller must refuse.  log $log"); exit 1 }
    2 { [Console]::Error.WriteLine("run-tests-job: gate STALLED - the job's log went quiet while it was alive (job $id) - NOT green.  log $log"); exit 2 }
    3 {
      if ($MaxTotalMin -gt 0 -and $total.Elapsed.TotalMinutes -ge $MaxTotalMin) {
        [Console]::Error.WriteLine("run-tests-job: still running after $MaxTotalMin min (job $id) - NOT green; the job keeps running.  re-check: pwsh -NoProfile -File `"$wait`" -JobId $id  log $log")
        exit 3
      }
      Say "run-tests-job: still running after a bounded wait (job $id, log $log) - watching again"
    }
    default { [Console]::Error.WriteLine("run-tests-job: unexpected wait-job exit $wc (job $id) - refusing.  log $log"); exit $wc }
  }
}
