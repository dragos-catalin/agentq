# agentq-trackers.ps1 - the three tracker verbs for the agentq dispatcher.
#
# WHY THIS IS A SEPARATE FILE, and not a case dropped into agentq.ps1. The tracking/resume store is
# implemented ONCE, in tools/track.mjs: portable Node, no PowerShell, no dependency, so it runs in any
# clone, any agentq slot, any cloud workspace on any OS. These verbs must NOT reimplement any of it -
# each resolves the repo root, execs `node <repo>/tools/track.mjs <sub>` with the caller's arguments
# untouched, and hands back the tool's own exit code. ps/bin/agentq.ps1 is a live trust surface several
# sessions edit at once, so the wiring is ONE line the owner adds (the exact line is at the bottom of
# this file); this module is additive and touches nothing else.
#
# Entry points (dot-sourced, then called from the verb switch):
#   Invoke-AgentqTrackers     -> node tools/track.mjs status <args...>   (the tracker index / drift)
#   Invoke-AgentqTrackerPlan  -> node tools/track.mjs plan   <args...>   (the session plan record)
#   Invoke-AgentqTrackerTask  -> node tools/track.mjs task   <args...>   (claimable tasks)
#   Invoke-AgentqTrackerVerb  -> the one-line dispatcher: -Verb trackers|plan|task
#
# Each writes the tool's stdout/stderr through UNCHANGED and sets $script:AgentqTrackExit to the tool's
# exit code (0 ok; 2 bad use / missing index / missing plan / claim held; 3 no ready task; n = drift
# findings, capped 255 by the tool). THIS MODULE NEVER CALLS `exit` - the caller does
# `exit $script:AgentqTrackExit` once per call, so a test can dot-source it and call the functions
# in-process without killing the runner.

# Resolve the module's own directory ONCE at load, the same way agentq.ps1 resolves the files beside
# itself: this file lives in <repo>\ps\bin, next to agentq.ps1, so the repo root is two levels up.
# Captured here (not read inside Get-AgentqTrackCliPath) so the value is the module file's own location
# regardless of what a caller's scope does with $PSScriptRoot. Never hardcode a path, so the module
# works from a clone, a hard-linked worktree slot or a cloud checkout.
$script:AgentqTrackModuleRoot = $PSScriptRoot
$script:AgentqTrackExit = 0

function Get-AgentqTrackCliPath {
    $root = Split-Path -Parent (Split-Path -Parent $script:AgentqTrackModuleRoot)
    Join-Path (Join-Path $root 'tools') 'track.mjs'
}

# The one place a verb shells out. Resolves the CLI, guards the two things that would otherwise throw
# (a missing CLI, a missing node) with a ONE-LINE error and the tool's own usage exit code (2), then
# runs the tool and records its exit code. Nothing is captured or reformatted: `& node @sa` streams the
# tool's own bytes to this process's stdout/stderr, so an agent reading the output sees exactly what the
# CLI printed - which is what makes `agentq trackers` and `node tools/track.mjs status` agree.
function Invoke-AgentqTrackCli {
    param(
        [Parameter(Mandatory = $true)][string]$Sub,
        [string[]]$Arguments = @()
    )
    $cli = Get-AgentqTrackCliPath
    if (-not (Test-Path -LiteralPath $cli)) {
        [Console]::Error.WriteLine("agentq: tracking store not found at '$cli' (expected <repo>\tools\track.mjs)")
        $script:AgentqTrackExit = 2
        return
    }
    if (-not (Get-Command -Name node -ErrorAction SilentlyContinue)) {
        [Console]::Error.WriteLine('agentq: node is required for the tracking store but was not found on PATH')
        $script:AgentqTrackExit = 2
        return
    }
    $sa = @($cli, $Sub)
    if ($Arguments -and $Arguments.Count -gt 0) { $sa += $Arguments }
    & node @sa
    $script:AgentqTrackExit = $LASTEXITCODE
}

# `agentq trackers [-- <args>]` - the tracker index: repo/item counts and the drift total. Maps to the
# tool's `status` (track.mjs has no `trackers` subcommand; status IS the "which trackers exist and do
# they agree" view). --json prints the raw index. The tool's `roster`, `export`, `import` and `drift`
# subcommands are NOT reachable through these three verbs (see the footer note).
function Invoke-AgentqTrackers {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    Invoke-AgentqTrackCli -Sub 'status' -Arguments $Arguments
}

# `agentq plan [-- <args>]` - the per-session plan record at <state>\chats\<session>.plan.json. The
# sub-verb and its flags are passed through untouched: `plan -- set --session s --goal x`,
# `plan -- show --session s [--json]`. A session with no plan file degrades cleanly - the tool prints
# one line ("no plan for session ...") and exits 2; this module does not invent a writer for it.
function Invoke-AgentqTrackerPlan {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    Invoke-AgentqTrackCli -Sub 'plan' -Arguments $Arguments
}

# `agentq task [-- <args>]` - a claimable unit at <state>\tasks\<id>.json. Sub-verbs pass through:
# add | claim | next | block | done | show | list. An unknown sub-verb is the tool's to refuse (it
# names the valid ones and exits 2).
function Invoke-AgentqTrackerTask {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    Invoke-AgentqTrackCli -Sub 'task' -Arguments $Arguments
}

# The dispatcher the one-line wiring calls. -Verb is the agentq verb name (lower-cased again here so a
# case-varied verb still resolves). An unknown verb here is a wiring bug, not a user mistake, so it
# names the three it knows and exits 2.
function Invoke-AgentqTrackerVerb {
    param(
        [Parameter(Mandatory = $true)][string]$Verb,
        [string[]]$Arguments = @()
    )
    switch ($Verb.ToLowerInvariant()) {
        'trackers' { Invoke-AgentqTrackers -Arguments $Arguments }
        'plan' { Invoke-AgentqTrackerPlan -Arguments $Arguments }
        'task' { Invoke-AgentqTrackerTask -Arguments $Arguments }
        default {
            [Console]::Error.WriteLine("agentq: internal - no tracker verb '$Verb' (expected trackers | plan | task)")
            $script:AgentqTrackExit = 2
        }
    }
}

# ---------------------------------------------------------------------------------------------------
# THE WIRING (the owner adds this - it is the SUM of the change to agentq.ps1). ONE line, added as a
# clause inside the `switch ($Verb.ToLowerInvariant())` block, anywhere before its `default`:
#
#   { $_ -in 'trackers','plan','task' } { . (Join-Path $PSScriptRoot 'agentq-trackers.ps1'); Invoke-AgentqTrackerVerb -Verb $_ -Arguments $Rest; exit $script:AgentqTrackExit }
#
# `$_` is the switch's value (the lower-cased verb); `$Rest` is everything the caller put after `--`,
# which is the only channel agentq.ps1's argument parser leaves untouched. Usage therefore is:
#   agentq trackers -- --json
#   agentq plan -- show --session <id> [--json]
#   agentq task -- list [--json]
# and the matching one-line help entry for $AqHelp:
#   'trackers' = @{ g = 'Tracking'; u = 'trackers [-- --json]'; d = 'tracker index: repo/item counts and drift (tools/track.mjs status)'; e = 'agentq trackers -- --json' }
#   'plan'     = @{ g = 'Tracking'; u = 'plan -- set|show --session <id> [--goal s] [--json]'; d = 'the per-session plan record (goal/doneMeans/next/roster/jobs/todos)'; e = 'agentq plan -- show --session $env:AGENTQ_SESSION' }
#   'task'     = @{ g = 'Tracking'; u = 'task -- add|claim|next|block|done|show|list [flags]'; d = 'a claimable task; claim is atomic across agents, next skips open dependencies'; e = 'agentq task -- list --json' }
# ---------------------------------------------------------------------------------------------------
