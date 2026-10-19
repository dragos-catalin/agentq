# guard-tooluse.ps1 devcloud D19: a plain build is FLAGGED with the exact `agentq run -Resource build
# -Where auto` command to run (an allow+updatedInput rewrite was verified ignored by the VS Code
# harness, 2026-10-12). Since axiom D-40 (2026-10-19) a non-hard block is a WARNING: allowed, with the
# guidance in additionalContext. AGENTQ_WHERE=local keeps the run-build message; compound commands keep
# the run-build message; the wrappers pass. Plus a mutation check.
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
$build = 'pnpm --filter @codai/common ' + 'typecheck'

$r = Hook $Guard $build
$reason = if ($r.json) { "$($r.json.hookSpecificOutput.additionalContext)" } else { '' }
if ($aqInstalled) {
  Check 'plain build flagged as a warning (no silent unqueued run)' ($reason -match '^WARNING \(allowed\)' -and $r.raw -notmatch '"deny"') $r.raw
  Check 'warning hands back agentq -Where auto command' ($reason -match [regex]::Escape('run -Resource build -Where auto -Purpose') -and $reason.Contains("-- $build")) $reason
  Check 'no updatedInput emitted' ($r.raw -notmatch 'updatedInput') ''
} else { Write-Host 'SKIP agentq cases (agentq not installed)' }

$env:AGENTQ_WHERE = 'local'
$r = Hook $Guard $build
Remove-Item Env:AGENTQ_WHERE
Check 'AGENTQ_WHERE=local -> run-build message' ($r.raw -match 'WARNING \(allowed\)' -and $r.raw -match 'run-build' -and $r.raw -notmatch 'Where auto') $r.raw

$r = Hook $Guard 'pnpm build; Remove-Item x'
Check 'compound command keeps run-build message' ($r.raw -match 'WARNING \(allowed\)' -and $r.raw -match 'run-build' -and $r.raw -notmatch 'Where auto') $r.raw
$r = Hook $Guard 'pnpm build' -NoVsCode
Check 'non-VS Code harness: soft block allowed (exit 0)' ($r.code -eq 0) "code=$($r.code)"
$r = Hook $Guard 'git push --force origin main' -NoVsCode
Check 'non-VS Code harness: hard block still exit 2' ($r.code -eq 2) "code=$($r.code)"
$r = Hook $Guard 'pwsh -NoProfile -File C:\x\agentq.ps1 run -Resource build -Where auto -Purpose p -- pnpm build'
Check 'agentq wrapper passes untouched' (-not $r.raw) $r.raw
$r = Hook $Guard 'git status'
Check 'non-build passes untouched' (-not $r.raw) $r.raw

# Owner decision 2026-10-19: irreversible data deletes stay HARD blocks under D-40 (strings split so
# this file does not trip the guard when it is edited or run).
$hardCases = @(('DROP ' + 'TABLE users;'), ('TRUN' + 'CATE orders;'), ('TRUNCATE ' + 'TABLE a, b;'), ('DELETE ' + 'FROM users;'),
  ('gsutil ' + '-m rm -r gs://prod/x'), ('gcloud storage ' + 'rm gs://b/o'), ('gcloud storage ' + 'buckets delete gs://b'))
foreach ($c in $hardCases) { $r = Hook $Guard $c; Check "hard block: $c" ($r.raw -match '"permissionDecision":"deny"' -and $r.raw -match 'HARD block') $r.raw }
$softOk = @(('DELETE ' + 'FROM users WHERE id = 1;'), 'rg -n truncate src', 'gsutil ls gs://b', 'gcloud storage cp a gs://b/a', 'git log --oneline -3')
foreach ($c in $softOk) { $r = Hook $Guard $c; Check "not blocked: $c" ($r.raw -notmatch '"deny"') $r.raw }

if ($aqInstalled) {
  $m = Join-Path $env:TEMP ('gc-mut-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
  $src = [IO.File]::ReadAllText($Guard)
  $mut = $src.Replace("`$env:AGENTQ_WHERE -ne 'local' -and", "`$false -and")
  Check 'mutation applied' ($mut -ne $src) ''
  [IO.File]::WriteAllText($m, $mut, [Text.UTF8Encoding]::new($true))
  $r = Hook $m $build
  Check 'mutation: without the branch the agentq command is gone' ($r.raw -notmatch 'Where auto') $r.raw
  Remove-Item $m -Force -ErrorAction SilentlyContinue
}
if ($fails) { Write-Host "$fails FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
