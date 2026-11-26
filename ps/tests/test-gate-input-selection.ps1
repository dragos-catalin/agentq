# Gate input selection: which gate suites RUN, which SKIP, and every way the answer must fail OPEN.
#
# `ps/bin/agentq-suite-inputs.ps1` lets the land gate run only the suites whose declared inputs changed
# (the pre-push hook's proven `git diff --name-only base...HEAD -- <globs>` approach, applied per suite).
# The DANGER of any input-based selection is skipping a suite that SHOULD have run, so this suite pins
# both directions and every uncertainty:
#   (a) an unrelated change          -> SKIP   (the selection actually selects)
#   (b) a change inside the inputs   -> RUN
#   (c) every error / unknown path    -> RUN    (fail-open: never skip what it cannot prove)
#   (d) a MUTATION - the decision is broken so a changed input is no longer detected - and the suite
#       shows the (b) assertion would then be RED (so the assertions are not vacuous).
# It also proves the TRANSPORT gate.ps1 depends on: a devcloud job carries no environment, so the SKIP
# list travels in argv and the module exports it as AGENTQ_TEST_SKIP for the child pool half. That is
# checked end to end against a fake pool half in a temp tree - no network, no real gate.
#
# Offline and hermetic: one throwaway git repo under %TEMP%, a fake pool half, nothing outside it.
# Exit: 0 all checks pass, 1 any fails. Summary line `--- <n> pass / <m> fail`.
[CmdletBinding()]
param(
    [string]$Module = (Join-Path $PSScriptRoot '..\bin\agentq-suite-inputs.ps1'),
    [string]$Pwsh
)
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Output "PASS $Name" }
    else { $script:fail++; Write-Output "FAIL $Name$(if ($Detail) { ' - ' + $Detail })" }
}
function Note([string]$Text) { Write-Output "note: $Text" }

$modulePath = (Resolve-Path -LiteralPath $Module).Path
Check "the module is readable ($modulePath)" (Test-Path -LiteralPath $modulePath)
if (-not (Test-Path -LiteralPath $modulePath)) { Write-Output "--- $pass pass / $fail fail"; exit 1 }
if (-not $Pwsh) { $Pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)[0].Source }
Check 'pwsh is available (the pool entry point runs in a child process)' ([bool]$Pwsh)

# ---- a scratch git repo: four commits, each changing a DIFFERENT file ----------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aq-gisin-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$repo = Join-Path $tmp 'repo'
New-Item -ItemType Directory -Force $repo | Out-Null
function W([string]$rel, [string]$text) {
    $p = Join-Path $repo $rel
    New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null
    [IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($false))
}
function Commit([string]$msg) {
    & git -C $repo add -A 2>$null | Out-Null
    & git -C $repo commit -q -m $msg 2>$null | Out-Null
    "$(& git -C $repo rev-parse HEAD 2>$null)".Trim()
}

try {
    & git -C $repo init -q 2>$null | Out-Null
    & git -C $repo config user.email 'gate-inputs@example.invalid' 2>$null | Out-Null
    & git -C $repo config user.name 'gate inputs test' 2>$null | Out-Null
    & git -C $repo config commit.gpgsign false 2>$null | Out-Null
    & git -C $repo config core.autocrlf false 2>$null | Out-Null

    W 'ps/bin/tool.ps1'      "v1`n"
    W 'docs/readme.md'       "base`n"
    W 'ps/tests/run-all.ps1' "runner`n"
    $c0 = Commit 'base'

    W 'docs/readme.md'       "changed docs`n"        # unrelated to every suite below
    $c1 = Commit 'docs only'

    W 'ps/bin/tool.ps1'      "v2`n"                  # inside 'demo suite' inputs
    $c2 = Commit 'tool changed'

    W 'ps/tests/run-all.ps1' "runner changed`n"      # a GLOBAL input
    $c3 = Commit 'runner changed'
    Check 'the scratch repo has the four commits it needs' ([bool]$c0 -and [bool]$c1 -and [bool]$c2 -and [bool]$c3) "c0=$c0 c1=$c1 c2=$c2 c3=$c3"

    # A test-local map. The REAL map is exercised through gate.ps1; this pins the DECISION function.
    $map = @{
        'demo suite'  = @('ps/bin/tool.ps1', 'ps/tests/test-tool.ps1')
        'other suite' = @('ps/other/thing.ps1')          # a valid glob that matches nothing
        'empty suite' = @()
        'bad suite'   = @(':(badmagic)ps/bin/tool.ps1')  # a malformed pathspec -> git error
    }
    $globals = @('ps/tests/run-all.ps1')

    . $modulePath   # defines Resolve-AqSuiteInputDecision / Select-AqSuites / Test-AqChangeInRange

    function Decide([string]$s, [string]$b, [string]$h) {
        Resolve-AqSuiteInputDecision -Suite $s -Base $b -Head $h -RepoRoot $repo -Map $map
    }

    # ---- (b) a change INSIDE a suite's declared inputs RUNS it ------------------------------------
    $d = Decide 'demo suite' $c1 $c2
    Check "(b) an input change RUNS 'demo suite'" ($d.Decision -eq 'run') "got=$($d.Decision) - $($d.Reason)"

    # ---- (a) an UNRELATED change SKIPS it ---------------------------------------------------------
    $d = Decide 'demo suite' $c0 $c1
    Check "(a) an unrelated change SKIPS 'demo suite'" ($d.Decision -eq 'skip') "got=$($d.Decision) - $($d.Reason)"

    # a valid glob that matches nothing is still PROVABLE (clean diff, empty) -> skip
    $d = Decide 'other suite' $c0 $c1
    Check 'a valid glob that matches nothing -> skip' ($d.Decision -eq 'skip') "got=$($d.Decision) - $($d.Reason)"

    # ---- (c) every error / unknown path RUNS it (never skip what cannot be proved) ----------------
    $d = Decide 'unknown suite' $c1 $c2
    Check '(c) an unknown suite force-runs' ($d.Decision -eq 'force-run') "got=$($d.Decision)"
    $d = Decide 'empty suite' $c1 $c2
    Check '(c) an empty glob list force-runs' ($d.Decision -eq 'force-run') "got=$($d.Decision)"
    $d = Decide 'bad suite' $c1 $c2
    Check '(c) a malformed pathspec (git error) force-runs' ($d.Decision -eq 'force-run') "got=$($d.Decision) - $($d.Reason)"
    $d = Decide 'demo suite' '' $c2
    Check '(c) no base commit force-runs' ($d.Decision -eq 'force-run') "got=$($d.Decision)"
    $d = Decide 'demo suite' 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' $c2
    Check '(c) an unresolvable base force-runs' ($d.Decision -eq 'force-run') "got=$($d.Decision)"
    $d = Decide 'demo suite' $c1 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'
    Check '(c) an unresolvable head force-runs' ($d.Decision -eq 'force-run') "got=$($d.Decision)"

    # ---- the whole-list selector -----------------------------------------------------------------
    $s = Select-AqSuites -Suites @('demo suite', 'other suite') -Base $c1 -Head $c2 -RepoRoot $repo -Map $map -GlobalGlobs $globals
    Check 'Select: a real narrowing is Proved (one runs, one skips)' ($s.Proved -and ($s.Run -contains 'demo suite') -and ($s.Skip -contains 'other suite')) "proved=$($s.Proved) run=$($s.Run -join ',') skip=$($s.Skip -join ',')"

    # NEVER a zero-suite gate: if everything skips, Proved is FALSE so the caller runs the full list.
    $s2 = Select-AqSuites -Suites @('demo suite', 'other suite') -Base $c0 -Head $c1 -RepoRoot $repo -Map $map -GlobalGlobs $globals
    Check 'Select: an all-skip selection is NOT Proved (no zero-suite gate)' (-not $s2.Proved) "proved=$($s2.Proved) run=$($s2.Run -join ',')"

    # GLOBAL widening: a change to a global input forces every suite to run -> not Proved.
    $s3 = Select-AqSuites -Suites @('demo suite', 'other suite') -Base $c2 -Head $c3 -RepoRoot $repo -Map $map -GlobalGlobs $globals
    Check 'Select: a global-input change widens to every suite (not Proved)' ((-not $s3.Proved) -and (@($s3.Skip).Count -eq 0)) "proved=$($s3.Proved) skip=$($s3.Skip -join ',')"

    # -Force runs everything unconditionally.
    $s4 = Select-AqSuites -Suites @('demo suite', 'other suite') -Base $c2 -Head $c2 -RepoRoot $repo -Map $map -GlobalGlobs $globals -Force
    Check 'Select: -Force runs everything (not Proved)' (-not $s4.Proved) "proved=$($s4.Proved)"

    # ---- Test-AqChangeInRange fail-opens ---------------------------------------------------------
    Check 'Test-AqChangeInRange: empty globs -> changed (true)' (Test-AqChangeInRange -RepoRoot $repo -Base $c1 -Head $c2 -Globs @())
    Check 'Test-AqChangeInRange: bad glob -> changed (true)' (Test-AqChangeInRange -RepoRoot $repo -Base $c1 -Head $c2 -Globs @(':(badmagic)x'))
    Check 'Test-AqChangeInRange: unrelated glob -> unchanged (false)' (-not (Test-AqChangeInRange -RepoRoot $repo -Base $c1 -Head $c2 -Globs @('docs/readme.md')))
    Check 'Test-AqChangeInRange: matching glob -> changed (true)' (Test-AqChangeInRange -RepoRoot $repo -Base $c1 -Head $c2 -Globs @('ps/bin/tool.ps1'))

    # ---- the TRANSPORT gate.ps1 relies on: argv in, AGENTQ_TEST_SKIP out to the pool half ---------
    if ($Pwsh) {
        $mini = Join-Path $tmp 'mini'
        New-Item -ItemType Directory -Force (Join-Path $mini 'ps/bin') | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $mini 'ps/devcloud') | Out-Null
        Copy-Item -LiteralPath $modulePath -Destination (Join-Path $mini 'ps/bin/agentq-suite-inputs.ps1')
        $fakePool = @'
param([string]$RepoKey, [int]$Parallel = 4)
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'seen.txt') -Value ("key={0};parallel={1};skip={2}" -f $RepoKey, $Parallel, $env:AGENTQ_TEST_SKIP)
exit 0
'@
        [IO.File]::WriteAllText((Join-Path $mini 'ps/devcloud/pool-suites.ps1'), $fakePool, [Text.UTF8Encoding]::new($false))

        & $Pwsh -NoProfile -File (Join-Path $mini 'ps/bin/agentq-suite-inputs.ps1') -RunPool -SuiteRepoKey 'agentq' -PoolParallel 4 -Skip 'a,b' | Out-Null
        $poolExit = $LASTEXITCODE
        $seen = if (Test-Path (Join-Path $mini 'ps/devcloud/seen.txt')) { Get-Content (Join-Path $mini 'ps/devcloud/seen.txt') -Raw } else { '' }
        Check 'transport: -RunPool exits with the pool half exit code' ($poolExit -eq 0) "exit=$poolExit"
        Check 'transport: AGENTQ_TEST_SKIP reaches the pool half (argv -> env)' ($seen -match 'skip=a,b') "seen='$($seen.Trim())'"
        Check 'transport: the repo key and parallelism are passed through' (($seen -match 'key=agentq') -and ($seen -match 'parallel=4')) "seen='$($seen.Trim())'"

        # An EMPTY skip list must export NOTHING, so the child runs every suite.
        Remove-Item (Join-Path $mini 'ps/devcloud/seen.txt') -ErrorAction SilentlyContinue
        & $Pwsh -NoProfile -File (Join-Path $mini 'ps/bin/agentq-suite-inputs.ps1') -RunPool -SuiteRepoKey 'agentq' -Skip '' | Out-Null
        $seen2 = if (Test-Path (Join-Path $mini 'ps/devcloud/seen.txt')) { Get-Content (Join-Path $mini 'ps/devcloud/seen.txt') -Raw } else { '' }
        Check 'transport: an empty skip list exports nothing' (($seen2 -match 'skip=\s*$') -or ($seen2 -match 'skip=;')) "seen='$($seen2.Trim())'"
    }

    # ---- the GATE end to end: gate.ps1 must PICK the narrowed remote command, and fall back ---------
    # A throwaway mini-repo that mirrors the real layout (a copy of gate.ps1, a copy of the module and a
    # two-suite config), so the wiring in gate.ps1 - not just the module - is exercised. The changed file
    # matches 'agentq v2' but not 'prewarm cloud', so the remote command must carry `-Skip prewarm cloud`.
    if ($Pwsh) {
        $g = Join-Path $tmp 'gate'
        New-Item -ItemType Directory -Force (Join-Path $g 'ps/bin') | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $g 'ps/devcloud') | Out-Null
        New-Item -ItemType Directory -Force (Join-Path $g 'ps/tests') | Out-Null
        Copy-Item -LiteralPath $modulePath -Destination (Join-Path $g 'ps/bin/agentq-suite-inputs.ps1')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\devcloud\gate.ps1') -Destination (Join-Path $g 'ps/devcloud/gate.ps1')
        [IO.File]::WriteAllText((Join-Path $g 'ps/bin/agentq-config.json'), '{"gateSuites":{"agentq":["agentq v2","prewarm cloud"]}}', [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $g 'ps/devcloud/pool-suites.ps1'), "exit 0`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $g 'ps/tests/run-all.ps1'), "exit 0`n", [Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText((Join-Path $g 'ps/bin/agentq-v2.ps1'), "v1`n", [Text.UTF8Encoding]::new($false))
        & git -C $g init -q 2>$null | Out-Null
        & git -C $g config user.email 'gate@example.invalid' 2>$null | Out-Null
        & git -C $g config user.name 'gate test' 2>$null | Out-Null
        & git -C $g config commit.gpgsign false 2>$null | Out-Null
        & git -C $g add -A 2>$null | Out-Null
        & git -C $g commit -q -m base 2>$null | Out-Null
        $gBase = "$(& git -C $g rev-parse HEAD 2>$null)".Trim()
        [IO.File]::WriteAllText((Join-Path $g 'ps/bin/agentq-v2.ps1'), "v2`n", [Text.UTF8Encoding]::new($false))
        & git -C $g add -A 2>$null | Out-Null
        & git -C $g commit -q -m change 2>$null | Out-Null
        & git -C $g update-ref refs/remotes/origin/main $gBase 2>$null

        $out1 = & $Pwsh -NoProfile -File (Join-Path $g 'ps/devcloud/gate.ps1') -DryRun 2>&1
        $t1 = (@($out1 | ForEach-Object { "$_" }) -join ' | ')
        Check 'gate: a proven change picks the NARROWED remote command' ($t1 -match 'agentq-suite-inputs\.ps1') $t1
        Check 'gate: the narrowed command carries -Skip for the unchanged suite' ($t1 -match '-Skip\s+prewarm cloud') $t1

        & git -C $g update-ref refs/remotes/origin/main HEAD 2>$null   # now nothing changed vs origin/main
        $out2 = & $Pwsh -NoProfile -File (Join-Path $g 'ps/devcloud/gate.ps1') -DryRun 2>&1
        $t2 = (@($out2 | ForEach-Object { "$_" }) -join ' | ')
        Check 'gate: no proven change falls back to the full pool command' (($t2 -match 'pool-suites\.ps1') -and ($t2 -notmatch 'agentq-suite-inputs\.ps1')) $t2
    }

    # ---- (d) MUTATION: break the decision so a changed input is no longer detected ----------------
    # The mutant replaces the ONLY predicate that can answer `run`, so the (b) assertion above MUST be
    # red under it. If this check ever passes while (b) still passes, the assertions are vacuous.
    $raw = Get-Content -LiteralPath $modulePath -Raw
    $anchor = "return 'match'"
    Check 'MUTATION anchor present in the module' ($raw.Contains($anchor))
    $mutText = $raw.Replace($anchor, "return 'none'")
    Check 'MUTATION applied (a changed input can no longer be detected)' ($mutText -ne $raw)
    $mutDir = Join-Path $tmp 'mut'
    New-Item -ItemType Directory -Force $mutDir | Out-Null
    $mutPath = Join-Path $mutDir 'agentq-suite-inputs.ps1'
    [IO.File]::WriteAllText($mutPath, $mutText, [Text.UTF8Encoding]::new($false))
    . $mutPath   # redefines the functions in THIS scope with the broken predicate
    $md = Resolve-AqSuiteInputDecision -Suite 'demo suite' -Base $c1 -Head $c2 -RepoRoot $repo -Map $map
    Check 'MUTATION the broken decision returns skip for a changed input ((b) would be RED)' ($md.Decision -eq 'skip') "got=$($md.Decision)"
    . $modulePath   # restore the real module
}
finally {
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output "--- $pass pass / $fail fail"
if ($fail) { exit 1 }
exit 0
