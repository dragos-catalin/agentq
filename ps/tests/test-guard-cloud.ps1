# guard-tooluse.ps1 devcloud D19 rewrite: a plain build in VS Code is rewritten (updatedInput) into
# `agentq run -Resource build -Where auto`; AGENTQ_WHERE=local, compound commands, non-VS Code
# harnesses and the wrappers themselves keep the old behaviour. Plus a mutation check.
param([string]$Guard = (Join-Path $PSScriptRoot '..\hooks\guard-tooluse.ps1'))
$ErrorActionPreference = 'Stop'
$Guard = (Resolve-Path $Guard).Path
$fails = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS $n" } else { Write-Host "FAIL $n $d"; $script:fails++ } }
function Hook([string]$g, [string]$command, [switch]$NoVsCode) {
  $p = @{ tool_name = 'run_in_terminal'; tool_input = @{ command = $command; explanation = 'x'; goal = 'y'; mode = 'sync' } }
  if (-not $NoVsCode) { $p.hook_event_name = 'PreToolUse' }
  $out = (($p | ConvertTo-Json -Compress) | pwsh -NoProfile -File $g 2>$null) -join ''
  [pscustomobject]@{ raw = $out; code = $LASTEXITCODE; json = $(try { $out | ConvertFrom-Json } catch { $null }) }
}
$aqInstalled = Test-Path (Join-Path $env:USERPROFILE '.copilot\bin\agentq.ps1')
Remove-Item Env:AGENTQ_WHERE -ErrorAction SilentlyContinue

$r = Hook $Guard 'pnpm --filter @codai/common typecheck'
$ui = if ($r.json) { $r.json.hookSpecificOutput.updatedInput } else { $null }
if ($aqInstalled) {
  Check 'plain build rewritten (allow + updatedInput)' ($r.json.hookSpecificOutput.permissionDecision -eq 'allow' -and $ui) $r.raw
  Check 'rewrite targets agentq -Where auto' ("$($ui.command)" -match 'agentq\.ps1" run -Resource build -Where auto -Purpose .+ -- pnpm --filter @codai/common typecheck$') "$($ui.command)"
  Check 'rewrite keeps other tool_input fields' ($ui.mode -eq 'sync' -and $ui.goal -eq 'y') ''
} else { Write-Host 'SKIP rewrite cases (agentq not installed)' }

$env:AGENTQ_WHERE = 'local'
$r = Hook $Guard 'pnpm --filter @codai/common typecheck'
Remove-Item Env:AGENTQ_WHERE
Check 'AGENTQ_WHERE=local -> old block' ($r.raw -match '"permissionDecision":"deny"' -and $r.raw -match 'run-build') $r.raw

$r = Hook $Guard 'pnpm build; Remove-Item x'
Check 'compound command not rewritten (blocked)' ($r.raw -match '"permissionDecision":"deny"') $r.raw
$r = Hook $Guard "pnpm --filter 'x' build"
Check 'quoted command not rewritten (blocked)' ($r.raw -match '"permissionDecision":"deny"') $r.raw
$r = Hook $Guard 'pnpm build' -NoVsCode
Check 'non-VS Code harness keeps exit-2 block' ($r.code -eq 2) "code=$($r.code)"
$r = Hook $Guard 'pwsh -NoProfile -File C:\x\agentq.ps1 run -Resource build -Where auto -Purpose p -- pnpm build'
Check 'agentq wrapper passes untouched' (-not $r.raw) $r.raw
$r = Hook $Guard 'git status'
Check 'non-build passes untouched' (-not $r.raw) $r.raw

# mutation: disable the rewrite branch -> the plain build must be blocked again
if ($aqInstalled) {
  $m = Join-Path $env:TEMP ('gc-mut-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
  $src = [IO.File]::ReadAllText($Guard)
  $mut = $src.Replace("`$env:AGENTQ_WHERE -ne 'local' -and", "`$false -and")
  Check 'mutation applied' ($mut -ne $src) ''
  [IO.File]::WriteAllText($m, $mut, [Text.UTF8Encoding]::new($true))
  $r = Hook $m 'pnpm --filter @codai/common typecheck'
  Check 'mutation: without the branch the build is blocked' ($r.raw -match '"permissionDecision":"deny"') $r.raw
  Remove-Item $m -Force -ErrorAction SilentlyContinue
}
if ($fails) { Write-Host "$fails FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
