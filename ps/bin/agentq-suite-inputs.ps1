# agentq-suite-inputs.ps1 - decide which gate SUITES a change must run, from each suite's declared
# input globs.
#
# WHY. `run-all.ps1 -RepoSuites` runs every suite in `gateSuites.<repo>` - 35 for agentq, which
# `ps/devcloud/gate.ps1` was measured running at 2160 s (36 min) of CPU (2026-11-25). Most changes
# touch a handful of those suites. The pre-push hook's PROVEN approach
# (`git diff --name-only "$base"...HEAD -- <globs>`; run the lane only when it is non-empty) is applied
# here once PER SUITE: a suite whose declared inputs did not change is SKIPPED, everything else runs.
#
# ONE GIT CALL. Rather than one `git diff` per suite (105 calls for agentq, each blocked for ~100 s
# during a sibling's heavy git operation - measured 2026-11-26), the changed paths are read ONCE
# (`Select-AqSuites` -> `Get-AqChangedPaths`) and each suite's globs are matched against that list in
# process. That makes the selection ~1 git call and immune to a git stall.
#
# FAIL-OPEN, ALWAYS TOWARD RUNNING. A decision is `skip` ONLY when it has been PROVEN:
#   - the suite is named in the map below (an unknown suite -> run),
#   - the map entry has at least one non-empty glob (none -> run),
#   - every one of its globs is a form this script can turn into a matcher (git pathspec MAGIC such as
#     `:(...)` is NOT, so it -> run),
#   - the range diff itself succeeded (a missing base, an unreadable commit or ANY git error -> run).
# Every other outcome is `run` or `force-run`. A wrong, stale or unreadable map therefore degrades
# toward running MORE suites, never toward skipping one that should have run. The one hazard a map
# cannot make safe - globs that OMIT a file a suite really depends on - is mitigated by (a) deliberately
# BROAD globs, (b) the GLOBAL widening set below (a change to the runner, the suite list, the installer
# or this module runs EVERYTHING), and (c) `run-all.ps1` itself never treating "nothing ran" as a pass.
#
# Dot-source this file for the selection functions:
#     . ps/bin/agentq-suite-inputs.ps1
#     Select-AqSuites -Suites <names> -Base <sha> -Head HEAD -RepoRoot <dir>
#
# The pool entry point (`-RunPool`) exists because a devcloud job carries NO environment: agentq submits
# argv tokens only, so an env var set by the caller cannot reach the workspace. gate.ps1 therefore hands
# the SKIP list in argv; this script exports it as `AGENTQ_TEST_SKIP` (run-all.ps1's documented override,
# merged into its `-Skip`) and then runs the UNCHANGED pool half (`ps/devcloud/pool-suites.ps1 -RepoKey
# <key>`), so the suite list is STILL resolved on the checkout under test and a missing key still fails
# loudly there. The child processes inherit the exported variable.
[CmdletBinding()]
param(
    # Pool entry point: export the skip list, then run ps/devcloud/pool-suites.ps1 and exit with its code.
    [switch]$RunPool,
    # Comma-separated suite names to SKIP (only used with -RunPool).
    [string]$Skip = '',
    # Repo key passed through to pool-suites.ps1 (named, never derived - see pool-suites.ps1's header).
    [string]$SuiteRepoKey = 'agentq',
    # Parallelism passed through to pool-suites.ps1.
    [int]$PoolParallel = 4
)

# --- the declared input map ------------------------------------------------------------------------
# suite name -> repo-relative globs (forward slashes). A suite NOT named here always RUNS. Prefer a
# directory over a single filename when unsure: a glob that is too narrow is the one mistake that could
# skip a suite that should have run.
$script:AqSuiteInputMap = [ordered]@{
    # --- the engine, which most suites drive through bin/agentq.ps1 -> bin/agentq-v2.ps1 ------------
    'agentq v1'               = @('ps/bin/**', 'ps/tests/test-agentq.ps1')
    'agentq v2'               = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/bin/agentq-jobs-lib.ps1', 'ps/tests/test-agentq-v2.ps1')
    'agentq v3'               = @('ps/bin/**', 'ps/tests/test-agentq-v3.ps1')
    'args'                    = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-agentq-args.ps1')
    'help'                    = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-agentq-help.ps1')
    'status readonly'         = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-status-readonly.ps1')
    'slot budget'             = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-slot-budget.ps1')
    'agentq slot share'       = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-agentq-slotshare.ps1')
    'lease liveness'          = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/bin/agentq-jobs-lib.ps1', 'ps/tests/test-agentq-lease-liveness.ps1')
    'prewarm verb'            = @('ps/bin/**', 'ps/tests/test-agentq-prewarm-verb.ps1')
    'prewarm cloud'           = @('ps/bin/prewarm-cloud.ps1', 'ps/bin/agentq-cloud.ps1', 'ps/tests/test-prewarm-cloud.ps1')
    'shared janitor'          = @('ps/bin/shared-clone-janitor.ps1', 'ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-shared-clone-janitor.ps1')

    # --- the guards (hooks/guard-tooluse.ps1 is the shared subject) ---------------------------------
    'guard'                   = @('ps/hooks/guard-tooluse.ps1', 'ps/hooks/lib/**', 'ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-guard-v2.ps1')
    'guard shared'            = @('ps/hooks/guard-tooluse.ps1', 'ps/hooks/lib/**', 'ps/tests/test-guard-shared.ps1')
    'guard cloud'             = @('ps/hooks/guard-tooluse.ps1', 'ps/tests/test-guard-cloud.ps1')
    'guard format'            = @('ps/hooks/guard-tooluse.ps1', 'ps/tests/test-guard-format.ps1')
    'guard forms'             = @('ps/hooks/guard-tooluse.ps1', 'ps/tests/test-guard.ps1')
    'deploy guard'            = @('ps/hooks/guard-tooluse.ps1', 'ps/hooks/deploy-clean.ps1', 'ps/tests/test-deploy-guard.ps1')

    # --- the commit / publish / land path ----------------------------------------------------------
    'shared commit'           = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-agentq-shared-commit.ps1')
    'publish'                 = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-agentq-publish.ps1')
    'land precheck'           = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-land-precheck.ps1')
    'land pregate'            = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/devcloud/**', 'ps/tests/test-land-pregate.ps1')
    'land pregate stale ref'  = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-land-pregate-stale-ref.ps1')
    'land batch'              = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-land-batch.ps1')
    'land default gate'       = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-land-default-gate.ps1')
    'land finalize'           = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-land-finalize.ps1')
    'land flakes'             = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-land-flakes.ps1')
    'land install'            = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-land-install.ps1')
    'land reclaim'            = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-land-reclaim.ps1')
    'post-land hook'          = @('ps/bin/agentq.ps1', 'ps/bin/agentq-v2.ps1', 'ps/tests/test-post-land.ps1')

    # --- autosync ----------------------------------------------------------------------------------
    'autosync wip snapshot'   = @('ps/bin/git-autosync.ps1', 'ps/tests/test-autosync-wip-snapshot.ps1')

    # --- the wiring / installer suites: they read the whole tree or the suite table -----------------
    'install'                 = @('ps/**')
    'script scope'            = @('ps/**', 'ps/tests/test-script-scope.ps1')
    'install wiring'          = @('ps/install.ps1', 'ps/tests/run-all.ps1', 'ps/bin/agentq-config.json', 'ps/tests/test-install-wiring.ps1')
    'land gate pool'          = @('ps/bin/agentq-config.json', 'ps/tests/land-gate-pool.allow.json', 'ps/tests/test-land-gate-pool.ps1', 'ps/devcloud/**', 'ps/bin/agentq-v2.ps1')
}

# --- inputs whose change invalidates the whole map -------------------------------------------------
# A change here can alter WHICH suites exist, HOW they run, or HOW this decision is made, so the only
# safe answer is "run everything". Same idea as the pre-push hook's ROOT_CHANGED widening.
$script:AqGlobalInputGlobs = @(
    'ps/tests/run-all.ps1'                 # the runner and the suite table itself
    'ps/bin/agentq-config.json'            # gateSuites.<repo> - the list being narrowed
    'ps/install.ps1'                       # the installer that consumes the green record
    'ps/devcloud/gate.ps1'                 # the caller
    'ps/devcloud/pool-suites.ps1'          # the pool half the selection is transported to
    'ps/bin/agentq-suite-inputs.ps1'       # this map
)

function Get-AqSuiteInputMap { $script:AqSuiteInputMap }

function Get-AqGlobalInputGlobs { @($script:AqGlobalInputGlobs) }

# Run git and NEVER throw: every caller must treat an error as "cannot prove -> run".
function Invoke-AqGitCapture {
    param([string]$RepoRoot = '.', [string[]]$GitArgs = @())
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -C $RepoRoot @GitArgs 2>$null
        $code = $LASTEXITCODE
        $lines = @(@($out) | ForEach-Object { "$_" } | Where-Object { $_.Trim().Length -gt 0 })
        [pscustomobject]@{ Ok = ($code -eq 0); Lines = $lines }
    } catch {
        [pscustomobject]@{ Ok = $false; Lines = @() }
    } finally { $ErrorActionPreference = $prev }
}

# The changed paths across <Base>...<Head>, in ONE git call. Ok=$false on a missing base, an unreadable
# commit or any git error - the caller must then run every suite.
function Get-AqChangedPaths {
    param([string]$RepoRoot = '.', [string]$Base, [string]$Head = 'HEAD')
    if (-not $Base -or -not "$Base".Trim()) { return [pscustomobject]@{ Ok = $false; Paths = @(); Reason = 'no base commit' } }
    $r = Invoke-AqGitCapture -RepoRoot $RepoRoot -GitArgs @('diff', '--name-only', "$Base...$Head")
    [pscustomobject]@{ Ok = $r.Ok; Paths = $r.Lines; Reason = $(if ($r.Ok) { '' } else { 'git diff failed' }) }
}

# A declared glob -> a regex string, or $null when the glob is a form this script will NOT guess at
# (git pathspec MAGIC such as `:(...)`, or empty). $null means "cannot prove" -> the caller runs.
# Matching is case-INSENSITIVE (PowerShell -match), i.e. a SUPERSET of git's match, which is the safe
# direction; `*` stays within a path segment and `**` crosses segments, as a git pathspec does.
function ConvertFrom-AqGlob {
    param([string]$Glob)
    $g = "$Glob".Trim()
    if (-not $g) { return $null }
    if ($g.StartsWith(':') -or $g.Contains(':(')) { return $null }   # pathspec magic - not modelled
    $g = ($g -replace '\\', '/').TrimStart('./')
    $hasWild = ($g.Contains('*') -or $g.Contains('?'))
    $sb = [Text.StringBuilder]::new()
    [void]$sb.Append('^')
    $i = 0
    while ($i -lt $g.Length) {
        $c = $g[$i]
        if ($c -eq '*') {
            if (($i + 1) -lt $g.Length -and $g[$i + 1] -eq '*') {
                [void]$sb.Append('.*'); $i += 2
                if ($i -lt $g.Length -and $g[$i] -eq '/') { $i++ }      # `**/` matches zero or more dirs
                continue
            }
            [void]$sb.Append('[^/]*'); $i++; continue
        }
        if ($c -eq '?') { [void]$sb.Append('[^/]'); $i++; continue }
        [void]$sb.Append([regex]::Escape("$c")); $i++
    }
    # a glob WITHOUT wildcards also names everything under that path, as a git directory pathspec does
    if (-not $hasWild) { [void]$sb.Append('(/.*)?') }
    [void]$sb.Append('$')
    $sb.ToString()
}

# Does any path in $Paths match any of $Globs?
#   'match'   - provably yes   (run)
#   'none'    - provably no    (skip)
#   'unknown' - an empty list or a glob that cannot be modelled (run)
function Test-AqGlobSetChanged {
    param([string[]]$Globs, [string[]]$Paths)
    $clean = @($Globs | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if (-not $clean.Count) { return 'unknown' }
    foreach ($g in $clean) {
        $rx = ConvertFrom-AqGlob $g
        if ($null -eq $rx) { return 'unknown' }
        foreach ($p in @($Paths)) { if ("$p" -match $rx) { return 'match' } }
    }
    return 'none'
}

# $true = something in $Globs changed across <Base>...<Head>, OR the question could not be answered
# (empty glob list, an unmodellable glob, a git error). Both mean "run the suite" - the fail-open way.
function Test-AqChangeInRange {
    param([string]$RepoRoot = '.', [string]$Base, [string]$Head = 'HEAD', [string[]]$Globs, $ChangedPaths)
    $clean = @($Globs | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    if (-not $clean.Count) { return $true }
    if ($null -eq $ChangedPaths) {
        $cp = Get-AqChangedPaths -RepoRoot $RepoRoot -Base $Base -Head $Head
        if (-not $cp.Ok) { return $true }
        $ChangedPaths = $cp.Paths
    }
    # fail-open: only a PROVABLE no-change is $false; 'unknown' (an unmodellable glob) runs the suite
    return ((Test-AqGlobSetChanged -Globs $clean -Paths $ChangedPaths) -ne 'none')
}

# Decide ONE suite: 'run' | 'skip' | 'force-run'. 'force-run' and 'run' both mean the suite runs;
# 'skip' is the only "do not run" answer and is reached ONLY by a proven no-change.
function Resolve-AqSuiteInputDecision {
    param(
        [Parameter(Mandatory = $true)][string]$Suite,
        [string]$Base,
        [string]$Head = 'HEAD',
        [string]$RepoRoot = '.',
        $Map,
        $ChangedPaths
    )
    if ($null -eq $Map) { $Map = Get-AqSuiteInputMap }

    $verdict = 'force-run'; $reason = ''; $globs = @()

    if (-not $Base -or -not "$Base".Trim()) {
        $reason = 'no base commit given - cannot diff a range'
    } else {
        # case-insensitive lookup, like run-all's suite resolution
        $byName = @{}; if ($Map -is [Collections.IDictionary]) { foreach ($k in $Map.Keys) { $byName["$k".ToLowerInvariant()] = $Map[$k] } }
        $key = "$Suite".ToLowerInvariant()
        if (-not $byName.ContainsKey($key)) {
            $reason = "no declared inputs for suite '$Suite' (an unknown suite runs)"
        } else {
            $globs = @($byName[$key] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            if (-not $globs.Count) {
                $reason = "suite '$Suite' declares no input globs (runs)"
            } else {
                if ($null -eq $ChangedPaths) {
                    $cp = Get-AqChangedPaths -RepoRoot $RepoRoot -Base $Base -Head $Head
                    if (-not $cp.Ok) {
                        $verdict = 'force-run'; $reason = 'cannot read the changed-path range (runs)'
                        return [pscustomobject]@{ Suite = $Suite; Decision = $verdict; Reason = $reason; Globs = @($globs); Changed = @() }
                    }
                    $ChangedPaths = $cp.Paths
                }
                switch (Test-AqGlobSetChanged -Globs $globs -Paths $ChangedPaths) {
                    'match'   { $verdict = 'run';  $reason = 'a declared input changed' }
                    'none'    { $verdict = 'skip'; $reason = 'no declared input changed' }
                    default   { $verdict = 'force-run'; $reason = 'a declared glob cannot be modelled (runs)' }
                }
            }
        }
    }

    [pscustomobject]@{ Suite = $Suite; Decision = $verdict; Reason = $reason; Globs = @($globs); Changed = @() }
}

# Decide a whole list. Returns an object with Run/Skip, a per-suite Decisions list and `Proved` - the
# single gate the caller keys on: a narrowing exists only when at least one suite runs AND at least one
# skips, and the global inputs did not change. Anything else (an empty run set, no skip, a global
# change) leaves Proved=$false so the caller falls back to the FULL list.
function Select-AqSuites {
    param(
        [Parameter(Mandatory = $true)][string[]]$Suites,
        [string]$Base,
        [string]$Head = 'HEAD',
        [string]$RepoRoot = '.',
        $Map,
        [string[]]$GlobalGlobs,
        [switch]$Force
    )
    if ($null -eq $Map) { $Map = Get-AqSuiteInputMap }
    if ($null -eq $GlobalGlobs) { $GlobalGlobs = Get-AqGlobalInputGlobs }

    $globalChanged = $false; $globalReason = ''
    $changedPaths = @()
    if ($Force) { $globalChanged = $true; $globalReason = '-Force' }
    elseif (-not $Base -or -not "$Base".Trim()) { $globalChanged = $true; $globalReason = 'no base commit - cannot prove the selection' }
    else {
        $cp = Get-AqChangedPaths -RepoRoot $RepoRoot -Base $Base -Head $Head
        if (-not $cp.Ok) { $globalChanged = $true; $globalReason = 'cannot read the changed-path range (git error)' }
        else {
            $changedPaths = $cp.Paths
            $globals = @($GlobalGlobs | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            foreach ($g in $globals) {
                $rx = ConvertFrom-AqGlob $g
                if ($null -eq $rx) { $globalChanged = $true; $globalReason = "a global input glob is unusable ('$g') - running every suite"; break }
                $hit = @($changedPaths | Where-Object { "$_" -match $rx })
                if ($hit.Count) { $globalChanged = $true; $globalReason = "global input changed: $($hit -join ', ')"; break }
            }
        }
    }

    $decisions = @()
    foreach ($s in $Suites) {
        if ($globalChanged) {
            $decisions += [pscustomobject]@{ Suite = $s; Decision = 'force-run'; Reason = $globalReason; Globs = @(); Changed = @() }
        } else {
            $decisions += Resolve-AqSuiteInputDecision -Suite $s -Base $Base -Head $Head -RepoRoot $RepoRoot -Map $Map -ChangedPaths $changedPaths
        }
    }

    $run = @($decisions | Where-Object { $_.Decision -eq 'run' -or $_.Decision -eq 'force-run' } | ForEach-Object { $_.Suite })
    $skip = @($decisions | Where-Object { $_.Decision -eq 'skip' } | ForEach-Object { $_.Suite })
    $proved = ($run.Count -gt 0 -and $skip.Count -gt 0)
    $reason = if ($globalChanged) { $globalReason }
        elseif ($proved) { "narrowed by input change: $($run.Count) run / $($skip.Count) skip" }
        else { 'no narrowing proved (running every suite)' }

    [pscustomobject]@{ Base = $Base; Head = $Head; Proved = $proved; Run = $run; Skip = $skip; Decisions = $decisions; Reason = $reason }
}

# --- the pool entry point --------------------------------------------------------------------------
# Runs ONLY when the script is invoked as a script (-RunPool). A dot-source for the selection leaves it
# off, so importing this file never starts a gate.
if ($RunPool) {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $skipList = @($Skip -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $pool = Join-Path $repoRoot 'ps/devcloud/pool-suites.ps1'
    if (-not (Test-Path -LiteralPath $pool)) {
        "AGENTQ-SUITE-INPUTS: no $pool - refusing (the gate cannot run without the pool half)."
        exit 2
    }
    if ($skipList.Count) {
        $env:AGENTQ_TEST_SKIP = ($skipList -join ',')
        "AGENTQ-SUITE-INPUTS: narrowing the pool gate - skipping $($skipList.Count) unchanged suite(s): $env:AGENTQ_TEST_SKIP"
    } else {
        Remove-Item Env:AGENTQ_TEST_SKIP -ErrorAction SilentlyContinue
        'AGENTQ-SUITE-INPUTS: no skip list - running every suite.'
    }
    & pwsh -NoProfile -File $pool -RepoKey $SuiteRepoKey -Parallel $PoolParallel
    exit $LASTEXITCODE
}
