# Shared-clone write advisory: fires for source in E:\gh\<repo>, never blocks, silent for slots/docs/scratch.
param([string]$Guard = (Join-Path $PSScriptRoot '..\hooks\guard-tooluse.ps1'))
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('gsc-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory "$root\repo\.git", "$root\repo\src", "$root\.wt\repo\task-1\src" -Force | Out-Null
$env:CODAI_GH_ROOT = $root; $env:CODAI_WT_ROOT = "$root\.wt"; $env:AGENTQ_HOME = "$root\coord"
$fail = 0
function Ok([bool]$c, [string]$m) { if ($c) { "PASS $m" } else { "FAIL $m"; $script:fail++ } }
function Call([string]$tool, $ti) {
  $j = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = $ti } | ConvertTo-Json -Compress -Depth 5
  $out = $j | & pwsh -NoProfile -File $Guard 2>$null
  [pscustomobject]@{ code = $LASTEXITCODE; out = ($out -join "`n") }
}
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.code -eq 0) 'shared source: allowed (exit 0)'; Ok ($r.out -match 'additionalContext' -and $r.out -match 'SHARED clone') 'shared source: advisory'
Ok ($r.out -notmatch '"deny"') 'shared source: not denied'
$r = Call 'apply_patch' @{ input = "*** Begin Patch`n*** Update File: $root\repo\src\b.ts`n@@`n-a`n+b`n*** End Patch"; explanation = 'x' }
Ok ($r.out -match 'SHARED clone') 'apply_patch path parsed'
$r = Call 'replace_string_in_file' @{ filePath = "$root\.wt\repo\task-1\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.code -eq 0 -and $r.out -notmatch 'SHARED clone') 'slot: silent'
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\docs\x.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch 'SHARED clone') 'docs/: silent'
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\README.md"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch 'SHARED clone') 'markdown: silent'
$r = Call 'create_file' @{ filePath = "$root\repo\.copilot-tmp\s.ps1"; content = 'x' }
Ok ($r.out -notmatch 'SHARED clone') 'scratch: silent'
$env:CODAI_SHARED_CLONE_WRITE_OK = '1'
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch 'SHARED clone') 'opt-out env: silent'
Remove-Item Env:CODAI_SHARED_CLONE_WRITE_OK
# ADR 0004 (W4-1): journal line in warn mode, deny in refuse mode, per-repo override, opt-out journaled.
$jf = Join-Path $env:AGENTQ_HOME 'journal.jsonl'
New-Item -ItemType Directory -Force $env:AGENTQ_HOME | Out-Null
$cfg = Join-Path $root 'cfg.json'; $env:AGENTQ_CONFIG = $cfg
function Lines { if (Test-Path $jf) { @(Get-Content $jf | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq 'shared-write') } else { @() } }
'{"sharedCloneMode":"warn"}' | Set-Content $cfg
$n0 = (Lines).Count
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
$l = Lines
Ok ($r.out -notmatch '"deny"' -and $l.Count -eq $n0 + 1 -and $l[-1].mode -eq 'warn' -and $l[-1].repo -eq 'repo' -and "$($l[-1].paths)" -eq 'src/a.ts') 'warn: allowed + shared-write journaled'
'{"sharedCloneMode":"refuse"}' | Set-Content $cfg
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -match '"deny"' -and $r.out -match 'ADR 0004') 'refuse: denied with the lease recipe'
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\docs\x.md"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch '"deny"') 'refuse: docs/markdown still writable'
$r = Call 'replace_string_in_file' @{ filePath = "$root\.wt\repo\task-1\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch '"deny"') 'refuse: slot writable'
$env:CODAI_SHARED_CLONE_WRITE_OK = '1'
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch '"deny"' -and (Lines)[-1].override -eq $true) 'refuse + opt-out env: allowed, journaled as override'
Remove-Item Env:CODAI_SHARED_CLONE_WRITE_OK
'{"sharedCloneMode":"refuse","sharedCloneModeRepos":{"repo":"warn"}}' | Set-Content $cfg
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch '"deny"' -and $r.out -match 'SHARED clone') 'per-repo warn beats global refuse'
'{"sharedCloneModeRepos":{"repo":"off"}}' | Set-Content $cfg
$n1 = (Lines).Count
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch 'SHARED clone' -and (Lines).Count -eq $n1) 'off: silent, not journaled'
Remove-Item Env:AGENTQ_CONFIG
Remove-Item -Recurse -Force $root
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
