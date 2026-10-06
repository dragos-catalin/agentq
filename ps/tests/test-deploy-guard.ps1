<#
.SYNOPSIS
  Prove the deploy-from-dirty-tree block fires in the REGISTERED dispatcher
  (guard-tooluse.ps1), with BOTH payload dialects (VS Code snake_case tool_input,
  CLI camelCase toolInput). guard-command.ps1 is covered by test-guard.ps1; this
  exists because "configured != registered != fires" (config-silent-failures.md).

    test-deploy-guard.ps1            # exit 1 on any hole
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$hook = "$env:USERPROFILE\.copilot\hooks\guard-tooluse.ps1"

function Invoke-Hook([hashtable]$payload) {
  $json = $payload | ConvertTo-Json -Compress -Depth 4
  $out = ($json | pwsh -NoProfile -File $hook 2>$null)
  $code = $LASTEXITCODE
  # VS Code dialect blocks with a JSON deny + exit 0 (exit 2 is not honoured there, 2026-09-27).
  try { if ((($out | Out-String) | ConvertFrom-Json).hookSpecificOutput.permissionDecision -eq 'deny') { return 2 } } catch { }
  return $code
}
$deploy = 'gcloud run services replace deploy/cloud-run/gateway.service.yaml --region europe-west1'
$read   = 'gcloud run services describe codai-gateway --region europe-west1'
$wrap   = "pwsh -NoProfile -File $env:USERPROFILE\.copilot\hooks\deploy-clean.ps1 -Command 'gcloud run services replace x.yaml'"

$fx = Join-Path $env:TEMP ("deploy-guard-fx-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx | Out-Null
Push-Location $fx
$fail = @()
try {
  git init -q .; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  Set-Content wip.txt 'x'
  # VS Code dialect (real payloads carry hook_event_name)
  $vs = @{ hook_event_name = 'PreToolUse'; tool_name = 'run_in_terminal' }
  if ((Invoke-Hook ($vs + @{ tool_input = @{ command = $deploy } })) -ne 2) { $fail += 'vscode dialect: deploy on dirty tree NOT blocked' }
  if ((Invoke-Hook ($vs + @{ tool_input = @{ command = $read } }))   -eq 2) { $fail += 'vscode dialect: read wrongly blocked' }
  if ((Invoke-Hook ($vs + @{ tool_input = @{ command = $wrap } }))   -eq 2) { $fail += 'vscode dialect: clean wrapper wrongly blocked' }
  # CLI dialect
  if ((Invoke-Hook @{ toolName = 'bash'; toolInput = @{ command = $deploy } }) -ne 2) { $fail += 'cli dialect: deploy on dirty tree NOT blocked' }
  # clean tree
  Remove-Item wip.txt
  if ((Invoke-Hook ($vs + @{ tool_input = @{ command = $deploy } })) -eq 2) { $fail += 'clean tree: deploy wrongly blocked' }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
}
if ($fail) { $fail | ForEach-Object { Write-Host "FAIL  $_" -ForegroundColor Red }; exit 1 }
Write-Host 'deploy guard OK (registered dispatcher, both dialects, dirty+clean)' -ForegroundColor Green
exit 0
