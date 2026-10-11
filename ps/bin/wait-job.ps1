<#
wait-job — BOUNDED wait on a background job, with stall detection. Never blocks longer than -MaxMin
(hard cap 10). Use it only when every remaining task depends on the job; otherwise keep working.

  wait-job.ps1 -JobId <id>                                  job registered by job-start.ps1 (completion =
                                                            registry state / runner exit, not log text)
  wait-job.ps1 -Log <path> -Done 'RB_EXIT=|DONE|EXIT=' [-Fail 'Traceback|BUILD FAILED'] [-Pid <n>]
  wait-job.ps1 -Pid <n>                                     done when the process exits
  common: [-MaxMin 10] [-StallMin 5] [-EveryS 15]

-Done / -Fail are pipe-separated LITERAL substrings (ordinal, case-sensitive): '^RB_EXIT' matches the
text "^RB_EXIT", never a regex anchor. A line `EXIT=<n>` / `RB_EXIT=<n>` with n != 0 counts as FAILED.
Prints one timestamped line per change (not per tick).

EXIT CODES
  0 DONE     done marker seen, or the pid exited with code 0 (or an unknown code)
  1 FAILED   fail marker, EXIT=<nonzero>, pid exit code != 0, or a registry job's process vanished
             without an EXIT marker (DEAD)
  2 STALLED  log size unchanged for -StallMin while the pid is alive (or no pid): prints diagnostics
             (log tail, process tree with CPU/working set, 'Terminate batch job' detection, agentq holders)
  3 TIMEOUT  -MaxMin reached while the job is still progressing: keep working or investigate
#>
param(
  [string]$Log, [string]$Done, [string]$Fail, [Alias('Pid')][int]$ProcId = 0, [string]$JobId,
  [double]$MaxMin = 10, [double]$StallMin = 5, [double]$EveryS = 15,
  # test-only fine-grained overrides (seconds); MaxSec is still capped at 600
  [double]$MaxSec = 0, [double]$StallSec = 0
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'agentq-jobs-lib.ps1')

function Say([string]$m) { Write-Output ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $m) }

$pidStart = $null
if ($JobId) {
  $job = Read-Job $JobId
  if (-not $job) { [Console]::Error.WriteLine("wait-job: no job '$JobId' in $(Get-JobDir)"); exit 2 }
  if (-not $Log) { $Log = "$($job['log'])" }
  if (-not $ProcId) { $ProcId = [int]$job['pid']; $pidStart = $job['pidStart'] }
  # Registry jobs: completion comes from the runner (registry state / runner pid exit), NOT a substring
  # the job itself might print (a test suite echoing "EXIT=0" ended the wait mid-run).
  $script:RegistryMode = -not $Done
}
if (-not (Test-Path variable:script:RegistryMode)) { $script:RegistryMode = $false }
if (-not $Log -and -not $ProcId) { [Console]::Error.WriteLine('wait-job: -Log <path>, -Pid <n> or -JobId <id> is required'); exit 2 }
if ($Log -and -not $Done -and -not $ProcId) { $Done = 'RB_EXIT=|DONE|EXIT=' }

$doneMarks = @("$Done" -split '\|' | Where-Object { $_ -ne '' })
$failMarks = @("$Fail" -split '\|' | Where-Object { $_ -ne '' })
$maxS = if ($MaxSec -gt 0) { [math]::Min($MaxSec, 600) } else { [math]::Min([math]::Max($MaxMin, 0), 10) * 60 }
$stallS = if ($StallSec -gt 0) { $StallSec } else { [math]::Max($StallMin, 0.05) * 60 }
$tick = [math]::Max(0.05, $EveryS)
$overlap = [math]::Max(8, (@($doneMarks + $failMarks | ForEach-Object { $_.Length }) | Measure-Object -Maximum).Maximum)

# A handle opened now lets us read the exit code after the process ends (when we may open it).
$proc = $null
if ($ProcId) {
  if (Test-JobPidAlive $ProcId $pidStart) { try { $proc = Get-Process -Id $ProcId -ErrorAction Stop; $null = $proc.Handle } catch { } }
}
function Test-PidAlive { if (-not $ProcId) { return $false }; if ($proc) { try { return -not $proc.HasExited } catch { } }; Test-JobPidAlive $ProcId $pidStart }
function Get-PidExit { if ($proc) { try { if ($proc.HasExited) { return $proc.ExitCode } } catch { } }; $null }

function Find-Literal([string]$text, [string[]]$marks) {
  foreach ($m in $marks) { if ($text.IndexOf($m, [StringComparison]::Ordinal) -ge 0) { return $m } }
  $null
}
function Get-ExitLine([string]$text) {
  $hit = $null
  foreach ($line in ($text -split "`r?`n")) { if ($line -match '^\s*(RB_)?EXIT=(-?\d+)\s*$') { $hit = [int]$Matches[2] } }
  $hit
}

function Show-Diagnostics {
  Write-Output '--- last 30 log lines'
  $tail = @(Read-JobTail $Log 30)
  $tail | ForEach-Object { Write-Output "  $_" }
  if (@($tail | Where-Object { $_ -match 'Terminate batch job \(Y/N\)' }).Count) {
    Write-Output '!!! log tail shows "Terminate batch job (Y/N)?": a cmd.exe got Ctrl+C (often a foreign one in a shared console) and waits for an answer that never comes. Kill its tree and relaunch hidden (job-start.ps1 / run-build with stdin from NUL).'
  }
  if ($ProcId) {
    Write-Output "--- process tree of pid $ProcId (cpu seconds, working set)"
    Format-JobTree $ProcId | ForEach-Object { Write-Output $_ }
  }
  if (@($tail | Where-Object { $_ -match 'agentq|run-build|waiting for|queued' }).Count) {
    $aq = Join-Path $PSScriptRoot 'agentq.ps1'
    if (-not (Test-Path $aq)) { $aq = Join-Path $HOME '.copilot\bin\agentq.ps1' }
    if (Test-Path $aq) {
      Write-Output '--- agentq status -All (the log mentions a queue)'
      & pwsh -NoProfile -File $aq status -All 2>&1 | Select-Object -First 40 | ForEach-Object { Write-Output "  $_" }
    }
  }
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$pos = 0L; $carry = ''; $lastGrowth = 0.0; $lastSize = -2L; $wasAlive = Test-PidAlive
$label = if ($JobId) { "job $JobId" } elseif ($Log) { $Log } else { "pid $ProcId" }
Say "waiting on $label (max $([math]::Round($maxS / 60, 2)) min, stall $([math]::Round($stallS / 60, 2)) min, done='$Done'$(if ($Fail) { " fail='$Fail'" })$(if ($ProcId) { " pid=$ProcId" }))"

while ($true) {
  if ($script:RegistryMode) {
    $j = Read-Job $JobId
    $st = if ($j) { "$($j['state'])" } else { '' }
    if ($st -in 'done', 'failed', 'killed') {
      $code = $j['exitCode']
      if ($st -eq 'done') { Say "DONE: job $JobId finished (exit $code)"; Read-JobTail $Log 5 | ForEach-Object { Write-Output "  $_" }; exit 0 }
      Say "FAILED: job $JobId $st$(if ($null -ne $code) { " (exit $code)" })"; Read-JobTail $Log 15 | ForEach-Object { Write-Output "  $_" }; exit 1
    }
  }
  if ($Log) {
    $size = Get-JobLogSize $Log
    if ($size -ne $lastSize) {
      if ($size -ge 0) {
        $chunk = Read-JobLogFrom $Log $pos
        $pos = $chunk.end
        $text = $carry + $chunk.text
        $f = Find-Literal $text $failMarks
        if ($f) { Say "FAILED: fail marker '$f' in log"; Read-JobTail $Log 15 | ForEach-Object { Write-Output "  $_" }; exit 1 }
        $d = Find-Literal $text $doneMarks
        if ($d) {
          $code = Get-ExitLine $text
          if ($null -ne $code -and $code -ne 0) { Say "FAILED: done marker '$d' with EXIT=$code"; Read-JobTail $Log 15 | ForEach-Object { Write-Output "  $_" }; exit 1 }
          Say "DONE: marker '$d' seen$(if ($null -ne $code) { " (EXIT=$code)" })"
          Read-JobTail $Log 5 | ForEach-Object { Write-Output "  $_" }
          exit 0
        }
        $carry = if ($text.Length -gt $overlap) { $text.Substring($text.Length - $overlap) } else { $text }
        if ($lastSize -ge -1) {
          $last = @(Read-JobTail $Log 1 | Where-Object { $_.Trim() }) | Select-Object -Last 1
          if ($null -eq $last) { $last = '' } elseif ($last.Length -gt 120) { $last = $last.Substring(0, 120) + '...' }
          Say "log $size bytes (+$([math]::Max(0, $size - [math]::Max(0, $lastSize)))): $last"
        }
      } elseif ($lastSize -ne -1) { Say "log not there yet: $Log" }
      $lastSize = $size; $lastGrowth = $sw.Elapsed.TotalSeconds
    }
  }
  if ($ProcId) {
    $alive = Test-PidAlive
    if ($wasAlive -and -not $alive) { Say "pid $ProcId exited" }
    if (-not $alive) {
      if ($script:RegistryMode) {
        Start-Sleep -Milliseconds 300
        $j = Read-Job $JobId; $st = if ($j) { "$($j['state'])" } else { '' }
        if ($st -eq 'done') { Say "DONE: job $JobId finished (exit $($j['exitCode']))"; exit 0 }
        if ($st -in 'failed', 'killed') { Say "FAILED: job $JobId $st (exit $($j['exitCode']))"; Read-JobTail $Log 15 | ForEach-Object { Write-Output "  $_" }; exit 1 }
        $le = Get-JobLogExit $Log
        if ($null -ne $le) { if ($le -eq 0) { Say "DONE: EXIT=0 in log"; exit 0 }; Say "FAILED: EXIT=$le in log"; exit 1 }
        Say "FAILED: job process is gone without an EXIT marker (DEAD)"; Read-JobTail $Log 15 | ForEach-Object { Write-Output "  $_" }; exit 1
      }
      if ($Log) {
        # final read: the marker may have landed between the size check and the exit
        $chunk = Read-JobLogFrom $Log $pos; $text = $carry + $chunk.text
        if (Find-Literal $text $failMarks) { Say 'FAILED: fail marker in log'; exit 1 }
        $d = Find-Literal $text $doneMarks
        if ($d) { $code = Get-ExitLine $text; if ($null -ne $code -and $code -ne 0) { Say "FAILED: EXIT=$code"; exit 1 }; Say "DONE: marker '$d' seen"; exit 0 }
        if ($JobId) { Say "FAILED: job process is gone without an EXIT marker (DEAD)"; Read-JobTail $Log 15 | ForEach-Object { Write-Output "  $_" }; exit 1 }
      }
      $code = Get-PidExit
      if ($null -ne $code -and $code -ne 0) { Say "FAILED: pid $ProcId exit code $code"; exit 1 }
      Say "DONE: pid $ProcId exited$(if ($null -ne $code) { " (exit $code)" })"
      exit 0
    }
    $wasAlive = $alive
  }
  $el = $sw.Elapsed.TotalSeconds
  if ($Log -and ($el - $lastGrowth) -ge $stallS) {
    Say "STALLED: log unchanged for $([math]::Round(($el - $lastGrowth) / 60, 1)) min ($Log, $([math]::Max(0, $lastSize)) bytes)$(if ($ProcId) { "; pid $ProcId alive" })"
    Show-Diagnostics
    exit 2
  }
  if ($el -ge $maxS) {
    Say "TIMEOUT after $([math]::Round($el / 60, 1)) min: still running, keep working or investigate"
    if ($Log) { Read-JobTail $Log 15 | ForEach-Object { Write-Output "  $_" } }
    if ($JobId) { Write-Output "  re-check later: pwsh -NoProfile -File `"$PSCommandPath`" -JobId $JobId" }
    exit 3
  }
  Start-Sleep -Milliseconds ([int]([math]::Min($tick, [math]::Max(0.05, $maxS - $el)) * 1000))
}
