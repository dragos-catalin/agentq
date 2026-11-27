# Pins the SPAWN SHAPE of a lease (perf, 2026-11-27): the re-lease hot path must decide worktree
# registration with ZERO git spawns and resolve the repo with ONE combined rev-parse. A `git.cmd` shim
# prepended to PATH records every git invocation, so the assertion is the SHAPE of the calls (which
# command, with which directives) rather than a fragile count that drifts with config and paths.
#
# WHY A SHAPE ASSERTION. The optimization (measured 10.33 -> 7.5 git spawns per lease) is invisible to
# every behavioural test: the slot still ends up in the right state, it just gets there with two fewer
# `git` processes on every lease. A regression that reintroduces `git worktree list --porcelain` on the
# reuse path - or splits the repo resolution back into two rev-parse calls - would ship green. This
# suite turns red for exactly those two shapes, plus the third one found on 2026-11-27: a repo-info
# OBJECT handed to `-C` (`-C "@{Top=...}"`), which git rejects and which made the caller degrade in
# silence because `$repo` and `$Repo` are one variable at script scope.
#
# MUTATION CONTROL. The second arm copies ps\bin and rewrites the combined rev-parse directive back to a
# single-directive call, then asserts the SAME shape check FAILS on it - so the check is proven to bite
# the regression it names, not to pass because the file happens to contain the string.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$binDir = Split-Path -Parent $Aq
$realGit = (Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $realGit) { Write-Host 'FAIL git.exe not found on PATH'; exit 1 }
# The fixture leaf carries THIS process id so the cleanup below can only ever remove this run's own tree: two
# suites running at once share one `%TEMP%`, and a pattern-based guard would let either delete the other's
# live fixture mid-run.
$script:fixHex = [guid]::NewGuid().ToString('N').Substring(0, 6)
$tmp = Join-Path ([IO.Path]::GetTempPath()) "aqspawn-$PID-$script:fixHex"
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_NO_REGISTRY = '1'
$env:AGENTQ_SESSION = 'test-spawn'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseIdleMin":45,"minFreeCommitGB":0}' | Set-Content (Join-Path $tmp 'cfg.json')
$env:AGENTQ_CONFIG = Join-Path $tmp 'cfg.json'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ([string]$exe) { $o = @(& pwsh -NoProfile -File $exe @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }

# --- fixture: a bare repo as origin, a working clone, one commit -------------------------------
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
& git init -q --bare -b dev $bare
& git init -q -b dev $repo
& git -C $repo config user.email t@t; & git -C $repo config user.name t
Set-Content (Join-Path $repo 'a.txt') 'a'; Set-Content (Join-Path $repo 'CHANGELOG.md') "# Changelog`n"
& git -C $repo add a.txt CHANGELOG.md; & git -C $repo commit -qm init
& git -C $repo remote add origin $bare; & git -C $repo push -q -u origin dev 2>$null

# --- the shim: record every git invocation, then forward to the real git ------------------------
$shimDir = Join-Path $tmp 'shim'; New-Item -ItemType Directory -Force $shimDir | Out-Null
$log = Join-Path $tmp 'gitcalls.txt'
$cmd = Join-Path $shimDir 'git.cmd'
@"
@echo off
>>"$log" echo %*
"$realGit" %*
exit /b %ERRORLEVEL%
"@ | Set-Content -LiteralPath $cmd -Encoding ascii
$env:PATH = $shimDir + ';' + $env:PATH

function Measure-LeaseShape([string]$exe, [string]$purpose) {
  Set-Content -LiteralPath $log -Value ''
  $o = AQ $exe lease -Slot scratch-1 -Purpose $purpose -Json
  return @{ code = $script:code; out = $o; calls = @(Get-Content -LiteralPath $log -ErrorAction SilentlyContinue) }
}
function Test-CombinedRepoInfo([string[]]$calls) {
  return @($calls | Where-Object { $_ -match 'rev-parse' -and $_ -match '--show-toplevel' -and $_ -match '--git-common-dir' }).Count -eq 1
}
function Test-NoSplitRepoInfo([string[]]$calls) {
  return @($calls | Where-Object { $_ -match 'rev-parse' -and $_ -match '--show-toplevel' -and $_ -notmatch '--git-common-dir' }).Count -eq 0
}
function Test-NoObjectRepoInfo([string[]]$calls) {
  return @($calls | Where-Object { $_ -match '-C "@\{' }).Count -eq 0
}
function Test-NoWorktreeList([string[]]$calls) { return -not (@($calls | Where-Object { $_ -match 'worktree list' }).Count) }
function Test-NoWorktreePrune([string[]]$calls) { return -not (@($calls | Where-Object { $_ -match 'worktree prune' }).Count) }

$fresh = @{ code = 1; out = ''; calls = @() }; $reuse = @{ code = 1; out = ''; calls = @() }; $mut = @{ code = 1; out = ''; calls = @() }
Push-Location $repo
try {
  # --- 1. FRESH lease: the slot does not exist yet, so `worktree add` runs (prune is allowed here) -
  $fresh = Measure-LeaseShape $Aq 'fresh'
  $l1 = $fresh.out | Select-Object -Last 1 | ConvertFrom-Json
  Check 'fresh lease succeeds' ($fresh.code -eq 0 -and (Test-Path (Join-Path $l1.path 'a.txt'))) $fresh.out
  Check 'fresh lease never runs `worktree list --porcelain`' (Test-NoWorktreeList $fresh.calls) ($fresh.calls -join ' | ')
  Check 'fresh lease never hands a repo-info object to -C' (Test-NoObjectRepoInfo $fresh.calls) ($fresh.calls -join ' | ')

  # --- 2. RE-LEASE of the same slot: the reuse hot path this optimization covers ------------------
  $reuse = Measure-LeaseShape $Aq 'reuse'
  Check 're-lease succeeds' ($reuse.code -eq 0) $reuse.out
  Check 're-lease decides registration with ZERO git spawns (no `worktree list`, no `worktree prune`)' ((Test-NoWorktreeList $reuse.calls) -and (Test-NoWorktreePrune $reuse.calls)) ($reuse.calls -join ' | ')
  Check 're-lease resolves the repo with ONE combined rev-parse' (Test-CombinedRepoInfo $reuse.calls) ($reuse.calls -join ' | ')
  Check 're-lease never hands a repo-info object to -C' (Test-NoObjectRepoInfo $reuse.calls) ($reuse.calls -join ' | ')
  Check 're-lease does NOT split the repo resolution back into two spawns' (Test-NoSplitRepoInfo $reuse.calls) ($reuse.calls -join ' | ')

  # --- 3. MUTATION CONTROL: rewrite the combined rev-parse back to a single-directive call and
  #        assert the SAME shape check goes red, so it is proven to bite rather than to pass by luck. -
  $mutBin = Join-Path $tmp 'mutbin'; New-Item -ItemType Directory -Force $mutBin | Out-Null
  Copy-Item (Join-Path $binDir '*') $mutBin -Recurse -Force
  $mutFile = Join-Path $mutBin 'agentq.ps1'
  $src = [IO.File]::ReadAllText($mutFile)
  $marker = '--show-toplevel --path-format=absolute --git-common-dir'
  $mutated = $src.Replace($marker, '--show-toplevel')
  Check 'mutation actually rewrote the file (the marker was present)' ($mutated.Length -ne $src.Length) "marker not found in agentq.ps1 - the mutation control cannot run"
  [IO.File]::WriteAllText($mutFile, $mutated, [Text.UTF8Encoding]::new($false))
  $mut = Measure-LeaseShape (Join-Path $mutBin 'agentq.ps1') 'reuse under mutation'
  Check 'mutation control: the mutant DID run a repo resolution (the control is not vacuous)' (@($mut.calls | Where-Object { $_ -match 'rev-parse' -and $_ -match '--show-toplevel' }).Count -ge 1) ($mut.calls -join ' | ')
  Check 'mutation control: the combined-rev-parse shape check DOES fail on the split form' (-not (Test-CombinedRepoInfo $mut.calls)) ($mut.calls -join ' | ')
} finally {
  Pop-Location
  # Clean up after ourselves. A suite that leaves its fixture tree behind is litter for the next agent's
  # sweep - the defect class already fixed twice in codai (`gate:suite-temp-roots`), and `%TEMP%` is one of
  # the two roots a nightly reaper sweeps. Guarded rather than unconditional: `Remove-Item -Recurse` on a
  # mistyped or empty $tmp deletes something real, so refuse unless the leaf is the exact one this run minted -
  # an equality against a string built from our own pid, NOT a pattern, because `-match` and `-like` ignore
  # case and would also accept a foreign leaf (measured 2026-11-27: `aqspawn-ABCDEF` passed a `[0-9a-f]{6}`
  # regex). A killed suite skips this block, which is exactly how the 122 empty directories in that codai wave
  # were born - the guard bounds the damage, it does not make the suite unkillable.
  if ((Split-Path -Leaf $tmp) -ceq "aqspawn-$PID-$script:fixHex") {
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
  }
}

Write-Host ("lease spawns: fresh={0} reuse={1} mutant={2}" -f $fresh.calls.Count, $reuse.calls.Count, $mut.calls.Count)
if ($fail) { Write-Host "test-lease-spawns FAIL $fail"; exit 1 } else { Write-Host 'test-lease-spawns PASS (11)'; exit 0 }
