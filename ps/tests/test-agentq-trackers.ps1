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

    # ---- 9-15. `trackers push` - the ONE sub-verb that is not a pass-through to the Node tool -------
    # A raw TCP listener in a child runspace is a real HTTP/1.1 exchange (no URL ACL, no admin, no
    # mock): it records the request line, headers and body the module actually sent, then answers with
    # the status the test asks for. Both the happy path and a refusal are therefore exercised end to end
    # and the assertions are about the WIRE, not about a function having been called.
    function Start-FakeHub {
        param([int]$Status, [string]$Reason, [string]$RespBody)
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $script:HubPort = ([Net.IPEndPoint]$listener.LocalEndpoint).Port
        $script:HubRec = Join-Path $tmp ("hub-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + ".txt")
        $rs = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(); $rs.Open()
        $ps = [Management.Automation.PowerShell]::Create(); $ps.Runspace = $rs
        $null = $ps.AddScript({
            param($listener, $status, $reason, $body, $recFile)
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                # One byte at a time is plenty for a request head and keeps the framing unambiguous.
                $head = [Text.StringBuilder]::new()
                $one = New-Object byte[] 1
                while ($true) {
                    $n = $stream.Read($one, 0, 1); if ($n -le 0) { break }
                    $null = $head.Append([char]$one[0])
                    if ($head.Length -ge 4 -and $head.ToString($head.Length - 4, 4) -eq "`r`n`r`n") { break }
                }
                $htext = $head.ToString()
                if ($htext -match '(?i)Expect:\s*100-continue') {
                    # Windows PowerShell 5.1 sends Expect: 100-continue by default; a server that ignores
                    # it makes the client wait out its own timeout, so answer it.
                    $cont = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 100 Continue`r`n`r`n")
                    $stream.Write($cont, 0, $cont.Length); $stream.Flush()
                }
                $len = 0
                foreach ($line in ($htext -split "`r`n")) { if ($line -match '^Content-Length:\s*(\d+)') { $len = [int]$Matches[1] } }
                $bytes = New-Object IO.MemoryStream
                $buf = New-Object byte[] 65536
                $left = $len
                while ($left -gt 0) {
                    $n = $stream.Read($buf, 0, [Math]::Min($buf.Length, $left)); if ($n -le 0) { break }
                    $bytes.Write($buf, 0, $n); $left -= $n
                }
                [IO.File]::WriteAllText($recFile, ($htext + "`n---BODY---`n" + [Text.Encoding]::UTF8.GetString($bytes.ToArray())))
                $rb = [Text.Encoding]::UTF8.GetBytes($body)
                $respHead = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status $reason`r`nContent-Type: application/json`r`nContent-Length: $($rb.Length)`r`nConnection: close`r`n`r`n")
                $stream.Write($respHead, 0, $respHead.Length); $stream.Write($rb, 0, $rb.Length); $stream.Flush()
            } finally { $client.Close(); $listener.Stop() }
        })
        foreach ($a in @($listener, $Status, $Reason, $RespBody, $script:HubRec)) { $null = $ps.AddArgument($a) }
        $script:HubPS = $ps; $script:HubRS = $rs; $script:HubHandle = $ps.BeginInvoke()
    }
    function Stop-FakeHub {
        if ($script:HubPS -and $script:HubHandle) {
            try { $null = $script:HubHandle.AsyncWaitHandle.WaitOne(5000) } catch { }
            try { if ($script:HubHandle.IsCompleted) { $null = $script:HubPS.EndInvoke($script:HubHandle) } else { $script:HubPS.Stop() } } catch { }
            try { $script:HubPS.Dispose() } catch { }
        }
        if ($script:HubRS) { try { $script:HubRS.Close() } catch { } }
        $script:HubPS = $null; $script:HubRS = $null; $script:HubHandle = $null
    }
    function HubBody([string]$rec) { (($rec -split '---BODY---')[-1]) }

    # The module reports on [Console]::Error, which writes to the PROCESS stderr handle and therefore
    # bypasses an in-process `2>&1` entirely. A child pwsh makes it a native child, whose stderr IS
    # capturable, so the "say it honestly" assertions below actually read the line the user will see.
    $childVerb = Join-Path $tmp 'child-verb.ps1'
    WriteText $childVerb (@'
param([string]$Mod,[string]$Root,[string]$Verb,[string]$ArgsLine)
. $Mod
$script:AgentqTrackModuleRoot = $Root
$trackArgs = @()
if ($ArgsLine) { $trackArgs = $ArgsLine -split ' ' }
Invoke-AgentqTrackerVerb -Verb $Verb -Arguments $trackArgs
exit $script:AgentqTrackExit
'@)
    function ChildRun([string]$Verb, [string[]]$TrackArgs) {
        $ErrorActionPreference = 'Continue'
        $o = @(& $hostExe -NoProfile -File $childVerb -Mod $Module -Root $binDir -Verb $Verb -ArgsLine ($TrackArgs -join ' ') 2>&1 | ForEach-Object { "$_" }) -join "`n"
        [pscustomobject]@{ Text = $o; Code = $LASTEXITCODE }
    }

    # -DryRun must PRINT and not POST. The -Hub below is a port nothing listens on, so a request would
    # exit 3 - exit 0 is the proof that the network was never touched.
    Remove-Item Env:\CODAI_HUB_KEY -ErrorAction SilentlyContinue
    $keyFile = Join-Path $tmp 'push.key'
    WriteText $keyFile 'codai_test_key_abcdef'
    $dead = 'http://127.0.0.1:9/v1'
    $m = ModuleRun 'trackers' @('push', '-DryRun', '-Hub', $dead, '-KeyFile', $keyFile)
    Check '9 push -DryRun exits 0 without touching an unreachable hub' ($m.Code -eq 0) "exit=$($m.Code) $($m.Text)"
    Check '9a -DryRun names the ingest URL, the size and the repo count' ($m.Text -match 'DRYRUN' -and $m.Text -match '/v1/trackers/ingest' -and $m.Text -match '1 repo\(s\)') $m.Text

    # ---- 10. the wire contract of a successful push --------------------------------------------------
    Start-FakeHub -Status 200 -Reason 'OK' -RespBody '{"count":1}'
    $m = ModuleRun 'trackers' @('push', '-Hub', "http://127.0.0.1:$($script:HubPort)/v1", '-KeyFile', $keyFile)
    Stop-FakeHub
    $rec = if (Test-Path -LiteralPath $script:HubRec) { [IO.File]::ReadAllText($script:HubRec) } else { '' }
    Check '10 push exits 0 on a 2xx' ($m.Code -eq 0) "exit=$($m.Code) $($m.Text)"
    Check '10a the hub received POST /v1/trackers/ingest' ($rec -match '^POST /v1/trackers/ingest ') ($rec -split "`n")[0]
    Check '10b the request carried the machine key as a bearer token' ($rec -match '(?i)authorization: Bearer codai_test_key_abcdef') ''
    Check '10c the body was the local index verbatim (repos + the repo name)' ($rec -match '"repos"' -and $rec -match '"demo"') (HubBody $rec).Substring(0, [Math]::Min(120, (HubBody $rec).Length))
    Check '10d the success line reports what was sent' ($m.Text -match 'ok: pushed 1 repo\(s\)') $m.Text

    # ---- 11. a refusal is reported and is NOT a success -----------------------------------------------
    Start-FakeHub -Status 422 -Reason 'Unprocessable Entity' -RespBody '{"error":{"message":"repos[0].repo is required"}}'
    $c = ChildRun 'trackers' @('push', '-Hub', "http://127.0.0.1:$($script:HubPort)/v1", '-KeyFile', $keyFile)
    Stop-FakeHub
    Check '11 a 422 exits non-zero' ($c.Code -ne 0) "exit=$($c.Code) $($c.Text)"
    Check '11a the refusal names the status code' ($c.Text -match 'refused \(422\)') $c.Text

    # ---- 12/13. the cheap refusals happen before any request ------------------------------------------
    $emptyHome = Join-Path $tmp 'emptyhome'
    New-Item -ItemType Directory -Force $emptyHome | Out-Null
    $savedHome = $env:AGENTQ_HOME
    $env:AGENTQ_HOME = $emptyHome
    $c = ChildRun 'trackers' @('push', '-Hub', $dead, '-KeyFile', $keyFile)
    Check '12 a missing index exits 2' ($c.Code -eq 2) "exit=$($c.Code) $($c.Text)"
    Check '12a the missing-index line names the path' ($c.Text -match 'no index at') $c.Text
    $env:AGENTQ_HOME = $savedHome
    $c = ChildRun 'trackers' @('push', '-Hub', $dead, '-KeyFile', (Join-Path $tmp 'absent.key'))
    Check '13 a missing key exits 2 (after the index exists)' ($c.Code -eq 2) "exit=$($c.Code) $($c.Text)"
    Check '13a the missing-key line names the file it looked for' ($c.Text -match 'no key at') $c.Text

    # ---- 14. -Repo narrows the payload, and a filter that matches nothing is a usage error -------------
    $twoHome = Join-Path $tmp 'twohome'
    New-Item -ItemType Directory -Force (Join-Path $twoHome 'trackers') | Out-Null
    $two = [ordered]@{
        generatedAt = '2026-01-01T00:00:00.000Z'
        repos = @(
            [ordered]@{ repo = 'alpha'; root = 'X:\a'; trackers = @(); drift = @() }
            [ordered]@{ repo = 'beta'; root = 'X:\b'; trackers = @(); drift = @() }
        )
    }
    WriteText (Join-Path $twoHome 'trackers\index.json') ($two | ConvertTo-Json -Depth 10)
    $env:AGENTQ_HOME = $twoHome
    Start-FakeHub -Status 200 -Reason 'OK' -RespBody '{"count":1}'
    $hub = "http://127.0.0.1:$($script:HubPort)/v1"
    $m = ModuleRun 'trackers' @('push', '-Repo', 'alpha', '-Hub', $hub, '-KeyFile', $keyFile)
    Stop-FakeHub
    $rec = if (Test-Path -LiteralPath $script:HubRec) { [IO.File]::ReadAllText($script:HubRec) } else { '' }
    Check '14 -Repo alpha exits 0' ($m.Code -eq 0) "exit=$($m.Code) $($m.Text)"
    Check '14a -Repo kept alpha and dropped beta from the body' ((HubBody $rec) -match '"alpha"' -and (HubBody $rec) -notmatch '"beta"') (HubBody $rec)
    $m = ModuleRun 'trackers' @('push', '-Repo', 'nosuchrepo', '-Hub', $hub, '-KeyFile', $keyFile)
    Check '14b a -Repo filter that matches nothing exits 2' ($m.Code -eq 2) "exit=$($m.Code) $($m.Text)"
    $c = ChildRun 'trackers' @('push', '-Bogus')
    Check '14c an unknown push flag is a usage error (exit 2, no request)' ($c.Code -eq 2 -and $c.Text -match 'unknown argument') "exit=$($c.Code) $($c.Text)"
    $env:AGENTQ_HOME = $savedHome

    # ---- 15. MUTATION CONTROL 3: the non-2xx exit is load-bearing --------------------------------------
    # A copy that reports success on a refusal must exit 0 where the real module exits 4. Without this,
    # "push exits non-zero on a 422" could pass for the wrong reason (e.g. an unrelated crash).
    $needle3 = '            $script:AgentqTrackExit = 4'
    $mut3 = Join-Path $tmp 'mut-push-refusal.ps1'
    Check '15 the mutation target line exists in the module' ($src.Contains($needle3)) 'needle not found'
    WriteText $mut3 ($src.Replace($needle3, '            $script:AgentqTrackExit = 0'))
    $child3 = Join-Path $tmp 'child-push.ps1'
    WriteText $child3 (@'
param([string]$Mod,[string]$Root,[string]$Hub,[string]$Key)
. $Mod
$script:AgentqTrackModuleRoot = $Root   # the copy lives in %TEMP%; point the resolver at the real ps\bin
Invoke-AgentqTrackers -Arguments @('push','-Hub',$Hub,'-KeyFile',$Key)
exit $script:AgentqTrackExit
'@)
    Start-FakeHub -Status 422 -Reason 'Unprocessable Entity' -RespBody '{"error":{"message":"no"}}'
    $ErrorActionPreference = 'Continue'   # the child writes the refusal to stderr
    & $hostExe -NoProfile -File $child3 -Mod $mut3 -Root $binDir -Hub "http://127.0.0.1:$($script:HubPort)/v1" -Key $keyFile 1>$null 2>$null
    $mutExit = $LASTEXITCODE
    Stop-FakeHub
    Check '15a reporting 0 on a refusal makes the exit assertion go red (the real module exits 4)' ($mutExit -eq 0) "mutated exit=$mutExit (real is 4)"

    # ---- 16. `push` is reachable through the REAL dispatcher, exactly as documented --------------------
    # A perfect module is not a usable verb: agentq.ps1's parser refuses every bare positional, so
    # `agentq trackers push ...` died with "unknown argument 'push' (put the command after '--')" until a
    # branch scoped to that one word forwarded the tail. This section drives ps/bin/agentq.ps1 itself,
    # and 16b is the vacuity control: a DIFFERENT bare word is still refused, so "push is reachable"
    # cannot be passing because the parser simply stopped refusing positionals.
    $AqPath = Join-Path $binDir 'agentq.ps1'
    $env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ADMISSION = '1'
    $env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
    $env:AGENTQ_SESSION = 'test-trackers'
    function DispatcherRun([string[]]$Argv) {
        $ErrorActionPreference = 'Continue'
        $o = @(& $hostExe -NoProfile -File $AqPath @Argv 2>&1 | ForEach-Object { "$_" }) -join "`n"
        [pscustomobject]@{ Text = $o; Code = $LASTEXITCODE }
    }
    $d1 = DispatcherRun @('trackers', 'push', '-DryRun', '-KeyFile', $keyFile)
    Check '16 the dispatcher reaches push, and -DryRun exits 0' ($d1.Code -eq 0 -and $d1.Text -match 'DRYRUN') "exit=$($d1.Code) $($d1.Text)"
    Check '16a the forwarded tail was parsed by push (it named the ingest URL)' ($d1.Text -match '/trackers/ingest') $d1.Text
    $d2 = DispatcherRun @('trackers', 'bubble', '-KeyFile', $keyFile)
    Check '16b another bare word is still refused, so the allowance is scoped to push' ($d2.Code -eq 2 -and $d2.Text -match "unknown argument 'bubble'") "exit=$($d2.Code) $($d2.Text)"
    $d3 = DispatcherRun @('trackers', '--', 'push', '-DryRun', '-KeyFile', $keyFile)
    Check '16c the `-- push` spelling keeps working' ($d3.Code -eq 0 -and $d3.Text -match 'DRYRUN') "exit=$($d3.Code) $($d3.Text)"
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
