# agentq trackers|plan|task - the three tracker verbs. Each is a THIN pass-through to the portable
# tools/track.mjs (the tracking/resume store is implemented once, in Node): it resolves the repo root,
# execs the CLI with the caller's arguments untouched and returns the CLI's OWN exit code. This suite
# proves that by running the module and the CLI side by side and demanding byte-identical output and
# equal exit codes, and it proves the pass-through is not vacuous with two deliberate MUTATIONS (drop
# the forwarded args; swallow the exit code) run in a child process - remove the pass-through and the
# equality/exit assertions go red.
#
# The module is tested DIRECTLY (dot-sourced), not through ps/bin/agentq.ps1: the one-line wiring in that
# file is the owner's to add (the exact line is in the module's footer). run-all.ps1 was ACTIVE-OWNER
# when this suite was written, so it is not registered yet either - both one-liners are reported.
param([string]$Module = (Join-Path $PSScriptRoot '..\bin\agentq-trackers.ps1'))
$ErrorActionPreference = 'Stop'
$Module = (Resolve-Path $Module).Path

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqtrack-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$coord = Join-Path $tmp 'coord'
foreach ($sub in 'trackers', 'chats', 'tasks') { New-Item -ItemType Directory -Force (Join-Path $coord $sub) | Out-Null }
# The tool reads its live state from AGENTQ_HOME, so a fabricated state dir makes the suite deterministic
# (the live index is 16 repos / 12678 items; a test must not depend on the fleet's drift count).
$env:AGENTQ_HOME = $coord
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function WriteText([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false)) }

$index = [ordered]@{
    generatedAt = '2026-01-01T00:00:00.000Z'
    repos = @([ordered]@{
        repo = 'demo'; root = 'X:\demo'
        trackers = @([ordered]@{ file = 't.csv'; items = @([ordered]@{ id = 'A' }, [ordered]@{ id = 'B' }, [ordered]@{ id = 'C' }) })
        drift = @()
    })
}
WriteText (Join-Path $coord 'trackers\index.json') ($index | ConvertTo-Json -Depth 10)
$plan = [ordered]@{
    version = 1; sessionId = 'sess1'; goal = 'ship the thing'; doneMeans = @('a', 'b')
    next = @([ordered]@{ title = 'one'; status = 'todo' }, [ordered]@{ title = 'two'; status = 'todo' })
    roster = @(); jobs = @(); todos = @(); updatedAt = '2026-01-01T00:00:00.000Z'
}
WriteText (Join-Path $coord 'chats\sess1.plan.json') ($plan | ConvertTo-Json -Depth 10)
$task = [ordered]@{ version = 1; id = 'T1'; title = 'do it'; status = 'todo'; createdAt = '2026-01-01T00:00:00.000Z'; updatedAt = '2026-01-01T00:00:00.000Z' }
WriteText (Join-Path $coord 'tasks\T1.json') ($task | ConvertTo-Json -Depth 10)

. $Module
$cli = Get-AgentqTrackCliPath
$binDir = Split-Path -Parent $Module

# Native stderr is EXPECTED here: the tool reports its errors (an unknown sub-verb, a missing plan) on
# stderr by design, and Windows PowerShell 5.1 turns a native command's stderr into a TERMINATING
# NativeCommandError when the preference is 'Stop'. The capture helpers relax it for exactly that call.
function DirectRun([string[]]$TrackArgs) {
    $ErrorActionPreference = 'Continue'
    $lines = @(& node $cli @TrackArgs 2>&1 | ForEach-Object { "$_" })
    [pscustomobject]@{ Text = ($lines -join "`n"); Code = $LASTEXITCODE }
}
function ModuleRun([string]$Verb, [string[]]$TrackArgs) {
    $ErrorActionPreference = 'Continue'
    $lines = @(Invoke-AgentqTrackerVerb -Verb $Verb -Arguments $TrackArgs 2>&1 | ForEach-Object { "$_" })
    [pscustomobject]@{ Text = ($lines -join "`n"); Code = $script:AgentqTrackExit }
}

try {
    # ---- 0. the root is resolved, not hardcoded ----------------------------------------------------
    # Shape-agnostic on purpose: the module resolves the tool BESIDE itself (<dst>\bin\track.mjs once
    # installed, which is where run-all.ps1 runs this suite too) or at the repository root
    # (<repo>\tools\track.mjs in a checkout). Pinning one layout made the installed gate red.
    Check '0 the CLI path is a resolved track.mjs that exists' ((Test-Path -LiteralPath $cli) -and (Split-Path -Leaf $cli) -eq 'track.mjs') $cli

    # ---- 1. trackers == `node track.mjs status` ----------------------------------------------------
    $d = DirectRun @('status'); $m = ModuleRun 'trackers' @()
    Check '1 trackers stdout is byte-identical to `node track.mjs status`' ($m.Text -ceq $d.Text) "direct=$($d.Text) | module=$($m.Text)"
    Check '1a the exit codes match' ($m.Code -eq $d.Code) "direct=$($d.Code) module=$($m.Code)"
    Check '1b status is rendered from the fabricated index' ($m.Text -match 'trackers: 1 repo\(s\), 3 item\(s\)' -and $m.Text -match 'demo: 3 item\(s\), 0 drift') $m.Text

    # ---- 2. a forwarded flag reaches the tool (--json) ---------------------------------------------
    $dJson = DirectRun @('status', '--json'); $mJson = ModuleRun 'trackers' @('--json')
    Check '2 trackers --json stdout is byte-identical to the CLI' ($mJson.Text -ceq $dJson.Text) "direct=$($dJson.Text) | module=$($mJson.Text)"
    Check '2a --json changed the output (the flag really reached the tool)' ($mJson.Text -cne $d.Text) $mJson.Text
    $parsed = $null; try { $parsed = $mJson.Text | ConvertFrom-Json } catch {}
    Check '2b trackers --json is the parsed index (1 repo, 3 items)' ($null -ne $parsed -and @($parsed.repos).Count -eq 1 -and @($parsed.repos[0].trackers[0].items).Count -eq 3) $mJson.Text

    # ---- 3. plan == `node track.mjs plan ...` ------------------------------------------------------
    foreach ($args in @(@('show', '--session', 'sess1'), @('show', '--session', 'sess1', '--json'))) {
        $d = DirectRun (@('plan') + $args); $m = ModuleRun 'plan' $args
        Check "3 plan $($args -join ' ') byte-identical" ($m.Text -ceq $d.Text) "direct=$($d.Text) | module=$($m.Text)"
        Check "3a plan $($args -join ' ') exit matches" ($m.Code -eq $d.Code) "direct=$($d.Code) module=$($m.Code)"
    }

    # ---- 4. task == `node track.mjs task ...` ------------------------------------------------------
    foreach ($args in @(@('list'), @('list', '--json'), @('show', '--id', 'T1'))) {
        $d = DirectRun (@('task') + $args); $m = ModuleRun 'task' $args
        Check "4 task $($args -join ' ') byte-identical" ($m.Text -ceq $d.Text) "direct=$($d.Text) | module=$($m.Text)"
        Check "4a task $($args -join ' ') exit matches" ($m.Code -eq $d.Code) "direct=$($d.Code) module=$($m.Code)"
    }

    # ---- 5. an unknown sub-verb fails non-zero and names the valid ones ----------------------------
    $m = ModuleRun 'plan' @('bogus', '--session', 'sess1')
    Check '5 plan bogus exits non-zero' ($m.Code -ne 0) "exit=$($m.Code)"
    Check '5a plan bogus names the valid sub-verbs' ($m.Text -match "unknown subcommand 'bogus'" -and $m.Text -match 'set \| show') $m.Text
    $m = ModuleRun 'task' @('bogus', '--id', 'x')
    Check '5b task bogus exits non-zero' ($m.Code -ne 0) "exit=$($m.Code)"
    Check '5c task bogus names the valid sub-verbs' ($m.Text -match "unknown subcommand 'bogus'" -and $m.Text -match 'add \| claim') $m.Text

    # ---- 6. a missing plan record degrades cleanly (one line, non-zero, no crash) -------------------
    $m = ModuleRun 'plan' @('show', '--session', '__no_such_session__')
    Check '6 a missing plan exits 2' ($m.Code -eq 2) "exit=$($m.Code)"
    Check '6a a missing plan is one clear line' ($m.Text -match 'no plan for session' -and ($m.Text -split "`n").Count -eq 1) $m.Text

    # ---- 7. MUTATION CONTROL 1: drop the forwarded arguments ----------------------------------------
    # A copy of the module with the pass-through removed must produce DIFFERENT output than the CLI for
    # `trackers --json` - proving the byte-identical assertions depend on the pass-through really working.
    $mut = Join-Path $tmp 'mut-drop.ps1'
    $src = [IO.File]::ReadAllText($Module)
    $needle = '    if ($Arguments -and $Arguments.Count -gt 0) { $sa += $Arguments }'
    Check '7 the mutation target line exists in the module' ($src.Contains($needle)) 'needle not found'
    WriteText $mut ($src.Replace($needle, '    # MUTATION: the forwarded arguments are dropped'))
    $hostExe = (Get-Process -Id $PID).Path
    $child = Join-Path $tmp 'child-drop.ps1'
    WriteText $child (@'
param([string]$Mod,[string]$Root)
. $Mod
$script:AgentqTrackModuleRoot = $Root   # the copy lives in %TEMP%; point the resolver at the real ps\bin
Invoke-AgentqTrackers -Arguments @('--json')
exit $script:AgentqTrackExit
'@)
    $mutOut = (& $hostExe -NoProfile -File $child -Mod $mut -Root $binDir 2>&1 | ForEach-Object { "$_" }) -join "`n"
    Check '7a dropping the args changes the output, so the equality checks are load-bearing' ($mutOut -cne $dJson.Text) "mutated=$mutOut"
    Check '7b the mutation did NOT stay byte-identical' (-not ($mutOut -ceq $dJson.Text)) ''

    # ---- 8. MUTATION CONTROL 2: swallow the tool's exit code ----------------------------------------
    # A copy that always records exit 0 must report 0 where the real CLI reports 2 (a missing plan).
    $mut2 = Join-Path $tmp 'mut-exit.ps1'
    $needle2 = '    $script:AgentqTrackExit = $LASTEXITCODE'
    Check '8 the mutation target line exists in the module' ($src.Contains($needle2)) 'needle not found'
    WriteText $mut2 ($src.Replace($needle2, '    $script:AgentqTrackExit = 0'))
    $child2 = Join-Path $tmp 'child-exit.ps1'
    WriteText $child2 (@'
param([string]$Mod,[string]$Root)
. $Mod
$script:AgentqTrackModuleRoot = $Root   # the copy lives in %TEMP%; point the resolver at the real ps\bin
Invoke-AgentqTrackerPlan -Arguments @('show','--session','__no_such_session__')
exit $script:AgentqTrackExit
'@)
    $ErrorActionPreference = 'Continue'   # the child propagates the tool's stderr (5.1: not while 'Stop')
    & $hostExe -NoProfile -File $child2 -Mod $mut2 -Root $binDir 1>$null 2>$null
    Check '8a swallowing the exit code reports 0 where the real CLI reports 2, so the exit checks are load-bearing' ($LASTEXITCODE -eq 0) "mutated exit=$LASTEXITCODE (real is 2)"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
