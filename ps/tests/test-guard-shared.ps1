# Shared-clone writes: advisory in warn mode, HARD deny in refuse mode (ADR 0004 §4, wired 2026-11-18 -
# the D-40 soft path had silently turned the documented deny into a warning), silent for slots/docs/scratch.
# 2026-11-22: two NEW warnings (never denials) for the paths that actually wedge a shared clone - a raw
# `git commit` typed into a shell (Rule A) and a plan/*.csv written in place (Rule B). D-40 keeps only
# force-push, reset --hard, clean -f and worktree remove --force hard, and agentq itself still refuses
# `commit`/`land` in a refuse clone, so the enforcement is not lost by warning here.
param([string]$Guard = (Join-Path $PSScriptRoot '..\hooks\guard-tooluse.ps1'))
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('gsc-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
# Rule A resolves the repo with `git rev-parse`, so `repo` must be a REAL main worktree and the slot a
# REAL linked worktree - a bare `.git` folder is not a worktree. The slot is created by git itself,
# because `git worktree add` refuses a directory that already has anything in it.
New-Item -ItemType Directory "$root\repo\src", "$root\other\.git", "$root\other\src" -Force | Out-Null
Push-Location "$root\repo"
try {
  git init -q .
  git -c user.email=t@t -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m init
  git worktree add -q -b task-1 "$root\.wt\repo\task-1"
} finally { Pop-Location }
New-Item -ItemType Directory "$root\.wt\repo\task-1\src" -Force | Out-Null
$env:CODAI_GH_ROOT = $root; $env:CODAI_WT_ROOT = "$root\.wt"; $env:AGENTQ_HOME = "$root\coord"
# A persisted (User/Machine scope) CODAI_SHARED_CLONE_WRITE_OK is inherited by every process, so it
# used to disarm the shared-clone advisory and the codai/brivio `refuse` deny for EVERY agent on the
# machine (2026-11-20: HKCU:\Environment held '1'). The guard now reports it and ignores it - which
# means the two assertions that exercise the DELIBERATE one-off cannot be tested honestly on such a
# machine. They are skipped with this named reason instead of failing with two mysteries.
$scPersisted = "$([Environment]::GetEnvironmentVariable('CODAI_SHARED_CLONE_WRITE_OK','User'))$([Environment]::GetEnvironmentVariable('CODAI_SHARED_CLONE_WRITE_OK','Machine'))"
if ($scPersisted) {
  "WARN CODAI_SHARED_CLONE_WRITE_OK is set PERSISTENTLY (value '$scPersisted'): the guard ignores it, and the 2 one-off assertions below are SKIPPED."
  "     Until it is cleared, no agent can use the one-off on this machine. Clear it: [Environment]::SetEnvironmentVariable('CODAI_SHARED_CLONE_WRITE_OK', `$null, 'User')"
}
$fail = 0
function Ok([bool]$c, [string]$m) { if ($c) { "PASS $m" } else { "FAIL $m"; $script:fail++ } }
function Call([string]$tool, $ti, [string]$Exe = 'pwsh') {
  $j = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = $ti } | ConvertTo-Json -Compress -Depth 5
  $out = $j | & $Exe -NoProfile -ExecutionPolicy Bypass -File $Guard 2>$null
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
if ($scPersisted) { "SKIP opt-out env: silent (a persisted override is present - see WARN)" } else { Ok ($r.out -notmatch 'SHARED clone') 'opt-out env: silent' }
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
# 2026-11-18: refuse denies. The soft path let 710 journaled shared-write events through for codai
# between 11-12 and 11-18, which is exactly why the shared clone kept drifting.
Ok ($r.out -match '"permissionDecision":"deny"' -and $r.out -match 'ADR 0004') 'refuse: denied (ADR 0004 recipe in the reason)'
Ok ($r.out -notmatch 'WARNING \(allowed\)') 'refuse: no longer downgraded to a warning'
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y'; explanation = 'axiom-override: I want to edit the shared clone anyway' }
Ok ($r.out -match '"permissionDecision":"deny"') 'refuse: an axiom-override does NOT lift a hard refusal'
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\docs\x.md"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch '"deny"') 'refuse: docs/markdown still writable'
$r = Call 'replace_string_in_file' @{ filePath = "$root\.wt\repo\task-1\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch '"deny"') 'refuse: slot writable'
$env:CODAI_SHARED_CLONE_WRITE_OK = '1'
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
if ($scPersisted) { "SKIP refuse + opt-out env: allowed, journaled as override (persisted override present)" } else { Ok ($r.out -notmatch '"deny"' -and (Lines)[-1].override -eq $true) 'refuse + opt-out env: allowed, journaled as override' }
Remove-Item Env:CODAI_SHARED_CLONE_WRITE_OK
'{"sharedCloneMode":"refuse","sharedCloneModeRepos":{"repo":"warn"}}' | Set-Content $cfg
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch '"deny"' -and $r.out -match 'SHARED clone') 'per-repo warn beats global refuse'
# ADR 0009 stage 0 (OQ-008): refuse only for the repos that have slots; every other repo keeps the advisory.
'{"sharedCloneMode":"warn","sharedCloneModeRepos":{"repo":"refuse"}}' | Set-Content $cfg
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -match '"permissionDecision":"deny"' -and $r.out -match 'sharedCloneMode=refuse' -and (Lines)[-1].mode -eq 'refuse' -and (Lines)[-1].repo -eq 'repo') 'per-repo refuse: denied, journaled as refuse'
$r = Call 'replace_string_in_file' @{ filePath = "$root\other\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -match 'SHARED clone' -and $r.out -notmatch 'sharedCloneMode=refuse' -and (Lines)[-1].mode -eq 'warn' -and (Lines)[-1].repo -eq 'other') 'per-repo refuse: another repo keeps the advisory'
# The editor starts this hook with Windows PowerShell 5.1. The mode was read with ConvertFrom-Json
# -AsHashtable, which 5.1 does not have: the read failed silently and every repo stayed on "warn".
$ps51 = if ($IsWindows) { (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source } else { $null }
if ($ps51) {
  $r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' } $ps51
  Ok ($r.out -match '"permissionDecision":"deny"' -and $r.out -match 'sharedCloneMode=refuse' -and (Lines)[-1].mode -eq 'refuse') 'per-repo refuse denies under Windows PowerShell 5.1 too'
  $r = Call 'replace_string_in_file' @{ filePath = "$root\other\src\a.ts"; oldString = 'x'; newString = 'y' } $ps51
  Ok ($r.out -match 'SHARED clone' -and (Lines)[-1].mode -eq 'warn') 'Windows PowerShell 5.1: another repo keeps the advisory'
} else { 'PASS (Windows PowerShell 5.1 not on this machine: the 5.1 cases did not run)' }
'{"sharedCloneModeRepos":{"repo":"off"}}' | Set-Content $cfg
$n1 = (Lines).Count
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\src\a.ts"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch 'SHARED clone' -and (Lines).Count -eq $n1) 'off: silent, not journaled'

# 2026-11-18: a `git commit` run from a SHELL in the shared clone of a refuse repo. The edit-tool rule
# above cannot see a command, and this is the path that wedged codai (15 unpushed commits, autosync
# refusing for days). A slot and a non-commit git command stay allowed.
function CallCmd([string]$command) {
  $j = @{ hook_event_name = 'PreToolUse'; tool_name = 'run_in_terminal'; tool_input = @{ command = $command } } | ConvertTo-Json -Compress -Depth 5
  $out = $j | & pwsh -NoProfile -ExecutionPolicy Bypass -File $Guard 2>$null
  [pscustomobject]@{ code = $LASTEXITCODE; out = ($out -join "`n") }
}
'{"sharedCloneModeRepos":{"repo":"refuse"}}' | Set-Content $cfg
# Rule A. Every case passes a pathspec: `git commit` with NO `--` is caught by the older pathspec-less
# rule, which is still a HARD block, and a hard block would exit before Rule A ever printed.
$r = CallCmd "Set-Location $root\repo; git commit -m x -- a.ts"
Ok ($r.code -eq 0 -and $r.out -match 'SHARED clone' -and $r.out -match 'agentq.ps1' -and $r.out -notmatch '"permissionDecision":"deny"') 'shell: a raw commit in the shared clone WARNS (never denies)'
$r = CallCmd "git -C $root\repo commit -m x -- a.ts"
Ok ($r.out -match 'SHARED clone' -and $r.out -notmatch '"deny"') 'shell: git -C <shared clone> commit warns'
$r = CallCmd "Set-Location $root\.wt\repo\task-1; git commit -m x -- a.ts"
Ok ($r.code -eq 0 -and $r.out -notmatch 'SHARED clone') 'shell: a commit in a leased slot is silent'
$r = CallCmd "Set-Location $root\repo; git log --grep commit"
Ok ($r.out -notmatch 'SHARED clone') 'shell: another git command (log) is silent'
$r = CallCmd "Set-Location $root\other; git commit -m x -- a.ts"
Ok ($r.out -notmatch 'SHARED clone') 'shell: a repo that is not refuse is silent'
$env:AGENTQ_SHARED_CLONE_COMMIT_OK = '1'
$r = CallCmd "Set-Location $root\repo; git commit -m x -- a.ts"
Ok ($r.out -notmatch 'SHARED clone') 'shell: the journaled one-off (AGENTQ_SHARED_CLONE_COMMIT_OK) silences it'
Remove-Item Env:AGENTQ_SHARED_CLONE_COMMIT_OK
# Rule B: a plan CSV is exempt from the source-write rule above (tracker rows are edited in place),
# which is exactly why it needs its own rule - those uncommitted rows are what wedged codai for ~4 h.
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\plan\dev-cloud-CANONICAL.csv"; oldString = 'x'; newString = 'y' }
Ok ($r.code -eq 0 -and $r.out -match 'SHARED clone' -and $r.out -match 'dev-cloud-CANONICAL' -and $r.out -notmatch '"deny"') 'plan CSV in the shared clone: warned, not denied'
$r = Call 'create_file' @{ filePath = "$root\repo\notes\plan\b.csv"; content = 'a' }
Ok ($r.out -match 'SHARED clone' -and $r.out -match 'b\.csv') 'nested */plan/*.csv: warned'
$r = Call 'replace_string_in_file' @{ filePath = "$root\.wt\repo\task-1\plan\a.csv"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch 'SHARED clone') 'plan CSV in a leased slot: silent'
$r = Call 'replace_string_in_file' @{ filePath = "$root\repo\plan\notes.md"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch 'SHARED clone') 'a non-CSV under plan/: silent'
$r = Call 'replace_string_in_file' @{ filePath = "$root\other\plan\a.csv"; oldString = 'x'; newString = 'y' }
Ok ($r.out -notmatch 'SHARED clone') 'plan CSV outside a shared clone: silent'

# 2026-11-25 (owner-ticked I1): a MULTI-FILE call is judged as a WHOLE. Only the FIRST `*** File:`
# header of a patch used to be read, so a patch whose first hunk was legitimate got source INTO the
# read-only shared clone through its later hunks (measured live: hunks 1-2 in a leased slot, hunk 3
# in E:\gh\codai, verdict = allowed). One refused path now refuses the whole call, and the reason
# names every path, so the reader can see which hunk was the refused one and that the others were
# not written either. The `repo` fixture here is refuse-mode and does have a slot.
$mix = "*** Begin Patch`n*** Update File: $root\.wt\repo\task-1\src\ok.ts`n@@`n-a`n+b`n*** Update File: $root\repo\src\bad.ts`n@@`n-a`n+b`n*** End Patch"
$r = Call 'apply_patch' @{ input = $mix; explanation = 'x' }
# The verdict is read as JSON, so a Windows separator arrives as `\\` in the text: match the ESCAPED
# form (4 backslashes in a single-quoted pattern = 2 literal ones). The first version of these
# assertions looked for `src\bad.ts` and failed against a guard that was behaving correctly.
Ok ($r.out -match '"permissionDecision":"deny"' -and $r.out -match 'src\\\\bad\.ts') 'multi-file patch: a shared-clone hunk refuses the WHOLE call'
Ok ($r.out -match 'task-1\\\\src\\\\ok\.ts') 'multi-file patch: the refusal names every path, the slot hunk included'
$bothSlot = "*** Begin Patch`n*** Update File: $root\.wt\repo\task-1\src\a.ts`n@@`n-a`n+b`n*** Update File: $root\.wt\repo\task-1\src\b.ts`n@@`n-a`n+b`n*** End Patch"
$r = Call 'apply_patch' @{ input = $bothSlot; explanation = 'x' }
Ok ($r.code -eq 0 -and $r.out -notmatch '"deny"') 'multi-file patch wholly inside the slot: allowed'
$bothShared = "*** Begin Patch`n*** Update File: $root\repo\src\a.ts`n@@`n-a`n+b`n*** Update File: $root\repo\src\b.ts`n@@`n-a`n+b`n*** End Patch"
$r = Call 'apply_patch' @{ input = $bothShared; explanation = 'x' }
Ok ($r.out -match '"permissionDecision":"deny"' -and $r.out -match 'src\\\\a\.ts' -and $r.out -match 'src\\\\b\.ts') 'multi-file patch wholly in the shared clone: denied, both paths named'
Remove-Item Env:AGENTQ_CONFIG
Remove-Item -Recurse -Force $root
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
