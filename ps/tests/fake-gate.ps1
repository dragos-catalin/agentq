# Test double for run-build.ps1 in land gates (ADR 0003 W2-5 tests). Logs every gate call; a gate whose
# purpose names a 'blocker' topic waits while $env:FAKE_GATE_HOLD exists (max 2 min); a tree that
# contains bad.txt fails the gate.
param([string]$Root, [switch]$Wait, [int]$TimeoutMin, [string]$Purpose, [string]$Command)
Add-Content -LiteralPath $env:FAKE_GATE_LOG -Value $Purpose
$i = 0
while ($Purpose -match 'blocker' -and $env:FAKE_GATE_HOLD -and (Test-Path -LiteralPath $env:FAKE_GATE_HOLD) -and $i -lt 240) { Start-Sleep -Milliseconds 500; $i++ }
if (Test-Path -LiteralPath (Join-Path $Root 'bad.txt')) { exit 1 }
exit 0
