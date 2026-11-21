# Behavioural tests for bin/run-tests-job.ps1 - the gate runner that gives a long suite its own console.
#
# The incident this pins (2026-11-21): ps/install.ps1 ran `tests/run-all.ps1 -Parallel 4` in a VS Code
# terminal, printed 24 of 45 suites green, went quiet, and the shell came back free - a terminal silent
# for ~20 min had been reaped by reap-terminals.ps1. Nothing was installed. So: the gate must run as a
# REGISTERED BACKGROUND JOB, and the exit code it hands the caller must be the suite's own.
#
# What is asserted here (all through the REAL wrapper, the REAL job-start.ps1 and the REAL wait-job.ps1):
#   * a green suite -> exit 0, and the banner names the job id AND the log path BEFORE the wait starts
#   * that job is a real registry entry (independent of this process), and its log ends EXIT=0 / DONE
#   * a red suite -> exit 1 (the caller refuses to install)
#   * -Foreground runs in THIS console and still propagates 0/1 (the old behaviour is kept)
#   * a silently wedged suite -> exit 2, never mistaken for green
#   * -MaxTotalMin reached while the suite still runs -> exit 3, explicitly NOT green
#   * an unusable -RunAll path -> exit 4, and no job is registered for it
#   * the install gate really is wired to this wrapper (source-level, and the wrapped call is asserted,
#     not a bare identifier)
# Isolated AGENTQ_HOME + temp dirs; never touches the real coord dir.
param([string]$Bin)
$ErrorActionPreference = 'Stop'
if (-not $Bin) { $Bin = Join-Path (Split-Path $PSScriptRoot) 'bin' }
$wrapper = Join-Path $Bin 'run-tests-job.ps1'
$jobs = Join-Path $Bin 'jobs.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aq-rtj-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_NO_ADMISSION = '1'
$env:AGENTQ_SESSION = 'rtjtest'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }

# Fake "run-all.ps1" targets. They only have to speak run-all's contract: text, then exit.
$green = Join-Path $tmp 'green.ps1'; Set-Content -LiteralPath $green -Value "Write-Output 'PASS green'; exit 0"
$red = Join-Path $tmp 'red.ps1'; Set-Content -LiteralPath $red -Value "Write-Output 'FAIL red'; exit 1"
$stall = Join-Path $tmp 'stall.ps1'; Set-Content -LiteralPath $stall -Value "Write-Output 'working'; Start-Sleep 30"
$slow = Join-Path $tmp 'slow.ps1'; Set-Content -LiteralPath $slow -Value '1..8 | ForEach-Object { Write-Output ("tick " + $_); Start-Sleep -Milliseconds 700 }; exit 0'

function Run-Wrapper([string[]]$a) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $out = @(& pwsh -NoProfile -File $wrapper @a 2>&1 | ForEach-Object { "$_" })
  @{ code = $LASTEXITCODE; out = ($out -join "`n"); sec = $sw.Elapsed.TotalSeconds }
}
# An id printed as `job <id>` / a log path printed as `log  <path>`; both are parsed the way a human reads
# the banner, so a banner that stops naming them fails here.
function Get-JobId([string]$o) { $m = [regex]::Match($o, '(?m)^\s*job\s+(\S+)\s*$'); if ($m.Success) { $m.Groups[1].Value } else { '' } }
function Get-JobLog([string]$o) { $m = [regex]::Match($o, '(?m)^\s*log\s+(\S+)\s*$'); if ($m.Success) { $m.Groups[1].Value } else { '' } }

# --- green: exit 0, and the caller is told WHERE the work is before it waits ------------------------
$r = Run-Wrapper @('-RunAll', $green, '-Cwd', $tmp, '-EveryS', '0.3')
$id = Get-JobId $r.out; $log = Get-JobLog $r.out
Check 'green suite -> exit 0' ($r.code -eq 0) "code=$($r.code) $($r.out)"
Check 'banner names the job id' ([bool]$id) $r.out
Check 'banner names the log path' ([bool]$log -and $log -like "$tmp*") "log='$log'"
$regFile = Join-Path (Join-Path $env:AGENTQ_HOME 'jobs') "$id.json"
Check 'the run is a REAL registered job (registry entry exists)' ([bool]$id -and (Test-Path -LiteralPath $regFile)) "missing $regFile"
if (Test-Path -LiteralPath $regFile) {
  $j = Get-Content -LiteralPath $regFile -Raw | ConvertFrom-Json
  Check 'the registry entry ended done with exitCode 0' ("$($j.state)" -eq 'done' -and [int]$j.exitCode -eq 0) "state=$($j.state) code=$($j.exitCode)"
}
Check 'the job log ends EXIT=0 / DONE' ((Test-Path -LiteralPath $log) -and ((Get-Content -LiteralPath $log -Raw) -match 'EXIT=0') -and ((Get-Content -LiteralPath $log -Raw) -match 'DONE')) "log=$log"
Check 'the wrapper says GREEN for a green suite' ($r.out -match 'gate GREEN')

# --- red: exit 1, and it says the caller must refuse ------------------------------------------------
$r = Run-Wrapper @('-RunAll', $red, '-Cwd', $tmp, '-EveryS', '0.3')
Check 'red suite -> exit 1 (install refuses)' ($r.code -eq 1) "code=$($r.code) $($r.out)"
Check 'red prints the log path so the failure can be read' ($r.out -match 'the caller must refuse' -and (Get-JobLog $r.out) -like "$tmp*") $r.out

# --- -Foreground keeps the old behaviour and still propagates the code -------------------------------
$r = Run-Wrapper @('-RunAll', $green, '-Cwd', $tmp, '-Foreground')
Check 'foreground green -> exit 0' ($r.code -eq 0) "code=$($r.code)"
Check 'foreground says this console can be reaped + prints the suite output' ($r.out -match 'FOREGROUND' -and $r.out -match 'PASS green') $r.out
$r = Run-Wrapper @('-RunAll', $red, '-Cwd', $tmp, '-Foreground')
Check 'foreground red -> exit 1' ($r.code -eq 1) "code=$($r.code)"

# --- a wedged suite: exit 2, never green ------------------------------------------------------------
$r = Run-Wrapper @('-RunAll', $stall, '-Cwd', $tmp, '-EveryS', '0.3', '-MaxSec', '30', '-StallSec', '2')
Check 'silently wedged suite -> exit 2 (STALLED, NOT green)' ($r.code -eq 2) "code=$($r.code) $($r.out)"
Check 'STALLED says it is not green and names the job' ($r.out -match 'NOT green' -and $r.out -match 'STALLED') $r.out

# --- the total cap: exit 3 while the suite is still alive -------------------------------------------
$r = Run-Wrapper @('-RunAll', $slow, '-Cwd', $tmp, '-EveryS', '0.3', '-MaxSec', '1', '-StallSec', '60', '-MaxTotalMin', '0.05')
Check 'wait cap reached -> exit 3' ($r.code -eq 3) "code=$($r.code) $($r.out)"
Check 'the cap answer is NOT green and tells the caller to re-check the job' ($r.out -match 'NOT green' -and $r.out -match 'still running after 0.05 min' -and $r.out -match 'wait-job.ps1" -JobId') $r.out

# --- a broken seam: exit 4, and nothing is registered ------------------------------------------------
$before = @(Get-ChildItem -LiteralPath (Join-Path $env:AGENTQ_HOME 'jobs') -File -ErrorAction SilentlyContinue).Count
$r = Run-Wrapper @('-RunAll', (Join-Path $tmp 'does-not-exist.ps1'), '-Cwd', $tmp)
$after = @(Get-ChildItem -LiteralPath (Join-Path $env:AGENTQ_HOME 'jobs') -File -ErrorAction SilentlyContinue).Count
Check 'missing run-all -> exit 4 (usage error)' ($r.code -eq 4) "code=$($r.code) $($r.out)"
Check 'a usage error registers no job' ($after -eq $before) "before=$before after=$after"

# --- the install gate is wired to this wrapper -------------------------------------------------------
# Source-level, but the assertion names the CALL, so deleting the call cannot keep it green, and a bare
# mention in a comment cannot satisfy it.
$installSrc = Get-Content -LiteralPath (Join-Path (Split-Path $PSScriptRoot) 'install.ps1') -Raw
Check 'install.ps1 runs the gate through bin\run-tests-job.ps1' ($installSrc -match "bin\\run-tests-job\.ps1'\)\s+-RunAll") 'install.ps1 does not call the wrapper'
Check 'install.ps1 still has a foreground path (run-all.ps1 directly)' ($installSrc -match '& pwsh -NoProfile -File \(Join-Path \$src ''tests\\run-all\.ps1''\) @raArgs') 'no foreground fallback'
Check 'install.ps1 refuses a stall and a timeout with their own message' ($installSrc -match 'the gate STALLED' -and $installSrc -match 'wait cap expired') 'stall/cap refusals missing'

# --- cleanup: kill anything still running so the next suite is not affected --------------------------
try {
  $list = @(& pwsh -NoProfile -File $jobs list -Json 2>$null | ConvertFrom-Json)
  foreach ($x in $list) { if ("$($x.state)" -in 'running', 'starting', 'suspect') { & pwsh -NoProfile -File $jobs kill "$($x.id)" 2>&1 | Out-Null } }
} catch { }
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($fail) { Write-Host "FAIL run-tests-job suite: $fail"; exit 1 }
Write-Host 'PASS run-tests-job (gate runs as a registered job; stall/cap are refusals)'
exit 0
