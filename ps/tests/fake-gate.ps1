# Test double for run-build.ps1 in land gates (ADR 0003 W2-5 tests). Logs every gate call; a gate whose
# purpose names a 'blocker' topic waits while $env:FAKE_GATE_HOLD exists (max 2 min); a tree that
# contains bad.txt fails the gate.
param([string]$Root, [switch]$Wait, [int]$TimeoutMin, [string]$Purpose, [string]$Command)
Add-Content -LiteralPath $env:FAKE_GATE_LOG -Value $Purpose
# Which tree the gate saw (land pre-gate tests): "<purpose>|<tree hash>|<root>".
if ($env:FAKE_GATE_TREE_LOG) { Add-Content -LiteralPath $env:FAKE_GATE_TREE_LOG -Value ("{0}|{1}|{2}" -f $Purpose, "$(git -C $Root rev-parse 'HEAD^{tree}' 2>$null)".Trim(), $Root) }
# Which placement the caller asked for, so a suite can prove a Windows-only gate wrapper is never
# cloud-placed (test-land-pregate.ps1, 2026-11-26): "<purpose>|<local|auto|cloud|>".
if ($env:FAKE_GATE_WHERE_LOG) { Add-Content -LiteralPath $env:FAKE_GATE_WHERE_LOG -Value ("{0}|{1}" -f $Purpose, "$env:AGENTQ_WHERE") }
$i = 0
while ($Purpose -match 'blocker' -and $env:FAKE_GATE_HOLD -and (Test-Path -LiteralPath $env:FAKE_GATE_HOLD) -and $i -lt 240) { Start-Sleep -Milliseconds 500; $i++ }
if (Test-Path -LiteralPath (Join-Path $Root 'bad.txt')) { exit 1 }
exit 0
