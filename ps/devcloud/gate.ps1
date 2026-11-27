<#
.SYNOPSIS
  agentq's land gate (`run-all.ps1 -RepoSuites`, 26 suites) submitted to the devcloud pool.

.DESCRIPTION
  agentq calls this as `landGate.agentq`. The gate ran on this workstation and was MEASURED at
  2160 s (36 min) of CPU for 26 suites - `TOTAL sec=2160 suites=26 failed=0`, 2026-11-25 - the last
  big local consumer in the land flow. This wrapper submits the same suite list to the dedicated
  Windows workspace `ws-agentq` (a lane proven to run `pwsh -NoProfile -File <script>`, the
  caelia / vitals-win shape) and returns the pool's exit code, so a land stops competing with the
  editor for this machine.

  ONE THING THE POOL CANNOT DERIVE, resolved HERE and passed along. `run-all.ps1` reads
  `gateSuites.<repo>`, where `<repo>` is the leaf of the parent of the git COMMON dir. agentq ships
  the pool a bundle of commits plus a patch of the working tree, and the runner builds the checkout
  with `git init` + `git fetch <bundle> HEAD:refs/devcloud/in/<job>` + `git checkout --detach <sha>`:
  that checkout has no `origin` remote and no tags, and its git common dir is `<checkout>/.git`, so
  the derived name is the CHECKOUT DIRECTORY's name - not `agentq`. A gate that derived it there
  would exit 2 with `run-all: -RepoSuites: no gateSuites.<name>`. So the repo key is named
  EXPLICITLY: this wrapper resolves the list under the key `agentq` and REFUSES to submit (exit 1)
  when the config cannot answer, and the remote half
  (`ps/devcloud/pool-suites.ps1 -RepoKey agentq`) repeats the resolution on the checkout and fails
  LOUDLY (non-zero) if the key is missing. A gate must never fail open on a pool checkout - the
  marcai precedent is exactly that hazard: `land-loss.mjs` prints "origin/main is not a ref here
  (shallow clone?) - nothing to check" and returns 0.

  The submission is made on the `verify` resource, NOT `build`: the land gate already runs THROUGH
  `run-build` (`agentq-v2.ps1` `Invoke-GateRun` -> `run-build.ps1`, which queues on `build:<repo>`,
  cap 1), so a nested submission on that same resource would wait for a ticket its own parent holds
  and the land would deadlock until the timeout. `verify` has the same cap, so the pool work is
  still serialised - the land just cannot deadlock against itself. Same choice as caelia, brivio
  and marcai.

  The exit code is the remote one (0 = pass), parsed from agentq's `[devcloud] exit <n>` trailer, so
  agentq reads this gate exactly like a local command. No trailer at all is exit 3, never 0.

  Examples:
    pwsh -NoProfile -File ps/devcloud/gate.ps1               # land gate on the pool (what agentq calls)
    pwsh -NoProfile -File ps/devcloud/gate.ps1 -DryRun       # print the plan, submit nothing
    pwsh -NoProfile -File ps/devcloud/gate.ps1 -LocalOnly    # today's local command, verbatim
    pwsh -NoProfile -File ps/devcloud/gate.ps1 -Help

.PARAMETER Resource
  agentq resource the submission queues on. Default `verify` - never `build` here (see above).

.PARAMETER Workspace
  agentq cloud workspace name. Default `agentq` (`cloudWorkspaces.agentq` -> `cloudRegistry.agentq`).

.PARAMETER TimeoutMin
  Wall-clock cap given to agentq. Default 90. The first run on a cold workspace also warms its
  checkouts and its pnpm store. Raised 60 -> 90 on 2026-11-27: `gateSuites.agentq` grew to 42 suites
  and a live run was killed at `[devcloud] timeout after 3600s` with 30/42 done (measured effective
  concurrency ~0.8 at -Parallel 4 - the suites are contention-bound on one pool checkout), so 3600 s
  was structurally below the ~4200-4600 s the full list needs. A gate that cannot finish inside its
  own cap is a land that can never pass.

.PARAMETER Repo
  Repository to bundle. Default: this script's own repo (resolved through git, so a leased worktree
  slot resolves to the repo agentq knows about).

.PARAMETER Purpose
  Recorded on the agentq ticket. Defaults to a description of the gate.

.PARAMETER LocalOnly
  Run TODAY's local command verbatim - `run-all.ps1 -RepoSuites -Parallel 4` - instead of submitting
  to the pool. This is the escape hatch for a pool outage; it is NOT a way to make a land pass, and
  it prints exactly which command it ran.

.PARAMETER DryRun
  Print the exact `agentq run` invocation and exit 0 without queueing anything.

.PARAMETER AllowLocalFallback
  Let agentq run the gate locally when `ws-agentq` is unavailable, instead of failing fast. Use only
  to diagnose a workspace outage.

.PARAMETER Help
  Print this help and exit 0.
#>
[CmdletBinding()]
param(
    [string]$Resource = 'verify',
    [string]$Workspace = 'agentq',
    [int]$TimeoutMin = 90,
    [string]$Repo,
    [string]$Purpose,
    [switch]$LocalOnly,
    [switch]$DryRun,
    [switch]$AllowLocalFallback,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# The repo key this gate resolves its suite list under. Named, never derived: the pool checkout is not
# called `agentq` and run-all's default derivation would refuse there (see the note above).
$RepoKey = 'agentq'

if ($Help) {
    @'
ps/devcloud/gate.ps1 - agentq's land gate on the devcloud pool (landGate.agentq)

  pwsh -NoProfile -File ps/devcloud/gate.ps1                 submit gateSuites.agentq to ws-agentq
  pwsh -NoProfile -File ps/devcloud/gate.ps1 -DryRun         print the plan, submit nothing
  pwsh -NoProfile -File ps/devcloud/gate.ps1 -LocalOnly      run today's local command, verbatim
  pwsh -NoProfile -File ps/devcloud/gate.ps1 -Resource verify -Workspace agentq -TimeoutMin 90

  -LocalOnly  runs `run-all.ps1 -RepoSuites -Parallel 4` HERE, on this workstation, and submits
              nothing. For a pool outage only - it is never a way to make a land pass.
  -DryRun     prints the `agentq run` argv, the resolved suite count and the remote command, then
              exits 0 without queueing anything.

  Exit code is the pool's exit code, parsed from `[devcloud] exit <n>`; a missing trailer exits 3.
'@
    exit 0
}

# A native command's stderr is not a reason to abort: git writes warnings there (CRLF hints) and this
# script only reads its stdout. PowerShell 7.4+ turns stderr into a terminating error under `Stop`,
# which would kill the gate before it is submitted.
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

# Never silently fall back to this workstation: `-Where cloud` alone degrades to a local run when the
# workspace is unavailable (agentq-cloud exit 4), which is the very thing this gate avoids.
if (-not $AllowLocalFallback) { $env:AGENTQ_CLOUD_STRICT = '1' }

# ps/devcloud/gate.ps1 -> the repo root is two levels up. A leased slot IS a checkout, so this resolves
# the same tree agentq will bundle.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $Repo) { $Repo = $repoRoot }

# --- (i) the precondition that depends on this checkout, resolved LOCALLY --------------------------
# No git ref is needed here (unlike brivio's `--base` or marcai's `origin/main`): what the pool would
# derive WRONGLY is the suite-list key. Resolve it explicitly and refuse to submit when the config
# cannot answer - a gate that submits with no suites is not a gate.
$cfgPath = Join-Path $repoRoot 'ps\bin\agentq-config.json'
$gateList = @()
if (-not (Test-Path -LiteralPath $cfgPath)) {
    "AGENTQ-CLOUD-GATE: no config at $cfgPath - refusing to submit a gate whose suite list cannot be resolved."
    exit 1
}
try {
    $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json -AsHashtable
} catch {
    "AGENTQ-CLOUD-GATE: cannot parse $cfgPath ('$($_.Exception.Message)') - refusing to submit a gate whose suite list cannot be resolved."
    exit 1
}
$gs = if ($cfg -is [Collections.IDictionary] -and $cfg.ContainsKey('gateSuites')) { $cfg['gateSuites'] } else { $null }
if ($gs -is [Collections.IDictionary] -and $gs.ContainsKey($RepoKey)) {
    $gateList = @($gs[$RepoKey] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}
if (-not $gateList.Count) {
    "AGENTQ-CLOUD-GATE: no gateSuites.$RepoKey in $cfgPath - refusing to submit a gate the pool would run with NO suites."
    exit 1
}

# --- the suite SELECTION: which of the $gateList suites did THIS change actually touch? -------------
# Computed HERE, where the git range (origin/main...HEAD) exists - a pool checkout has no origin refs,
# so it can only be TOLD the result. Every uncertainty falls back to the FULL list (see
# ps/bin/agentq-suite-inputs.ps1: fail-open toward running). `Proved` is false unless at least one suite
# still runs AND at least one skips AND the global inputs (the runner, the suite list, this module) did
# not change, so a narrowing can never leave the gate with nothing to run.
$selection = $null
try {
    . (Join-Path $repoRoot 'ps\bin\agentq-suite-inputs.ps1')
    $base = ''
    $u = "$(& git -C $repoRoot rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)".Trim()
    if ($LASTEXITCODE -eq 0 -and $u) { $base = $u }
    elseif (& git -C $repoRoot rev-parse --verify --quiet origin/main 2>$null) { $base = 'origin/main' }
    if ($base) {
        $mb = "$(& git -C $repoRoot merge-base $base HEAD 2>$null)".Trim()
        if ($LASTEXITCODE -eq 0 -and $mb) { $base = $mb }
    }
    $selection = Select-AqSuites -Suites $gateList -Base $base -Head 'HEAD' -RepoRoot $repoRoot
} catch {
    "AGENTQ-CLOUD-GATE: suite selection failed ('$($_.Exception.Message)') - running the full list."
    $selection = $null
}
$narrow = [bool]($selection -and $selection.Proved)
$selectionReason = if ($selection) { "$($selection.Reason)" } else { 'selection unavailable (running the full list)' }

if (-not $Purpose) { $Purpose = "devcloud pool land gate (gateSuites.$RepoKey - $($gateList.Count) suites)" }

# --- -LocalOnly: today's command, verbatim (escape hatch, never a land shortcut) --------------------
if ($LocalOnly) {
    $runAll = Join-Path $repoRoot 'ps\tests\run-all.ps1'
    "AGENTQ-CLOUD-GATE: -LocalOnly - running TODAY's local command on this workstation; nothing is submitted to the pool."
    "AGENTQ-CLOUD-GATE: & pwsh -NoProfile -File $runAll -RepoSuites -Parallel 4"
    # run-all.ps1 reads AGENTQ_TEST_SKIP (its documented -Skip override), so the same narrowing applies here.
    if ($narrow) { $env:AGENTQ_TEST_SKIP = ($selection.Skip -join ',') } else { Remove-Item Env:AGENTQ_TEST_SKIP -ErrorAction SilentlyContinue }
    if ($narrow) { "AGENTQ-CLOUD-GATE: $selectionReason (AGENTQ_TEST_SKIP=$env:AGENTQ_TEST_SKIP)" } else { "AGENTQ-CLOUD-GATE: full list - $selectionReason" }
    & pwsh -NoProfile -File $runAll -RepoSuites -Parallel 4
    $localCode = $LASTEXITCODE
    if ($localCode -eq 0) { "AGENTQ-CLOUD-GATE: PASS (local exit 0; the pool was not used)" }
    else { "AGENTQ-CLOUD-GATE: FAILED (local exit $localCode; the pool was not used)" }
    exit $localCode
}

# --- (ii) the remote command: separate argv tokens, each a word (the caelia / vitals-win shape) ----
# The lane runs `pwsh -NoProfile -File <script>`; the script resolves gateSuites.<RepoKey> on the
# CHECKOUT under test (not this tree) and fails loudly when the key is missing.
# A PROVEN narrowing travels in argv (a devcloud job carries NO environment): ps/bin/agentq-suite-inputs.ps1
# exports AGENTQ_TEST_SKIP and then runs the SAME pool half, so the suite list is still resolved on the
# checkout and a missing key still fails loudly there. With no proven narrowing the command is
# byte-for-byte today's, so the fallback path carries no new risk.
if ($narrow) {
    $inner = @('pwsh', '-NoProfile', '-File', 'ps/bin/agentq-suite-inputs.ps1', '-RunPool', '-SuiteRepoKey', $RepoKey, '-PoolParallel', '4', '-Skip', ($selection.Skip -join ','))
} else {
    $inner = @('pwsh', '-NoProfile', '-File', 'ps/devcloud/pool-suites.ps1', '-RepoKey', $RepoKey, '-Parallel', '4')
}

$agentq = Join-Path $HOME '.copilot/bin/agentq.ps1'
$argv = @(
    '-NoProfile', '-File', $agentq,
    'run', '-Resource', $Resource, '-Where', 'cloud', '-Ws', $Workspace,
    '-Repo', $Repo, '-Purpose', $Purpose, '-TimeoutMin', "$TimeoutMin",
    '--'
) + $inner

if ($DryRun) {
    'agentq ' + ($argv[3..($argv.Count - 1)] -join ' ')
    "  workspace: $Workspace   resource: $Resource"
    "  repo key:  $RepoKey ($($gateList.Count) suites: $($gateList -join ', '))"
    "  selection: $selectionReason"
    "  remote:    $($inner -join ' ')"
    "  repo:      $Repo"
    '  (dry run: nothing queued)'
    exit 0
}

$logDir = Join-Path $repoRoot '.copilot-tmp/agentq-cloud-gate'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir ("{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
"=== land gate on the pool: gateSuites.$RepoKey ($($gateList.Count) resolved; $selectionReason) on ws-$Workspace"
"=== log: $log"

& pwsh @argv 2>&1 | Tee-Object -FilePath $log
$agentqExit = $LASTEXITCODE

# Parse the trailer rather than trusting $LASTEXITCODE: agentq exits 3 for "someone else holds the
# resource", which is a queueing problem, not a gate result.
$remote = $null
$m = Select-String -Path $log -Pattern '\[devcloud\] exit (\d+)' | Select-Object -Last 1
if ($m) { $remote = [int]$m.Matches[0].Groups[1].Value }

if ($null -eq $remote) {
    "AGENTQ-CLOUD-GATE: no '[devcloud] exit' line in the log - agentq did not run the gate (exit 3, never treated as success)."
    exit 3
}
if ($remote -ne 0) {
    "AGENTQ-CLOUD-GATE: FAILED (remote exit $remote) - see $log"
    exit $remote
}
"AGENTQ-CLOUD-GATE: PASS (remote exit 0; gateSuites.$RepoKey = $($gateList.Count) suites on ws-$Workspace)"
exit 0
