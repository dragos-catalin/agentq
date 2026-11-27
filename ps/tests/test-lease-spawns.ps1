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
#
# BOUNDED CHILDREN. Every child this suite starts is waited for with a bound (`$script:childBoundSec`): a
# wedge - `git` blocked on a lock, an interactive credential prompt, a resolver that never returns - used to
# hang the whole run AND leave the `%TEMP%\aqspawn-*` fixture behind, because the `finally` cleanup below only
# runs once the child returns. The bound is on the CHILD, never on the assertions.
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
# How long one child may take before it is killed and counted as a failure. The whole suite's honest worst
# case is ~10 s (measured 8-9 s here) and a single lease child 1-3 s even on a loaded machine, so 180 s is
# ~60x generous: a slow box still passes, only a WEDGE trips it. 3 x 180 s = 540 s also stays inside the
# devcloud pool gate's 1044 s budget (the figure at the `-Wait` note in agentq-v2.ps1), so a wedged child is
# reported as a red suite rather than the gate being killed with the fixture orphaned behind it.
# `$env:AGENTQ_TEST_CHILD_BOUND_SEC` overrides it, which is how the bound itself is proven (never in CI).
$script:childBoundSec = if ($env:AGENTQ_TEST_CHILD_BOUND_SEC) { [int]$env:AGENTQ_TEST_CHILD_BOUND_SEC } else { 180 }
function AQ([string]$exe) {
  $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $outF = Join-Path $tmp "aq-out-$tag.txt"; $errF = Join-Path $tmp "aq-err-$tag.txt"
  # Start-Process takes a command LINE, not an argv array, so a value containing a space must be quoted here or
  # the child receives it as TWO arguments (the mutation arm passes `-Purpose 'reuse under mutation'`). A value
  # containing a double quote is refused loudly rather than mangled into a different command.
  $line = foreach ($a in (@('-NoProfile', '-File', $exe) + @($args))) {
    $s = "$a"
    if ($s.IndexOf('"') -ge 0) { throw "AQ: refusing an argument containing a double quote (Start-Process cannot quote it portably): $s" }
    if ($s.IndexOf(' ') -ge 0) { '"' + $s + '"' } else { $s }
  }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath 'pwsh' -ArgumentList ($line -join ' ') -NoNewWindow -PassThru -RedirectStandardOutput $outF -RedirectStandardError $errF
  if (-not $p.WaitForExit($script:childBoundSec * 1000)) {
    try { $p.Kill($true) } catch {}
    $p.WaitForExit(5000) | Out-Null
    $sw.Stop()
    $so = @(Get-Content -LiteralPath $outF -ErrorAction SilentlyContinue); $se = @(Get-Content -LiteralPath $errF -ErrorAction SilentlyContinue)
    Write-Host ("FAIL AQ child exceeded the {0}s bound and was KILLED - it hung instead of returning (the bound doing its job, not a lease failure)" -f $script:childBoundSec) -ForegroundColor Red
    Write-Host "     cmd:     pwsh $($line -join ' ')"
    Write-Host ("     elapsed: {0:0.0}s (bound {1}s)" -f $sw.Elapsed.TotalSeconds, $script:childBoundSec)
    Write-Host "     --- stdout ---"; $so | ForEach-Object { Write-Host "     $_" }
    Write-Host "     --- stderr ---"; $se | ForEach-Object { Write-Host "     $_" }
    $script:code = 124
    $script:fail++
    return (@($se) + @($so)) -join "`n"
  }
  $sw.Stop()
  $p.WaitForExit(5000) | Out-Null
  $script:code = $p.ExitCode
  # stderr BEFORE stdout. Every caller takes `Select-Object -Last 1` as the JSON payload; git writes its
  # warnings ("LF will be replaced by CRLF") to stderr and the payload to stdout, and the old `2>&1` merge
  # happened to put the warning first. Concatenating stdout last keeps that contract.
  return (@(Get-Content -LiteralPath $errF -ErrorAction SilentlyContinue) + @(Get-Content -LiteralPath $outF -ErrorAction SilentlyContinue)) -join "`n"
}

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
# `ConvertFrom-Json`'s failure is STATEMENT-TERMINATING in PowerShell 7, so neither `-ErrorAction
# SilentlyContinue` nor a null check keeps it from aborting the whole suite when a child died (measured
# 2026-11-27: a killed child's non-JSON output ended the run at check 1 instead of reporting all of them).
# try/catch is the only form that holds.
function Convert-FromJsonOrNull([string]$text) { try { return ($text | ConvertFrom-Json) } catch { return $null } }
# The lease result's `head` must come out of the process that resolved the repo: it used to cost a second
# `rev-parse --short HEAD`, and the only way to drop that spawn is for the combined repo-info call to carry
# the directive. Two conditions, because there are two ways to regress - zero fused calls (un-fused again) and
# two calls carrying `--short HEAD` (the separate spawn back). Shape only, so it holds whatever the sha is.
function Test-HeadFusedIntoRepoInfo([string[]]$calls) {
  return (@($calls | Where-Object { $_ -match '--short HEAD' -and $_ -match '--show-toplevel' -and $_ -match '--git-common-dir' }).Count -eq 1) -and
         (@($calls | Where-Object { $_ -match '--short HEAD' }).Count -eq 1)
}

$fresh = @{ code = 1; out = ''; calls = @() }; $reuse = @{ code = 1; out = ''; calls = @() }; $mut = @{ code = 1; out = ''; calls = @() }
Push-Location $repo
try {
  # --- 1. FRESH lease: the slot does not exist yet, so `worktree add` runs (prune is allowed here) -
  $fresh = Measure-LeaseShape $Aq 'fresh'
  # Tolerant parse: a child that was killed (or exited non-zero) prints no JSON, and a hard parse failure here
  # would abort the suite before it printed its verdict - the failure would be reported as a crash, not a check.
  $l1 = Convert-FromJsonOrNull ($fresh.out | Select-Object -Last 1)
  Check 'fresh lease succeeds' ($fresh.code -eq 0 -and $null -ne $l1 -and (Test-Path (Join-Path $l1.path 'a.txt'))) $fresh.out
  Check 'fresh lease never runs `worktree list --porcelain`' (Test-NoWorktreeList $fresh.calls) ($fresh.calls -join ' | ')
  Check 'fresh lease never hands a repo-info object to -C' (Test-NoObjectRepoInfo $fresh.calls) ($fresh.calls -join ' | ')
  Check 'fresh lease resolves the short HEAD with the repo-info spawn, not a second one' (Test-HeadFusedIntoRepoInfo $fresh.calls) ($fresh.calls -join ' | ')

  # --- 2. RE-LEASE of the same slot: the reuse hot path this optimization covers ------------------
  $reuse = Measure-LeaseShape $Aq 'reuse'
  Check 're-lease succeeds' ($reuse.code -eq 0) $reuse.out
  Check 're-lease decides registration with ZERO git spawns (no `worktree list`, no `worktree prune`)' ((Test-NoWorktreeList $reuse.calls) -and (Test-NoWorktreePrune $reuse.calls)) ($reuse.calls -join ' | ')
  Check 're-lease resolves the repo with ONE combined rev-parse' (Test-CombinedRepoInfo $reuse.calls) ($reuse.calls -join ' | ')
  Check 're-lease never hands a repo-info object to -C' (Test-NoObjectRepoInfo $reuse.calls) ($reuse.calls -join ' | ')
  Check 're-lease does NOT split the repo resolution back into two spawns' (Test-NoSplitRepoInfo $reuse.calls) ($reuse.calls -join ' | ')
  Check 're-lease resolves the short HEAD with the repo-info spawn, not a second one' (Test-HeadFusedIntoRepoInfo $reuse.calls) ($reuse.calls -join ' | ')

  # --- 3. MUTATION CONTROL: rewrite the combined rev-parse back to a single-directive call and
  #        assert the SAME shape check goes red, so it is proven to bite rather than to pass by luck. -
  $mutBin = Join-Path $tmp 'mutbin'; New-Item -ItemType Directory -Force $mutBin | Out-Null
  Copy-Item (Join-Path $binDir '*') $mutBin -Recurse -Force
  $mutFile = Join-Path $mutBin 'agentq.ps1'
  $src = [IO.File]::ReadAllText($mutFile)
  $marker = '--show-toplevel --path-format=absolute --git-common-dir'
  # Two regressions, one mutant: the repo resolution is split back into a single-directive call AND the short
  # HEAD is un-fused (a directive the old code gave to its own spawn), so one mutant proves both shape checks bite.
  $mutated = $src.Replace('--git-common-dir --short HEAD', '--git-common-dir').Replace($marker, '--show-toplevel')
  Check 'mutation actually rewrote the file (the marker was present)' ($mutated.Length -ne $src.Length) "marker not found in agentq.ps1 - the mutation control cannot run"
  [IO.File]::WriteAllText($mutFile, $mutated, [Text.UTF8Encoding]::new($false))
  $mut = Measure-LeaseShape (Join-Path $mutBin 'agentq.ps1') 'reuse under mutation'
  Check 'mutation control: the mutant DID run a repo resolution (the control is not vacuous)' (@($mut.calls | Where-Object { $_ -match 'rev-parse' -and $_ -match '--show-toplevel' }).Count -ge 1) ($mut.calls -join ' | ')
  Check 'mutation control: the combined-rev-parse shape check DOES fail on the split form' (-not (Test-CombinedRepoInfo $mut.calls)) ($mut.calls -join ' | ')
  Check 'mutation control: the short-HEAD fuse check DOES fail on the un-fused form' (-not (Test-HeadFusedIntoRepoInfo $mut.calls)) ($mut.calls -join ' | ')
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
    # Retried: on Windows the removal can lose a race against a just-killed child's still-closing handles (and
    # git's pack files are read-only). The assertion after this block is what turns a silent failure into red.
    for ($i = 0; $i -lt 3 -and (Test-Path -LiteralPath $tmp); $i++) {
      try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch {}
      if (Test-Path -LiteralPath $tmp) { Start-Sleep -Milliseconds 250 }
    }
  }
}

# A killed child (or any wedge) must leave nothing behind: `%TEMP%` is one of the two roots the nightly reaper
# sweeps, and an unattributable `aqspawn-*` tree reads as litter to the next agent. Assertion for the bound above.
Check 'the fixture tree is gone (this run left no %TEMP%\aqspawn-* behind)' (-not (Test-Path -LiteralPath $tmp)) $tmp

Write-Host ("lease spawns: fresh={0} reuse={1} mutant={2}" -f $fresh.calls.Count, $reuse.calls.Count, $mut.calls.Count)
if ($fail) { Write-Host "test-lease-spawns FAIL $fail"; exit 1 } else { Write-Host 'test-lease-spawns PASS (15)'; exit 0 }
