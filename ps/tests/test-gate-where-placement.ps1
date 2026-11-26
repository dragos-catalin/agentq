# Placement of a GATE wrapper: a Windows-only command must never be sent to a Linux workspace.
#
# The defect this pins (measured 2026-11-26): `landGate.<repo>` is `pwsh -NoProfile -File <script>`, and
# when `build:machine` was saturated the `auto` placement escalated the wrapper to `ws-codai`, which
# answered `{"exit":64,"event":"cloud-fail","phases":{"sync":0.4,"install":0,"run":0.1},"host":"ws-codai"}`
# in 0.1 s having executed nothing. agentq read that 64 as a pre-gate FAILURE, failed the land BEFORE the
# queue and quarantined the topic, so no later batch absorbed it either - the lane looked held and the exit
# code described the runner, not the gate.
#
# Get-GateRunWhere is the fix: `local` for a PowerShell host, `auto` for anything a pool can really run.
# It is extracted from the LIVE bin/agentq-v2.ps1 by regex (not paraphrased), so the suite fails if the
# rule is renamed away, weakened, or left in a form whose own bug makes it inert - which is exactly what
# happened once: a missing @() turned `('pwsh' -split '[\\/]')[-1]` into the last CHARACTER 'h', and the
# pwsh rule silently stopped matching while the file still LOOKED right.
#
# Offline, no agentq ticket, no network.
#   -V2   path to agentq-v2.ps1 (default: <parent of this file>\bin\agentq-v2.ps1)
param([string]$V2)
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
if (-not $V2) { $V2 = Join-Path (Join-Path $root 'bin') 'agentq-v2.ps1' }

$pass = 0; $fail = 0
function Check([string]$name, $ok, [string]$extra = '') {
  if ($ok) { $script:pass++; Write-Host "PASS $name" }
  else { $script:fail++; Write-Host "FAIL $name  $extra" }
}

if (-not (Test-Path -LiteralPath $V2)) { Write-Host "FAIL agentq-v2.ps1 not found: $V2"; exit 1 }
$raw = Get-Content -LiteralPath $V2 -Raw

# 1. The file must still parse - the extraction below would happily read a syntactically broken function.
$tok = $null; $err = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($V2, [ref]$tok, [ref]$err)
Check 'agentq-v2.ps1 parses (0 errors)' (@($err).Count -eq 0) (@($err) | ForEach-Object { $_.Message } | Select-Object -First 3 | Join-String -Separator '; ')

# 2. Exactly one definition - two would mean the extraction tested the wrong one.
$defs = [regex]::Matches($raw, '(?ms)^function Get-GateRunWhere\(').Count
Check 'exactly one Get-GateRunWhere definition' ($defs -eq 1) "count=$defs"

$m = [regex]::Match($raw, '(?ms)^function Get-GateRunWhere\(\[string\]\$GateCommand\).*?^\}')
Check 'Get-GateRunWhere extracted' $m.Success
if (-not $m.Success) { Write-Host "--- $pass pass / $fail fail"; exit 1 }
Invoke-Expression $m.Value

# 3. The placement decision, case by case. `local` = the wrapper runs on this host; `auto` = the pool may
#    take it. A Windows path in an ARGUMENT must NOT force local: the gate command's executable is what
#    decides, so `bash -c 'run E:\gh\x'` is still pool-eligible.
$cases = @(
  @{ c = 'pwsh -NoProfile -File C:\Users\x\.copilot\hooks\run-build.ps1'; w = 'local'; y = 'the shipped landGate form' }
  @{ c = 'pwsh.exe -NoProfile -File x.ps1';                             w = 'local'; y = 'pwsh.exe' }
  @{ c = 'powershell -File x.ps1';                                      w = 'local'; y = 'Windows PowerShell' }
  @{ c = 'cmd /c gate.bat';                                             w = 'local'; y = 'bare cmd is a Windows-only interpreter' }
  @{ c = 'C:\Windows\System32\cmd.exe /c gate.bat';                     w = 'local'; y = 'fully-qualified cmd' }
  @{ c = 'C:\Program Files\PowerShell\7\pwsh.exe -NoProfile -File x.ps1'; w = 'local'; y = 'fully-qualified pwsh (the @() bug hid here)' }
  @{ c = 'C:\tools\gate.ps1';                                           w = 'local'; y = 'Windows path as the executable' }
  @{ c = '\\srv\share\gate.cmd /run';                                   w = 'local'; y = 'UNC executable' }
  @{ c = 'bash scripts/cloud-gate.sh';                                  w = 'auto';  y = 'POSIX command stays pool-eligible' }
  @{ c = 'bash -c "run E:\gh\x"';                                       w = 'auto';  y = 'Windows path only in an ARGUMENT' }
  @{ c = 'node scripts/gate.mjs';                                       w = 'auto';  y = 'node is pool-eligible' }
  @{ c = 'pnpm --filter x test';                                        w = 'auto';  y = 'a package manager is pool-eligible' }
)
foreach ($t in $cases) {
  $got = ''
  try { $got = [string](Get-GateRunWhere $t.c) } catch { $got = "threw: $($_.Exception.Message)" }
  Check "where='$($t.w)' for [$($t.c)]" ($got -eq $t.w) "got='$got' ($($t.y))"
}

# 4. Wiring: a rule nobody calls is decorative. Invoke-GateRun must set AGENTQ_WHERE from it, and must do
#    so only when the caller left the variable unset (an explicit -Where / AGENTQ_WHERE is the caller's).
$call = [regex]::Match($raw, '(?m)^\s*if \(-not \$prevWhere\) \{ \$env:AGENTQ_WHERE = Get-GateRunWhere \$Gate \}')
Check 'Invoke-GateRun sets AGENTQ_WHERE from Get-GateRunWhere when the caller left it unset' $call.Success
$restore = [regex]::Match($raw, '(?m)^\s*finally \{ if \(\$prevWhere\)')
Check 'Invoke-GateRun restores the caller env in a finally block' $restore.Success
Check 'the gate placement is read from $Gate, not a hard-coded value' ($raw -match 'Get-GateRunWhere \$Gate')

Write-Host "--- $pass pass / $fail fail"
if ($fail) { exit 1 }
exit 0
