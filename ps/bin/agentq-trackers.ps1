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
#   Invoke-AgentqTrackersPush -> `trackers push`: POST the local index to <Hub>/trackers/ingest
#
# ONE exception to the pass-through rule: `agentq trackers push` is NOT `node tools/track.mjs ...`. The
# upload needs a machine key (DPAPI) and an HTTP POST to the Codwen gateway, so it lives here; the Node
# tool stays strictly offline and portable. push REIMPLEMENTS NOTHING of the store - it reads the very
# file the `trackers` verb reads and sends it verbatim, so the hub holds exactly what a local reader sees.
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
    # TWO shapes, one rule. Installed, the module sits in <dst>\bin (one level under the install root,
    # where ~\.copilot is the root), so two levels up leaves the tree entirely - `C:\Users\<user>\tools`
    # instead of `<dst>\tools`. The tool is therefore looked for
    #   1. BESIDE the module - ps\bin\track.mjs in a checkout, <dst>\bin\track.mjs once installed, which
    #      is the same place agentq-store.mjs and agentq-slo.mjs already live - and
    #   2. at the repository root, tools\track.mjs, where the canonical copy lives in a checkout.
    # Order matters: an installed engine must never depend on a checkout being present, and a checkout
    # copy must not shadow the installed one. The candidate is built from AgentqTrackModuleRoot, not
    # $PSScriptRoot: that variable is the module's own directory by definition, and a caller (the tracker
    # suite's mutation harness) may re-point it at the module's real directory while the code runs from a
    # copy in %TEMP%. Reading $PSScriptRoot there looked for track.mjs in %TEMP% and reported "store not
    # found" - a mutation control that fails for the wrong reason is worse than no control.
    # The fallback is returned even when neither exists, so the caller's error names the path a reader can
    # actually find and edit.
    $sibling = Join-Path $script:AgentqTrackModuleRoot 'track.mjs'
    if (Test-Path -LiteralPath $sibling) { return $sibling }
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

# The index `tracker-lint.mjs --scan` writes: <root>/trackers/index.json, where root is $AGENTQ_HOME or
# ~/.codai/coord. The SAME resolution agentq.ps1 and agentq-sync.ps1 use, so a push uploads the exact
# file the Vitals page and `agentq trackers` read - never a re-serialised approximation of it.
function Get-AgentqTrackIndexPath {
    $root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
    Join-Path (Join-Path $root 'trackers') 'index.json'
}

# The DPAPI-hex key convention, copied from ps/bin/devbox-team-sync.ps1 - the one place on this machine
# it is defined: a `codai...` value is the key verbatim (a short dev/test key), anything else is a hex
# dump of a CurrentUser-DPAPI blob. CODAI_HUB_KEY wins (tests, and a caller that holds the key in its
# own environment). A missing or unreadable file is $null, never a crash, so the caller can print one
# honest line and exit non-zero. The key is NEVER printed by this module.
function Get-AgentqPushKey {
    param([Parameter(Mandatory = $true)][string]$KeyFile)
    if ($env:CODAI_HUB_KEY) { return $env:CODAI_HUB_KEY }
    if (-not (Test-Path -LiteralPath $KeyFile)) { return $null }
    try { $txt = ([IO.File]::ReadAllText($KeyFile)).Trim() } catch { return $null }
    if ($txt -like 'codai*') { return $txt }
    if ($txt.Length -eq 0 -or ($txt.Length % 2) -ne 0) { return $null }
    try {
        Add-Type -AssemblyName System.Security
        $raw = [byte[]]::new($txt.Length / 2)
        for ($i = 0; $i -lt $raw.Length; $i++) { $raw[$i] = [Convert]::ToByte($txt.Substring($i * 2, 2), 16) }
        [Text.Encoding]::Unicode.GetString([Security.Cryptography.ProtectedData]::Unprotect($raw, $null, 'CurrentUser')).Trim()
    } catch { $null }
}

function Write-AgentqPushUsage {
    [Console]::Error.WriteLine('agentq trackers push [-Hub <url>] [-KeyFile <path>] [-DryRun] [-Repo <name>]')
    [Console]::Error.WriteLine('  POSTs the local tracker index to <url>/trackers/ingest with the machine key.')
    [Console]::Error.WriteLine('  -Hub      gateway base URL (default https://ai.codai.ro/v1)')
    [Console]::Error.WriteLine('  -KeyFile  DPAPI-hex key file (default ~/.codai/copilot.key); CODAI_HUB_KEY overrides')
    [Console]::Error.WriteLine('  -DryRun   print what would be sent, make no request')
    [Console]::Error.WriteLine('  -Repo     push only these repositories (repeatable); default: every repo in the index')
}

# `agentq trackers push [-Hub <url>] [-KeyFile <path>] [-DryRun] [-Repo <name>]`
#   POST <Hub>/trackers/ingest with the local index (the file the `trackers` verb reads), authorised by
#   the machine key. The body IS the index, so the hub stores exactly what a local reader sees; a
#   `-Repo` filter re-serialises only when the caller asks for a subset.
#   Exit: 0 sent (or printed, with -DryRun); 2 no index / no key / bad use / an empty -Repo filter;
#         3 the hub could not be reached; 4 the hub refused (a non-2xx status).
function Invoke-AgentqTrackersPush {
    param([string[]]$Arguments = @())

    $Hub = 'https://ai.codai.ro/v1'
    $KeyFile = Join-Path $HOME '.codai/copilot.key'
    $dryRun = $false
    $include = @()
    # @($null) is an empty array in PowerShell, but be explicit: an empty argument list must reach the
    # "no flags" path, never the unknown-argument branch with a phantom '' flag.
    $args0 = @()
    if ($Arguments) { $args0 = @($Arguments) }
    for ($i = 0; $i -lt $args0.Count; $i++) {
        $flag = "$($args0[$i])".ToLowerInvariant()
        if ($flag -in '-hub', '-keyfile', '-repo') {
            if (($i + 1) -ge $args0.Count) { Write-AgentqPushUsage; $script:AgentqTrackExit = 2; return }
            $i++
            switch ($flag) {
                '-hub' { $Hub = "$($args0[$i])" }
                '-keyfile' { $KeyFile = "$($args0[$i])" }
                '-repo' { $include += "$($args0[$i])" }
            }
        } elseif ($flag -eq '-dryrun') {
            $dryRun = $true
        } else {
            [Console]::Error.WriteLine("agentq trackers push: unknown argument '$($args0[$i])'")
            Write-AgentqPushUsage
            $script:AgentqTrackExit = 2
            return
        }
    }

    $idxPath = Get-AgentqTrackIndexPath
    if (-not (Test-Path -LiteralPath $idxPath)) {
        [Console]::Error.WriteLine("agentq trackers push: no index at '$idxPath' (run the scan that writes it first)")
        $script:AgentqTrackExit = 2
        return
    }
    $raw = $null
    try { $raw = [IO.File]::ReadAllText($idxPath) } catch {
        [Console]::Error.WriteLine("agentq trackers push: cannot read '$idxPath': $($_.Exception.Message)")
        $script:AgentqTrackExit = 2
        return
    }
    # A leading BOM would make the gateway's JSON.parse throw, and node's writeFileSync never adds one -
    # strip it defensively so an editor that saved the index cannot break every push.
    $raw = $raw.TrimStart([char]0xFEFF)
    $index = $null
    try { $index = $raw | ConvertFrom-Json } catch {
        [Console]::Error.WriteLine("agentq trackers push: '$idxPath' is not JSON: $($_.Exception.Message)")
        $script:AgentqTrackExit = 2
        return
    }
    if (-not $index -or -not ($index.PSObject.Properties.Name -contains 'repos')) {
        [Console]::Error.WriteLine("agentq trackers push: '$idxPath' has no 'repos' array")
        $script:AgentqTrackExit = 2
        return
    }

    if ($include.Count -gt 0) {
        $kept = @($index.repos | Where-Object { $include -contains "$($_.repo)" })
        if ($kept.Count -eq 0) {
            [Console]::Error.WriteLine("agentq trackers push: no repository in the index matches -Repo $($include -join ', ')")
            $script:AgentqTrackExit = 2
            return
        }
        $index.repos = $kept
        # Depth 100: the index nests repos -> trackers -> items -> counts, and ConvertTo-Json defaults to 2.
        $body = [Text.Encoding]::UTF8.GetBytes(($index | ConvertTo-Json -Depth 100 -Compress))
    } else {
        # The whole index, byte for byte: no re-serialisation, so the hub receives what the file says.
        $body = [Text.Encoding]::UTF8.GetBytes($raw)
    }
    $repoCount = @($index.repos).Count
    $url = ($Hub.TrimEnd('/')) + '/trackers/ingest'

    if ($dryRun) {
        Write-Output ("DRYRUN would POST {0} ({1} repo(s), {2} bytes) using the key from '{3}'" -f $url, $repoCount, $body.Length, $KeyFile)
        $script:AgentqTrackExit = 0
        return
    }

    $key = Get-AgentqPushKey -KeyFile $KeyFile
    if (-not $key) {
        [Console]::Error.WriteLine("agentq trackers push: no key at '$KeyFile' (DPAPI-hex or a codai... value; set CODAI_HUB_KEY to override)")
        $script:AgentqTrackExit = 2
        return
    }

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $url -Headers @{ Authorization = "Bearer $key" } `
            -ContentType 'application/json' -Body $body -TimeoutSec 180 -ErrorAction Stop
        Write-Output ("ok: pushed {0} repo(s) to {1}" -f $repoCount, $url)
        $script:AgentqTrackExit = 0
    } catch {
        $status = 0
        try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
        $msg = "$($_.Exception.Message)"
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = "$($_.ErrorDetails.Message)" }
        if ($status -gt 0) {
            [Console]::Error.WriteLine("agentq trackers push: hub refused ($status): $msg")
            $script:AgentqTrackExit = 4
        } else {
            [Console]::Error.WriteLine("agentq trackers push: could not reach $url : $msg")
            $script:AgentqTrackExit = 3
        }
    }
}

# `agentq trackers [-- <args>]` - the tracker index: repo/item counts and the drift total. Maps to the
# tool's `status` (track.mjs has no `trackers` subcommand; status IS the "which trackers exist and do
# they agree" view). --json prints the raw index. `push` is the ONE sub-verb handled here rather than
# forwarded (see its own doc above); everything else passes through untouched. The tool's `roster`,
# `export`, `import` and `drift` subcommands are NOT reachable through these three verbs (footer note).
function Invoke-AgentqTrackers {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    if ($Arguments -and $Arguments.Count -gt 0 -and "$($Arguments[0])".ToLowerInvariant() -eq 'push') {
        Invoke-AgentqTrackersPush -Arguments @($Arguments | Select-Object -Skip 1)
        return
    }
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
#   agentq trackers push [-Hub <url>] [-KeyFile <path>] [-DryRun] [-Repo <name>]   (no `--`; handled here)
#   agentq plan -- show --session <id> [--json]
#   agentq task -- list [--json]
# and the matching one-line help entry for $AqHelp:
#   'trackers' = @{ g = 'Tracking'; u = 'trackers [push [-Hub <url>] [-KeyFile <path>] [-DryRun] [-Repo <name>]] [-- --json]'; d = 'tracker index: repo/item counts and drift (tools/track.mjs status); push uploads it to the Codwen hub'; e = 'agentq trackers -- --json  |  agentq trackers push -DryRun' }
#   'plan'     = @{ g = 'Tracking'; u = 'plan -- set|show --session <id> [--goal s] [--json]'; d = 'the per-session plan record (goal/doneMeans/next/roster/jobs/todos)'; e = 'agentq plan -- show --session $env:AGENTQ_SESSION' }
#   'task'     = @{ g = 'Tracking'; u = 'task -- add|claim|next|block|done|show|list [flags]'; d = 'a claimable task; claim is atomic across agents, next skips open dependencies'; e = 'agentq task -- list --json' }
# ---------------------------------------------------------------------------------------------------
