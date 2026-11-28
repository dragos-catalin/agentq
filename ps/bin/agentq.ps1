<#
agentq — cross-agent coordination for builds, deploys, installs and commits on this machine.

NEW HERE? RUN `agentq help` FIRST. It prints every verb (one line each, grouped) and `agentq help
<verb>` prints that verb's usage plus a copy-paste example (`agentq help land`). Unknown verbs and
unknown flags print the same index and exit 2, so a guess costs one call, not a search. The list below
is the long form of the same thing; it is not the only way in.

WHY: many agents share one clone (and its worktrees). Before this, every lock was
poll-and-race, per worktree, with no reason field and no shared history, so builds
corrupted each other's .next/.turbo, deploys raced, a commit swept another agent's
staged files, and nobody could see who held what or why (incidents 2026-09-03..27).

MODEL
  * A RESOURCE is a string: build:<repo>, build:machine (capacity 2), install:<repo>,
    commit:<repo>, deploy:<repo>:<target>, or anything you name. <repo> is the name of
    the COMMON git dir's parent, so every worktree of one repo shares its resources.
  * A TICKET is a waiter/holder: one JSON file per ticket in
    ~/.codai/coord/queues/<resource>/<seq>-<id>.json. FIFO order = seq, allocated under a
    named OS mutex (Global\agentq-<resource>) so two processes never get the same seq.
  * The first <capacity> live tickets in seq order HOLD the resource. The rest wait.
  * Liveness: holder pid + its process start time (PID-reuse safe) + a heartbeat file
    touched every 20 s by `run`. A dead pid is reaped at once; a heartbeat older than
    -StaleMin (default 10) marks the ticket STALE (visible in status, reason recorded);
    `agentq break` removes it with a reason.
  * A resource can be MARKED frozen|blocked with a reason (~/.codai/coord/marks/). `run`
    and `acquire` refuse a frozen/blocked resource and print who froze it and why. A
    `land:<repo>` mark older than `landFreezeMaxMin` (30) minutes is EXPIRED: the next
    land breaks it, records why, and proceeds (docs/RELEASE_TRAIN.md: never for a whole
    train). Incident/provider/deploy marks never expire.
  * Everything is appended to ~/.codai/coord/journal.jsonl (one JSON per line):
    queued, start, done(exit,dur), fail, break, mark, unmark, note, commit(sha,paths).
    `status`, `log`, `since` read it — this is how agents learn what others did.

COMMANDS (all accept -Repo <path>; default = current dir's repo. -ExpectRepo <path> or
          env AGENTQ_EXPECT_REPO refuses (exit 3) when the resolved repo differs — X-02)
  agentq run     -Resource build -Purpose "why" -- <command...>   queue, hold, run, release
                  -Resource may be a short kind (build|install|deploy:<target>|commit) —
                  expanded to <kind>:<repo>; build also takes build:machine (cap 2) and
                  waits for >= -MinFreeGB RAM (default 6).
  agentq commit  -Purpose "why" -Message "type(scope): msg" -Paths a,b [-NoPush]
                  under commit:<repo>: add+commit ONLY those paths, trailers
                  Agent-Session / Agent-Purpose, then fetch+merge+push with retry.
  agentq status  [-All] [-Json]    holders, waiters, stale, marks (this repo or all);
                                  -Json/--json prints the SAME data as JSON (see JSON OUTPUT)
  agentq log     [-Last 30] [-All] recent journal entries
  agentq since   [-Hours 12]       what changed in this repo: journal + git log
  agentq mark    -Resource R -State frozen|blocked -Reason "..."   (unmark: -State clear)
  agentq break   -Resource R [-Id <ticket>] -Reason "..."          remove a stale/stuck ticket
  agentq note    -Message "..."    free-form journal entry (handoffs, "don't touch X")
  agentq acquire / release         low-level (scripts): acquire prints the ticket id
  agentq lease   -Purpose "why" [-Slot task-2] [-Branch b] [-Ref r] [-Wait [-MaxMin n]]
                                  take a slot lease (ADR 0001); prints the slot path (exit 0).
                                  -Wait: poll for a free slot, bounded to -MaxMin minutes
                                  (default 5, never unbounded) -> exit 0 leased, 7 bound
                                  expired without a slot, 3 the slot is frozen/blocked.
                                  -Wait also works as a bounded "is a slot free?" probe: with -Wait,
                                  -Purpose may be omitted (a plain lease still requires it).

JSON OUTPUT (-Json / --json; `status --json` is the machine form of the == table. Keys are
  stable; other agents parse them. The plain table output is UNCHANGED when the flag is absent.)
    { agents, leases, releases, marks, tickets, load, bursts }
      agents   = the == AGENTS line: { limit, base, state (present|away|night|unknown|off), why,
                 inputIdleSec, sampleAgeSec, night, nightWindow, leased }
      leases   = the == SLOTS rows: { leaseId, repo, slot, role (the kind), state
                 (ok|chat|owner-gone|STALE), idleMin, chatIdleMin, branch, session (holder
                 terminal), purpose, path, pid, created, beat, alive, stale }
      releases = the == RELEASES rows: the release record (repo, target, state, sha, phase,
                 committed, follow, session, purpose, supersedeSha, pendingSha, exitCode, ...);
                 `phase` is the LAST checkpoint entered, not the step that failed - `exitCode` (when
                 recorded) is the run's own exit code and does not belong to any phase
      marks    = the == MARKS rows: { resource, state, at, session, reason }
      tickets  = the == QUEUES rows: { resource, role, lane, prio, state, ageMin, session,
                 purpose, id }
      load     = the == LOAD line: { enabled, saturated, probeMs, medianMs, samples, ageSec,
                 thresholdMs, src }
      bursts   = the == BURST lines: { resource, by, until, session, reason }

v3 SCHEDULER (devcloud F1, 2026-10-11)
  -Lane interactive|quick|gate|heavy|batch  (build default gate, others quick); -Priority -50..50.
  Waiters are ranked by lane base + priority + bumps + aging (+5 per agingMin waited), not FIFO.
  All tickets of one run are granted ATOMICALLY: nothing is held while any part still waits, so
  waiting for build:machine no longer blocks build:<repo>. Soft slots on build:machine:
  quick/interactive get `quickBurst` extra slots; non-batch jobs may run beside batch holders
  (batch runs at Idle CPU). Idle-yield: a holder whose process tree burned < idleCpuSec over
  idleYieldMin stops counting against the machine cap until CPU returns.
  agentq bump    [-Id t | -Session s] -By 20 -Reason "..."  raise MY waiting ticket; -Session/-Id target one explicitly (cap bumpMax)
  agentq burst   [-Resource build:machine] -By 1 -Minutes 30 -Reason "..."  temporary extra slot
                  (refused when RAM/commit headroom < 2x the gate; cap burstMax/burstMaxMin)
  agentq propose [-Reason "..."]  diagnose my wait and APPLY safe remedies (break dead/STALE >2x
                  holders, bump my long waits, short burst when RAM allows); prints the rest
  Overrides need -Reason (>= 8 chars), are journaled and limited to overridesPerHour per session.
  agentq metrics [-Hours 24] [-Json]   wait/hold p50/p90 per resource x lane x kind
  agentq rotate                        archive journal now (sweep does it above journalRotateMB)
  Knobs: bin/agentq-config.json (machineCap quickBurst agingMin idleYieldMin idleCpuSec bumpMax
  fairShare burstMax burstMaxMin overridesPerHour journalRotateMB). Plan: E:\gh\vmui\docs\devcloud\PLAN.md
  fairShare: true|false | { enabled, maxPerSession } - when >= 2 sessions compete on a resource with
  cap >= 2, waiters are interleaved by round over sessions and a session may hold ceil(cap/sessions)
  slots (ADR 0014 D4). AGENTQ_NO_FAIRSHARE=1 opts out for one call.

CLOUD PLACEMENT (devcloud F2, DC-037)
  agentq run -Resource build -Where local|cloud|auto [-Ws <name>] -Purpose x -- <cmd>
  cloud = run on the repo's warm workspace through agentq-cloud.ps1 (git delta upload, log stream,
  remote exit code; contract E:\gh\agentq\spec\job.md). No local tickets are taken.
  auto  = cloud when the repo has a workspace (config cloudWorkspaces) AND the command is a
  build/typecheck/test/lint kind AND (local build:machine is full, or free RAM/commit is below
  the gate, or the kind's local p50 hold >= cloudAutoMinSec). Otherwise local.
  Default = env AGENTQ_WHERE, else local. AGENTQ_WHERE=local is the opt-out everywhere.
  Journal: cloud-queued / cloud-done / cloud-fail (resource cloud:<ws>) + placement(where, why).
  Evidence: a run that reached the workspace writes the whole log into the TARGET repo as runs/<jobid>.log
  and appends ONE row to that repo's own run journal (docs/RUNS.md or RUNS.md, following its columns,
  idempotent by job id; a repo without one gets the log only, .gitignore is never edited).

STAGE 0 OF THE ORCHESTRATOR PLAN (ADR 0009, tracker OQ-001..012, 2026-11)
  status / log / metrics / doctor only READ the state folder (no reaping, no capacity rewrite, no notice
  consumed, no registry write). Reaping happens in working verbs and in `agentq sweep`.
  agentq probe [-Force] [-Json]   take a load sample now: start latency of a trivial process + seconds since
                  the last keyboard/mouse input. `status` prints it as == LOAD and == AGENTS.
  Admission by load (config `admission`): while the probe median is above probeMs, no new task lease and no
  second gate/heavy/batch build; quick/interactive are never held; held longer than maxHoldMin = admitted
  anyway (journal admission-hold / admission-override). AGENTQ_NO_ADMISSION=1 opts one call out.
  Agent limit (config `agentLimit`): the machine-wide limit on task leases follows owner presence and a
  night window (present / away / night); a value that is not set = taskSlotsMachine. Never stops a running
  lease. AGENTQ_NO_AGENT_LIMIT=1 opts one call out.
  Chat keep-alive: the per-tool-call hook binds a chat to the lease of a slot it works in and refreshes it on
  every later tool call of that chat; a chat active within leaseDeadIdleMin counts like a live owner shell.
  Land pre-gate: `agentq land` from a leased task slot runs the gate on the rebased result in that slot BEFORE
  taking the land ticket (exit 6 before the queue on failure). From the shared clone it takes a `scratch-N`
  slot for the length of the gate and gives it back; with no free slot - or one whose install is known to have
  failed - it skips the pre-gate and journals why. A tree that already passed a gate command is not gated
  again (green ledger, greenTtlHours). Config `landPregate`, `landPregateFromMain`, `landPregateScratchWaitMin`;
  AGENTQ_LAND_NO_PREGATE=1 off.
  agentq prune [-WhatIf] [-Days n] [-All] [-Json]   remove state nobody needs (also run by sweep).
  agentq doctor [-All] [-Src <checkout>/ps] [-Json] [-Only <check[,check]>] [-Quiet]
                 health report; exit 1 when a check fails. -Only runs just those checks (unknown name =
                 exit 2 listing the valid ones), -Quiet prints the findings only.
  agentq slo [-Hours 168] [-Json]  adds queue time, waits over 10 min, hook cost per day, start-probe buckets
                  and slots lost with a live chat.

EXIT CODES: 0 ok; command's own exit code for `run`; 3 = frozen/blocked or timed out;
2 = usage error; 7 = `lease -Wait` bound expired without a free slot.
#>
# Hand-rolled argument parsing: `pwsh -File agentq.ps1 run ... -- cmd -x` passes `--` and
# the command's own dashed flags to the script, which PowerShell's binder rejects
# ("parameter name '' is ambiguous"). Everything after the first `--` is the command.
$Verb = 'status'; $Resource = $null; $Purpose = $null; $Message = $null; $Paths = @()
$Repo = $null; $ExpectRepo = $null; $State = $null; $Reason = $null; $Id = $null
# -Session <id> (2026-11-23): tick the SELECTOR for `bump`. Bare `bump` matches the caller's own
# session; -Session names a session explicitly and -Id names one ticket, so a waiter can bump ONLY its
# own ticket instead of the sibling whose session the bare form happened to resolve to (the reported
# bug: `bump -By 20` from one session raised a land + a perf(gate) land to 105/100). Kept out of
# $script: - the script scope IS the top scope, so a $script: reset after the parse loop would wipe it
# (the 2026-11-22 class that silently dropped -Lane/-Priority/-Capacity).
$PickSession = $null
$Capacity = 1; $TimeoutMin = 60; $StaleMin = 10; $Last = 30; $Hours = 12; $MinFreeGB = 6
$All = $false; $NoPush = $false; $NoWait = $false; $Json = $false; $CapacityGiven = $false
$StaleOnly = $false; $IdleHours = [double]0; $Reclaim = $false; $Track = $false
# timings: a flag this dispatcher does not type itself is forwarded verbatim to agentq-timings.ps1, so a
# knob that module already supports (-LogDir, -Top, -AllSlots, -WorktreeRoot, -NoLastGreen) is reachable
# from `agentq timings` without a second edit here. `-Root` is deliberately NOT one of them: that name is
# prewarm's (it has its own case above) and would be swallowed there.
$TimingsExtra = @()
# bounded slot acquisition for `lease -Wait` (exit 7 on the bound; 0/3 otherwise).
$Wait = $false; $MaxMin = $null; $MaxMinGiven = $false
# v2 (ADR 0001): slots/leases, release runs, landing (implemented in agentq-v2.ps1).
$Slot = $null; $Role = $null; $WtPath = $null; $Branch = $null; $Onto = $null; $Gate = $null
# (c) owner 2026-11-28: `land -WaitShare [-WaitShareMin n]` waits (bounded, 15 min default) for the fair
# share to admit a land slot instead of refusing at once. The refusal itself is unchanged: on the bound it
# is still exit 3, nothing queued and no ticket held. Opt-in, so a land without the flag behaves as before.
$WaitShare = $false; $WaitShareMin = 15
# -RebaseOnConflict (2026-11-23): a land pick conflict normally means "rebase the topic and land again",
# but the merge is computed when the ticket reaches the head of the queue, so that advice cannot be
# followed while the ticket is still queued. With this flag land rebases the topic onto origin/<onto> in
# its own slot and retries the pick once. Off by default: without it the land path is unchanged.
$RebaseOnConflict = $false
# -Hold [-HoldMin n] (ADR 0012): the holder is running a long job OUTSIDE the slot and asks agentq to keep
# the lease until then (journalled, bounded). Without it a lease is reclaimed when its slot has seen no work
# for leaseIdleMin (45 min) / leaseOwnerIdleMin (90 min, live owner shell) - work, not "the chat is busy".
$Hold = $false; $HoldMin = $null
$FbKind = $null; $EvalSample = $false
# -Code <n> (release-end): the wrapped command's exit code, recorded SEPARATELY from `phase` (see
# Invoke-ReleaseEnd). `phase` is not an attribution of failure, so the code can never be stored on it.
$Code = $null; $Phase = $null; $Unsafe = $false; $Target = $null; $Sha = $null; $Ref = $null; $Follow = $null
$RunId = $null; $OwnerPid = 0; $LeaseId = $null; $Also = @(); $Base = $null; $DoLand = $false; $Force = $false
# recover (2026-11-21): -To = target worktree for a restore (dry run unless -Apply is also given).
$To = $null; $Apply = $false
# v3 (devcloud F1): lanes, priority, overrides, watchdog, metrics.
$Lane = $null; $Priority = 0; $By = 0; $Minutes = 30; $TimeoutGiven = $false
# devcloud F2: placement.
$Where = $null; $Ws = $null
# ADR 0005 (W4-2): advisory path claims.
$Claims = @()
# ADR 0007: `agentq workspace take|release|list -Name <ws>` (sub-verb is the first bare word after the verb).
$WsName = $null; $Sub = $null
# ADR 0009 stage 0: prune (-WhatIf, -Days), doctor (-Src <checkout>/ps).
$WhatIf = $false; $Src = $null; $Days = 0
# doctor -Only <check[,check]> -Quiet (2026-11-25): the two questions asked most often before starting
# work ("is this install in sync?" / "would heavy work run LOCAL on this box?") must not pay for the
# whole report, and a caller that only wants the findings should not have to filter a table of `info`
# lines. -Only filters which CHECKS run (unknown name = usage error, never a silent empty report);
# -Quiet keeps the human report's findings and drops its `ok`/`info` lines. Neither touches -Json.
$DoctorOnly = @(); $Quiet = $false
# ADR 0003 W2-5: set by Invoke-Land while an absorbed land waiter waits for its batch result.
$script:WaitAbort = $null; $script:WaitAborted = $false
$script:PreemptNote = ''; $script:WaitSec = 0; $script:CommitDone = $false
# D4: ticket id whose fair-share refusal was already journaled (the wait loop polls every few seconds;
# without this the journal would grow one `fair-share` line per poll).
$script:FsNoted = ''
# D3: cache of the memory floors Get-MachineMemory reads out of the config. It MUST exist: the function
# starts with `if ($null -eq $script:MmFloors)`, and under Set-StrictMode that READ throws
# ("The variable '$script:MmFloors' cannot be retrieved because it has not been set"), which took down
# every `agentq run` (2026-11-21, caught by this repository's own fair-share suite).
$script:MmFloors = $null
# prewarm (2026-11-25): knobs of prewarm-cloud.ps1, forwarded verbatim by `agentq prewarm`. The wait
# is NOT $WaitSec - that name is already the wait loop's, and PowerShell variables ignore case, so the
# two would be ONE slot and a prewarm would silently change the wait loop's bound.
$ActivityMin = $null; $MaxResumesPerDay = $null; $PrewarmWaitSec = $null; $VmState = $null
$GcloudExe = $null; $PrewarmRoot = $null; $PrewarmConfig = $null; $PrewarmTickLog = $null
$MaxTickSec = $null; $ReportDays = $null; $PrewarmReport = $false
$PrewarmOff = $false; $script:PrewarmCfg = $null
$Rest = @()
$argv = @($args)
$dd = [array]::IndexOf($argv, '--')
if ($dd -ge 0) { $Rest = @($argv | Select-Object -Skip ($dd + 1)); $argv = @($argv | Select-Object -First $dd) }
$i = 0
# `agentq help [<verb>]`, `agentq -h|--help|-?`: the discoverability entry point. An agent that does
# not know a verb exists must be able to ask in ONE step. Before this there was no `help` verb at all,
# so `agentq help` fell into `default` (dump the whole comment block, exit 2 = "failed" to an agent)
# and an agent looking for `land` burned 7 turns guessing verb names (2026-11-20).
if ($argv.Count -and "$($argv[0])".ToLowerInvariant() -in @('help', '-h', '--help', '-?', '/?')) {
  $Verb = 'help'
  if ($argv.Count -gt 1 -and "$($argv[1])" -notlike '-*') { $Sub = "$($argv[1])".ToLowerInvariant() }
  $argv = @()
}
if ($argv.Count -and "$($argv[0])" -notlike '-*') { $Verb = "$($argv[0])"; $i = 1 }
if ($Verb -eq 'workspace' -and $argv.Count -gt 1 -and "$($argv[1])" -notlike '-*') { $Sub = "$($argv[1])".ToLowerInvariant(); $i = 2 }
while ($i -lt $argv.Count) {
  $a = "$($argv[$i])"
  $name = $a.TrimStart('-').ToLowerInvariant()
  $next = { if ($i + 1 -ge $argv.Count) { throw "agentq: $a needs a value" }; $script:i++; "$($argv[$script:i])" }
  switch ($name) {
    'resource' { $Resource = & $next }
    'purpose' { $Purpose = & $next }
    'message' { $Message = & $next }
    'paths' {
      # In-process '& agentq.ps1 -Paths $arr' delivers ONE arg "a b c" (or the array itself); a .ps1
      # wrapper with -File delivers "a,b". Accept all: commas first, then whitespace when no comma.
      $raw = @($argv[$i + 1]); if ($i + 1 -ge $argv.Count) { throw "agentq: $a needs a value" }; $script:i++
      $vals = @(); foreach ($r in $raw) { $vals += @("$r") }
      while ($i + 1 -lt $argv.Count -and "$($argv[$i + 1])" -notlike '-*') { $script:i++; $vals += "$($argv[$i])" }
      $Paths = @($vals | ForEach-Object { if ($_ -match ',') { $_ -split ',' } elseif ($_ -match '\s' -and -not (Test-Path -LiteralPath $_)) { $_ -split '\s+' } else { $_ } } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    'repo' { $Repo = & $next }
    'claims' { $Claims = @((& $next) -split ',' | ForEach-Object { $_.Trim().Replace('\', '/') } | Where-Object { $_ }) }
    'expectrepo' { $ExpectRepo = & $next }
    'state' { $State = & $next }
    'reason' { $Reason = & $next }
    'id' { $Id = & $next }
    'session' { $PickSession = & $next }
    'capacity' { $Capacity = [int](& $next); $CapacityGiven = $true }
    'timeoutmin' { $TimeoutMin = [int](& $next); $TimeoutGiven = $true }
    'stalemin' { $StaleMin = [int](& $next) }
    'last' { $Last = [int](& $next) }
    'limit' { $Last = [int](& $next) }
    'hours' { $Hours = [double](& $next) }
    'minfreegb' { $MinFreeGB = [double](& $next) }
    'all' { $All = $true }
    'nopush' { $NoPush = $true }
    'nowait' { $NoWait = $true }
    'wait' { $Wait = $true }
    'maxmin' { $MaxMin = [double](& $next); $MaxMinGiven = $true }
    'json' { $Json = $true }
    'staleonly' { $StaleOnly = $true }
    'idlehours' { $IdleHours = [double](& $next) }
    'stale-only' { $StaleOnly = $true }
    'idle-hours' { $IdleHours = [double](& $next) }
    'reclaim' { $Reclaim = $true }
    'track' { $Track = $true }
    'slot' { $Slot = & $next }
    'role' { $Role = & $next }
    'hold' { $Hold = $true }
    'holdmin' { $Hold = $true; $HoldMin = & $next }
    'kind' { $FbKind = & $next }
    'sample' { $EvalSample = $true }
    'path' { $WtPath = & $next }
    'branch' { $Branch = & $next }
    'onto' { $Onto = & $next }
    'gate' { $Gate = & $next }
    # (c) `land -WaitShare`: wait for the share to admit instead of refusing at once.
    'waitshare' { $WaitShare = $true }
    'waitsharemin' { $WaitShare = $true; $WaitShareMin = [double](& $next) }
    'rebaseonconflict' { $RebaseOnConflict = $true }
    'phase' { $Phase = & $next }
    'unsafe' { $Unsafe = $true }
    'code' { $Code = [int](& $next) }
    'target' { $Target = & $next }
    'sha' { $Sha = & $next }
    'ref' { $Ref = & $next }
    'follow' { $Follow = & $next }
    'runid' { $RunId = & $next }
    'ownerpid' { $OwnerPid = [int](& $next) }
    'leaseid' { $LeaseId = & $next }
    'also' { $Also = @((& $next) -split ',' | Where-Object { $_ }) }
    'lane' { $Lane = (& $next).ToLowerInvariant() }
    'priority' { $Priority = [int](& $next) }
    'by' { $By = [int](& $next) }
    'minutes' { $Minutes = [int](& $next) }
    'where' { $Where = (& $next).ToLowerInvariant() }
    'base' { $Base = & $next }
    'land' { $DoLand = $true }
    'force' { $Force = $true }
    'to' { $To = & $next }
    'apply' { $Apply = $true }
    'ws' { $Ws = & $next }
    'name' { $WsName = & $next }
    'whatif' { $WhatIf = $true }
    'src' { $Src = & $next }
    'days' { $Days = [double](& $next) }
    # doctor: -Only <check[,check]> (the check keys of Invoke-Doctor), -Quiet = findings only.
    # `-Only a,b` arrives as ONE token in-process but as TWO from a native `pwsh -File` call (PowerShell
    # turns `a,b` into an array before binding) - the same trap `-Paths` documents, so it consumes the
    # following non-flag tokens exactly the same way. Without this, `-Only x,y` is a usage error, which
    # is the one outcome a filter flag must never produce by accident.
    'only' {
      $vals = @($argv[$i + 1]); if ($i + 1 -ge $argv.Count) { throw "agentq: $a needs a value" }
      $script:i++
      while ($i + 1 -lt $argv.Count -and "$($argv[$i + 1])" -notlike '-*') { $script:i++; $vals += "$($argv[$i])" }
      $DoctorOnly = @($vals | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    # prewarm: the knobs of prewarm-cloud.ps1, forwarded. -VmState/-Gcloud/-Root/-ConfigPath/-TickLog
    # exist so the suite (and a manual probe) can drive a fake gcloud instead of touching a real VM.
    'activitymin' { $ActivityMin = [int](& $next) }
    'maxresumesperday' { $MaxResumesPerDay = [int](& $next) }
    'waitsec' { $PrewarmWaitSec = [int](& $next) }
    'maxticksec' { $MaxTickSec = [int](& $next) }
    'reportdays' { $ReportDays = [int](& $next) }
    'report' { $PrewarmReport = $true }
    'vmstate' { $VmState = & $next }
    'gcloud' { $GcloudExe = & $next }
    'root' { $PrewarmRoot = & $next }
    'configpath' { $PrewarmConfig = & $next }
    'ticklog' { $PrewarmTickLog = & $next }
    'off' { $PrewarmOff = $true }
    'quiet' { $Quiet = $true }
    default {
      # `agentq trackers push [...]` (agentq-trackers.ps1 §push) is the ONE positional a tracker verb
      # takes, and the flags after it (-Hub/-KeyFile/-DryRun/-Repo) belong to push, not to agentq. The
      # whole tail is therefore forwarded verbatim rather than demanding `--`: without this the
      # documented spelling died in the parser with "unknown argument 'push' (put the command after
      # '--')" (measured 2026-11-28). Deliberately scoped to that one word, so a mistyped flag
      # (`agentq trackers -jsn`) is still refused here with the fix instead of at the Node tool.
      if ($Verb -and $Verb.ToLowerInvariant() -eq 'trackers' -and "$a".ToLowerInvariant() -eq 'push') {
        $Rest = @($argv[$i..($argv.Count - 1)]) + @($Rest)
        $i = $argv.Count
        break
      }
      # timings forwards an untyped flag (with its value) straight to the module instead of refusing it.
      # The usage string is the only place a user learns the flags, so a supported-but-untyped knob is
      # otherwise unreachable from the verb (2026-11-27: `timings -LogDir <dir>` was refused with
      # "unknown argument" while the module accepted exactly that flag and its own error text told the
      # user to pass it).
      if ($Verb -and $Verb.ToLowerInvariant() -eq 'timings' -and $a -like '-*') {
        $TimingsExtra += $a
        while ($i + 1 -lt $argv.Count -and "$($argv[$i + 1])" -notlike '-*') { $script:i++; $TimingsExtra += "$($argv[$i])" }
        break
      }
      if ($Verb -and $Verb.ToLowerInvariant() -eq 'run' -and $a -notlike '-*') {
        [Console]::Error.WriteLine("agentq: unknown argument '$a' - the command must follow '--'. In-process calls (& agentq.ps1 ... -- cmd) lose a bare -- in PowerShell: quote it as '--' or call 'pwsh -NoProfile -File agentq.ps1 ... -- cmd'.")
        exit 2
      }
      [Console]::Error.WriteLine("agentq: unknown argument '$a' (put the command after '--').")
      [Console]::Error.WriteLine("  flags of 'agentq $Verb': agentq help $Verb")
      [Console]::Error.WriteLine("  every verb:             agentq help")
      exit 2
    }
  }
  $i++
}
# TASK 3: reject a comma-joined value on a parameter that holds ONE value.
# `pwsh -NoProfile -File agentq.ps1 -Repo a,b` does NOT build an array: PowerShell's `-File` binder hands the
# whole `a,b` token to the parameter as ONE string, so the verb quietly looks up a repo literally named
# "a,b" and prints nothing - which reads as "no such work" instead of "your value is nonsense". Two real
# round trips died on this (codai scripts/ops/forensics/README.md: `dead-leases.ps1 -Repo a,b` printed
# `0 lease(s), 0 DEAD`). Commas only expand for `-Command` or an in-session call, so a value for one of
# these parameters can NEVER legitimately contain one: refuse it, with the fix, instead of guessing.
# `-Paths`, `-Claims`, `-Also` and `-Only` accept a comma list ON PURPOSE (they split it themselves) and are
# deliberately absent here. `-Gate`, `-Message`, `-Purpose`, `-Reason` and the path flags are absent too:
# those are free text or real filesystem paths, where a comma is legal.
$script:CommaSingles = [ordered]@{
  Repo = 'Repo'; ExpectRepo = 'ExpectRepo'; Slot = 'Slot'; Role = 'Role'; Branch = 'Branch'; Onto = 'Onto'
  Target = 'Target'; Sha = 'Sha'; Ref = 'Ref'; Base = 'Base'; Ws = 'Ws'; Name = 'WsName'; State = 'State'
  Kind = 'FbKind'; Lane = 'Lane'; Where = 'Where'; Session = 'PickSession'; Id = 'Id'; LeaseId = 'LeaseId'
  Follow = 'Follow'; RunId = 'RunId'; Phase = 'Phase'
}
foreach ($cn in $script:CommaSingles.Keys) {
  $cv = Get-Variable -Name $script:CommaSingles[$cn] -ValueOnly -ErrorAction SilentlyContinue
  if ($null -eq $cv -or "$cv" -notmatch ',') { continue }
  [Console]::Error.WriteLine("agentq: -$cn got ONE value containing a comma: '$cv'")
  [Console]::Error.WriteLine("  -$cn holds a SINGLE value, so '$cv' can never match anything.")
  [Console]::Error.WriteLine("  'pwsh -File agentq.ps1 -$cn a,b' binds the whole 'a,b' as ONE string: a comma list only")
  [Console]::Error.WriteLine("  expands for -Command or an in-session call, and the run then filters on 'a,b' in silence.")
  [Console]::Error.WriteLine("  Pass it once per value (-$cn a -$cn b), or use the verb's list flag (-Paths/-Claims/-Also/-Only).")
  exit 2
}
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
# Pre-initialised so a read-before-assignment cannot throw under StrictMode 3 (2026-11-22). Only the two
# exit codes need it; every other name here has its default in the initialiser block ABOVE the argument loop.
# DO NOT re-add `$script:Lane` / `$script:Priority` / `$script:Capacity` / `$script:CapacityGiven` to this
# block: in a script file the top-level scope IS the script scope, so `$script:Lane = $null` and
# `$Lane = $null` are the SAME slot - written after the parse loop they wiped the flags just read, so every
# `-Lane`, `-Priority` and `-Capacity` was silently ignored (all tickets got lane `gate` + priority 0 and
# the v3 scheduler's soft slots and priority order never fired; the three red cases of test-agentq-v3.ps1,
# 2026-11-22). The same slot aliasing is why `$script:i = $null` went too - it clobbered the arg index.
$script:LandExit = $null
$script:DoctorExit = $null

# ADR 0009 stage 0 (OQ-007): these verbs only READ the state folder. Before, `status` reaped dead
# tickets, rewrote the machine capacity, sampled the adaptive cap, marked dead releases failed and
# consumed lease notices, so every reader was also a writer (and `status -All` cost 4 s). Reaping now
# happens where work happens (run/commit/lease/land) and in `sweep`.
# `since` belongs in this set (agentq round 4). Its help line already advertises it as READ-ONLY and
# Register-Agent already excludes it, but it was NOT here: it ends in `Show-Status` and ran as a working
# verb, so the first call of nearly every task boot silently REAPED the dead tickets `sweep` exists to
# report (Get-Live drops them when the flag is off) and CONSUMED the caller's own lease-loss notice. The
# brief lists `since` under "READ-ONLY (never queue, never reap)" - this makes the code say what the docs
# promise. Session liveness is unaffected: line ~2674 renews the session for `since` explicitly.
$script:ReadOnly = $Verb.ToLowerInvariant() -in 'status', 'log', 'since', 'lessons', 'metrics', 'doctor', 'help', 'timings'
$script:AdmCfg = $null; $script:LoadHoldSince = $null; $script:LoadOverride = $false

# Two stores (ADR 0007, devbox teams). $Root = the USER store (~/.codai/coord, or AGENTQ_HOME): jobs,
# notices, agent registry, prep state - private to the person. $SysRoot = the SYSTEM store shared by every
# user of a multi-user machine (devbox: /var/lib/agentq, root-provisioned, group agentq, default ACL g:rw):
# queues, marks, leases, releases, workspaces and the journal live there, so build:machine and slot caps
# are machine-wide across people. Repo-scoped queue dirs and per-repo journals (journal.d/<repo>.jsonl)
# are owned by the repo's Unix group r-<repo> (2770): a user outside the group cannot read or join them.
# No system store (Windows workstation, tests) -> $SysRoot = $Root, exactly the old single-store layout.
$Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path (Join-Path $HOME '.codai') 'coord' }
$SysRoot = if ($env:AGENTQ_SYSTEM_HOME) { $env:AGENTQ_SYSTEM_HOME } elseif (-not $IsWindows -and -not $env:AGENTQ_HOME -and (Test-Path -LiteralPath '/var/lib/agentq/system.json')) { '/var/lib/agentq' } else { $Root }
$SystemMode = ($SysRoot -ne $Root)
$QDir = Join-Path $SysRoot 'queues'
$MDir = Join-Path $SysRoot 'marks'
$Journal = Join-Path $SysRoot 'journal.jsonl'
$JournalD = Join-Path $SysRoot 'journal.d'
foreach ($d in $Root, $QDir, $MDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }
# Optional state Wait-All reads/writes. This file runs under Set-StrictMode, where READING an unset
# script-scope variable is an error - so both exist from the start. agentq-v2.ps1 sets WaitPoll (a
# per-poll hook, currently Invoke-LandWedgeReap) while a land waiter polls; LandRequeue counts the
# land requeues tried in this process (one land per process).
$script:WaitPoll = $null
$script:LandRequeue = 0
# Journal file for one event: in system mode a repo's events go to journal.d/<repo>.jsonl (group r-<repo>)
# when that file's directory exists, so their purposes/commands stay inside the repo's group.
function Get-JournalFor([hashtable]$e) {
  if ($SystemMode -and (Test-Path -LiteralPath $JournalD)) {
    $rn = if ($e.ContainsKey('repo') -and $e.repo) { "$($e.repo)" } else { $null }
    if (-not $rn -and $e.ContainsKey('resource') -and $e.resource) {
      # 'build:codai,build:machine' / 'deploy:codai:gateway' / 'slot:codai:task-1' -> codai
      $p = @(("$($e.resource)" -split ',')[0] -split ':'); if ($p.Count -ge 2 -and $p[1] -ne 'machine') { $rn = $p[1] }
    }
    if ($rn) {
      $f = Join-Path $JournalD (($rn.ToLowerInvariant() -replace '[^a-z0-9._-]', '_') + '.jsonl')
      if (Test-Path -LiteralPath $f) { return $f }
    }
  }
  $Journal
}
# Every journal file this user may read (system journal + readable repo journals).
function Get-JournalFiles {
  $out = @(); if (Test-Path -LiteralPath $Journal) { $out += $Journal }
  if ($SystemMode -and (Test-Path -LiteralPath $JournalD)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $JournalD -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
      try { $s = [IO.File]::OpenRead($f.FullName); $s.Dispose(); $out += $f.FullName } catch {}
    }
  }
  $out
}

# Machine-wide capacities for named resources (override with -Capacity on first use).
# 'push:*' (ADR 0014 D1): pushing only contends on the remote ref, so two pushes may overlap; the
# pre-push gates are the slow part and they must not hold the commit:<repo> index lock (see Invoke-Commit).
$DefaultCapacity = @{ 'build:machine' = 2; 'push:*' = 2 }

function Now { [DateTime]::UtcNow }
function Iso([datetime]$d) { $d.ToUniversalTime().ToString('o') }
# ISO strings from our own files are UTC; a bare [datetime] cast converts them to LOCAL time
# (3 h off here), which made every holder look dead/stale. Always parse through this.
function ParseUtc($s) { if ($s -is [datetime]) { return $s.ToUniversalTime() }; [DateTimeOffset]::Parse("$s", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }

# The LONG-LIVED process that owns this agentq call. Incident 2026-11-22: the owner was the PARENT pid,
# which in agent harnesses (Copilot CLI/app, Claude Code, Codex) is the throw-away shell of ONE tool call.
# Every lease looked "owner alive=False" seconds after it was taken and was expired + reset at 45 min
# (63 of 82 expiries on 2026-11-21/22, most with 10-42 dirty files) - agents saw it as lost work.
# Walk up to the first agent host; a plain terminal keeps the old answer (the interactive parent shell).
$script:AgentHostNames = @('copilot', 'claude', 'codex', 'Code', 'Code - Insiders', 'cursor', 'windsurf', 'copilotapphost')
$script:AgentHostPidCache = $null
function Get-AgentHostPid {
  if ($null -ne $script:AgentHostPidCache) { return $script:AgentHostPidCache }
  $parent = 0
  try {
    $p = (Get-Process -Id $PID).Parent
    if ($p) { $parent = $p.Id }
    for ($i = 0; $p -and $i -lt 8; $i++) {
      if ($script:AgentHostNames -contains $p.ProcessName) { $script:AgentHostPidCache = $p.Id; return $p.Id }
      $p = $p.Parent
    }
  } catch {}
  $script:AgentHostPidCache = $(if ($parent) { $parent } else { $PID })
  $script:AgentHostPidCache
}
function Get-SessionId {
  # COPILOT_AGENT_SESSION_ID: the Copilot CLI/app session (stable across tool calls and CLI restarts).
  foreach ($v in $env:AGENTQ_SESSION, $env:COPILOT_SESSION_ID, $env:COPILOT_AGENT_SESSION_ID, $env:CLAUDE_SESSION_ID, $env:CODEX_SESSION_ID) { if ($v) { return $v } }
  # Stable per terminal/agent host. Get-Process .Parent costs ~20 ms; the CIM query it replaced cost
  # ~570 ms on EVERY agentq call (measured 2026-10-06).
  "term-$(Get-AgentHostPid)"
}
$Session = Get-SessionId

# Declared here, not first-assigned in the function: Set-StrictMode -Version 3 makes READING an unset
# variable a terminating error, and Get-RepoInfo can be called before anything else writes it.
$script:RepoInfoCache = $null
# Same reason, same shape: one Win32_OperatingSystem query costs ~100 ms on this machine and a single
# `status` asks for it twice (its own headroom line, then Get-MachineBudget for slot admission).
$script:MemInfoCache = $null

function Get-RepoInfo($path) {
  # A repo-info OBJECT is a valid input and comes straight back. `$repo` and `$Repo` are ONE variable in
  # PowerShell (names ignore case), so a script-scope `$repo = Get-RepoInfo $Repo` - the dispatcher does
  # exactly that before the verb switch - leaves $Repo holding the OBJECT. A later `Get-RepoInfo $Repo`
  # then stringified it into `-C "@{Top=...; Common=...; Name=...}"`, which git rejects: the caller got
  # $null and degraded in silence (measured 2026-11-27 on the `lease` reuse arm - two combined rev-parse
  # spawns, the second one carrying the object as -C). Accepting the object fixes the whole class in one
  # place rather than the one call site, and costs nothing: the answer is already computed.
  if ($null -ne $path -and $path -isnot [string] -and (@($path.PSObject.Properties.Name) -contains 'Top')) { return $path }
  $p = if ($path) { "$path" } else { (Get-Location).Path }
  # PERF (2026-11-26). Two `git` spawns, ~105 ms each on this machine, and one verb asks several times
  # (status has its own get-repoinfo phase, Renew-ForSession, the message notices, Register-Agent).
  # The identity of a path cannot change inside one CLI invocation, so the answer is memoized per path -
  # including the "not a repo" answer, which is why ContainsKey is the test, not truthiness.
  if ($null -eq $script:RepoInfoCache) { $script:RepoInfoCache = @{} }
  $key = $p.ToLowerInvariant()
  if ($script:RepoInfoCache.ContainsKey($key)) { return $script:RepoInfoCache[$key] }
  # PERF (2026-11-27). ONE spawn, not two: `rev-parse` prints one line per directive in ARGUMENT order,
  # so both answers come out of a single process. This runs at the start of EVERY verb (status, commit,
  # run, slo, lease), so the saving is not lease-only. A non-repo fails the whole call (exit 128, stderr
  # suppressed) -> zero lines -> the cached "not a repo" answer, exactly as before.
  # 2026-11-27: the SHORT HEAD rides along as a THIRD directive, so `lease` reads the sha off THIS
  # process instead of spawning `rev-parse --short HEAD` again (measured: -1 spawn on BOTH the fresh and
  # the re-lease arm). An UNBORN HEAD fails the directive (exit 128) while the first two lines are still
  # printed, so "is this a repo" is the LINE COUNT, not $LASTEXITCODE - keying on the exit code would
  # turn a fresh `git init` (no commit) into "not a repo" for every verb. Line 3 is absent when HEAD does
  # not resolve, which is exactly the '' the old separate spawn produced.
  $out = @((& git -C $p rev-parse --show-toplevel --path-format=absolute --git-common-dir --short HEAD 2>$null) | Where-Object { "$_" -ne '' })
  if ($out.Count -lt 2) { $script:RepoInfoCache[$key] = $null; return $null }
  $top = $out[0]; $common = $out[1]
  $sha = if ($out.Count -ge 3) { "$($out[2])" } else { '' }
  $name = Split-Path (Split-Path $common -Parent) -Leaf
  $ds = [IO.Path]::DirectorySeparatorChar
  $info = [pscustomobject]@{ Top = ($top -replace '/', $ds); Common = ($common -replace '/', $ds); Name = $name.ToLowerInvariant(); Sha = $sha }
  $script:RepoInfoCache[$key] = $info
  $info
}

# A commit or a land made IN the SHARED clone of a repo the owner marked read-only
# (agentq-config.json `sharedCloneModeRepos: { "<repo>": "refuse" }`, with the global `sharedCloneMode`
# as the default) is what makes git-autosync refuse. Measured 2026-11-18: codai's shared main carried 15
# unpushed local commits - 7 already upstream by patch-id, 8 parked on a WIP ref - and autosync refused
# for days with "its owner must rebase", while nothing was actually at risk except the readable state of
# the clone. The PreToolUse guard covers editor writes; this covers the agentq verbs that create the
# commits and the landings. Work belongs in a leased slot. Deliberate one-off (say why in the purpose):
# AGENTQ_SHARED_CLONE_COMMIT_OK=1.
#
# The refusal must fire ONLY for the repo's MAIN working tree. A leased slot is a LINKED worktree, and a
# slot is exactly where `agentq commit` / `agentq land` are supposed to run (2026-11-19: every commit in
# a slot was refused as "E:\gh\codai is the SHARED clone" because the decision rested on path arithmetic
# over `--git-common-dir`, whose parent is the main clone for EVERY worktree of the repo).
# Production tells the two apart: a linked worktree has its own git dir (<common>/worktrees/<name>), so
# only the main worktree has git-dir == git-common-dir. Test-IsMainWorktree asks git that question; the
# path comparison stays as a second, independent witness and a refusal needs BOTH to say "main tree".
function Test-IsMainWorktree([object]$repo) {
  if (-not $repo -or -not $repo.Top) { return $false }
  $gd = "$(& git -C $repo.Top rev-parse --path-format=absolute --git-dir 2>$null)".Trim()
  $cd = "$($repo.Common)".Trim()
  if (-not $gd -or -not $cd) { return $false }   # cannot prove it is the main tree -> do not refuse
  $norm = { param($p) ([IO.Path]::GetFullPath("$p")).TrimEnd('\', '/').ToLowerInvariant() }
  ((& $norm $gd) -eq (& $norm $cd))
}
function Assert-SharedCloneWriteAllowed([object]$repo, [string]$verb) {
  if (-not $repo -or -not $repo.Top -or -not $repo.Common) { return }
  if (-not (Test-IsMainWorktree $repo)) { return }               # a linked worktree (leased slot): fine
  $norm = { param($p) ([IO.Path]::GetFullPath("$p")).TrimEnd('\', '/').ToLowerInvariant() }
  # Top is the worktree path, Common the shared .git: they are equal only in the shared clone itself.
  $commonRoot = Split-Path $repo.Common -Parent
  if ((& $norm $repo.Top) -ne (& $norm $commonRoot)) { return }   # a leased slot (linked worktree): fine
  $cfg = Get-Config
  $mode = if ($cfg.ContainsKey('sharedCloneMode')) { "$($cfg['sharedCloneMode'])" } else { 'warn' }
  $map = if ($cfg.ContainsKey('sharedCloneModeRepos')) { $cfg['sharedCloneModeRepos'] } else { $null }
  if ($map -and $map.ContainsKey($repo.Name)) { $mode = "$($map[$repo.Name])" }
  if ($mode -ne 'refuse') { return }
  # Where this repo's slots live. The MANAGED root is Get-WtRoot (agentq-v2.ps1: CODAI_WT_ROOT, else
  # E:\gh\.wt) and does not depend on where the clone sits; the legacy sibling `<clone>\.wt\<repo>` is
  # only right for a clone directly under the fleet root. 2026-11-25: checking the sibling alone made
  # the policy armed and inert for every NESTED clone (E:\gh\frontiers\<repo>), because a directory that
  # never exists reads as "this repo has no slots" - ADR 0009 stage 0 (OQ-008: protect only the repos
  # that HAVE slots, so an unprovisioned repo keeps the advisory and its agent is never left with
  # nowhere to work). Both roots are honoured, per repo, in the same shape the editor guard uses.
  $wtRoot = if (Get-Command Get-WtRoot -ErrorAction SilentlyContinue) { Get-WtRoot }
    elseif ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT }
    elseif ($IsWindows) { 'E:\gh\.wt' } else { '/work/.wt' }
  $siblingSlots = Join-Path (Split-Path $repo.Top -Parent) ('.wt' + [IO.Path]::DirectorySeparatorChar + $repo.Name)
  $managedSlots = Join-Path $wtRoot $repo.Name
  if (-not (Test-Path -LiteralPath $siblingSlots) -and -not (Test-Path -LiteralPath $managedSlots)) { return }   # repo without slots: nothing to protect
  # Owner-only override, journaled and with a reason (2026-11-22: agents copied the bypass from the
  # refusal text itself and left unpushed commits on shared main again, so it is no longer advertised).
  if ($env:AGENTQ_SHARED_CLONE_COMMIT_OK -eq '1' -and $env:AGENTQ_SHARED_CLONE_REASON) {
    Write-Journal @{ event = 'shared-clone-override'; repo = $repo.Name; verb = $verb; reason = "$env:AGENTQ_SHARED_CLONE_REASON" }
    return
  }
  [Console]::Error.WriteLine("agentq: REFUSED - $($repo.Top) is the SHARED clone of $($repo.Name) (sharedCloneMode=refuse). Agents never $verb here: it leaves the clone dirty, blocks git-autosync and collides with other agents. Lease a slot: agentq lease -Purpose <why> [-Branch <topic>] (the slot directory is created on demand, there is nothing to set up), work there, commit + land, then unlease. Do NOT look for a bypass.")
  Write-Journal @{ event = 'shared-clone-refused'; repo = $repo.Name; verb = $verb; note = 'shared clone of a repo marked read-only' }
  exit 3
}

# X-02 (2026-10-05): run_in_terminal sometimes DROPS a leading Set-Location, so a commit/build
# meant for a worktree ran in the shared clone (twice: brivio SW-0302, codai). -ExpectRepo <dir>
# (or env AGENTQ_EXPECT_REPO) refuses unless the resolved repo top equals it.
function Assert-ExpectedRepo($repo) {
  $want = if ($ExpectRepo) { $ExpectRepo } elseif ($env:AGENTQ_EXPECT_REPO) { $env:AGENTQ_EXPECT_REPO } else { $null }
  if (-not $want) { return }
  $w = (Get-RepoInfo $want)
  $wTop = if ($w) { $w.Top } else { $want }
  $norm = { param($p) $n = [IO.Path]::GetFullPath("$p").TrimEnd('\', '/'); if ($IsWindows) { $n.ToLowerInvariant() } else { $n } }
  if (-not $repo -or (& $norm $repo.Top) -ne (& $norm $wTop)) {
    $got = if ($repo) { $repo.Top } else { '(no repo)' }
    [Console]::Error.WriteLine("agentq: REFUSED - expected repo '$wTop' but this runs in '$got' (cwd $((Get-Location).Path)). A dropped Set-Location? Pass -Repo '$wTop'.")
    exit 3
  }
}

function Resolve-Resource([string]$r, $repo) {
  if (-not $r) { throw 'agentq: -Resource is required' }
  if ($r -match ':') {
    # deploy:<target> (no repo) -> deploy:<repo>:<target>; anything with 2+ colons is literal.
    if ($r -match '^(deploy):([^:]+)$' -and $repo) { return "deploy:$($repo.Name):$($Matches[2])" }
    return $r.ToLowerInvariant()
  }
  if (-not $repo) { throw "agentq: '$r' needs a repo (run inside a git repo or pass -Repo)" }
  "$($r.ToLowerInvariant()):$($repo.Name)"
}

function Safe([string]$s) { ($s -replace '[^A-Za-z0-9._-]', '_') }
function QPath([string]$res) { Join-Path $QDir (Safe $res) }
# System mode: a repo-scoped dir created on demand (deploy:<repo>:<target>, a new slot dir) gets the repo's
# group r-<repo> and mode 2770, like the ones devbox-teams pre-creates. The creator is in that group
# (else the repo was unreadable to begin with), so chgrp is allowed. Best effort; no-op elsewhere.
function Set-RepoGroupDir([string]$dir, [string]$repoName) {
  if (-not $SystemMode -or $IsWindows -or -not $repoName -or $repoName -eq 'machine') { return }
  $g = 'r-' + ($repoName.ToLowerInvariant() -replace '[^a-z0-9._-]', '-')
  if ($g.Length -gt 32) { $g = $g.Substring(0, 32) }
  try { & chgrp $g $dir 2>$null; & chmod 2770 $dir 2>$null } catch {}
}
function Get-ResourceRepo([string]$res) { $p = @($res -split ':'); if ($p.Count -ge 2) { $p[1] } else { $null } }

# Append one line to a journal file, retrying while any other writer holds it. The journal is
# DIAGNOSTICS: not being able to write it must never abort the operation it describes. 2026-11-25: a
# sharing violation on journal.jsonl threw straight out of Write-Journal and killed a land pre-gate
# before its gate had run at all ("land: gate failed (1) ... nothing queued, nothing pushed") - while
# several chats held tickets on this box. The mutex below only serialises the writers that take it;
# the heartbeat job's idle-yield lines take none, so it can always lose the race.
# 25 attempts, a 25 ms delay growing to a 200 ms cap - about 4.3 s of patience: long enough to
# outlast a sibling writer that holds the file for a couple of seconds, short enough never to stall
# the operation long.  Out of patience the LINE is lost, the operation continues (see above).
function Append-JournalLine([string]$path, [string]$line) {
  $enc = [Text.UTF8Encoding]::new($false)
  for ($i = 1; $i -le 25; $i++) {
    try { [IO.File]::AppendAllText($path, $line + "`n", $enc); return $true } catch { Start-Sleep -Milliseconds ([Math]::Min(25 * $i, 200)) }
  }
  $false
}
function Write-Journal([hashtable]$e) {
  $e.ts = Iso (Now); if (-not $e.ContainsKey('session')) { $e.session = $Session }
  $line = ($e | ConvertTo-Json -Compress -Depth 6)
  $m = $null
  try { $m = [Threading.Mutex]::new($false, "Global\agentq-journal$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })") } catch {}
  if ($m) { try { [void]$m.WaitOne(5000) } catch {} }
  try { [void](Append-JournalLine (Get-JournalFor $e) $line) }
  finally { if ($m) { try { $m.ReleaseMutex() } catch {} ; $m.Dispose() } }
}

function Get-ProcStart([int]$procId) {
  try { (Get-Process -Id $procId -ErrorAction Stop).StartTime.ToUniversalTime() } catch { $null }
}

function Test-Alive($t) {
  $st = Get-ProcStart ([int]$t.pid)
  if (-not $st) { return $false }
  if ($t.procStart) { return ([math]::Abs(($st - (ParseUtc $t.procStart)).TotalSeconds) -lt 3) }
  $true
}

function Read-Tickets([string]$res) {
  $dir = QPath $res
  if (-not (Test-Path $dir)) { return @() }
  @(Get-ChildItem $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'adaptive.json' | Sort-Object Name | ForEach-Object {
      try {
        $raw = $null
        for ($r = 0; $r -lt 5; $r++) {
          try { $raw = Get-Content $_.FullName -Raw -ErrorAction Stop; if ($raw) { $raw | ConvertFrom-Json | Out-Null; break } } catch { $raw = $null }
          Start-Sleep -Milliseconds 50
        }
        if (-not $raw) {
          if (-not (Test-Path $_.FullName)) { return }  # released meanwhile
          # Fail closed: hold the slot with a placeholder that looks alive (pid = us).
          [pscustomobject]@{ id = "unreadable-$($_.BaseName)"; resource = $res; pid = $PID; procStart = $null; session = '?'; purpose = 'unreadable ticket'; created = (Iso (Now)); file = $_.FullName; beat = (Now) }
          return
        }
        $t = $raw | ConvertFrom-Json -DateKind String
        $t | Add-Member -NotePropertyName file -NotePropertyValue $_.FullName -Force
        $hb = "$($_.FullName).hb"
        $beat = if (Test-Path $hb) { (Get-Item $hb).LastWriteTimeUtc } else { (ParseUtc $t.created) }
        $t | Add-Member -NotePropertyName beat -NotePropertyValue $beat -Force
        $t
      } catch { $null }
    } | Where-Object { $_ })
}

function Remove-Ticket($t, [string]$why, [string]$kind = 'reap') {
  Remove-Item -LiteralPath $t.file, "$($t.file).hb", "$($t.file).wedged" -Force -ErrorAction SilentlyContinue
  Write-Journal @{ event = $kind; resource = $t.resource; ticket = $t.id; holderSession = $t.session; purpose = $t.purpose; reason = $why }
}

# Reap dead holders; flag stale ones. Returns live tickets in FIFO order.
function Get-Live([string]$res) {
  $out = @()
  foreach ($t in Read-Tickets $res) {
    if (-not (Test-Alive $t)) { if (-not $script:ReadOnly) { Remove-Ticket $t "holder pid $($t.pid) is gone" }; continue }
    $age = ((Now) - (ParseUtc $t.beat)).TotalMinutes
    $t | Add-Member -NotePropertyName stale -NotePropertyValue ($age -gt $StaleMin) -Force
    $t | Add-Member -NotePropertyName beatAgeMin -NotePropertyValue ([math]::Round($age, 1)) -Force
    $out += $t
  }
  $out
}

# TASK 1: how many `land:<repo>` tickets may be live at once. `land` was capacity-1 because the merge to
# origin/<onto> is a single per-repo operation - but the ticket was ALSO the only place a pre-gate could
# run, so a land that waited 13 min (p90) held the whole lock while its own gate ran, and land was 60 % of
# all fleet queue time (7 days to 2026-11-26: 83.6 h, p90 13.3 min, max 6.4 h). Config `landCapacity`
# (default 1 = today's behaviour) may raise it to 2 - two lands then pre-gate and queue in parallel, and
# the merge/push phase takes a bounded per-repo mutex (Enter-LandMergeMutex), so only ONE land is ever
# merging/pushing. Clamped to 1..2: there is one `land` worktree per repo, and a third waiter would only
# lengthen the mutex queue without buying a second merge.
# `-Capacity` on `land:` is deliberately NOT honoured - the config flag is the switch, so a stray
# `-Capacity 2` cannot silently enable the concurrent path.
function Get-LandCapacity {
  $c = Get-Config
  $v = if ($c -and $c.ContainsKey('landCapacity')) { [int]$c['landCapacity'] } else { 1 }
  if ($v -lt 1) { 1 } elseif ($v -gt 2) { 2 } else { $v }
}
function Get-Capacity([string]$res) {
  # build:machine: config machineCap (+ an active, unexpired burst) wins over the sticky capacity
  # file, which is rewritten so the hub/sync readers see the effective value (DC-014).
  if ($res -eq 'build:machine') {
    $cap = (Get-AdaptiveMachineCap) + (Get-BurstExtra $res)
    if ($script:ReadOnly) { return $cap }
    $f = Join-Path (QPath $res) 'capacity'
    try { if (-not (Test-Path $f) -or [int](Get-Content $f -Raw) -ne $cap) { New-Item -ItemType Directory -Force (QPath $res) | Out-Null; [IO.File]::WriteAllText($f, "$cap") } } catch {}
    return $cap
  }
  if ($res -eq 'gate:machine') {
    # The MACHINE-WIDE bound on heavy gate/verify runs. A heavy land pre-gate takes only verify:<repo>
    # (cap 1 PER REPO), so before this existed N repos ran N ~90-fork gates at once - 13 concurrent
    # measured on this machine, 2026-11-26. The cap is FIXED; the load hold below is the part that
    # follows real load, and it narrows this to ONE heavy run while the machine is saturated. Never
    # below 1 - that is the progress guarantee. Read from config on purpose: a sticky capacity file
    # must not be able to raise a machine-wide bound.
    $gc = Get-Config
    $gateCap = if ($gc.ContainsKey('gateMachineCap')) { [int]$gc['gateMachineCap'] } else { 3 }
    if ($gateCap -lt 1) { $gateCap = 1 }
    return $gateCap + (Get-BurstExtra $res)
  }
  # land:<repo> (TASK 1): the config flag wins over the sticky file, for the same reason build:machine
  # does - a sticky `1` written before the flag was turned on must not pin a repo at capacity 1, and a
  # sticky `2` left behind must not keep the concurrent path alive after the flag was turned off. The
  # file is rewritten so the hub/sync readers and the queue display show the effective value.
  if ($res -like 'land:*') {
    $cap = Get-LandCapacity
    if ($script:ReadOnly) { return $cap }
    $f = Join-Path (QPath $res) 'capacity'
    try { if (-not (Test-Path $f) -or [int](Get-Content $f -Raw) -ne $cap) { New-Item -ItemType Directory -Force (QPath $res) | Out-Null; [IO.File]::WriteAllText($f, "$cap") } } catch {}
    return $cap
  }
  $f = Join-Path (QPath $res) 'capacity'
  $base = if (Test-Path $f) { [int](Get-Content $f -Raw) } elseif ($DefaultCapacity.ContainsKey($res)) { $DefaultCapacity[$res] } elseif ($DefaultCapacity.ContainsKey(($res -split ':')[0] + ':*')) { $DefaultCapacity[($res -split ':')[0] + ':*'] } else { 1 }
  $base + (Get-BurstExtra $res)
}

# Adaptive machine cap (S18-08, 2026-10-17). A fixed 2 left the i9 idle at night and saturated it
# during the day. Config `machineCapAdaptive` = { min, max, cpuHigh, cpuLow, minFreeRamGB,
# minFreeCommitGB, everySec }; absent -> the fixed machineCap. The decision is shared by every agentq
# process through queues/build_machine/adaptive.json and refreshed at most every `everySec`, because
# Get-Capacity runs on every 1.5 s poll. CPU is the AVERAGE since the previous refresh
# (raw perf-counter deltas), so a one-second spike cannot flap the cap. One step per refresh.
# Raw counter, not Add-Type GetSystemTimes: compiling the P/Invoke cost ~730 ms per agentq process
# and PerfFormattedData ~14 s under load (measured 2026-10-17); PerfRawData answers in ~33 ms.
# Raw PercentProcessorTime for _Total is cumulative IDLE time in 100 ns units.
function Get-SysTimes {
  if (-not $IsWindows) {
    # /proc/stat first line: cpu user nice system idle iowait irq softirq steal ... (USER_HZ ticks)
    $f = @((Get-Content -LiteralPath '/proc/stat' -TotalCount 1) -split '\s+' | Select-Object -Skip 1 | Where-Object { $_ } | ForEach-Object { [long]$_ })
    $tot = [long]0; foreach ($x in $f) { $tot += $x }
    return @{ idle = [long]($f[3] + $f[4]); total = $tot }
  }
  $r = Get-CimInstance Win32_PerfRawData_PerfOS_Processor -Filter "Name='_Total'" -Property PercentProcessorTime, Timestamp_Sys100NS
  @{ idle = [long]$r.PercentProcessorTime; total = [long]$r.Timestamp_Sys100NS }
}
# Free RAM / commit headroom in KB, same fields as Win32_OperatingSystem. Linux: MemAvailable, and
# CommitLimit - Committed_AS as the commit headroom (overcommit makes it advisory, like Windows' pagefile).
function Get-MemInfo {
  if ($null -ne $script:MemInfoCache) { return $script:MemInfoCache }
  if (-not $IsWindows) {
    $m = @{}; foreach ($l in Get-Content -LiteralPath '/proc/meminfo') { if ($l -match '^(\w+):\s+(\d+)') { $m[$Matches[1]] = [double]$Matches[2] } }
    $commit = if ($m.ContainsKey('CommitLimit') -and $m.ContainsKey('Committed_AS')) { [math]::Max(0, $m['CommitLimit'] - $m['Committed_AS']) } else { $m['MemAvailable'] }
    # vm.overcommit_memory=0 (Ubuntu default) never refuses on CommitLimit: report MemAvailable+swap as headroom
    $mode = try { [int](Get-Content -LiteralPath '/proc/sys/vm/overcommit_memory' -Raw) } catch { 0 }
    if ($mode -ne 2) { $commit = $m['MemAvailable'] + $(if ($m.ContainsKey('SwapFree')) { $m['SwapFree'] } else { 0 }) }
    $script:MemInfoCache = [pscustomobject]@{ FreePhysicalMemory = $m['MemAvailable']; FreeVirtualMemory = $commit }
    return $script:MemInfoCache
  }
  $script:MemInfoCache = Get-CimInstance Win32_OperatingSystem -Property FreePhysicalMemory, FreeVirtualMemory
  $script:MemInfoCache
}
function Get-AdaptiveMachineCap {
  $cfg = Get-Config
  $fixed = [int]$cfg.machineCap
  $a = if ($cfg.ContainsKey('machineCapAdaptive')) { $cfg['machineCapAdaptive'] } else { $null }
  if (-not $a) { return $fixed }
  # config is read -AsHashtable, and P() only sees object properties
  $H = { param($k, $d) if ($a.ContainsKey($k) -and $null -ne $a[$k]) { $a[$k] } else { $d } }
  function P($o, $k, $d) { & $H $k $d }
  $min = [int](P $a 'min' $fixed); $max = [int](P $a 'max' $fixed)
  if ($max -le $min) { return $min }
  $every = [double](P $a 'everySec' 15)
  $f = Join-Path (QPath 'build:machine') 'adaptive.json'
  $prev = $null
  try { if (Test-Path -LiteralPath $f) { $prev = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } } catch {}
  $now = Now
  $prevAt = $null
  if ($prev -and $prev.at) {
    $prevAt = if ($prev.at -is [datetime]) { $prev.at.ToUniversalTime() } else { try { [DateTime]::Parse("$($prev.at)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch { $null } }
  }
  # A read-only verb reports the last shared decision; it never samples or writes one.
  if ($script:ReadOnly) { return $(if ($prev -and $prev.cap) { [math]::Max($min, [math]::Min($max, [int]$prev.cap)) } else { $min }) }
  if ($prevAt -and ($now - $prevAt).TotalSeconds -lt $every) {
    return [math]::Max($min, [math]::Min($max, [int]$prev.cap))
  }
  $m = [Threading.Mutex]::new($false, "Global\agentq-adaptive$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  $got = $false
  try {
    try { $got = $m.WaitOne(0) } catch [Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { return $(if ($prev) { [math]::Max($min, [math]::Min($max, [int]$prev.cap)) } else { $min }) }
    $t = Get-SysTimes
    $cpu = $null
    if ($prev -and $prev.total -and ([long]$t.total - [long]$prev.total) -gt 0) {
      $dt = [double]([long]$t.total - [long]$prev.total); $di = [double]([long]$t.idle - [long]$prev.idle)
      $cpu = [math]::Round(100 * (1 - $di / $dt), 1)
    }
    $mm = Get-MachineMemory ([double]$MinFreeGB)
    $ram = $mm.ramGB; $commit = $mm.commitGB
    $cap = if ($prev -and $prev.cap) { [int]$prev.cap } else { $min }
    $why = 'hold'
    $memLow = ($ram -lt $mm.ramFloorGB) -or ($commit -lt $mm.commitFloorGB)
    if ($memLow) { $cap--; $why = "memory low (ram ${ram} GB, commit ${commit} GB)" }
    elseif ($null -ne $cpu -and $cpu -ge [double](P $a 'cpuHigh' 85)) { $cap--; $why = "cpu ${cpu}% >= high" }
    elseif ($null -ne $cpu -and $cpu -le [double](P $a 'cpuLow' 55)) { $cap++; $why = "cpu ${cpu}% <= low" }
    $cap = [math]::Max($min, [math]::Min($max, $cap))
    $rec = [ordered]@{ at = Iso $now; cap = $cap; cpu = $cpu; freeRamGB = $ram; freeCommitGB = $commit; why = $why; idle = $t.idle; total = $t.total; min = $min; max = $max }
    New-Item -ItemType Directory -Force (QPath 'build:machine') | Out-Null
    [IO.File]::WriteAllText("$f.tmp", ($rec | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)); Move-Item -Force "$f.tmp" $f
    if ($prev -and [int]$prev.cap -ne $cap) { Write-Journal @{ event = 'cap'; resource = 'build:machine'; from = [int]$prev.cap; to = $cap; reason = $why; cpu = $cpu; freeRamGB = $ram; freeCommitGB = $commit } }
    return $cap
  } catch { return $(if ($prev -and $prev.cap) { [int]$prev.cap } else { $fixed }) }
  finally { if ($got) { try { $m.ReleaseMutex() } catch {} }; $m.Dispose() }
}

# ---- v3 scheduling helpers (devcloud F1, DC-010..013) -----------------------------------
# P (property-or-default) is defined in agentq-v2.ps1, dot-sourced before any of this runs.
$LaneBase = [ordered]@{ interactive = 100; quick = 80; gate = 50; heavy = 30; batch = 10 }
function Resolve-Lane([string]$res, [string]$lane) {
  if ($lane) {
    if (-not $LaneBase.Contains($lane)) { throw "agentq: -Lane must be one of $($LaneBase.Keys -join '|')" }
    return $lane
  }
  if ($res -like 'build:*') { return 'gate' }
  'quick'
}
function BurstFile([string]$res) { Join-Path (QPath $res) 'burst.json' }
function Get-BurstExtra([string]$res) {
  $f = BurstFile $res
  if (-not (Test-Path $f)) { return 0 }
  try {
    $b = Get-Content $f -Raw | ConvertFrom-Json -DateKind String
    if ((ParseUtc $b.until) -gt (Now)) { return [int]$b.by }
    if ($script:ReadOnly) { return 0 }
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    Write-Journal @{ event = 'burst-expired'; resource = $res; reason = "$($b.reason)" }
  } catch {}
  0
}
# Effective priority = lane base + explicit -Priority + bumps + aging (+5 per AgingMin waited).
function Get-EffPrio($t) {
  $lane = "$(P $t 'lane' 'gate')"
  $base = if ($LaneBase.Contains($lane)) { $LaneBase[$lane] } else { 50 }
  $aging = [int](Get-Config).agingMin
  $waited = ((Now) - (ParseUtc $t.created)).TotalMinutes
  $age = if ($aging -gt 0) { 5 * [math]::Floor($waited / $aging) } else { 0 }
  $base + [int](P $t 'prio' 0) + [int](P $t 'bump' 0) + $age
}
# D4 (ADR 0014): per-session fair share. The order above is priority-only, so one agent that fans out
# N parallel jobs could take EVERY slot of a resource (build:machine cap 2-4) and every other session
# waited behind the whole block. Two changes, both active only while at least two sessions compete:
# the rank order is round-robin over sessions (priority order INSIDE a session), and a session may
# hold at most ceil(cap / sessions) slots. With one session this is exactly the old behaviour.
# Config `fairShare`: true|false | { enabled, maxPerSession } (default enabled, maxPerSession 0 =
# derived). AGENTQ_NO_FAIRSHARE=1 turns it off for one call.
function Get-FairShare {
  $d = @{ enabled = $true; maxPerSession = 0; slotsPerSession = 0 }
  $c = Get-Config
  if ($c.ContainsKey('fairShare')) {
    $v = $c['fairShare']
    if ($v -is [Collections.IDictionary]) {
      if ($v.ContainsKey('enabled')) { $d.enabled = [bool]$v['enabled'] }
      if ($v.ContainsKey('maxPerSession') -and $null -ne $v['maxPerSession']) { $d.maxPerSession = [int]$v['maxPerSession'] }
      # D5: the SLOT-side twin of maxPerSession. 0 = derive it from the machine task cap (ceil(cap / sessions)).
      if ($v.ContainsKey('slotsPerSession') -and $null -ne $v['slotsPerSession']) { $d.slotsPerSession = [int]$v['slotsPerSession'] }
    } elseif ($null -ne $v -and "$v" -ne '') { $d.enabled = [bool]$v }
  }
  if ($env:AGENTQ_NO_FAIRSHARE -eq '1') { $d.enabled = $false }
  $d
}
# D5 (owner 2026-11-23, ADR 0014) - the slot-side twin of the queue's fair share. ONE VS Code window is ONE
# agentq session, so every terminal AND every subagent of that window shares one session id; measured
# 2026-11-26: ONE live process held 12 slot leases while other windows starved. The scratch pool offers far
# fewer than one session held, so the land PRE-GATE found no scratch slot, was SKIPPED, and ran a 5-40 min
# repo gate inside the cap-1 land mutex. Two behaviours, both inert for a lone session (no regression):
#   (1) REUSE BEFORE RENTING - a session that already holds a CLEAN slot of the requested role in this repo
#       gets that slot back instead of renting a second one ("subagents work in the lead's slot", ADR 0012).
#   (2) PER-SESSION SHARE - at most `fairShare.slotsPerSession` slots when > 0, else ceil(machine task cap /
#       competing sessions) floored at 1. Over it: a bounded wait, then a refusal naming the held slots and
#       both recipes.
# D6/D7: each lease RECORD with its chat binding attached (`chats`), read from the sidecar the guard hook
# writes (<lease>.json.chat). ONE definition, so the lease path and `status` cannot drift on WHICH store the
# chat key comes from: both hand Get-SlotShare the RAW `Read-Leases $null` view and it attaches the bindings
# here. A lease with no record file (the helper suite builds hashtables by hand) is passed through untouched,
# and Add-LeaseChats is never invoked for a batch that has none - so it need not even be defined then.
function Add-LeaseChats($leases) {
  # Idempotent: an item that already carries `chats` (Add-LeaseChats output, e.g. `status`'s $all, handed on
  # to Get-SlotShare) is returned as is - `Select-Object *, @{ n = 'chats' ... }` THROWS when the property
  # already exists (measured 2026-11-28: passing the enriched list to Get-SlotShare broke `status`).
  @($leases | ForEach-Object {
      if (-not $_ -or -not "$(P $_ 'file' '')") { $_ }
      elseif (@($_.PSObject.Properties.Name) -contains 'chats') { $_ }
      else { $chb = @(); try { $chb = @((Read-LeaseChat (P $_ 'file' '')).chats) } catch { }; $_ | Select-Object *, @{ n = 'chats'; e = { $chb } } }
    })
}
# $leases is a lease array (a RAW Read-Leases view: the chat binding is attached HERE, the one store), $sess a
# session id, $taskCap the machine task-slot cap, $chat the caller's chat id ('' keys the share by session).
function Get-SlotShare($leases, [string]$sess, [int]$taskCap, [string]$chat, [string]$repoFilter = '') {
  $fs = Get-FairShare
  # D6/D7: the chat binding is attached in ONE place, so the lease path and `status` read the SAME store. The
  # guard keeps the helper suite (part A: hand-built hashtables, no Read-LeaseChat in scope) working: no lease
  # has a record file, so Add-LeaseChats is not called at all and those leases key by session exactly as before.
  if (@($leases | Where-Object { $_ -and "$(P $_ 'file' '')" }).Count) { $leases = @(Add-LeaseChats $leases) }
  $live = @($leases | Where-Object { $_ -and -not [bool](P $_ 'stale' $false) })
  # (e) owner 2026-11-28 "charge lands per REPO, not across repos": WHAT IS CHARGED is not the same question as
  # WHAT COMPETES. The divisor stays machine-wide ($units -> share, unchanged, so the machine task-slot budget
  # is respected exactly as before); only the numerator ($held) narrows to one repo when the caller passes
  # $repoFilter, and ONLY the land path does (a land can only ever take a slot of its own repo). Measured
  # 2026-11-28: this window's chats held 12 leases across agentq/brivio/marcai/codai against a share of 4, so a
  # land OF codai - which needed ONE codai scratch - was refused, billed for other repos' work. The task/scratch
  # rental path passes '' and is byte-identical to before (no behaviour change for a lone session either way).
  $charged = if ($repoFilter) { @($live | Where-Object { "$(P $_ 'repo' '')" -ceq "$repoFilter" }) } else { $live }
  # D6 (owner 2026-11-28, proposal SHAREPERCHAT): the share KEY is the CHAT when the caller's chat id is
  # known AND at least one live lease carries a chat binding, else the session (one VS Code window) exactly
  # as before. The window key charged every chat of a window as ONE holder: measured 2026-11-28 this
  # window's chats held 14 -> 17 slots against a share of 6 while each chat's own work was 1-2 slots, so a
  # window with several chats could not land at all, and each attempt burned the cap-1 land ticket for
  # 10 min before the refusal. A lease with NO chat binding is its own unit keyed by session: it still
  # competes (it cannot be free), it simply cannot be charged to me. Chat mode is never entered on a guess -
  # an unknown chat id falls back to the session, so a lone session keeps the old behaviour byte for byte.
  $chat = "$chat"
  $bound = @($live | Where-Object { @(P $_ 'chats' @()).Count -gt 0 }).Count
  $chatMode = [bool]($chat -and $bound -gt 0)
  $units = @()
  foreach ($l in $live) {
    if ($chatMode) {
      $cs = @(P $l 'chats' @())
      if ($cs.Count) { $units += @($cs) } else { $units += ('session:' + [string](P $l 'session' '')) }
    } else { $units += [string](P $l 'session' '') }
  }
  $units = @(@($units | Where-Object { $_ }) | Sort-Object -Unique)
  $held = if ($chatMode) { @($charged | Where-Object { @(P $_ 'chats' @()) -contains $chat }).Count } else { @($charged | Where-Object { "$(P $_ 'session' '')" -eq "$sess" }).Count }
  $pin = [int](P $fs 'slotsPerSession' 0)
  $derived = [int][math]::Ceiling([double][math]::Max(0, [int]$taskCap) / [double][math]::Max(1, $units.Count))
  $share = if ($pin -gt 0) { $pin } else { [math]::Max(1, $derived) }
  [pscustomobject]@{
    enabled = [bool]$fs.enabled; competing = ($units.Count -gt 1); sessions = $units.Count
    held = [int]$held; share = [int]$share; slotsPerSession = $pin; taskCap = [int]$taskCap
    mode = $(if ($chatMode) { 'chat' } else { 'session' }); chat = $chat
    chargedIn = $repoFilter; chargedCount = @($charged).Count
  }
}
# D8 (owner 2026-11-28): the CHAT behind a lease, for DISPLAY. D6/D7 made the CHAT the accounting unit, but
# `status` and `who` still showed the SESSION, so one window's 18 leases under a single `term-<pid>` could
# not be told apart - which lease belongs to which chat was unreadable. These helpers turn a lease into
# "which chat, how old". The id is the lease's FIRST chat binding: the guard hook writes it to the
# <lease>.json.chat sidecar, attached as `.chats` by Add-LeaseChats (status) or read here for a RAW
# Read-Leases view (`who`); a lease with no binding falls back to its session. The AGE is the per-chat
# registry file's CREATION time (<Root>\chats\<id>.json, the same file Get-ShareChatId confirms against),
# i.e. how long that chat has been working here - $null (shown '-') when the registry file is gone.
function Get-ChatAgeMin([string]$chatId) {
  if (-not $chatId) { return $null }
  try {
    $cf = Join-Path (Join-Path $Root 'chats') (($chatId -replace '[^A-Za-z0-9._-]', '_') + '.json')
    if (-not [IO.File]::Exists($cf)) { return $null }
    [math]::Round(((Now) - [IO.File]::GetCreationTimeUtc($cf)).TotalMinutes, 1)
  } catch { $null }
}
# The lease's chat (id + age + idle), or its session when no chat is bound. ONE helper, so `status`, `who`
# and the doctor rows cannot drift on which chat a lease belongs to. The `chats` key is tested on an
# IDictionary and on a PSObject: the helper suite builds hashtables by hand, the real path passes objects.
function Get-LeaseChatInfo($l) {
  $idleMin = $null; $ids = @()
  if ($l) {
    try {
      $isDict = $l -is [System.Collections.IDictionary]
      $hasChats = if ($isDict) { $l.Contains('chats') } else { @($l.PSObject.Properties.Name) -contains 'chats' }
      if ($hasChats) { $ids = @(P $l 'chats' @()) }
      elseif ("$(P $l 'file' '')") { $ch = Read-LeaseChat "$(P $l 'file')"; $ids = @($ch.chats); if ($ch.at) { $idleMin = [math]::Round(((Now) - $ch.at).TotalMinutes, 1) } }
    } catch {}
  }
  $ids = @($ids | ForEach-Object { "$_" } | Where-Object { $_ })
  if (-not $ids.Count) { return [pscustomobject]@{ key = 'session'; id = "$(P $l 'session' '')"; ageMin = $null; idleMin = $idleMin } }
  $id = "$($ids[0])"
  [pscustomobject]@{ key = 'chat'; id = $id; ageMin = (Get-ChatAgeMin $id); idleMin = $idleMin }
}
# "chat <id> (age 12m, idle 3m)" for the SLOT SHARE held list, or "session <id>" when no chat is bound.
function Format-LeaseChatTag($l) {
  $ci = Get-LeaseChatInfo $l
  if ($ci.key -ne 'chat') { return "session $($ci.id)" }
  $age = if ($null -ne $ci.ageMin) { "$($ci.ageMin)m" } else { '-' }
  $idle = if ($null -ne $ci.idleMin) { "$($ci.idleMin)m" } else { '-' }
  "chat $($ci.id) (age $age, idle $idle)"
}
# "<id> (age 12m, idle 3m)" for the `who` chat column, or '-' when the lease has no chat binding.
function Format-LeaseChatCell($l) {
  $ci = Get-LeaseChatInfo $l
  if ($ci.key -ne 'chat') { return '-' }
  $age = if ($null -ne $ci.ageMin) { "$($ci.ageMin)m" } else { '-' }
  $idle = if ($null -ne $ci.idleMin) { "$($ci.idleMin)m" } else { '-' }
  "$($ci.id) (age $age, idle $idle)"
}
# (1) REUSE BEFORE RENTING: the CLEAN slot of $role this session already holds in $repoName, else $null.
# The dirty test is the SAME one the pre-gate uses (tracked OR non-ignored untracked changes disqualify):
# handing a slot back while the caller is still writing in it would silently lose that work.
function Get-SlotReuse([string]$repoName, [string]$role, [string]$slot) {
  if (-not (Get-FairShare).enabled) { return $null }
  foreach ($l in @(Read-Leases $repoName)) {
    if (-not $l -or $l.stale) { continue }
    # 2026-11-27: an EXPLICIT -Slot reuses too - the named-slot twin of D5. Without it `-Slot scratch-N`
    # on a lease MY session already holds skipped D5, fell into New-Lease, found the slot held and NOT
    # stale (scratch staleness is leaseScratchIdleMin = 15 min) and waited the full 15 min: measured
    # 905-906 s in ps/tests/test-lease-spawns.ps1, i.e. 87% of the whole devcloud pool gate (1044 s) and
    # of every land pre-gate that rents through it. Test-GitClean still gates the reuse, so a DIRTY own
    # slot keeps the old wait-then-take-over path (nothing is lost).
    if ($slot -and "$(P $l 'slot' '')" -cne "$slot") { continue }
    if ("$(P $l 'role' '')" -ne "$role") { continue }
    # D7 (owner 2026-11-28): OURS, not "the same session" - the whole point of the reuse is that a chat gets
    # its OWN slot back, and its session id is NEW after a window reload. Test-LeaseOurs is the recovery
    # predicate (my session, or my chat with the recorded owner host gone): a chat id is one conversation,
    # and a lease another LIVE session holds is never ours.
    if (-not (Test-LeaseOurs $l)) { continue }
    $p = Norm-Dir "$(P $l 'path' '')"
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { continue }
    # D7: a slot my CHAT was working in (recorded owner host gone) is handed back AS IT IS, dirty tree
    # included - that tree IS this conversation's own work, and a recovery that reset or refused it would be
    # worse than renting a new slot. The cleanliness rule stays for every other reuse: handing a slot back
    # while its holder is still writing in it would silently lose that work.
    $recover = Test-LeaseChatMine $l
    if (-not $recover -and -not (Test-GitClean $p)) { continue }
    $jr = @{ event = 'slot-reuse'; resource = "slot:${repoName}:$($l.slot)"; ticket = "$(P $l 'leaseId' '')"; session = $Session; role = $role; slot = "$($l.slot)"; repo = $repoName; purpose = "$(P $l 'purpose' '')" }
    if ($recover) { $jr.recovery = $true }
    Write-Journal $jr
    return $l
  }
  $null
}
# (2) PER-SESSION SHARE: $null while this session may still rent, else the refusal text (journaled ONCE).
function Test-SlotShareRefusal([string]$repoName, [string]$role, [switch]$PerRepo) {
  $fs = Get-FairShare
  if (-not (Get-Variable -Name SlotShareSaid -Scope Script -ErrorAction SilentlyContinue)) { $script:SlotShareSaid = $false }
  # NOTE the $cap local: the literal call below is pinned by test-agentq-slotshare.ps1 (A9), that IS the shape.
  $cap = [int](Get-TaskSlotBudget).cap
  # D6: ONE read of the all-repos view for the chat-id derivation and the "mine" list below, each lease
  # carrying its chat binding (Add-LeaseChats reads the sidecars only, and copies - never Add-Member: the
  # Read-Leases records are memoized in-process, so writing to them would leak a `chats` key into every other
  # view that reads the same list - status -Json, the SLO report). The chat id is best effort - Get-ShareChatId
  # returns $null for a call that is not under a live hook payload (a script, a scheduled task) and whenever
  # the hook's candidate cannot be CONFIRMED against the per-chat registry (see its D6 note); '' then keys the
  # share by session, exactly as before.
  $all = @(Add-LeaseChats (Read-Leases $null))
  $chat = "$(Get-ShareChatId $all)"
  # The ENRICHED all-repos view ($all, chat bindings attached above) goes in: Get-SlotShare's Add-LeaseChats
  # is idempotent, so the lease path and `status` share ONE store (the sidecars) without a second read.
  # test-agentq-slotshare.ps1 A9 pins this literal call shape.
  $sh = Get-SlotShare $all $Session $cap $chat $(if ($PerRepo) { $repoName } else { '' })
  # (a) owner 2026-11-28: an override that CHANGED THE OUTCOME is journaled - once per invocation, with the
  # numbers it overrode. Without this AGENTQ_NO_FAIRSHARE leaves no trace anywhere, and a fleet where every
  # caller quietly opts out looks exactly like a fleet with no contention. An override UNDER the share journals
  # nothing (it overrode nothing), and the read above is the price of knowing which of the two happened: it is
  # paid only while the override is set.
  if (-not $fs.enabled) {
    if (-not $script:SlotShareSaid -and $sh.competing -and $sh.held -ge $sh.share) {
      $script:SlotShareSaid = $true
      Write-Journal @{ event = 'fair-share-override'; resource = "slot:${repoName}:$(if ($role) { $role } else { 'slot' })"; session = $Session; keyBy = $sh.mode; chat = $sh.chat; held = [int]$sh.held; cap = [int]$sh.share; slotsPerSession = [int]$sh.slotsPerSession; sessions = [int]$sh.sessions; taskCap = [int]$sh.taskCap; perRepo = [bool]$PerRepo; repo = $repoName; reason = "AGENTQ_NO_FAIRSHARE=1 admitted a call the share refused ($($sh.held)/$($sh.share) slot(s), $($sh.sessions) unit(s) competing)" }
    }
    return $null
  }
  if (-not $sh.competing -or $sh.held -lt $sh.share) { return $null }
  # Who is "mine" follows the SAME key as `held`, or the message would name slots the refusal never counted.
  $isMine = { param($l) if ($sh.mode -eq 'chat') { @(P $l 'chats' @()) -contains $chat } else { "$(P $l 'session' '')" -eq "$Session" } }
  $mine = @($all | Where-Object { $_ -and -not $_.stale -and (& $isMine $_) })
  # the message lists what was CHARGED, or it would name slots the refusal never counted
  if ($PerRepo) { $mine = @($mine | Where-Object { "$(P $_ 'repo' '')" -ceq "$repoName" }) }
  # repo/slot, not the bare slot: this list is built from Read-Leases $null (EVERY repo), and the same
  # slot NAME lives in each repo (`codai/scratch-1` beside `marcai/scratch-1`), so a bare name read as one
  # duplicate lease held twice (the same 2026-11-27 display defect fixed in Show-SlotShare).
  $heldTxt = ($mine | ForEach-Object { "$($_.repo)/$($_.slot) ($($_.leaseId), idle $($_.idleMin)m, '$($_.purpose)')" }) -join '; '
  $keyTxt = if ($sh.mode -eq 'chat') { "chat $chat" } else { "session $Session" }
  $unitTxt = if ($sh.mode -eq 'chat') { 'chats' } else { 'sessions' }
  if (-not $script:SlotShareSaid) {
    $script:SlotShareSaid = $true
    Write-Journal @{ event = 'slot-fair-share'; resource = "slot:${repoName}:$(if ($role) { $role } else { 'slot' })"; session = $Session; keyBy = $sh.mode; chat = $sh.chat; held = [int]$sh.held; cap = [int]$sh.share; slotsPerSession = [int]$sh.slotsPerSession; sessions = [int]$sh.sessions; taskCap = [int]$sh.taskCap; slots = @($mine | ForEach-Object { "$($_.slot)" }); repo = $repoName; reason = "this $keyTxt already holds $($sh.held) slot(s); its share of the machine task cap $($sh.taskCap) is $($sh.share) while $($sh.sessions) $unitTxt compete" }
  }
  "this $keyTxt already holds $($sh.held) of the $($sh.sessions) competing $unitTxt' share of $($sh.share) slot(s) (machine task cap $($sh.taskCap), slotsPerSession $($sh.slotsPerSession), keyed by $($sh.mode)): $heldTxt`n  Subagents work in the LEAD's slot - pass them its path. You may reuse a slot this session already holds; or give one back first: agentq unlease -Repo <path> -LeaseId <id>; or wait for another $unitTxt to finish."
}
# The `SLOT SHARE` line of `status`. It answers three questions in one line (D8, owner 2026-11-28):
#   (a) how many slots MY chat holds vs its fair share - printed ALWAYS, so a lone holder still reads "3/3"
#       and never a bare "15 (nothing else competes)" (the number that started this);
#   (b) how many chats (or sessions, when no chat key applies) compete for the machine task cap;
#   (c) for EVERY held slot, the CHAT it belongs to and that chat's age - not just the session.
function Show-SlotShare {
  $fs = Get-FairShare
  if (-not $fs.enabled) { Write-Output 'SLOT SHARE off (fairShare.enabled = false)'; return }
  # D6: the status line shows the SAME key the refusal uses, or the two would disagree (the reader would see
  # 17 held by the window while the refusal charged 1 to the chat). The "mine" list below needs the enriched
  # view; Get-SlotShare attaches the bindings itself, so the enriched list is handed in as-is (one store -
  # see Test-SlotShareRefusal; Add-LeaseChats is idempotent). Copies, never Add-Member: the Read-Leases
  # records are memoized in-process.
  $leases = @(Add-LeaseChats (Read-Leases $null))
  $cap = [int](Get-TaskSlotBudget).cap
  $chat = "$(Get-ShareChatId $leases)"
  $sh = Get-SlotShare $leases $Session $cap $chat
  $isMine = { param($l) if ($sh.mode -eq 'chat') { @(P $l 'chats' @()) -contains $chat } else { "$(P $l 'session' '')" -eq "$Session" } }
  $mine = @($leases | Where-Object { $_ -and -not $_.stale -and (& $isMine $_) })
  # repo/slot, not the bare slot: the same slot NAME lives in every repo (`codai\scratch-1` next to
  # `marcai\scratch-1`), so a bare name made two sessions in different repos read as one duplicate lease
  # (2026-11-27). D8 adds the CHAT + its AGE to each entry, so a window's many chats are a readable list.
  $held = ($mine | ForEach-Object { " [$($_.repo)/$($_.slot) $(P $_ 'role' '') $(Format-LeaseChatTag $_)]" }) -join ''
  $unitTxt = if ($sh.mode -eq 'chat') { 'chats' } else { 'sessions' }
  $keyId = if ($sh.mode -eq 'chat') { $chat } else { $Session }
  $keyTxt = if ($sh.mode -eq 'chat') { "my chat $keyId" } else { "my session $keyId" }
  # (a) held vs share ALWAYS; (b) the competing count; both derivation numbers last.
  $compete = if ($sh.competing) { "$($sh.sessions) $unitTxt compete" } else { 'nothing else competes' }
  Write-Output ("SLOT SHARE {0}/{1} held by {2} - {3} (machine task cap {4}, slotsPerSession $($sh.slotsPerSession)){5}" -f $sh.held, $sh.share, $keyTxt, $compete, $sh.taskCap, $held)
}
# Interleave by round: round 1 takes each session's first waiter, round 2 its second, ... so one
# session's block of five waiters cannot sit in front of another session's single waiter. Grouping
# them (round-robin by session, not by round) would NOT fix the starvation it was written for
# (caught by this repository's own suite, 2026-11-21). Order inside a session is preserved.
function Sort-BySession($waiting, [string[]]$sessions) {
  $rest = [Collections.ArrayList]::new()
  foreach ($x in @($waiting)) { [void]$rest.Add($x) }
  $out = @()
  while ($rest.Count -gt 0) {
    $took = $false
    foreach ($s in $sessions) {
      $i = -1
      for ($k = 0; $k -lt $rest.Count; $k++) { if ("$(P $rest[$k] 'session' '?')" -eq $s) { $i = $k; break } }
      if ($i -ge 0) { $out += $rest[$i]; $rest.RemoveAt($i); $took = $true }
    }
    if (-not $took) { foreach ($x in $rest) { $out += $x }; break }
  }
  $out
}
# Legacy tickets (no `v`, written by agentq <= 0.2 during an install transition) hold by position.
function Test-Held($t, [object[]]$live, [int]$cap) {
  if (P $t 'v') { return [bool](P $t 'held' $false) }
  $legacy = @($live | Where-Object { -not (P $_ 'v') })
  [array]::IndexOf(@($legacy | ForEach-Object id), $t.id) -lt $cap
}
function Update-Ticket($t, [hashtable]$set) {
  $raw = Get-Content -LiteralPath $t.file -Raw | ConvertFrom-Json -AsHashtable
  foreach ($k in $set.Keys) { $raw[$k] = $set[$k] }
  [IO.File]::WriteAllText("$($t.file).tmp", ($raw | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move("$($t.file).tmp", $t.file, $true)
}

# ---- admission by load (ADR 0009 stage 0, OQ-004) -----------------------------------------------
# The caps count builds and slots, not how the machine feels. The load probe (agentq-probe.ps1) is the
# start latency of a trivial process; when its recent median is above `admission.probeMs` the machine
# is saturated and agentq stops ADDING load: a gate/heavy/batch build is not granted while another
# build already holds build:machine, and a new task lease waits. Progress is guaranteed: with no
# holder a build still starts, quick/interactive lanes are never gated, and a waiter held back only by
# load for `admission.maxHoldMin` is admitted anyway (journal `admission-override`).
# Config `admission`: { enabled, probeMs 400, window 5, everySec 20, staleSec 300, maxHoldMin 20 }.
# AGENTQ_NO_ADMISSION=1 turns it off for one call.
. (Join-Path $PSScriptRoot 'agentq-probe.ps1')
function Get-AdmissionConfig {
  if ($script:AdmCfg) { return $script:AdmCfg }
  $d = @{ enabled = $true; probeMs = 400; window = 5; everySec = 20; staleSec = 300; maxHoldMin = 20 }
  $c = Get-Config
  if ($c.ContainsKey('admission') -and $c['admission'] -is [Collections.IDictionary]) { foreach ($k in @($c['admission'].Keys)) { $d["$k"] = $c['admission'][$k] } }
  if ($env:AGENTQ_NO_ADMISSION -eq '1') { $d.enabled = $false }
  $script:AdmCfg = $d
  $d
}
# -NoSample (and every read-only verb): judge the shared record, never take a sample.
function Get-AdmissionLoad([switch]$NoSample) {
  $a = Get-AdmissionConfig
  if (-not $a.enabled) { return @{ enabled = $false; saturated = $false; median = $null; last = $null; ageSec = $null; n = 0; thresholdMs = [double]$a.probeMs; src = '' } }
  $p = if ($NoSample -or $script:ReadOnly) { Read-LoadProbe $Root } else { Invoke-LoadProbe $Root ([double]$a.everySec) 12 'agentq' }
  $v = Get-LoadVerdict $p ([double]$a.probeMs) ([int]$a.window) ([double]$a.staleSec)
  $v.enabled = $true
  $v
}
# Called each time a waiter is held back by load. Journals the hold once and returns $true when the
# waiter has been held long enough to be admitted anyway.
function Test-AdmissionOverride([string]$res, [string]$purpose, $load) {
  if ($script:LoadOverride) { return $true }
  if (-not $script:LoadHoldSince) {
    $script:LoadHoldSince = Now
    Write-Journal @{ event = 'admission-hold'; resource = $res; purpose = $purpose; probeMs = $load.median; thresholdMs = $load.thresholdMs; reason = "machine saturated: start probe median $($load.median) ms > $($load.thresholdMs) ms" }
  }
  $max = [double](Get-AdmissionConfig).maxHoldMin
  if (((Now) - $script:LoadHoldSince).TotalMinutes -ge $max) {
    $script:LoadOverride = $true
    Write-Journal @{ event = 'admission-override'; resource = $res; purpose = $purpose; probeMs = $load.median; thresholdMs = $load.thresholdMs; reason = "held $max min by load; admitted anyway" }
    return $true
  }
  $false
}
function Get-LoadWaitSec { if ($script:LoadHoldSince) { [int][math]::Round(((Now) - $script:LoadHoldSince).TotalSeconds) } else { 0 } }

# ---- agent limit by owner presence and schedule (ADR 0009 stage 0, OQ-005) ----------------------
# taskSlotsMachine is one number for every hour of the day. `agentLimit` lets the machine-wide limit on
# task leases follow the owner:
#   present   while the last keyboard or mouse input is younger than awayAfterMin (default 15)
#   night     owner away and the local time is inside night.from..night.to (may wrap midnight)
#   away      owner away, outside the night window
# A value that is not set means taskSlotsMachine, so a config without numbers changes nothing. Presence is
# read from the shared load record (agentq-probe.ps1; the resident sync loop samples once a minute); a
# record older than admission.staleSec, or one without an idle value, is "unknown" = taskSlotsMachine.
# The limit only gates NEW task leases; nothing that runs is ever stopped. Release, land and pinned slots
# are not counted. AGENTQ_NO_AGENT_LIMIT=1 turns it off for one call.
function Get-AgentLimit {
  $c = Get-Config
  $base = [int]$c.taskSlotsMachine
  $r = @{ limit = $base; base = $base; state = 'off'; idleSec = $null; ageSec = $null; night = $false; nightWindow = ''; why = 'agentLimit is off' }
  $al = if ($c.ContainsKey('agentLimit') -and $c['agentLimit'] -is [Collections.IDictionary]) { $c['agentLimit'] } else { $null }
  if (-not $al -or -not $al['enabled'] -or $env:AGENTQ_NO_AGENT_LIMIT -eq '1') { return $r }
  $num = { param($v) if ($null -ne $v -and "$v" -ne '') { [math]::Max(1, [int]$v) } else { $base } }
  $awayAfterSec = 60 * $(if ($null -ne $al['awayAfterMin'] -and "$($al['awayAfterMin'])" -ne '') { [double]$al['awayAfterMin'] } else { 15.0 })
  $n = $al['night']
  $nightLimit = $base
  if ($n -is [Collections.IDictionary] -and $n['from'] -and $n['to']) {
    try {
      $from = [TimeSpan]::Parse("$($n['from'])", [Globalization.CultureInfo]::InvariantCulture); $to = [TimeSpan]::Parse("$($n['to'])", [Globalization.CultureInfo]::InvariantCulture)
      $nowT = if ($env:AGENTQ_FAKE_LOCALTIME) { [TimeSpan]::Parse($env:AGENTQ_FAKE_LOCALTIME, [Globalization.CultureInfo]::InvariantCulture) } else { (Get-Date).TimeOfDay }
      $r.night = if ($from -le $to) { $nowT -ge $from -and $nowT -lt $to } else { $nowT -ge $from -or $nowT -lt $to }
      $r.nightWindow = "$($n['from'])-$($n['to'])"
      $nightLimit = & $num $n['limit']
    } catch { $r.night = $false }
  }
  $p = Read-LoadProbe $Root
  $at = if ($p) { ConvertTo-ProbeUtc $p['at'] } else { $null }
  if ($at) { $r.ageSec = [math]::Round(((Now) - $at).TotalSeconds) }
  $known = $p -and $at -and $null -ne $p['idleSec'] -and $r.ageSec -le [double](Get-AdmissionConfig).staleSec
  if (-not $known) { $r.state = 'unknown'; $r.why = 'owner presence unknown (no fresh sample)'; return $r }
  $r.idleSec = [double]$p['idleSec']
  if ($r.idleSec -lt $awayAfterSec) { $r.state = 'present'; $r.limit = & $num $al['present']; $r.why = "owner present (last input $([int]$r.idleSec) s ago)" }
  elseif ($r.night) { $r.state = 'night'; $r.limit = $nightLimit; $r.why = "owner away, night schedule $($r.nightWindow)" }
  else { $r.state = 'away'; $r.limit = & $num $al['away']; $r.why = "owner away (no input for $([int][math]::Floor($r.idleSec / 60)) min)" }
  $r
}
# Can ticket $t take a slot on its resource NOW? Returns @{ ok; why }.
function Test-Admissible($t, [scriptblock]$gate) {
  $live = @(Get-Live $t.resource)
  if (-not ($live | Where-Object id -eq $t.id)) { throw "agentq: ticket $($t.id) vanished from $($t.resource) (broken by another agent? see agentq log)" }
  $cap = Get-Capacity $t.resource
  # A holder whose process tree has been idle (idle-yield, DC-012) does not occupy a machine slot.
  $held = @($live | Where-Object { (Test-Held $_ $live $cap) -and -not ($t.resource -eq 'build:machine' -and (P $_ 'yielded' $false)) })
  $heldIds = @($live | Where-Object { Test-Held $_ $live $cap } | ForEach-Object { $_.id })
  # Waiters that cannot start anyway (blocked on another resource of the same run: ready=false)
  # do not reserve a slot here — backfill lets the next ready waiter use it (DC-013).
  $waiting = @($live | Where-Object { ($heldIds -notcontains $_.id) -and ($_.id -eq $t.id -or (P $_ 'ready' $true)) } |
      Sort-Object @{ e = { Get-EffPrio $_ }; Descending = $true }, @{ e = { [long]$_.seq } })
  if ($t.resource -like 'land:*' -and $waiting.Count -gt 1) { $waiting = @(Sort-ByClaims $waiting) }
  $lane = "$(P $t 'lane' 'gate')"
  # D4 (ADR 0014): round-robin the rank order over sessions while >= 2 sessions compete, so one
  # agent's fan-out does not sit as a block in front of another session's single waiter.
  $fs = Get-FairShare
  $fsRefused = $false
  if ($fs.enabled -and $cap -ge 2 -and $waiting.Count -gt 1) {
    $sess = @()
    foreach ($x in @($held + $waiting)) { $s = "$(P $x 'session' '?')"; if ($sess -notcontains $s) { $sess += $s } }
    if ($sess.Count -ge 2) {
      if ($fs.maxPerSession -le 0) { $fs.maxPerSession = [int][math]::Ceiling($cap / $sess.Count) }
      $bySess = @{}
      foreach ($h in $held) { $hs = "$(P $h 'session' '?')"; $bySess[$hs] = [int]$bySess[$hs] + 1 }
      # A session already at its share is NOT ranked at all: the slot a holder just freed goes to the
      # other session instead of idling under a ticket that would be refused anyway. The filter is the
      # same for every caller, so two tickets never disagree about who is in front.
      $mineShared = ([int]$bySess["$(P $t 'session' '?')"]) -ge $fs.maxPerSession
      if ($mineShared) {
        $fsRefused = $true
        if ($script:FsNoted -ne $t.id) {
          $script:FsNoted = $t.id
          Write-Journal @{ event = 'fair-share'; resource = $t.resource; ticket = $t.id; session = "$(P $t 'session' '?')"; held = [int]$bySess["$(P $t 'session' '?')"]; cap = $cap; maxPerSession = $fs.maxPerSession; reason = 'another session is waiting: my session is at its share' }
        }
        $script:PreemptNote = "fair share: my session holds $([int]$bySess["$(P $t 'session' '?')"]) of $cap (share $($fs.maxPerSession))"
      }
      $waiting = @($waiting | Where-Object { ([int]$bySess["$(P $_ 'session' '?')"]) -lt $fs.maxPerSession })
      $waiting = @(Sort-BySession $waiting $sess)
    }
  }
  $rank = [array]::IndexOf(@($waiting | ForEach-Object id), $t.id)
  $ok = ($rank -ge 0 -and $rank -lt ($cap - $held.Count))
  if (-not $ok -and $t.resource -eq 'build:machine') {
    # Soft slots (DC-011): quick/interactive jobs get `quickBurst` extra slots so a 5 s lint never
    # waits behind two 30 min gates; any non-batch job may run beside a batch holder (batch runs at
    # Idle CPU priority, so it yields — that is the preemption). Ranked only among their peers.
    $c = Get-Config
    $heldBatch = @($held | Where-Object { "$(P $_ 'lane' 'gate')" -eq 'batch' }).Count
    if ($lane -in 'interactive', 'quick') {
      $peers = @($waiting | Where-Object { "$(P $_ 'lane' 'gate')" -in 'interactive', 'quick' })
      $r = [array]::IndexOf(@($peers | ForEach-Object id), $t.id)
      $burstUsed = [math]::Max(0, $held.Count - $cap)
      $ok = ($r -ge 0 -and $r -lt ([int]$c.quickBurst - $burstUsed))
      if ($ok) { $script:PreemptNote = 'quick burst slot' }
    }
    if (-not $ok -and $lane -ne 'batch' -and $heldBatch -gt 0) {
      $peers = @($waiting | Where-Object { "$(P $_ 'lane' 'gate')" -ne 'batch' })
      $r = [array]::IndexOf(@($peers | ForEach-Object id), $t.id)
      $ok = ($r -ge 0 -and ($held.Count - $heldBatch + $r) -lt $cap)
      if ($ok) { $script:PreemptNote = "beside $heldBatch batch holder(s)" }
    }
  }
  # OQ-004: a saturated machine does not get a second gate/heavy/batch run - a build (build:machine) or a
  # heavy gate (gate:machine) alike. One such run always starts, and it is the FIRST in rank: without the
  # rank test a lower-priority waiter that polled right after the holder ended started first and the
  # higher-priority one was then held by load behind it.
  if ($ok -and $t.resource -in 'build:machine', 'gate:machine' -and $lane -notin 'interactive', 'quick' -and ($held.Count -ge 1 -or $rank -ge 1)) {
    # -NoSample: this runs under the scheduler mutex; Wait-All refreshes the sample before taking it.
    $ld = Get-AdmissionLoad -NoSample
    if ($ld.saturated -and -not (Test-AdmissionOverride $t.resource "$(P $t 'purpose' '')" $ld)) {
      return @{ ok = $false; why = 'load'; load = $ld; live = $live; held = $held; cap = $cap; rank = $rank }
    }
  }
  if (-not $ok) { return @{ ok = $false; why = 'queue'; live = $live; held = $held; cap = $cap; rank = $rank; fairShare = $fsRefused } }
  if ($gate -and -not (& $gate)) { return @{ ok = $false; why = 'ram'; live = $live; held = $held; cap = $cap; rank = $rank } }
  @{ ok = $true; why = ''; live = $live; held = $held; cap = $cap; rank = $rank }
}

function Get-Mark([string]$res) {
  $f = Join-Path $MDir ((Safe $res) + '.json')
  if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json -DateKind String } else { $null }
}

# Policy (docs/RELEASE_TRAIN.md): a `land:<repo>` freeze is at most `landFreezeMaxMin` (30) minutes and is
# never held for a whole train; an older mark with no fresh note is expired and may be broken by any land,
# which records why. Other marks (incident/provider/deploy/slot) never expire: they are cleared by hand.
# 2026-11-24: an ad-hoc release orchestrator held `land:brivio` frozen ~3 h across its own nightly retry
# loop, so two lanes queued for hours behind a freeze the policy already called breakable. Config `-1`
# disables the expiry for a repo that genuinely needs a long pin (and must then clear it by hand).
function Get-LandFreezeMaxMin {
  $c = Get-Config
  if ($c.ContainsKey('landFreezeMaxMin') -and $null -ne $c['landFreezeMaxMin']) { return [double]$c['landFreezeMaxMin'] }
  30.0
}
function Test-MarkExpired($m) {
  if (-not $m -or "$($m.resource)" -notmatch '^land:') { return $false }
  $max = Get-LandFreezeMaxMin
  if ($max -lt 0 -or -not $m.at) { return $false }
  try { ((Now) - (ParseUtc $m.at)).TotalMinutes -ge $max } catch { $false }
}
function Assert-NotMarked([string]$res) {
  $m = Get-Mark $res
  if ($m) {
    if (Test-MarkExpired $m) {
      $age = try { [int][math]::Round(((Now) - (ParseUtc $m.at)).TotalMinutes) } catch { 0 }
      [Console]::Error.WriteLine("agentq: $res was $($m.state.ToUpper()) since $($m.at) by $($m.session) - EXPIRED after $age min (max $([int](Get-LandFreezeMaxMin)) min, docs/RELEASE_TRAIN.md); breaking it and proceeding")
      Remove-Item (Join-Path $MDir ((Safe $res) + '.json')) -Force -ErrorAction SilentlyContinue
      Write-Journal @{ event = 'freeze-expired'; resource = $res; session = $m.session; ageMin = $age; reason = $m.reason }
      return
    }
    [Console]::Error.WriteLine("agentq: $res is $($m.state.ToUpper()) since $($m.at) by $($m.session): $($m.reason)")
    [Console]::Error.WriteLine("        clear it (only if the reason no longer holds): agentq mark -Resource $res -State clear -Reason '<why>'")
    exit 3
  }
}

function New-Ticket([string]$res, [string]$purpose, [string]$cmd, [string]$repoTop) {
  $dir = QPath $res
  $m = [Threading.Mutex]::new($false, "Global\agentq-$(Safe $res)$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  try {
    try { [void]$m.WaitOne(10000) } catch [Threading.AbandonedMutexException] {}
    # The folder is created UNDER the queue mutex: `agentq prune` removes an idle, ticket-less queue
    # folder while holding the same mutex, so a folder can no longer vanish between this check and
    # the seq write below (reproduced 2026-11-11: "Could not find a part of the path ...\seq").
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null; Set-RepoGroupDir $dir (Get-ResourceRepo $res) }
    if ($script:CapacityGiven -or -not (Test-Path (Join-Path $dir 'capacity'))) {
      $cap = if ($script:Capacity -gt 1) { $script:Capacity } else { Get-Capacity $res }
      [IO.File]::WriteAllText((Join-Path $dir 'capacity'), "$cap")
    }
    $seqFile = Join-Path $dir 'seq'
    $seq = if (Test-Path $seqFile) { [long](Get-Content $seqFile -Raw) + 1 } else { 1 }
    # NOT `Set-Content -NoNewline <path> <v>`: in pwsh 7.6 that positional form writes NOTHING,
    # so seq never advanced, every ticket got seq 1 and two holders ran at once.
    [IO.File]::WriteAllText($seqFile, "$seq")
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    # The holder is the long-lived process: this pwsh running `agentq run` (it spawns and
    # waits for the command). For acquire/release from a script, pass the owning PID via
    # $env:AGENTQ_OWNER_PID.
    $owner = if ($env:AGENTQ_OWNER_PID) { [int]$env:AGENTQ_OWNER_PID } else { $PID }
    $t = [ordered]@{
      id = $id; seq = $seq; resource = $res; pid = $owner; procStart = (Iso (Get-ProcStart $owner))
      session = $Session; purpose = $purpose; cmd = $cmd; repo = $repoTop; host = [Environment]::MachineName; user = [Environment]::UserName
      created = (Iso (Now))
      # v3: priority scheduling. held flips true when the scheduler grants the slot; ready=false
      # while the same run is still blocked on another resource (backfill skips it).
      v = 3; lane = (Resolve-Lane $res $script:Lane); prio = [math]::Max(-50, [math]::Min(50, $script:Priority)); bump = 0
      held = $false; ready = $true
    }
    $file = Join-Path $dir ('{0:D8}-{1}.json' -f $seq, $id)
    # Atomic publish: a reader must never see a half-written ticket (it would parse-fail,
    # be skipped, and the next waiter would think it is first — observed as an overlap).
    [IO.File]::WriteAllText("$file.hb", '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText("$file.tmp", ($t | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move("$file.tmp", $file)
    [pscustomobject]$t | Add-Member -NotePropertyName file -NotePropertyValue $file -PassThru
  } finally { try { $m.ReleaseMutex() } catch {} ; $m.Dispose() }
}

# Give a ticket back early (idempotent with the `finally` that removes it). Used by Invoke-Commit to end
# the index lock BEFORE the pre-push gates run, so the next agent's `git add` starts immediately.
function Drop-Ticket($t) {
  if (-not $t) { return }
  $f = (P $t 'file'); if (-not $f) { return }
  Remove-Item -LiteralPath $f, "$f.hb" -Force -ErrorAction SilentlyContinue
}

# Acquire ALL tickets of one run atomically (DC-013): nothing is held while any part waits, so a
# run waiting for build:machine no longer blocks build:<repo> (96.5 h measured in 15 days).
# Check+grant happens under one machine-wide mutex so two runs never both take the last slot.
function Wait-All([object[]]$tickets, [hashtable]$gates, [int]$timeoutMin) {
  $deadline = (Now).AddMinutes($timeoutMin)
  $announced = [DateTime]::MinValue
  $ready = @{}; foreach ($t in $tickets) { $ready[$t.id] = $true }
  while ($true) {
    # ADR 0003 W2-5: a land waiter absorbed into another holder's batch stops waiting once its result exists.
    if ($script:WaitAbort -and (& $script:WaitAbort)) { $script:WaitAborted = $true; return }
    foreach ($t in $tickets) { Assert-NotMarked $t.resource; [IO.File]::SetLastWriteTimeUtc("$($t.file).hb", (Now)) }
    # A land waiter installs a per-poll hook (Invoke-LandWedgeReap in agentq-v2.ps1): it reaps a WEDGED
    # land HOLDER (heartbeat stale, gate green, no land event) so the freed cap-1 lock goes to this waiter
    # instead of needing a manual `agentq break -Id` (2026-11-23: 85.9 min on one topic, gate already green).
    # `$null =`: the hook RETURNS a bool, and an emitted value from here would land on agentq's STDOUT.
    if ($script:WaitPoll) { try { $null = & $script:WaitPoll } catch {} }
    # OQ-004: refresh the load sample (at most every admission.everySec, one sampler at a time) BEFORE
    # the scheduler mutex, so a slow process start on a saturated machine never holds the scheduler.
    if (@($tickets | Where-Object { $_.resource -eq 'build:machine' }).Count) { $null = Get-AdmissionLoad }
    $m = [Threading.Mutex]::new($false, "Global\agentq-sched$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
    $granted = $false; $res = @{}
    try {
      try { [void]$m.WaitOne(15000) } catch [Threading.AbandonedMutexException] {}
      foreach ($t in $tickets) { $res[$t.id] = Test-Admissible $t $gates[$t.id] }
      $allOk = -not ($tickets | Where-Object { -not $res[$_.id].ok })
      if ($allOk) {
        foreach ($t in $tickets) { Update-Ticket $t @{ held = $true; ready = $true; acquired = (Iso (Now)) } }
        $granted = $true
      } else {
        # A ticket whose sibling is blocked is not ready: let others backfill past it.
        foreach ($t in $tickets) {
          $sib = @($tickets | Where-Object { $_.id -ne $t.id -and -not $res[$_.id].ok })
          $r = ($sib.Count -eq 0)
          if ($ready[$t.id] -ne $r) { Update-Ticket $t @{ ready = $r }; $ready[$t.id] = $r }
        }
      }
    } finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
    if ($granted) {
      $wait = [math]::Round(((Now) - (ParseUtc $tickets[0].created)).TotalSeconds)
      Write-Journal @{ event = 'acquired'; resource = (($tickets | ForEach-Object resource) -join ','); tickets = @($tickets | ForEach-Object id); lane = $tickets[0].lane; waitSec = $wait; loadWaitSec = (Get-LoadWaitSec); purpose = $tickets[0].purpose; note = "$script:PreemptNote" }
      $script:WaitSec = $wait
      return
    }
    if (((Now) - $announced).TotalSeconds -ge 30) {
      $msgs = foreach ($t in $tickets) {
        $r = $res[$t.id]; if ($r.ok) { continue }
        $who = ($r.held | ForEach-Object { "$($_.session) '$($_.purpose)' [$(P $_ 'lane' '?')] $([math]::Round(((Now) - (ParseUtc $_.created)).TotalMinutes,1))m$(if ($_.stale) { ' STALE' })" }) -join '; '
        $why = if ($r.why -eq 'ram') { 'waiting for free RAM/commit' } elseif ($r.why -eq 'load') { "machine saturated (start probe median $($r.load.median) ms > $($r.load.thresholdMs) ms): no second build until it recovers or $([double](Get-AdmissionConfig).maxHoldMin) min pass" } elseif ($r.fairShare) { "session fair share: my session already holds its slots of cap $($r.cap) and another session is waiting (ADR 0014 D4)" } else { "rank $($r.rank + 1) by priority, cap $($r.cap)" }
        "$($t.resource) [$($t.lane)] $why; held by: $who"
      }
      [Console]::Error.WriteLine("agentq: waiting — $($msgs -join ' | ')")
      [Console]::Error.WriteLine("        stuck? agentq propose -Reason '...' | agentq bump [-Id <hash>] -By 20 -Reason '...' | agentq burst -Resource build:machine -Reason '...'")
      $announced = Now
    }
    if ((Now) -gt $deadline) {
      # 2026-11-23: a LAND that hit its window used to LEAVE the queue (exit 3) - with 8+ waiters ahead the
      # attempts "evaporated" (measured 10 x "timed out after 60 min" in 90 min, each re-queued by hand at
      # the BACK), so a deep land queue never advanced. Instead the SAME ticket goes back to the HEAD of its
      # queue (seq 0, below every live seq; prio/bump = its ORIGINAL priority kept) and waits one more window,
      # bounded by `landRequeueMax` (default 3). Journaled `land-requeue`. Only after the cap does it give up,
      # so it can never loop forever. A non-land resource keeps the old give-up behaviour.
      $isLand = @($tickets | Where-Object { "$($_.resource)".StartsWith('land:') }).Count -gt 0
      if ($isLand -and -not $script:ReadOnly) {
        $maxRequeue = 3
        try { $lc = Get-Config; if ($lc.ContainsKey('landRequeueMax') -and $null -ne $lc['landRequeueMax']) { $maxRequeue = [math]::Max(0, [int]$lc['landRequeueMax']) } } catch {}
        if ($script:LandRequeue -lt $maxRequeue) {
          $script:LandRequeue++
          foreach ($t in $tickets) {
            $waitedSec = [int][math]::Round(((Now) - (ParseUtc $t.created)).TotalSeconds)
            Update-Ticket $t @{ seq = [long]0 }
            Write-Journal @{ event = 'land-requeue'; resource = $t.resource; ticket = $t.id; waitedSec = $waitedSec; attempts = [int]$script:LandRequeue; max = $maxRequeue; seq = [long]0; purpose = $t.purpose }
          }
          [Console]::Error.WriteLine("agentq: land wait expired after $timeoutMin min - put back at the HEAD of the queue (attempt $($script:LandRequeue)/$maxRequeue); nothing lost")
          $deadline = (Now).AddMinutes($timeoutMin)
          continue
        }
      }
      foreach ($t in $tickets) { Remove-Ticket $t "timed out after $timeoutMin min" 'timeout' }
      [Console]::Error.WriteLine("agentq: gave up waiting for $(($tickets | ForEach-Object resource) -join ',') after $timeoutMin min")
      exit 3
    }
    Start-Sleep -Milliseconds 1500
  }
}

function Wait-Turn($ticket, [int]$timeoutMin, [scriptblock]$extraGate, [object[]]$heldTickets = @()) {
  # Kept for single-resource callers (commit, land, acquire): now priority-aware via Wait-All.
  Wait-All @($ticket) @{ $ticket.id = $extraGate } $timeoutMin
}

# ---- one machine-memory authority (D3, ADR 0014) -------------------------------------------------
# "How much memory must be free before work starts" was answered in three places with three numbers:
#   * the queue gate     -MinFreeGB, default 6, handed to Test-FreeRam;
#   * the burst gate     -MinFreeGB * 2 = 12, an inline x2 that named no config key;
#   * the adaptive cap   machineCapAdaptive.minFreeRamGB / minFreeCommitGB = 24 / 24.
# Get-MachineMemory is the ONE place that reads them, next to the live numbers, so they can be shown
# side by side (`agentq doctor` row `machine-memory`) and `unified` says whether they still agree.
# The config-derived part is cached per process: Test-FreeRam runs inside every poll's gate scriptblock.
# The VALUES are unchanged on purpose - collapsing them to one number decides which builds start, and
# that is a scheduling policy (pick one, then set the config), not a refactor.
function Get-MachineMemory([double]$queueGB) {
  if ($null -eq $script:MmFloors) {
    $cfg = Get-Config
    $a = if ($cfg.ContainsKey('machineCapAdaptive')) { $cfg['machineCapAdaptive'] } else { $null }
    $ramA = if ($a -and $a.ContainsKey('minFreeRamGB') -and $null -ne $a['minFreeRamGB']) { [double]$a['minFreeRamGB'] } else { 24.0 }
    $comA = if ($a -and $a.ContainsKey('minFreeCommitGB') -and $null -ne $a['minFreeCommitGB']) { [double]$a['minFreeCommitGB'] } else { 24.0 }
    $comG = if ($cfg.ContainsKey('minFreeCommitGB') -and $null -ne $cfg['minFreeCommitGB']) { [double]$cfg['minFreeCommitGB'] } else { 12.0 }
    $script:MmFloors = @{ ram = $ramA; commitAdaptive = $comA; commitGuard = $comG }
  }
  $f = $script:MmFloors
  $os = Get-MemInfo
  $ram = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
  $commit = [math]::Round($os.FreeVirtualMemory / 1MB, 1)
  # The multiplication MUST be parenthesised: inside @(...) the comma binds TIGHTER than *, so
  # `@($q, $q * 2, ...)` is `($q, $q, ...) * 2` - the whole list repeated twice, every value doubled
  # in significance and `unified` never true (2026-11-21: the doctor row printed "N different floors"
  # for a machine whose three numbers were identical).
  # Only REAL floors count: a 0 means that gate is not configured, and listing it would report a
  # disagreement between a number and an absence of one (doctor noise, not a finding).
  $floors = @(@($queueGB, ($queueGB * 2), $f.commitGuard, $f.ram, $f.commitAdaptive) | Where-Object { $_ -gt 0 } | Sort-Object -Unique)
  [pscustomobject]@{
    ramGB = $ram; commitGB = $commit
    queueFloorGB = $queueGB; burstFloorGB = $queueGB * 2
    commitGuardGB = $f.commitGuard; ramFloorGB = $f.ram; commitFloorGB = $f.commitAdaptive
    floors = $floors; unified = ($floors.Count -eq 1)
  }
}
function Test-FreeRam([double]$gb) {
  # Commit charge too: 2026-09-30 "memory allocation failed" with 50 GB RAM free because the commit
  # limit was exhausted (vmmemWSL). FreeVirtualMemory = commit limit - committed (KB).
  $mm = Get-MachineMemory ([double]$MinFreeGB)
  ($mm.ramGB -ge $gb) -and ($gb -le 0 -or $mm.commitGuardGB -le 0 -or ($mm.commitGB -ge $mm.commitGuardGB))
}

function Expand-Resources([string]$kind, $repo) {
  $primary = Resolve-Resource $kind $repo
  $list = @($primary)
  if ($primary -like 'build:*' -and $primary -ne 'build:machine') { $list += 'build:machine' }
  # A HEAVY gate (gate/heavy/batch) on a verify:* resource takes the machine-wide gate ticket too, so N
  # repos cannot run N heavy gates at once. verify:* ONLY: a build already takes build:machine, and
  # coupling the two would queue an ordinary build behind the gate cap.
  if ($primary -like 'verify:*' -and (Resolve-Lane $primary $script:Lane) -in 'gate', 'heavy', 'batch') { $list += 'gate:machine' }
  foreach ($a in $Also) { $list += (Resolve-Resource $a $repo) }
  $list
}

function Get-SignalUrl { 'http://127.0.0.1:3737/api/copilot/event' }

function Get-CmdKind([string]$c) {
  $s = "$c".ToLowerInvariant()
  switch -Regex ($s) {
    'playwright|e2e' { return 'e2e' }
    'gradle' { return 'gradle' }
    'cargo|rustc|clippy' { return 'cargo' }
    'next build' { return 'next-build' }
    'vitest|jest|pytest|\btest\b' { return 'test' }
    'typecheck|\btsc\b|tsgo' { return 'typecheck' }
    'lint|eslint|oxlint|biome|knip' { return 'lint' }
    '\.ps1' { return 'gate-script' }
    'build|tsdown|vite' { return 'build' }
    default { return 'other' }
  }
}

# ---- overrides (DC-011): every one needs -Reason, is journaled, capped and rate-limited ----
function Assert-OverrideBudget([string]$verb) {
  if (-not $Reason -or $Reason.Trim().Length -lt 8) { throw "agentq ${verb}: -Reason '<why, >= 8 chars>' is required (journaled; other agents read it)" }
  $limit = [int](Get-Config).overridesPerHour
  $mine = @(Read-Journal 400 ((Now).AddHours(-1)) $null | Where-Object { (JProp $_ 'event') -in 'bump', 'burst', 'propose-applied' -and (JProp $_ 'session') -eq $Session })
  if ($limit -gt 0 -and $mine.Count -ge $limit) { [Console]::Error.WriteLine("agentq: override budget spent ($($mine.Count)/$limit per hour for $Session). Ask the user, or wait."); exit 3 }
}
function Find-MyTickets {
  $out = @()
  foreach ($d in @(Get-ChildItem $QDir -Directory -ErrorAction SilentlyContinue)) {
    $sample = Get-ChildItem $d.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object Name -ne 'adaptive.json' | Select-Object -First 1
    if (-not $sample) { continue }
    $res = (Get-Content $sample.FullName -Raw | ConvertFrom-Json -DateKind String).resource
    # Selector, in order of preference (2026-11-23): -Id names ONE ticket; -Session names a session;
    # bare matches the CALLER's own session. Before this there was no -Session, and the bare form
    # silently matched whichever session the env resolved to - so a waiter could bump a SIBLING's ticket.
    $out += @(Get-Live $res | Where-Object {
        if ($Id) { "$($_.id)" -eq "$Id" }
        elseif ($PickSession) { "$($_.session)" -eq "$PickSession" }
        else { "$($_.session)" -eq $Session }
      })
  }
  $out
}
# Every live ticket of ONE session, across EVERY repo (Find-MyTickets honours -Id/-Session and the
# caller's own session only); with $OnlyWaiting it drops the held ones. `status` uses it to print a
# session's OWN waiting ticket ids - the other half of the bump bug: the id was never visible, so a
# waiter could not target `bump -Id <hash>` even though -Id existed.
# PERF (2026-11-26). `status` enumerates the ~120 resource directories TWICE (the queue table and the
# `== MINE` line) and every per-directory Get-ChildItem costs 2-5 ms even when the directory is empty,
# which almost all of them are (measured: 120 dirs, 4 with a JSON file). ONE recursive walk of the whole
# queue tree costs 53 ms. The map is directory -> its JSON files, so a directory with no file is absent -
# exactly the set the old loops skipped after a wasted enumeration.
function Get-QueueIndex {
  $map = @{}
  foreach ($f in @(Get-ChildItem $QDir -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    if ($f.Name -eq 'adaptive.json') { continue }
    $k = $f.DirectoryName
    if (-not $map.ContainsKey($k)) { $map[$k] = [System.Collections.ArrayList]::new() }
    [void]$map[$k].Add($f)
  }
  $map
}
function Get-QueueSample($files) {
  # burst.json is a BURST record, not a ticket: `status` (and the burst read below) keeps it in the same
  # directory, so a resource whose only *.json is a burst record must not be represented by one.
  foreach ($f in $files) { if ($f.Name -notin 'adaptive.json', 'burst.json') { return $f } }
  $null
}
function Get-SessionTickets([string]$sess, [bool]$OnlyWaiting, $qidx = $null) {
  $out = @()
  if (-not $qidx) { $qidx = Get-QueueIndex }
  foreach ($k in @($qidx.Keys)) {
    $files = @($qidx[$k])
    $sample = Get-QueueSample $files
    if (-not $sample) { continue }
    # Only a resource that HAS a ticket naming this session can produce a row for it, and the loop below
    # calls Get-Live on every resource. One raw read per ticket file (~0.1 ms) settles it; a false positive
    # only costs the pass it would have paid anyway.
    $maybe = $false
    foreach ($f in $files) {
      try { if ([IO.File]::ReadAllText($f.FullName).Contains("`"$sess`"")) { $maybe = $true; break } } catch { }
    }
    if (-not $maybe) { continue }
    $res = ([IO.File]::ReadAllText($sample.FullName) | ConvertFrom-Json -DateKind String).resource
    $live = @(Get-Live $res); $cap = Get-Capacity $res
    foreach ($t in $live) {
      if ("$($t.session)" -ne "$sess") { continue }
      $held = Test-Held $t $live $cap
      if ($OnlyWaiting -and $held) { continue }
      $t | Add-Member -NotePropertyName heldState -NotePropertyValue $held -Force
      $out += $t
    }
  }
  $out
}
function Invoke-Bump {
  if ($Id -and $PickSession) { [Console]::Error.WriteLine('agentq bump: -Id and -Session are mutually exclusive - name ONE target'); exit 2 }
  Assert-OverrideBudget 'bump'
  $by = if ($By) { $By } else { 20 }
  $max = [int](Get-Config).bumpMax
  # Name the selector in the output and in the error, so nothing is ever silent about WHICH ticket moved.
  $selector = if ($Id) { "id $Id" } elseif ($PickSession) { "session $PickSession" } else { "session $Session (mine)" }
  $mine = @(Find-MyTickets | Where-Object { -not (P $_ 'held' $false) })
  if (-not $mine) { [Console]::Error.WriteLine("agentq bump: no waiting ticket for $selector - list them with 'agentq status' (the == MINE line), then target one: 'agentq bump -Id <hash>' or 'agentq bump -Session <id>'"); exit 2 }
  # ALWAYS print which ticket(s) it bumped (id + session): the bare form used to bump silently and,
  # when its session resolved to another session, bumped a SIBLING's ticket ahead of mine (2026-11-23).
  foreach ($t in $mine) {
    $nb = [math]::Min($max, [int](P $t 'bump' 0) + $by)
    Update-Ticket $t @{ bump = $nb; bumpReason = $Reason }
    Write-Journal @{ event = 'bump'; resource = $t.resource; ticket = $t.id; holderSession = $t.session; by = $by; bump = $nb; reason = $Reason; purpose = $t.purpose }
    Write-Output "bumped ticket $($t.id) [session $($t.session)] on $($t.resource) to +$nb ($Reason)"
  }
}
function Invoke-Burst {
  Assert-OverrideBudget 'burst'
  if (-not $Resource) { $Resource = 'build:machine' }
  $res = Resolve-Resource $Resource (Get-RepoInfo $Repo)
  $c = Get-Config
  $by = [math]::Max(1, [math]::Min([int]$c.burstMax, $(if ($By) { $By } else { 1 })))
  $min = [math]::Max(1, [math]::Min([int]$c.burstMaxMin, $Minutes))
  $mm = Get-MachineMemory ([double]$MinFreeGB)
  if ($res -eq 'build:machine' -and -not (Test-FreeRam $mm.burstFloorGB)) {
    [Console]::Error.WriteLine("agentq burst: refused - less than $($mm.burstFloorGB) GB RAM (or commit headroom) free; a burst would OOM the machine. Use -Where cloud when available."); exit 3
  }
  New-Item -ItemType Directory -Force (QPath $res) | Out-Null
  $b = [ordered]@{ resource = $res; by = $by; until = (Iso ((Now).AddMinutes($min))); reason = $Reason; session = $Session; at = (Iso (Now)) }
  [IO.File]::WriteAllText((BurstFile $res), ($b | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  Write-Journal @{ event = 'burst'; resource = $res; by = $by; minutes = $min; reason = $Reason }
  Write-Output "burst $res +$by for $min min ($Reason)"
}
# propose: diagnose why the caller waits and APPLY the safe remedy (break a dead/hung holder,
# bump a long waiter, or open a short burst when RAM allows). Unsafe remedies are printed only.
function Invoke-Propose {
  if (-not $Reason) { $Reason = 'propose: auto-remedy for a long wait' }
  $repo = Get-RepoInfo $Repo
  $c = Get-Config
  $actions = @()
  foreach ($res in @('build:machine', 'gate:machine') + @(if ($repo) { "build:$($repo.Name)", "commit:$($repo.Name)", "install:$($repo.Name)" })) {
    $live = @(Get-Live $res); if (-not $live) { continue }
    $cap = Get-Capacity $res
    foreach ($h in @($live | Where-Object { Test-Held $_ $live $cap })) {
      if ($h.stale -and $h.beatAgeMin -gt (2 * $StaleMin)) {
        Remove-Ticket $h "propose: heartbeat stale $($h.beatAgeMin) min ($Reason)" 'break'
        $actions += "broke STALE holder $($h.id) on $res ($($h.beatAgeMin) min)"
      }
    }
    $waiters = @($live | Where-Object { -not (Test-Held $_ $live $cap) })
    $mine = @($waiters | Where-Object session -eq $Session)
    foreach ($w in $mine) {
      $waitedMin = ((Now) - (ParseUtc $w.created)).TotalMinutes
      if ($waitedMin -ge 10 -and [int](P $w 'bump' 0) -lt 20) {
        Update-Ticket $w @{ bump = 20; bumpReason = "propose: waited $([math]::Round($waitedMin)) min" }
        $actions += "bumped own ticket $($w.id) on $res (+20, waited $([math]::Round($waitedMin)) min)"
      }
    }
    $ld = Get-AdmissionLoad -NoSample
    $mm = Get-MachineMemory ([double]$MinFreeGB)
    # A burst only raises capacity, and admission's load hold is applied AFTER the rank test
    # (Test-Admissible) - so while the machine is saturated (OQ-004) a burst produces a slot nobody
    # can use. Offering it as a remedy made `propose` report an action that changes nothing; say why
    # and name the escape instead. Test-AdmissionOverride is deliberately not consulted: it is
    # per-process state, not a property of the queue.
    if ($res -eq 'build:machine' -and $mine -and $ld.saturated -and -not (Test-Path (BurstFile $res))) {
      Write-Output ("skip: burst cannot admit anything while admission is saturated (start probe median {0} ms > {1} ms) - extra capacity is not the blocker. Use -Where cloud (or AGENTQ_WHERE=auto) for a repo with a cloudWorkspaces entry, or wait for the load hold to lift." -f $ld.median, $ld.thresholdMs)
    }
    elseif ($res -eq 'build:machine' -and $mine -and -not (Test-Path (BurstFile $res)) -and (Test-FreeRam $mm.burstFloorGB)) {
      $b = [ordered]@{ resource = $res; by = 1; until = (Iso ((Now).AddMinutes(20))); reason = "propose: $Reason"; session = $Session; at = (Iso (Now)) }
      [IO.File]::WriteAllText((BurstFile $res), ($b | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
      $actions += 'opened burst build:machine +1 for 20 min (RAM headroom >= 2x gate)'
    }
  }
  if ($actions) {
    Write-Journal @{ event = 'propose-applied'; resource = 'agentq'; reason = $Reason; message = ($actions -join '; ') }
    $actions | ForEach-Object { Write-Output "applied: $_" }
  } else { Write-Output 'propose: nothing safe to apply (holders healthy, RAM below 2x gate, or no long wait). Consider -Where cloud or agentq bump -Reason.' }
}

# ---- metrics (DC-017): wait/hold distributions from the journal --------------------------
# ---- can-preempt verdict (ADR 0013, 2026-11-19): ONE instant answer ----------------------
# An agent blocked on a resource used to spend minutes discovering whether the holder can be stopped:
# read status, find the pid, sample CPU, guess, maybe break the wrong ticket. This answers in one call
# with a verdict AND the exact command. READ-ONLY: it never breaks, never renews, never writes state.
function Invoke-Eval {
  if (-not $Resource) { [Console]::Error.WriteLine('agentq eval -Resource <build:repo|install:repo|commit:repo|deploy:repo:target|slot:repo:slot> [-Sample]'); exit 2 }
  $res = Resolve-Resource $Resource (Get-RepoInfo $Repo)
  $sample = [bool]$EvalSample
  $line = { param($k, $v) "{0,-9}: {1}" -f $k, $v }

  # --- a slot: answer is about the lease, not a queue -----------------------------------------
  if ("$res" -like 'slot:*') {
    $p = "$res" -split ':'
    $l = @(Read-Leases $p[1] | Where-Object { $_.slot -eq $p[2] } | Select-Object -First 1)
    if (-not $l) { & $line 'verdict' 'FREE'; & $line 'why' "no lease on $($p[1])/$($p[2])"; return }
    $idle = [math]::Round([double](P $l 'idleMin' 0))
    $why = @("lease $($l.leaseId) held by $($l.session) since $((P $l 'created' '')): '$((P $l 'purpose' ''))'", "work clock: slot idle $idle min; owner pid alive=$($l.alive); chat idle=$(if ($null -ne (P $l 'chatIdleMin' $null)) { (P $l 'chatIdleMin') } else { '-' }) min")
    if ($l.stale) {
      & $line 'verdict' 'STALE-RECLAIM'
      & $line 'why' ($why -join '; ')
      & $line 'how' "agentq unlease -Repo `"$(P $l 'path')`" -LeaseId $($l.leaseId) -Reason 'stale, reclaiming'  (backs up unsaved state to refs/backup/wt/... first)"
    } else {
      & $line 'verdict' 'WAIT'
      & $line 'why' ($why -join '; ')
      & $line 'how' "not stale yet. If the work is real but runs OUTSIDE the slot, the holder must renew it (agentq renew -LeaseId $($l.leaseId)); do not break a live lease - coordinate with $($l.session)."
    }
    return
  }

  # --- a queue resource: answer is about the holder ticket -------------------------------------
  $cap = Get-Capacity $res
  $live = @(Get-Live $res)
  $holders = @($live | Where-Object { Test-Held $_ $live $cap })
  $waiting = @($live | Where-Object { -not (Test-Held $_ $live $cap) })
  if (-not $holders.Count) {
    & $line 'verdict' 'FREE'
    & $line 'why' "$res has no holder ($($waiting.Count) waiter(s)); your ticket is next"
    return
  }
  $rows = @()
  $worst = 'FREE'
  foreach ($h in $holders) {
    $pid0 = [int](P $h 'pid' 0)
    $alive = Test-Alive $h
    $beat = [double](P $h 'beatAgeMin' 999)
    $kids = 0; $cpu = $null
    if ($alive -and $pid0 -gt 0) {
      try { $kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$pid0" -ErrorAction SilentlyContinue).Count } catch { }
      try { $cpu = (Get-Process -Id $pid0 -ErrorAction SilentlyContinue).CPU } catch { }
    }
    if ($sample -and $alive -and $pid0 -gt 0) {
      Start-Sleep -Milliseconds 900
      try { $c2 = (Get-Process -Id $pid0 -ErrorAction SilentlyContinue).CPU; if ($null -ne $cpu -and $null -ne $c2) { $cpu = [math]::Round(($c2 - $cpu), 2) } } catch { $cpu = $null }
    }
    $cmd = "$(P $h 'cmd' '') `"$(P $h 'purpose' '')`""
    $isDeploy = $cmd -match '(?i)deploy|release|land|pulumi|terraform apply|gcloud run (replace|update)|vercel'
    $v = 'WAIT'; $whyH = @()
    if (-not $alive) { $v = 'PREEMPT-OK'; $whyH += 'holder pid is GONE (crashed)' }
    elseif ($isDeploy) { $v = 'NEVER'; $whyH += 'this is a deploy/release: stopping it mid-flight can leave a half-shipped service' }
    elseif ($kids -eq 0 -and ($null -eq $cpu -or $cpu -lt 0.5) -and $beat -gt 5) { $v = 'PREEMPT-OK'; $whyH += "no child processes and ~no CPU (${cpu}s/0.9s) for $([math]::Round($beat)) min: the holder looks wedged" }
    elseif ($beat -gt (2 * $StaleMin)) { $v = 'PREEMPT-OK'; $whyH += "heartbeat stale $([math]::Round($beat)) min (> 2x stale $StaleMin) even though the pid lives" }
    else { $whyH += "holder is alive and working (children=$kids, cpu=${cpu}s): let it finish" }
    $whyH += "holder $($h.id) on ${res}: pid $pid0, beat $([math]::Round($beat)) min, '$((P $h 'purpose' ''))'"
    $rows += [pscustomobject]@{ verdict = $v; ticket = $h.id; pid = $pid0; kids = $kids; cpuSec = $cpu; beatMin = [math]::Round($beat); why = ($whyH -join '; ') }
    if ($v -eq 'NEVER') { $worst = 'NEVER' } elseif ($v -eq 'PREEMPT-OK' -and $worst -ne 'NEVER') { $worst = 'PREEMPT-OK' }
  }
  if ($Json) { @{ resource = $res; verdict = $worst; holders = $rows; waiting = $waiting.Count } | ConvertTo-Json -Depth 4; return }
  foreach ($r in $rows) {
    & $line 'verdict' $r.verdict
    & $line 'holder' "ticket $($r.ticket) pid $($r.pid) children $($r.kids) cpu $($r.cpuSec)s beat $($r.beatMin)m"
    & $line 'why' $r.why
    if ($r.verdict -eq 'PREEMPT-OK') { & $line 'how' "agentq break -Resource '$res' -Id $($r.ticket) -Reason 'wedged: no child/CPU for $($r.beatMin) min'   (then re-run your command; the queue slot is yours)" }
    elseif ($r.verdict -eq 'NEVER') { & $line 'how' 'wait, or ask the owner; a release must not be broken mid-flight' }
    else { & $line 'how' "wait. If it exceeds 2x its usual hold, agentq propose -Reason '...' breaks a STALE holder automatically." }
  }
  & $line 'queue' "$($holders.Count) holder(s), $($waiting.Count) waiter(s), capacity $cap"
}

# ---- feedback for future agents (ADR 0013) -------------------------------------------------
# Anomalies, ideas and "next time do X" notes about agentq itself, from agents that had to work around
# it. They belong to the TOOL, not to a task, so they live next to the coordinator and show up in
# `agentq since`/the hub, not in a repo tracker. One JSON file per note; the journal gets the event.
function Invoke-Feedback {
  $dir = Join-Path $Root 'feedback'
  if ($Message) {
    $kind = if ($FbKind) { "$FbKind".ToLowerInvariant() } else { 'note' }
    if ($kind -notin 'note', 'idea', 'bug', 'anomaly', 'praise') { [Console]::Error.WriteLine("agentq feedback: -Kind must be note|idea|bug|anomaly|praise (got '$kind')"); exit 2 }
    New-Item -ItemType Directory -Force $dir | Out-Null
    $ts = (Now).ToString('yyyyMMdd-HHmmss')
    $id = "$ts-$((Get-Random -Minimum 1000 -Maximum 9999))"
    $f = Join-Path $dir "$id.json"
    $o = [ordered]@{ id = $id; ts = (Iso (Now)); kind = $kind; session = $Session; host = $env:COMPUTERNAME; repo = $(if ($RepoArg) { Split-Path $RepoArg -Leaf } else { '' }); resource = "$Resource"; message = $Message }
    [IO.File]::WriteAllText($f, ($o | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    Write-Journal @{ event = 'feedback'; resource = 'agentq'; kind = $kind; message = $Message; id = $id; session = $Session }
    Write-Output "recorded $kind feedback $id -> $dir"
    Write-Output "the next agent working on agentq sees it with: agentq feedback"
    return
  }
  if (-not (Test-Path $dir)) { Write-Output 'no feedback yet (agentq feedback -Kind idea|bug|anomaly|note -Message "...")'; return }
  $items = @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First $Last | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
  if (-not $items.Count) { Write-Output 'no feedback yet'; return }
  if ($Json) { @{ feedback = @($items) } | ConvertTo-Json -Depth 4; return }
  foreach ($i in $items) { "{0}  {1,-7}  {2,-12}  {3}" -f $i.ts, $i.kind, $i.session, $i.message | Write-Output }
  Write-Output ""
  Write-Output "$(@($items).Count) note(s), newest first. Add yours: agentq feedback -Kind bug|idea|anomaly -Message '...'"
}

function Show-Metrics {
  $from = (Now).AddHours(-$Hours)
  $items = @(Read-Journal 0 $from $null | Where-Object { (JProp $_ 'event') -in 'done', 'fail', 'cloud-done', 'cloud-fail' -and $_.PSObject.Properties['holdSec'] })
  $q = { param($a, [double]$p) if (-not $a) { return 0 }; $s = @($a | Sort-Object); $s[[math]::Min($s.Count - 1, [math]::Floor($p * $s.Count))] }
  $rows = $items | Group-Object { "{0}|{1}|{2}" -f ("$($_.resource)" -replace ',build:machine', ''), "$(P $_ 'lane' '?')", "$(P $_ 'kind' '?')" } | ForEach-Object {
    $w = @($_.Group | ForEach-Object { [double](P $_ 'waitSec' 0) }); $h = @($_.Group | ForEach-Object { [double]$_.holdSec })
    $k = $_.Name -split '\|'
    [pscustomobject]@{ resource = $k[0]; lane = $k[1]; kind = $k[2]; runs = $_.Count; fail = @($_.Group | Where-Object event -in 'fail', 'cloud-fail').Count
      waitP50 = (& $q $w 0.5); waitP90 = (& $q $w 0.9); holdP50 = (& $q $h 0.5); holdP90 = (& $q $h 0.9); holdMin = [math]::Round(($h | Measure-Object -Sum).Sum / 60, 1) }
  } | Sort-Object holdMin -Descending
  $ev = @(Read-Journal 0 $from $null | Where-Object { (JProp $_ 'event') -in 'idle-yield', 'bump', 'burst', 'propose-applied', 'timeout', 'reap', 'break' } | Group-Object event | ForEach-Object { "$($_.Name)=$($_.Count)" })
  $res = @($items | Where-Object { $_.event -like 'cloud-*' -and $_.PSObject.Properties['resumeSec'] } | ForEach-Object { [double]$_.resumeSec })
  $cloud = if ($res) { "resumes=$($res.Count) resumeP50=$(& $q $res 0.5)s resumeMax=$(($res | Measure-Object -Maximum).Maximum)s" } else { 'resumes=0' }
  if ($Json) { @{ hours = $Hours; rows = @($rows); events = $ev; cloud = $cloud } | ConvertTo-Json -Depth 4; return }
  Write-Output "== agentq metrics, last $Hours h (seconds; v3 runs only)"
  if ($rows) { $rows | Format-Table -AutoSize | Out-String -Width 200 | Write-Output } else { Write-Output '(no v3 runs yet)' }
  Write-Output "== scheduler events: $(if ($ev) { $ev -join ' ' } else { 'none' })"
  Write-Output "== cloud: $cloud"
}

# ---- journal rotation (DC-016): archive when > journalRotateMB; agentq-sync resets its offset
# when the file shrinks (Get-NewLines: offset > length -> 0) and dedupes on line hash server-side.
function Invoke-RotateJournal([switch]$Force) {
  if (-not (Test-Path $Journal)) { return }
  $mb = (Get-Item $Journal).Length / 1MB
  if (-not $Force -and $mb -lt [double](Get-Config).journalRotateMB) { return }
  $arch = Join-Path $Root 'journal-archive'; New-Item -ItemType Directory -Force $arch | Out-Null
  $m = [Threading.Mutex]::new($false, "Global\agentq-journal$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  try {
    try { [void]$m.WaitOne(10000) } catch [Threading.AbandonedMutexException] {}
    $dst = Join-Path $arch ("journal-{0}.jsonl" -f (Now).ToString('yyyyMMdd-HHmmss'))
    [IO.File]::Move($Journal, $dst)
    [IO.File]::WriteAllText($Journal, '', [Text.UTF8Encoding]::new($false))
  } finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
  Write-Journal @{ event = 'rotate'; resource = 'agentq'; reason = "archived $([math]::Round($mb,1)) MB -> $(Split-Path $dst -Leaf)" }
  Write-Output "rotated journal ($([math]::Round($mb,1)) MB) -> $dst"
}
function Send-Signal([string]$ev, [string]$text) {
  if ($env:AGENTQ_NO_SIGNAL) { return }
  try {
    $body = @{ event = $ev; source = 'agentq'; message = $text } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri (Get-SignalUrl) -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 1 | Out-Null
  } catch {}
}

# ---------------------------------------------------------------------------------------
# devcloud F2 (DC-037): decide local vs cloud. Returns @{ where; ws; why }.
# One repo may name ONE cloud workspace (a string, the original shape) or several (an array).
# Several exist so two lanes that must not share a machine can run at once: vitals' rust and
# android lanes are both concurrency:1 dedicated in .devcloud/profile.json, yet they serialised
# behind the single vitals-win VM (vitals tracker row S26-12). With an array the lane comes from
# `-Lane <name>` on the command line, then from the optional cloudLaneWorkspaces pin, then
# round-robin by session, so two concurrent lanes of one session diverge instead of colliding.
# A workspace with no cloudRegistry entry is never picked: a name nothing can place is a typo,
# and choosing it would fail the run at submit time instead of here. A STRING value is returned
# unchanged, so no other repo's placement moves.
function Resolve-WorkspaceForLane($cfg, [string]$repoName, $value, [string]$cmdLine) {
  if ($value -is [string] -or $value -isnot [System.Collections.IEnumerable]) { return $value }
  $list = @($value | Where-Object { $_ })
  if ($list.Count -eq 0) { return $null }
  if ($list.Count -eq 1) { return $list[0] }
  $reg = if ($cfg.ContainsKey('cloudRegistry') -and $cfg['cloudRegistry']) { $cfg['cloudRegistry'] } else { @{} }
  $known = @($list | Where-Object { $reg.ContainsKey("$_") })
  if ($known.Count) { $list = $known }
  if ($list.Count -eq 1) { return $list[0] }
  $lane = $null
  if ($cmdLine -and $cmdLine -match '(?:^|\s)-Lane\s+([A-Za-z0-9._-]+)') { $lane = $Matches[1].ToLowerInvariant() }
  if ($lane -and $cfg.ContainsKey('cloudLaneWorkspaces') -and $cfg['cloudLaneWorkspaces']) {
    $pins = $cfg['cloudLaneWorkspaces']
    if ($pins.ContainsKey($repoName)) {
      $pin = $pins[$repoName]
      if ($pin -and $pin.ContainsKey($lane) -and $pin[$lane]) { return $pin[$lane] }
    }
  }
  # Round-robin by session + lane. Stated as a hash rather than a counter because the two lanes
  # are separate processes: a shared counter would need a lock to be correct and a hash costs
  # nothing. Two lanes of one session differ because the lane name is in the key.
  $key = if ($lane) { "$Session|$lane" } else { "$Session" }
  $h = 0
  foreach ($ch in $key.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 1000003 }
  $list[$h % $list.Count]
}
function Resolve-Placement($repo, [string]$res, [string]$cmdLine) {
  $want = if ($Where) { $Where } elseif ($env:AGENTQ_WHERE) { $env:AGENTQ_WHERE.ToLowerInvariant() } else { 'local' }
  if ($want -notin 'local', 'cloud', 'auto') { throw "agentq: -Where must be local|cloud|auto (got '$want')" }
  $cfg = Get-Config
  $map = if ($cfg.ContainsKey('cloudWorkspaces') -and $cfg['cloudWorkspaces']) { $cfg['cloudWorkspaces'] } else { @{} }
  $ws = if ($Ws) { $Ws } elseif ($repo -and $map.ContainsKey($repo.Name)) { Resolve-WorkspaceForLane $cfg $repo.Name $map[$repo.Name] $cmdLine } else { $null }
  if ($want -eq 'local') { return @{ where = 'local'; ws = $ws; why = $(if ($Where) { '-Where local' } elseif ($env:AGENTQ_WHERE) { 'AGENTQ_WHERE=local' } else { 'default' }) } }
  if (-not $ws) {
    if ($want -eq 'cloud') { throw "agentq: no cloud workspace for repo '$($repo.Name)' (config cloudWorkspaces or -Ws)" }
    return @{ where = 'local'; ws = $null; why = "auto: no workspace for $($repo.Name)" }
  }
  $down = Get-CloudDown $ws
  if ($down -and $env:AGENTQ_CLOUD_STRICT -ne '1') { return @{ where = 'local'; ws = $ws; why = "cloud:$ws down until $($down.until) ($($down.reason))" } }
  if ($want -eq 'cloud') { return @{ where = 'cloud'; ws = $ws; why = '-Where cloud' } }
  # auto
  $kind = Get-CmdKind $cmdLine
  if ($res -notlike 'build:*' -or $kind -notin 'typecheck', 'test', 'lint', 'build', 'next-build', 'gate-script') { return @{ where = 'local'; ws = $ws; why = "auto: kind $kind / $res stays local" } }
  $live = @(Get-Live 'build:machine' | Where-Object { (P $_ 'held' $false) -and -not (P $_ 'yielded' $false) })
  if ($live.Count -ge (Get-Capacity 'build:machine')) { return @{ where = 'cloud'; ws = $ws; why = "auto: build:machine full ($($live.Count) held)" } }
  if (-not (Test-FreeRam $MinFreeGB)) { return @{ where = 'cloud'; ws = $ws; why = 'auto: local RAM/commit below the gate' } }
  # The machine can be SATURATED without `build:machine` being full: admission holds a new gate back
  # when the start probe is over its limit (OQ-004), and a cloud-eligible run then waits for a LOCAL
  # slot it does not need. Measured 2026-11-25: a codai land pre-gate sat in `waiting - build:machine
  # [gate] machine saturated (start probe median 864.5 ms > 400 ms)` while its real work ran on
  # ws-codai. The shared record is READ (-NoSample), never sampled, so this costs no probe; and the
  # branch is reached only on the auto path (an explicit -Where local is honoured above).
  $ld = Get-AdmissionLoad -NoSample
  if ($ld.enabled -and $ld.saturated) { return @{ where = 'cloud'; ws = $ws; why = "auto: machine saturated (start probe median $($ld.median) ms > $($ld.thresholdMs) ms)" } }
  $minSec = if ($cfg.ContainsKey('cloudAutoMinSec')) { [double]$cfg['cloudAutoMinSec'] } else { 240.0 }
  $holds = @(Read-Journal 0 ((Now).AddDays(-7)) $repo.Name | Where-Object { (JProp $_ 'event') -in 'done', 'fail' -and $_.PSObject.Properties['holdSec'] -and (P $_ 'kind' '') -eq $kind } | ForEach-Object { [double]$_.holdSec } | Sort-Object)
  if ($holds.Count -ge 3) {
    $p50 = $holds[[math]::Floor($holds.Count / 2)]
    if ($p50 -ge $minSec) { return @{ where = 'cloud'; ws = $ws; why = "auto: local $kind p50 ${p50}s >= ${minSec}s" } }
    return @{ where = 'local'; ws = $ws; why = "auto: local $kind p50 ${p50}s < ${minSec}s, machine free" }
  }
  @{ where = 'local'; ws = $ws; why = 'auto: machine free, no history' }
}

# cloud-down/<ws>.json is written by agentq-cloud when a run could not even be submitted (VM gone,
# auth, quota). Returns the record while it is unexpired, else $null (and removes a stale file).
function Get-CloudDown([string]$ws) {
  $f = Join-Path (Join-Path $Root 'cloud-down') "$ws.json"
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try {
    $d = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    # pwsh 7 ConvertFrom-Json already turns ISO strings into DateTime; re-parsing its culture
    # string (ro-RO here) threw and silently disabled the breaker.
    $until = if ($d.until -is [datetime]) { $d.until } else { [DateTime]::Parse("$($d.until)", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    if ($until.ToUniversalTime() -gt (Now)) { return $d }
    Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue
  } catch {}
  $null
}

function Invoke-CloudRun($repo, [string[]]$cmdArgs, $placement) {
  $tool = if ($env:AGENTQ_CLOUD_TOOL) { $env:AGENTQ_CLOUD_TOOL } else { Join-Path $PSScriptRoot 'agentq-cloud.ps1' }
  if (-not (Test-Path $tool)) { throw "agentq: $tool missing (install agentq cloud)" }
  $a = @('-Ws', $placement.ws, '-Purpose', $Purpose, '-Repo', $repo.Top, '-Lane', $(if ($Lane) { $Lane } else { 'gate' }))
  if ($TimeoutGiven) { $a += @('-TimeoutMin', "$TimeoutMin") }
  $all = @($a) + @('--') + @($cmdArgs)
  & $tool @all
  $rc = $LASTEXITCODE
  # 4 = nothing was submitted: run it here instead of failing the caller's hook/commit.
  if ($rc -eq 4 -and $env:AGENTQ_CLOUD_STRICT -ne '1') {
    [Console]::Error.WriteLine("agentq: cloud:$($placement.ws) unavailable, running locally")
    Write-Journal @{ event = 'placement'; resource = 'cloud-fallback'; repo = $(if ($repo) { $repo.Name } else { '' }); where = 'local'; ws = "$($placement.ws)"; reason = 'cloud unavailable (exit 4), fell back to local'; purpose = $Purpose }
    return
  }
  exit $rc
}

function Invoke-Run {
  $repo = Get-RepoInfo $Repo
  Assert-ExpectedRepo $repo
  if (-not $Resource) { throw 'agentq run: -Resource build|install|commit|deploy:<target>|<literal> is required' }
  if (-not $Purpose) { throw 'agentq run: -Purpose "<why>" is required (other agents read it)' }
  # only agentq's own separator is consumed (line ~94); a later '--' belongs to the command (turbo/pnpm/vitest)
  $cmdArgs = @($Rest)
  if (-not $cmdArgs) { throw 'agentq run: nothing to run (agentq run -Resource build -Purpose x -- <command>)' }
  $cmdLine = ($cmdArgs -join ' ')
  $resList = @(Expand-Resources $Resource $repo)
  foreach ($r in $resList) { Assert-NotMarked $r }
  $pl = Resolve-Placement $repo $resList[0] $cmdLine
  # Additive (2026-11-26): expose the RESOLVED placement to the child, so a wrapper that must not
  # mistake a cloud wait for a local wedge (run-build.ps1's wedge watch) reads the engine's decision
  # instead of re-deriving it. local for every ordinary run; cloud only when cloud was chosen.
  $env:AGENTQ_PLACEMENT = "$($pl.where)"
  if ($Where -or $env:AGENTQ_WHERE) { Write-Journal @{ event = 'placement'; resource = $resList[0]; repo = $(if ($repo) { $repo.Name } else { '' }); where = $pl.where; ws = "$($pl.ws)"; reason = $pl.why; purpose = $Purpose; cmd = $cmdLine } }
  if ($pl.where -eq 'cloud') { [Console]::Error.WriteLine("agentq: placement cloud:$($pl.ws) ($($pl.why))"); Invoke-CloudRun $repo $cmdArgs $pl }
  $tickets = @()
  $started = Now
  try {
    # v3 (DC-013): all tickets exist from the start but NONE is held until every one is
    # admissible; the grant is atomic (Wait-All). Held is an explicit flag, so the 2026-09-30
    # phantom-hold (position = hold) cannot recur.
    $gates = @{}
    foreach ($r in $resList) {
      $t = New-Ticket $r $Purpose $cmdLine ($repo.Top)
      $tickets += $t   # before waiting, so the finally below removes it on Ctrl+C or an exception
      Write-Journal @{ event = 'queued'; resource = $r; ticket = $t.id; purpose = $Purpose; cmd = $cmdLine; repo = $repo.Name; lane = $t.lane }
      $gates[$t.id] = if ($t.resource -eq 'build:machine' -and $MinFreeGB -gt 0) { { Test-FreeRam $MinFreeGB } } else { $null }
    }
    if ($NoWait) {
      if ($resList -contains 'build:machine' -or $resList -contains 'gate:machine') { $null = Get-AdmissionLoad }
      $busy = @($tickets | Where-Object { -not (Test-Admissible $_ $gates[$_.id]).ok })
      if ($busy) {
        $h = @(Get-Live $busy[0].resource)[0]
        foreach ($t in $tickets) { Remove-Ticket $t 'busy (-NoWait)' 'giveup' }
        [Console]::Error.WriteLine("agentq: $($busy[0].resource) is busy: $($h.session) '$($h.purpose)' since $($h.created)")
        [Console]::Error.WriteLine("  next: agentq eval -Resource '$($busy[0].resource)' -Purpose '<what you want to do>' says whether the holder can be preempted, and the exact command; agentq status lists every holder.")
        [Console]::Error.WriteLine("        Or drop -NoWait: the run queues and starts the moment the holder releases (agentq help run).")
        exit 3
      }
      foreach ($t in $tickets) { Update-Ticket $t @{ held = $true; acquired = (Iso (Now)) } }
      $script:WaitSec = 0
    } else { Wait-All $tickets $gates $TimeoutMin }
    $acquiredAt = Now
    $held = ($resList -join ',')
    Write-Journal @{ event = 'start'; resource = $held; tickets = @($tickets | ForEach-Object id); purpose = $Purpose; cmd = $cmdLine; repo = $repo.Name; lane = $tickets[0].lane; waitSec = $script:WaitSec }
    Send-Signal 'agentq-start' "$held — $Purpose"
    $env:AGENTQ_HELD = (@($env:AGENTQ_HELD, $held) | Where-Object { $_ }) -join ','
    $env:AGENTQ_PURPOSE = $Purpose
    $env:AGENTQ_SESSION = $Session
    $env:AGENTQ_LANE = "$($tickets[0].lane)"
    # run-build writes <ticket>.wedged beside these when its build log stops growing (WEDGED in status).
    $env:AGENTQ_TICKET_FILES = (@($env:AGENTQ_TICKET_FILES) + @($tickets | ForEach-Object file) | Where-Object { $_ }) -join ';'

    # Heartbeat: a background job touches every ticket's .hb file every 20 s.
    # Idle watchdog (DC-012): every 60 s it sums the CPU time of this run's process tree. A tree
    # that burned < idleCpuSec over idleYieldMin minutes is doing nothing locally (waiting on a
    # cloud VM, network, a hung child): its build:machine ticket YIELDS (does not count against
    # the machine cap) until CPU comes back. The repo ticket stays held (correctness).
    $hbFiles = @($tickets | ForEach-Object { "$($_.file).hb" })
    $machineFile = @($tickets | Where-Object resource -eq 'build:machine' | ForEach-Object file) | Select-Object -First 1
    $cfg = Get-Config
    $hb = Start-ThreadJob -ArgumentList $hbFiles, $machineFile, $PID, ([int]$cfg.idleYieldMin), ([double]$cfg.idleCpuSec), $Journal, $Session -ScriptBlock {
      param($files, $mfile, $rootPid, $yieldMin, $cpuSec, $journal, $session)
      $samples = [Collections.Generic.List[object]]::new(); $tick = 0; $yielded = $false
      function TreeCpu([int]$root) {
        # Get-Process + .Parent, NOT Get-CimInstance Win32_Process: each WMI enumeration cost
        # WmiPrvSE ~6.7 s of CPU with ~1200 processes (measured elevated 2026-10-19), and every
        # agentq run holder did one per minute -> ~1 core of WmiPrvSE with 10 holders. This
        # path takes ~0.25 s in-process and touches no WMI provider.
        $kids = @{}
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
          $k = try { [int]$p.Parent.Id } catch { -1 }
          if ($k -le 0) { continue }
          if (-not $kids[$k]) { $kids[$k] = [Collections.Generic.List[object]]::new() }; $kids[$k].Add($p)
        }
        $sum = 0.0; $stack = [Collections.Generic.Stack[int]]::new(); $stack.Push($root); $seen = @{}
        while ($stack.Count) { $id = $stack.Pop(); if ($seen[$id]) { continue }; $seen[$id] = 1
          foreach ($c in @($kids[$id])) { if ($c) { $cpu = try { $c.TotalProcessorTime.TotalSeconds } catch { 0 }; $sum += [double]$cpu; $stack.Push([int]$c.Id) } } }
        $sum
      }
      function SetFlag([string]$f, [bool]$v) {
        try { $raw = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable; $raw['yielded'] = $v; $raw['yieldAt'] = [DateTime]::UtcNow.ToString('o')
          [IO.File]::WriteAllText("$f.tmp", ($raw | ConvertTo-Json -Depth 4)); [IO.File]::Move("$f.tmp", $f, $true) } catch {}
      }
        # A thread job runs in a FRESH session state: the parent's Append-JournalLine is not visible
        # here (CommandNotFoundException, swallowed by the catch below), so the watchdog flipped the
        # flag but journaled nothing. Same retry contract, defined locally (2026-11-25: suite check
        # 'idle-yield journaled' failed while 'idle watchdog marks sleeping holder yielded' passed).
        function Append-Line([string]$path, [string]$line) {
          $enc = [Text.UTF8Encoding]::new($false)
          for ($i = 1; $i -le 25; $i++) {
            try { [IO.File]::AppendAllText($path, $line, $enc); return $true } catch { Start-Sleep -Milliseconds ([Math]::Min(25 * $i, 200)) }
          }
          $false
        }
      while ($true) {
        foreach ($f in $files) { try { [IO.File]::SetLastWriteTimeUtc($f, [DateTime]::UtcNow) } catch {} }
        if ($mfile -and $yieldMin -gt 0 -and ($tick % 3) -eq 0) {
          try {
            $samples.Add(@{ t = [DateTime]::UtcNow; cpu = (TreeCpu $rootPid) })
            # Drop the oldest only while the NEXT one still covers the whole window.
            while ($samples.Count -gt 2 -and ([DateTime]::UtcNow - $samples[1].t).TotalMinutes -ge $yieldMin) { $samples.RemoveAt(0) }
            $span = ([DateTime]::UtcNow - $samples[0].t).TotalMinutes
            $burn = $samples[$samples.Count - 1].cpu - $samples[0].cpu
            $idle = ($span -ge ($yieldMin - 0.5)) -and ($burn -lt $cpuSec)
            $busyAgain = $yielded -and $samples.Count -ge 2 -and (($samples[$samples.Count - 1].cpu - $samples[$samples.Count - 2].cpu) -ge $cpuSec)
            if ($idle -and -not $yielded) { $yielded = $true; SetFlag $mfile $true
              [void](Append-Line $journal ((@{ ts = [DateTime]::UtcNow.ToString('o'); event = 'idle-yield'; resource = 'build:machine'; session = $session; reason = "cpu $([math]::Round($burn,1))s in $([math]::Round($span,1)) min" } | ConvertTo-Json -Compress) + "`n")) }
            elseif ($busyAgain) { $yielded = $false; SetFlag $mfile $false
              [void](Append-Line $journal ((@{ ts = [DateTime]::UtcNow.ToString('o'); event = 'idle-resume'; resource = 'build:machine'; session = $session } | ConvertTo-Json -Compress) + "`n")) }
          } catch {}
        }
        $tick++; Start-Sleep -Seconds 20
      }
    }
    # ADR 0003 W2-4: this process (and every child it starts) runs in a job object: leftover children die
    # with the holder (kill-on-close) and CPU is shared by lane weight when the machine is saturated.
    # Best effort: any failure runs the command exactly as before. AGENTQ_NO_JOBOBJ=1 disables it.
    $jobInfo = $null
    if ($env:AGENTQ_NO_JOBOBJ -ne '1' -and $IsWindows) {
      $libJ = Join-Path $PSScriptRoot 'agentq-jobobject-lib.ps1'
      if (Test-Path -LiteralPath $libJ) {
        . $libJ
        $wByLane = @{ interactive = 9; quick = 8; gate = 7; heavy = 4; batch = 2 }
        $lw = "$($tickets[0].lane)"; $wt = if ($wByLane.ContainsKey($lw)) { $wByLane[$lw] } else { 5 }
        # 'land pregate' is the SAME gate, only run before the ticket - it must not be starved either
        # (2026-11-25: a pre-gate at BelowNormal lost the box to sibling gates and was reaped as dead).
        if ($held -like 'land:*' -or $Purpose -match '^land (pre)?gate') { $wt = 9 }
        $jobInfo = Enter-AgentqJob $wt
        if ($jobInfo.error) { Write-Journal @{ event = 'jobobj-failed'; resource = $held; reason = $jobInfo.error; repo = $repo.Name } }
        else { $jobInfo.weight = $wt }
      }
    }
    # Job-object weight only arbitrates BETWEEN jobs; VS Code, its terminals and the agents' shells are in
    # no job, so a saturating build still starved them (terminals 2-7 s, up to tens of s to start, 32/32
    # cores busy, 2026-10-19). A priority class does compete with them, and children inherit it.
    # interactive/land stay Normal; quick/gate/heavy BelowNormal; batch Idle. AGENTQ_RUN_PRIORITY overrides.
    $pcByLane = @{ interactive = 'Normal'; quick = 'BelowNormal'; gate = 'BelowNormal'; heavy = 'BelowNormal'; batch = 'Idle' }
    # 'land pregate' matches with 'land gate' on purpose: the owner's rule is the land gate runs Normal
    # while ordinary builds stay BelowNormal, and the pre-gate IS the land gate.
    $pc = if ($env:AGENTQ_RUN_PRIORITY) { $env:AGENTQ_RUN_PRIORITY } elseif ($held -like 'land:*' -or $Purpose -match '^land (pre)?gate') { 'Normal' } elseif ($pcByLane.ContainsKey("$($tickets[0].lane)")) { $pcByLane["$($tickets[0].lane)"] } else { 'BelowNormal' }
    try { (Get-Process -Id $PID).PriorityClass = [Diagnostics.ProcessPriorityClass]$pc; if ($jobInfo) { $jobInfo.priority = $pc } } catch {}
    try {
      $exe = $cmdArgs[0]; $argv = @($cmdArgs | Select-Object -Skip 1)
      # Run at the repo root, like Invoke-Commit does. Prepare-Slot launches the slot-prep install as
      # `agentq run -Repo <slot> -- pnpm install` from the CALLER's directory, so without this the
      # install filled the caller's tree, returned 0, and the prep recorded ready=true for a slot that
      # still had no node_modules (2026-11-21, reported as "the next brand-new slot starts hollow").
      # Only when the current directory is OUTSIDE the repo, so an ordinary in-repo invocation keeps
      # its own (possibly nested) cwd exactly as before.
      $pushed = $false
      if ($repo -and $repo.Top) {
        $here = (Get-Location).ProviderPath
        $top = "$($repo.Top)".TrimEnd('\')
        $inside = $here.Equals($top, [StringComparison]::OrdinalIgnoreCase) -or $here.StartsWith($top + '\', [StringComparison]::OrdinalIgnoreCase)
        if (-not $inside) { Push-Location $repo.Top; $pushed = $true }
      }
      try { & $exe @argv } finally { if ($pushed) { Pop-Location } }
      $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    } finally { Stop-Job $hb -ErrorAction SilentlyContinue; Remove-Job $hb -Force -ErrorAction SilentlyContinue }
    $jstat = if ($jobInfo -and $jobInfo.job -ne [IntPtr]::Zero) { Get-AgentqJobStats $jobInfo.job } else { $null }
    $dur = [math]::Round(((Now) - $started).TotalSeconds)
    $holdSec = [math]::Round(((Now) - $acquiredAt).TotalSeconds)
    $je = @{ event = $(if ($code -eq 0) { 'done' } else { 'fail' }); resource = $held; exit = $code; durSec = $dur; holdSec = $holdSec; waitSec = $script:WaitSec; lane = $tickets[0].lane; kind = (Get-CmdKind $cmdLine); purpose = $Purpose; cmd = $cmdLine; repo = $repo.Name }
    if ($jstat) { $je.cpuSec = $jstat.cpuSec; $je.peakMB = $jstat.peakMB; $je.procs = $jstat.procs; $je.cpuWeight = $jobInfo.weight }
    if ($pc) { $je.priority = $pc }
    Write-Journal $je
    if ($code -ne 0) { Send-Signal 'agentq-fail' "$held failed ($code) — $Purpose" }
    exit $code
  } finally {
    foreach ($t in $tickets) { Remove-Item -LiteralPath $t.file, "$($t.file).hb", "$($t.file).wedged" -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-Commit {
  $repo = Get-RepoInfo $Repo
  Assert-ExpectedRepo $repo
  if (-not $repo) { throw 'agentq commit: not in a git repo' }
  if (-not $Purpose) { throw 'agentq commit: -Purpose is required' }
  if (-not $Message) { throw 'agentq commit: -Message is required' }
  $plist = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if (-not $plist) { throw 'agentq commit: -Paths a,b,c is required (explicit paths only — never the whole index)' }
  $outside = @($plist | Where-Object { [IO.Path]::IsPathRooted($_) -and -not ([IO.Path]::GetFullPath($_).ToLowerInvariant().StartsWith($repo.Top.ToLowerInvariant() + [IO.Path]::DirectorySeparatorChar)) })
  if ($outside) { [Console]::Error.WriteLine("agentq: REFUSED - paths outside $($repo.Top): $($outside -join ', ')"); exit 3 }
  Assert-SharedCloneWriteAllowed $repo 'commit'
  $res = "commit:$($repo.Name)"
  Assert-NotMarked $res
  $t = New-Ticket $res $Purpose "commit $($plist -join ' ')" $repo.Top
  Write-Journal @{ event = 'queued'; resource = $res; ticket = $t.id; purpose = $Purpose; paths = $plist; repo = $repo.Name }
  $script:CommitDone = $false
  $tPush = $null
  try {
    Wait-Turn $t $TimeoutMin $null
    $env:AGENTQ_HELD = (@($env:AGENTQ_HELD, $res) | Where-Object { $_ }) -join ','
    $env:AGENTQ_PURPOSE = $Purpose; $env:AGENTQ_SESSION = $Session
    Push-Location $repo.Top
    try {
      # A worktree installed with `pnpm install --ignore-scripts` has core.hooksPath=.husky/_ but no
      # .husky/_/pre-commit: git then runs NO hook, silently (brivio 2026-09-29, three times). Refuse
      # instead of committing ungated; the fix is one command.
      $hp = (& git config --get core.hooksPath 2>$null)
      if ($hp -and -not $env:SKIP_HOOKS -and -not $env:FAST_COMMIT) {
        $hookDir = if ([IO.Path]::IsPathRooted($hp)) { $hp } else { Join-Path $repo.Top $hp }
        $hpParent = Split-Path $hp -Parent
        # Single-segment hooksPath (e.g. '.githooks'): parent is '' and Join-Path would throw.
        $declared = if ($hpParent) { Join-Path $repo.Top (Join-Path $hpParent 'pre-commit') } else { Join-Path $repo.Top 'pre-commit' }
        if ((Test-Path -LiteralPath $declared) -and -not (Test-Path -LiteralPath (Join-Path $hookDir 'pre-commit'))) {
          throw "agentq commit: core.hooksPath='$hp' has no pre-commit (hooks would be skipped silently). Run 'pnpm exec husky' in $($repo.Top) first."
        }
      }
      # Stage and commit in ONE critical section, pathspec-limited: a commit without a
      # pathspec takes EVERYTHING staged, including other agents' files (7cc672f7).
      # Deleted paths cannot be `git add`-ed ("pathspec did not match", 2026-09-28):
      # stage those with `git rm --cached`, still limited to @plist.
      # X-03 (2026-10-05): remember what was staged BEFORE we touch the index, so a rejected
      # commit can unstage exactly the paths we added (a later amend swallowed them, 2026-10-02).
      $preStaged = @(& git diff --cached --name-only -- @plist)
      $gone = @($plist | Where-Object { -not (Test-Path -LiteralPath $_) })
      $live = @($plist | Where-Object { Test-Path -LiteralPath $_ })
      if ($live.Count) { & git add -- @live; if ($LASTEXITCODE) { throw "git add failed ($LASTEXITCODE)" } }
      if ($gone.Count) { & git rm -q --cached --ignore-unmatch -- @gone; if ($LASTEXITCODE) { throw "git rm failed ($LASTEXITCODE)" } }
      $msg = "$Message`n`nAgent-Session: $Session`nAgent-Purpose: $Purpose"
      $tmp = [IO.Path]::GetTempFileName()
      [IO.File]::WriteAllText($tmp, $msg, [Text.UTF8Encoding]::new($false))
      & git commit -q -F $tmp -- @plist
      $cc = $LASTEXITCODE; Remove-Item $tmp -Force
      if ($cc) {
        $ours = @(& git diff --cached --name-only -- @plist | Where-Object { $preStaged -notcontains $_ })
        if ($ours.Count) { & git reset -q -- @ours 2>$null }
        throw "git commit failed ($cc) — nothing committed; unstaged $($ours.Count) path(s) agentq had staged"
      }
      $sha = (& git rev-parse --short HEAD).Trim()
      $script:CommitDone = $true
      $files = @(& git show --name-only --format= HEAD)
      $foreign = @($files | Where-Object { $f = $_; -not ($plist | Where-Object { $f -like "$($_ -replace '\\','/')*" }) })
      Write-Journal @{ event = 'commit'; resource = $res; sha = $sha; purpose = $Purpose; message = $Message; paths = $files; foreign = $foreign; repo = $repo.Name }
      if ($foreign) { [Console]::Error.WriteLine("agentq: WARNING commit $sha also contains files outside -Paths: $($foreign -join ', ')") }
      Write-Output "committed $sha ($($files.Count) files)"
    } finally { Pop-Location }
    # ---- push phase (ADR 0014 D1) ----------------------------------------------------------------
    # The index lock ENDS here. Holding `commit:<repo>` across the pre-push gates (husky lint/typecheck,
    # minutes) queued every other agent's `git add` behind it - commit:codai was held 9.2 h over 7 days,
    # and an agent that only wants to commit waited for the length of someone else's gates. A push has its
    # own ticket (push:<repo>, capacity 2) because it contends on the remote ref only, and the retry loop
    # below already DEFERS when an incoming change overlaps another agent's uncommitted edits.
    Drop-Ticket $t
    # A repository with no 'origin' (frontiers-index and most of the research repos have none) can only fail
    # the push, and the failure looked exactly like a refused gate while the commit HAD landed. Detect it
    # first, say so, and leave the commit local (2026-11-25).
    $hasOrigin = $false
    Push-Location $repo.Top
    try { $hasOrigin = (@(& git remote) -contains 'origin') } finally { Pop-Location }
    if (-not $NoPush -and -not $hasOrigin) {
      [Console]::Error.WriteLine("agentq: no 'origin' remote in $($repo.Top) - commit $sha stays LOCAL (nothing pushed)")
    }
    if (-not $NoPush -and $hasOrigin) {
      $resPush = "push:$($repo.Name)"
      Assert-NotMarked $resPush
      $tPush = New-Ticket $resPush $Purpose "push $($repo.Name)" $repo.Top
      Write-Journal @{ event = 'queued'; resource = $resPush; ticket = $tPush.id; purpose = $Purpose; repo = $repo.Name }
      Wait-Turn $tPush $TimeoutMin $null
      $env:AGENTQ_HELD = (@($env:AGENTQ_HELD, $resPush) | Where-Object { $_ }) -join ','
      Push-Location $repo.Top
      try {
        $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
        $pushed = $false
        for ($i = 1; $i -le 4 -and -not $pushed; $i++) {
          $pushOut = @(Invoke-GitNet @('-C', $repo.Top, 'push', '-q', 'origin', "HEAD:$branch") -TimeoutSec (Get-GitPushTimeoutSec))
          if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
          # Only a lost race (remote moved) is worth fetch+merge+retry. A pre-push hook
          # rejection (failing gates) would re-run the gates 4x in silence and look frozen.
          # A LOST RACE, not a refusal. Two pushes to the same branch may now overlap (push:<repo>, cap 2),
          # and a bare/remote repo answers the loser with `! [remote rejected] HEAD -> main (failed to
          # update ref)` - which the old pattern (non-fast-forward|fetch first|rejected .*(stale|Updates
          # were rejected) did NOT match, so the loser threw and its commit stayed local (caught by
          # test-agentq-commit-fast, 2026-11-21). "cannot lock ref" is the same race seen by a second pusher.
          if (-not ($pushOut -match 'non-fast-forward|fetch first|rejected .*\(stale|Updates were rejected|failed to update ref|cannot lock ref')) {
            $pushOut | Select-Object -Last 25 | ForEach-Object { [Console]::Error.WriteLine($_) }
            Write-Journal @{ event = 'push-failed'; resource = $res; sha = $sha; branch = $branch; repo = $repo.Name }
            throw "push failed (not a race: pre-push hook or remote refused; output above). Commit $sha is local - fix and push again."
          }
          Invoke-GitNet @('-C', $repo.Top, 'fetch', '-q', 'origin', $branch) | Out-Null
          # A merge in a shared clone must never touch another agent's uncommitted files.
          # Distinguish a real content conflict from "incoming change overlaps a dirty file".
          $incoming = @(& git diff --name-only "HEAD...origin/$branch")
          $dirtyNow = @(& git status --porcelain | ForEach-Object { $_.Substring(3).Trim('"') })
          $overlap = @($incoming | Where-Object { $dirtyNow -contains $_ })
          if ($overlap) {
            Write-Journal @{ event = 'push-deferred'; resource = $res; sha = $sha; branch = $branch; overlap = $overlap; repo = $repo.Name }
            throw "push deferred: origin/$branch changes files with UNCOMMITTED local edits (other agents'): $($overlap -join ', '). Commit $sha stays local and rides the next push from this clone; do NOT stash/reset them."
          }
          & git merge-tree --write-tree HEAD "origin/$branch" *> $null
          if ($LASTEXITCODE) { throw "push rejected: merge of origin/$branch has content conflicts — resolve by hand (commit $sha is local)" }
          $mergeOut = @(& git merge -q --no-edit "origin/$branch" 2>&1 | ForEach-Object { "$_" })
          $mergeCode = $LASTEXITCODE
          if ($mergeCode) {
            if (Test-Path (Join-Path (& git rev-parse --git-dir) 'MERGE_HEAD')) { & git merge --abort 2>$null }
            $mergeOut | Select-Object -Last 15 | ForEach-Object { [Console]::Error.WriteLine($_) }
            throw "push rejected: git merge origin/$branch failed ($mergeCode) — commit $sha is local"
          }
        }
        if (-not $pushed) { throw "push failed after 4 attempts (commit $sha is local)" }
        $head = (& git rev-parse --short HEAD).Trim()
        Write-Journal @{ event = 'push'; resource = $res; sha = $head; branch = $branch; repo = $repo.Name }
        Write-Output "pushed $head -> origin/$branch"
        $acts = @(Notify-Landing $repo.Name $branch "$(& git rev-parse HEAD)".Trim() '')
        if ($acts) { Write-Output "releases following origin/${branch}: $($acts -join ', ')" }
      } finally { Pop-Location }
    }
  } catch {
    # DC-015: ~30 % of commit tickets ended with no commit and no journaled reason. Record it.
    $msg = "$($_.Exception.Message)"
    Write-Journal @{ event = $(if ($script:CommitDone) { 'push-failed' } else { 'commit-failed' }); resource = $res; purpose = $Purpose; reason = $msg.Substring(0, [math]::Min(400, $msg.Length)); paths = $plist; repo = $repo.Name }
    throw
  } finally { Drop-Ticket $t; Drop-Ticket $tPush }
}

# r7 (land ETA): an honest wait estimate for a land:<repo> waiter, from data the journal already has.
# land:<repo> is capacity-1, so a hold ends with the next `acquired` or with the holder's own
# `land`/`land-gate-failed`/`land-push-failed`/`land-conflict` event. Read-only; returns $null when
# there is less than 3 holds of history, so the caller prints `unknown (no history)` instead of a number.
function Get-LandHoldStats([string]$repoName, [int]$days = 3) {
  $res = "land:$repoName"; $since = (Now).AddDays(-$days)
  $evs = @(Read-Journal 2000 $since $repoName | Where-Object { "$(JProp $_ 'resource')" -eq $res } | Sort-Object { ParseUtc (JProp $_ 'ts') })
  $terminal = @('land', 'land-gate-failed', 'land-push-failed', 'land-conflict', 'land-ungated', 'land-batch')
  $holds = @(); $lastAcq = $null
  for ($i = 0; $i -lt $evs.Count; $i++) {
    if ("$(JProp $evs[$i] 'event')" -ne 'acquired') { continue }
    $at = ParseUtc (JProp $evs[$i] 'ts'); $sess = "$(JProp $evs[$i] 'session')"; $lastAcq = $at
    for ($j = $i + 1; $j -lt $evs.Count; $j++) {
      $ev = "$(JProp $evs[$j] 'event')"; $et = ParseUtc (JProp $evs[$j] 'ts')
      if ($et -le $at) { continue }
      if ($ev -eq 'acquired' -or (($terminal -contains $ev) -and "$(JProp $evs[$j] 'session')" -eq $sess)) { $holds += ($et - $at).TotalSeconds; break }
    }
  }
  if ($holds.Count -lt 3) { return $null }
  $s = @($holds | Sort-Object); $n = $s.Count
  [pscustomobject]@{ n = $n; p50 = [int]$s[[math]::Floor(($n - 1) * 0.5)]; p90 = [int]$s[[math]::Floor(($n - 1) * 0.9)]; lastAcq = $lastAcq }
}

function Show-Status {
  $repo = Get-RepoInfo $Repo
  $qidx = Get-QueueIndex
  $dirs = @($qidx.Keys)
  $rows = @()
  $landEta = @{}
  # (b) owner 2026-11-28: a read verb must NEVER throw on ticket churn. A live `agentq status` died with
  # "Could not find file '...\queues\gate_machine\00000119-*.json'" because the sample Get-QueueSample picked
  # was claimed/reaped by another agent before the read - i.e. the ordinary, healthy case, not corruption.
  # Re-pick a FRESH sample (up to 3 picks) and read through Read-JsonFile (retrying, returns $null instead of
  # throwing); a resource that still fails is SKIPPED and COUNTED, and the count is printed below - never
  # swallowed, because a silent skip is how a queue quietly disappears from the reader's view.
  $churn = @()
  foreach ($k in $dirs) {
    $raw = $null
    for ($a = 1; $a -le 3 -and -not $raw; $a++) {
      $sample = Get-QueueSample @($qidx[$k])
      if (-not $sample) { break }
      $raw = Read-JsonFile $sample.FullName
      if ($raw -is [string]) { $raw = $null }
    }
    if (-not $raw) { if ("$k") { $churn += "$k" }; continue }
    $res = $raw.resource
    if (-not $All -and $repo -and $res -notmatch "(^|:)$([regex]::Escape($repo.Name))(:|$)" -and $res -notin 'build:machine', 'gate:machine') { continue }
    # B) the negative ledger for this land queue (branch -> {at,tree,reason}), read once per resource.
    $qmap = if ($res -like 'land:*') { Get-LandQuarantine (Get-ResourceRepo $res) } else { $null }
    # r7: hold-time history for this land queue (null when the journal has too little history).
    $hs = if ($res -like 'land:*') { Get-LandHoldStats (Get-ResourceRepo $res) 3 } else { $null }
    if ($res -like 'land:*') { $landEta[$res] = $hs }
    $live = @(Get-Live $res)
    $cap = Get-Capacity $res
    $wq = @($live | Where-Object { -not (Test-Held $_ $live $cap) } | Sort-Object @{ e = { Get-EffPrio $_ }; Descending = $true }, @{ e = { [long]$_.seq } })
    foreach ($t in $live) {
      $isHeld = Test-Held $t $live $cap
      $role = if ($isHeld) { if (P $t 'yielded' $false) { 'HOLD(idle)' } else { 'HOLD' } } else { "wait#$([array]::IndexOf(@($wq | ForEach-Object id), $t.id) + 1)$(if (-not (P $t 'ready' $true)) { '~' })" }
      # r7: an ETA for a waiter, from the hold history of THIS queue - always a range, never a promise,
      # and never a number when the journal has too little history to support one.
      $etaTxt = $null
      if (-not $isHeld -and $res -like 'land:*') {
        $pos = [array]::IndexOf(@($wq | ForEach-Object id), $t.id) + 1
        $etaTxt = if (-not $hs) { 'unknown (no history)' }
          elseif (($pos * $hs.p50) -ge 3600) { '>60m TIMEOUT' }
          else { "~$([math]::Round($pos * $hs.p50 / 60))-$([math]::Round([math]::Min($pos * $hs.p90, 3600) / 60))m" + $(if (($pos * $hs.p90) -ge 3600) { '+' } else { '' }) }
      }
      # WEDGED: run-build saw its build log silent for -WedgeMin (sidecar <ticket>.wedged, JSON {since,quietMin,log,pid}).
      $wedgeTxt = $null
      if (Test-Path -LiteralPath "$($t.file).wedged") {
        $wm = '?'
        try {
          $w = Get-Content -LiteralPath "$($t.file).wedged" -Raw | ConvertFrom-Json -DateKind String
          if ($w.PSObject.Properties['since'] -and $w.since) { $q = if ($w.PSObject.Properties['quietMin']) { [double]$w.quietMin } else { 0 }; $wm = [math]::Round(((Now) - (ParseUtc $w.since)).TotalMinutes + $q, 0) }
        } catch { }
        $wedgeTxt = "WEDGED(${wm}m)"
      }
      # B) a ticket whose topic is quarantined shows the reason right in the row, so a waiter can see WHY
      # its land is not being absorbed by the holder instead of only noticing that it never moves.
      $qtxt = $null
      if ($qmap -and $qmap.Count) {
        $qb = "$(P $t 'landBranch' '')"
        if ($qb -and $qmap.ContainsKey($qb)) { $qtxt = "$(P $qmap[$qb] 'reason') (at $(P $qmap[$qb] 'at' ''), tree $(Short "$(P $qmap[$qb] 'tree' '')") )" }
      }
      $rows += [pscustomobject]@{
        resource = $res; role = $role; lane = "$(P $t 'lane' '-')"; prio = $(if (P $t 'v') { Get-EffPrio $t } else { '-' })
        state = $(if ($t.stale -and $wedgeTxt) { "STALE($($t.beatAgeMin)m),$wedgeTxt" } elseif ($t.stale) { "STALE($($t.beatAgeMin)m)" } elseif ($wedgeTxt) { $wedgeTxt } elseif ($qtxt) { 'QUARANTINED' } else { 'ok' })
        ageMin = [math]::Round(((Now) - (ParseUtc $t.created)).TotalMinutes, 1)
        session = $t.session; purpose = $t.purpose; id = $t.id
        landBranch = "$(P $t 'landBranch' '')"; quarantine = $qtxt; eta = $etaTxt
      }
    }
  }
  $marks = @(Get-ChildItem $MDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -DateKind String })
  $v2 = Get-V2Status $(if (-not $All -and $repo) { $repo.Name } else { $null })
  # OQ-004: the load probe and what admission does with it (read from the shared record, never sampled here).
  $ld = Get-AdmissionLoad -NoSample
  # OQ-005: the agent limit in force and why (owner presence + schedule, from the same shared record).
  $agl = Get-AgentLimit
  # machine-wide count; with -All (or outside a repo) the leases were just read, so they are not read twice
  $leasedTasks = if ($All -or -not $repo) { @($v2.leases | Where-Object { "$($_.role)" -eq 'task' }).Count } else { Get-TaskLeaseCount }
  # PERF (2026-11-26). The burst records sit next to the tickets, so the queue index that was built for
  # the ticket scan already knows where they are - the recursive walk this replaces was a SECOND pass
  # over the same 120 directories.
  $bursts = @(foreach ($k in @($qidx.Keys)) {
      foreach ($bf in @($qidx[$k])) {
        if ($bf.Name -ne 'burst.json') { continue }
        $b = try { Get-Content $bf.FullName -Raw | ConvertFrom-Json -DateKind String } catch { $null }
        if ($b -and (ParseUtc $b.until) -gt (Now)) { $b }
      }
    })
  if ($Json) {
    $o = ConvertTo-V2Json $v2; $o.tickets = $rows; $o.marks = $marks; $o.bursts = $bursts
    $o.load = [ordered]@{ enabled = [bool]$ld.enabled; saturated = [bool]$ld.saturated; probeMs = $ld.last; medianMs = $ld.median; samples = $ld.n; ageSec = $ld.ageSec; thresholdMs = $ld.thresholdMs; src = "$($ld.src)" }
    $o.agents = [ordered]@{ limit = [int]$agl.limit; base = [int]$agl.base; state = "$($agl.state)"; why = "$($agl.why)"; inputIdleSec = $agl.idleSec; sampleAgeSec = $agl.ageSec; night = [bool]$agl.night; nightWindow = "$($agl.nightWindow)"; leased = [int]$leasedTasks }
    $o.landQuarantine = @($rows | Where-Object { $_.quarantine } | ForEach-Object { [ordered]@{ resource = $_.resource; branch = $_.landBranch; reason = $_.quarantine } })
    $o | ConvertTo-Json -Depth 5; return
  }
  if ($marks) {
    Write-Output '== MARKS'
    $marks | ForEach-Object { $x = if (Test-MarkExpired $_) { "  [EXPIRED after $([int](Get-LandFreezeMaxMin)) min - the next land breaks it]" } else { '' }; Write-Output ("{0,-34} {1,-8} since {2} by {3}: {4}{5}" -f $_.resource, $_.state.ToUpper(), $_.at, $_.session, $_.reason, $x) }
  }
  if (-not $ld.enabled) { Write-Output '== LOAD admission by load is off (config admission.enabled / AGENTQ_NO_ADMISSION)' }
  elseif ($null -eq $ld.last) { Write-Output "== LOAD no start probe yet (a sample is taken by agentq run/lease and by the sync loop); admission OPEN" }
  else {
    $verdict = if ($ld.saturated) { 'SATURATED: no new task slot and no second gate/heavy/batch build until it recovers' } elseif ($ld.n -lt 3) { 'OPEN (fewer than 3 fresh samples)' } else { 'OPEN' }
    Write-Output ("== LOAD start probe {0} ms ({1} s ago, by {2}); median of last {3}: {4} ms; limit {5} ms -> admission {6}" -f $ld.last, $ld.ageSec, $(if ($ld.src) { $ld.src } else { '?' }), $ld.n, $(if ($null -ne $ld.median) { $ld.median } else { '-' }), $ld.thresholdMs, $verdict)
  }
  $nightTxt = if ($agl.nightWindow) { "; night $($agl.nightWindow): $(if ($agl.night) { 'now' } else { 'not now' })" } else { '' }
  Write-Output ("== AGENTS limit {0} of {1} task slots ({2}{3}); {4} leased" -f $agl.limit, $agl.base, $agl.why, $(if ($agl.state -eq 'off') { '' } else { $nightTxt }), $leasedTasks)
  # D5 (ADR 0014): my session's slot share, so an agent that only reads `status` sees why its next lease
  # would be refused and what it already holds. One line, never in -Json (that path returned above).
  Show-SlotShare
  # Discoverability for the read-only `timings` verb: reading codai's 2.4k gate logs costs ~18 s, so it
  # must never run HERE - one line naming it is the only cheap way an agent learns it exists. Never -Json.
  Write-Output 'tip: agentq timings -Limit 5 -> per-suite gate wall times from the build logs (slowest last run first)'
  Format-V2Status $v2
  if ($rows) {
    Write-Output '== QUEUES'
    $rows | Format-Table resource, role, lane, prio, state, ageMin, session, purpose, id, eta -AutoSize | Out-String -Width 240 | Write-Output
    # r7: the queue's own numbers behind the ETA, so the range can be judged instead of trusted.
    foreach ($rn in @($landEta.Keys)) {
      $h = $landEta[$rn]; $waiting = @($rows | Where-Object { $_.resource -eq $rn -and "$($_.role)" -like 'wait#*' }).Count
      $dist = if ($h) { "p50 $([math]::Round($h.p50 / 60, 1))m / p90 $([math]::Round($h.p90 / 60, 1))m (n=$($h.n), 3d)" } else { 'no history - ETA unknown' }
      $held = if ($h -and $h.lastAcq) { [math]::Round(((Now) - $h.lastAcq).TotalMinutes, 0) } else { '?' }
      Write-Output "== LAND ETA $rn`: depth $($waiting + 1) ($waiting waiting); holder ${held}m in; hold $dist; queue timeout 60m (estimate from history, not a promise)"
    }
  } else { Write-Output "== QUEUES: idle$(if (-not $All -and $repo) { " for $($repo.Name) (use -All for every repo)" })" }
  # B) the quarantined topics of the land queues in scope, with the reason and its stamp: a red topic is
  # skipped by the batch picker (journal land-topic-quarantined) and gates on its own turn.
  $qrows = @($rows | Where-Object { $_.quarantine })
  if ($qrows) {
    Write-Output '== LAND QUARANTINE previous pre-gate failed; the batch picker skips these until a fresh pre-gate passes (explicit land -Branch <b>; TTL landQuarantineHours)'
    $qrows | ForEach-Object { Write-Output ("{0,-16} {1,-28} {2}" -f $_.resource, $_.landBranch, $_.quarantine) }
  }
  # == MINE (2026-11-23): the other half of the bump bug. The QUEUES table is repo-scoped unless -All,
  # and it never said WHICH row was the caller's, so a waiter could not read the id of its own ticket.
  # Print the caller's own waiting tickets (all repos) with the id, so `bump -Id <hash>` / `-Session <s>`
  # has a target. Read-only: Get-Live/Get-Capacity never write on a read-only verb.
  $mine = @(Get-SessionTickets $Session $true $qidx)
  if ($mine) { Write-Output ("== MINE session {0}: {1}" -f $Session, (($mine | ForEach-Object { "$($_.id) on $($_.resource)" }) -join '; ')) }
  else { Write-Output ("== MINE session {0}: no waiting ticket" -f $Session) }
  foreach ($b in $bursts) { Write-Output ("== BURST {0} +{1} until {2} by {3}: {4}" -f $b.resource, $b.by, $b.until, $b.session, $b.reason) }
  # (b) 2026-11-28: a skipped resource is a fact about the fleet, not noise. One line, only when it happened.
  if ($churn.Count) { Write-Output ("== QUEUE CHURN {0} resource(s) skipped: a sample vanished mid-read (re-picked up to 3x): {1}" -f $churn.Count, ($churn -join ', ')) }
  # Discoverability (2026-11-20): an agent that only ever reads `status` must still learn where the rest
  # of the tool is. One line, always last, never in -Json (that path returned above, parsers).
  Write-Output '== HELP every verb + group: agentq help | usage + example for one: agentq help <verb> (e.g. agentq help land)'
}

# Journal lines come from several writers (agentq, guard hook: tool/paths/repo, no resource); StrictMode 3
# throws on a missing property, so read journal fields through JProp.
function JProp($o, [string]$k) { $p = $o.PSObject.Properties[$k]; if ($p) { $p.Value } else { $null } }

function Read-Journal([int]$n, $since, [string]$repoName) {
  $files = @(Get-JournalFiles)
  if (-not $files) { return @() }
  if ($n -gt 0) {
    # The tail is what almost every caller wants, and the same tail is asked for several times per command.
    $items = @(Get-JournalTailItems ([math]::Max($n * 8, 400)))
  } else {
    $lines = foreach ($jf in $files) { Get-Content $jf }
    # PERF (2026-11-26). The journal is one append-only file that reached 42 MB / 97 000 lines, and a
    # `since` query used to ConvertFrom-Json EVERY line and then ParseUtc each one to compare (measured
    # 6.1 s + 9.8 s on this machine for a 12 h window - the single biggest cost in `agentq since`, which
    # agents run at the start of every task). Every line carries exactly one "ts":"..." key, verified on
    # all 97 107 lines, and the timestamps are ISO-8601 UTC, which compares correctly as a STRING. So the
    # cheap native IndexOf/Substring below cuts the set to the window BEFORE any JSON is parsed; the exact
    # filter still runs afterwards, and the cheap one was proved to select the identical set
    # (4211 = 4211 for a 12 h window). Keep the exact filter: this is a pre-filter, never a substitute.
    if ($since) {
      $cutStr = ([datetime]$since).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss')
      $lines = @($lines | Where-Object {
          $i = $_.IndexOf('"ts":"')
          ($i -ge 0) -and ($i + 25 -le $_.Length) -and ($_.Substring($i + 6, 19) -ge $cutStr)
        })
    }
    $items = @($lines | ForEach-Object { try { $_ | ConvertFrom-Json -DateKind String } catch { $null } } | Where-Object { $_ })
    if ($files.Count -gt 1) { $items = @($items | Sort-Object { "$(JProp $_ 'ts')" }) }
  }
  if ($since) { $items = @($items | Where-Object { (JProp $_ 'ts') -and (ParseUtc (JProp $_ 'ts')) -ge $since }) }
  # The regex is constant, so build it ONCE: the old form compiled it again for every item.
  if ($repoName) {
    $rxRepo = "(^|:)$([regex]::Escape($repoName))(:|$)"
    $items = @($items | Where-Object { ($_.PSObject.Properties.Name -contains 'repo' -and $_.repo -eq $repoName) -or ("$(JProp $_ 'resource')" -match $rxRepo) })
  }
  if ($n -gt 0) { $items = @($items | Select-Object -Last $n) }
  $items
}

# One read+parse of the journal TAIL per process. `status`, `since` and `jobs` each read this tail
# several times (Get-LandHoldStats once per land:* resource, Get-RecentLeaseLosses once more), and a
# read+parse of 16 000 lines cost 0.5-1.5 s EVERY time on the machine of 2026-11-26. The tail is a
# suffix, so a deeper read serves every shallower request: cache the parsed items of the deepest tail
# asked for and slice the end for anything smaller. Read-only verbs exit after one command, so nothing
# outlives the call and a stale cache cannot cross two commands.
function Get-JournalTailItems([int]$nLines, [string[]]$only = $null) {
  if ($nLines -lt 1) { $nLines = 400 }
  $key = "$nLines|$(if ($only) { $only -join ',' } else { '' })"
  $items = @()
  $c = $script:JTail
  if ($c -and $c.ContainsKey($key)) {
    $it = @($c[$key])
    if ($it.Count -le $nLines) { $items = $it } else { $items = @($it[($it.Count - $nLines)..($it.Count - 1)]) }
  } else {
    $files = @(Get-JournalFiles)
    if ($files) {
      $lines = foreach ($jf in $files) { Get-Content $jf -Tail $nLines }
      # `only`: parse nothing that cannot match, the same trick the `since` prefilter uses. A caller that
      # wants one event kind used to ConvertFrom-Json all 4 000 tail lines to keep 25 of them (measured
      # 2026-11-26: 629 ms per call, and it is called on every `status`). A false positive only costs a
      # parse - the caller's own exact filter still runs on the parsed item.
      if ($only) {
        $keep = [System.Collections.Generic.List[string]]::new()
        foreach ($s in $lines) { foreach ($m in $only) { if ($s.Contains($m)) { $keep.Add($s); break } } }
        $lines = $keep
      }
      $items = @($lines | ForEach-Object { try { $_ | ConvertFrom-Json -DateKind String } catch { $null } } | Where-Object { $_ })
      if ($files.Count -gt 1) { $items = @($items | Sort-Object { "$(JProp $_ 'ts')" }) }
      if (-not $script:JTail) { $script:JTail = @{} }
      $script:JTail[$key] = $items
    }
  }
  return $items
}

function Format-Entry($e) {
  $extra = @()
  foreach ($k in 'exit', 'durSec', 'sha', 'reason', 'state') { if ($e.PSObject.Properties.Name -contains $k -and "$($e.$k)") { $extra += "$k=$($e.$k)" } }
  $what = if ($e.PSObject.Properties.Name -contains 'purpose' -and $e.purpose) { $e.purpose } elseif ($e.PSObject.Properties.Name -contains 'message') { $e.message } else { '' }
  $sess = "$(JProp $e 'session')"
  $ts = JProp $e 'ts'; $when = if ($ts) { (ParseUtc $ts).ToLocalTime().ToString('MM-dd HH:mm') } else { '?' }
  '{0} {1,-8} {2,-30} {3,-14} {4} {5}' -f $when, "$(JProp $e 'event')", "$(JProp $e 'resource')", $sess.Substring(0, [math]::Min(14, $sess.Length)), $what, ($extra -join ' ')
}

function Show-Log {
  $repo = Get-RepoInfo $Repo
  $name = if ($All -or -not $repo) { $null } else { $repo.Name }
  $items = @(Read-Journal $Last $null $name)
  if ($Json) { $items | ConvertTo-Json -Depth 5; return }
  $items | ForEach-Object { Format-Entry $_ }
}

function Show-Since {
  $repo = Get-RepoInfo $Repo
  if (-not $repo) { throw 'agentq since: not in a git repo' }
  $from = (Now).AddHours(-$Hours)
  Write-Output "== agentq journal for $($repo.Name), last $Hours h"
  $items = @(Read-Journal 0 $from $repo.Name) | Where-Object { (JProp $_ 'event') -notin 'queued', 'reap' }
  if ($items) { $items | ForEach-Object { Format-Entry $_ } } else { Write-Output '(no entries)' }
  # The NAME, not $Repo: `$repo = Get-RepoInfo $Repo` above overwrote $Repo itself (PowerShell variable
  # names ignore case), so by here $Repo is the repo OBJECT and Get-RepoInfo would be handed a
  # PSCustomObject, fail its `git -C` and return $null - which is how the hint first shipped silent
  # (test-agentq-prewarm-verb.ps1, 2026-11-25).
  Show-PrewarmHint $repo.Name
  Write-Output "== git log origin (last $Hours h)"
  Invoke-GitNet @('-C', $repo.Top, 'fetch', '-q') | Out-Null
  # ONE log spawn, not two: `@{u}` asks git for the upstream itself and the separate
  # `rev-parse --abbrev-ref '@{u}'` existed only to choose the NEXT spawn's argument -- a whole process
  # whose output was never printed. The fallback keeps the no-upstream case at the same two spawns as
  # before (log fails, log HEAD succeeds), so this only ever removes one. `since` is the first call of
  # nearly every task boot, so the saving is paid fleet-wide (agentq round 4).
  $sinceArg = "--since=$([int]($Hours * 60)) minutes ago"
  $fmtArg = '--format=%h %ad %an %s'
  $dtArg = "--date=format:%m-%d %H:%M"
  & git -C $repo.Top log '@{u}' $sinceArg $fmtArg $dtArg -n 60 2>$null
  if ($LASTEXITCODE) { & git -C $repo.Top log HEAD $sinceArg $fmtArg $dtArg -n 60 }
  Write-Output '== live queues'
  Show-Status
}

# ---- prewarm (2026-11-25) -----------------------------------------------------------------------
# A suspended cloud workspace pays ~41 s of resume on the FIRST job that needs it (measured), and
# nothing in the queue announces that cost beforehand. prewarm-cloud.ps1 removes it by resuming a
# workspace while the journal shows the repos it serves are working; this verb is the agent-facing way
# in, so an agent does not have to know the script exists.
function Invoke-Prewarm {
  $tool = Join-Path $PSScriptRoot 'prewarm-cloud.ps1'
  if (-not (Test-Path -LiteralPath $tool)) { [Console]::Error.WriteLine("agentq prewarm: $tool is missing (install drift - ps/install.ps1 mirrors it)"); exit 2 }
  $named = @{}
  if ($Ws) { $named['Ws'] = "$Ws" }
  # No -Ws: name the repo we are in, so a bare `agentq prewarm` acts for this workspace instead of
  # falling back to the tool's own default repo.
  if (-not $Ws) { $here = Get-RepoInfo $Repo; if ($here) { $named['Repo'] = $here.Name } }
  if ($All) { $named['All'] = $true }
  if ($PrewarmReport) { $named['Report'] = $true }
  if ($PrewarmOff) { $named['Off'] = $true }
  if ($Quiet) { $named['Quiet'] = $true }
  $pairs = @{ ActivityMin = $ActivityMin; MaxResumesPerDay = $MaxResumesPerDay; WaitSec = $PrewarmWaitSec; MaxTickSec = $MaxTickSec; ReportDays = $ReportDays; VmState = $VmState; Gcloud = $GcloudExe; Root = $PrewarmRoot; ConfigPath = $PrewarmConfig; TickLog = $PrewarmTickLog }
  foreach ($k in @($pairs.Keys | Sort-Object)) { if ($null -ne $pairs[$k] -and "$($pairs[$k])" -ne '') { $named[$k] = "$($pairs[$k])" } }
  # In-process on purpose: this runs on a schedule where the common outcome is "nothing to do", so a
  # second pwsh start (~400 ms) would be most of the tick. Splatted as a HASHTABLE: an array splat is
  # positional, and `'-ActivityMin','42'` then binds "-ActivityMin" to the third parameter's int
  # (measured by test-agentq-prewarm-verb.ps1, which the array form failed).
  & $tool @named
  if ($LASTEXITCODE) { exit $LASTEXITCODE }
}

# Where a repo runs in the cloud, and whether that workspace is asleep. Read from agentq-config.json
# (cloudWorkspaces + cloudRegistry) rather than duplicated, so a moved workspace is moved once.
function Get-PrewarmConfig {
  if ($script:PrewarmCfg) { return $script:PrewarmCfg }
  $path = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $PSScriptRoot 'agentq-config.json' }
  $wsmap = @{}; $reg = @{}
  try {
    if (Test-Path -LiteralPath $path) {
      $c = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
      $m = $c.PSObject.Properties['cloudWorkspaces']
      if ($m -and $m.Value) { foreach ($x in $m.Value.PSObject.Properties) { $wsmap[$x.Name] = "$($x.Value)" } }
      $r = $c.PSObject.Properties['cloudRegistry']
      if ($r -and $r.Value) { foreach ($x in $r.Value.PSObject.Properties) { $reg[$x.Name] = @{ project = "$($x.Value.project)"; zone = "$($x.Value.zone)" } } }
    }
  } catch { }
  $script:PrewarmCfg = @{ workspaces = $wsmap; registry = $reg }
  $script:PrewarmCfg
}

# The state of one workspace, cached for five minutes. `since` is the first call of nearly every task,
# so an uncached describe would add a gcloud round-trip to all of them for a fact that changes on the
# order of minutes. The cache stores EPOCH SECONDS, not the ISO string: ConvertFrom-Json returns a
# [DateTime] whose printed form is culture-shaped, and comparing those silently failed once already
# (prewarm-cloud.ps1, 2026-11-25).
function Get-PrewarmVmStatus([string]$ws) {
  $cfg = Get-PrewarmConfig
  $reg = $cfg.registry[$ws]
  if (-not $reg) { return '' }
  $f = Join-Path (Join-Path $Root 'prewarm') "vmstate-$ws.json"
  $nowSec = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  # CACHE ONLY - never a live call. This function runs inside `agentq since`, `jobs` and `wait-job`, the
  # first commands of a task, and an unbounded `gcloud instances describe` there turns a hint into a hang:
  # measured 2026-11-25, one suite run took 6 minutes instead of 52 seconds because every hint call paid a
  # real gcloud. prewarm-cloud.ps1 -All rewrites this file for every workspace on each 20-minute tick, so
  # the worst case is a recommendation a later measure proves unnecessary - and `agentq prewarm` measures
  # again before it acts, so a stale SUSPENDED can only waste one command. Anything older than 30 minutes
  # is unknown, and unknown is silent: a hint that fires on the healthy path is noise, and noise is how
  # agents learn to skip a block of output.
  try {
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    $c = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json
    if ($null -eq $c.atSec) { return '' }
    if (($nowSec - [int64]$c.atSec) -gt 1800) { return '' }
    "$($c.status)"
  } catch { '' }
}

# One line, and only when the workspace is actually SUSPENDED. A hint that fires on the healthy path is
# noise, and noise is how agents learn to skip a section of the output.
function Show-PrewarmHint([string]$repoName) {
  if (-not $repoName) { return }
  $cfg = Get-PrewarmConfig
  $ws = "$($cfg.workspaces[$repoName])"
  if ($env:AGENTQ_PREWARM_DEBUG) { [Console]::Error.WriteLine("prewarm-hint: repo='$repoName' ws='$ws' cfgPath='$(if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $PSScriptRoot 'agentq-config.json' })' maps=$($cfg.workspaces.Count) regs=$($cfg.registry.Count) root='$Root'") }
  if (-not $ws) { return }
  if ((Get-PrewarmVmStatus $ws) -ne 'SUSPENDED') { return }
  Write-Output '== workspace'
  Write-Output "note: ws-$ws is SUSPENDED and $repoName runs there - the next cloud job pays ~41 s to resume it."
  Write-Output "      Warm it now (about 15 s, agentq does it for you): agentq prewarm -Ws $ws"
}

function Set-Mark {
  if (-not $Resource -or -not $State) { throw 'agentq mark -Resource <r> -State frozen|blocked|clear -Reason "..."' }
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  $f = Join-Path $MDir ((Safe $res) + '.json')
  if ($State -eq 'clear') {
    if (-not $Reason) { throw 'agentq mark -State clear needs -Reason (why it is safe again)' }
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    Write-Journal @{ event = 'unmark'; resource = $res; reason = $Reason }
    Write-Output "cleared $res"; return
  }
  if ($State -notin 'frozen', 'blocked') { throw '-State must be frozen, blocked or clear' }
  if (-not $Reason) { throw 'agentq mark needs -Reason (other agents will read it)' }
  $m = [ordered]@{ resource = $res; state = $State; reason = $Reason; session = $Session; at = (Iso (Now)) }
  [IO.File]::WriteAllText($f, ($m | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  Write-Journal @{ event = 'mark'; resource = $res; state = $State; reason = $Reason }
  Write-Output "$res marked $State"
}

function Invoke-Break {
  if (-not $Resource -or -not $Reason) { throw 'agentq break -Resource <r> [-Id <ticket>] -Reason "..."' }
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  $targets = @(Read-Tickets $res | Where-Object { -not $Id -or $_.id -eq $Id })
  # Without -Id, break only when the choice is unambiguous. "First ticket" once removed a live,
  # healthy holder instead of the STALE one next to it (2026-09-30).
  if (-not $Id -and $targets.Count -gt 1) {
    $list = ($targets | ForEach-Object { "$($_.id) $($_.session) '$($_.purpose)'" }) -join '; '
    [Console]::Error.WriteLine("agentq: $res has $($targets.Count) tickets - pass -Id <ticket>: $list")
    exit 2
  }
  if (-not $targets) { Write-Output "nothing to break on $res"; return }
  foreach ($t in $targets) {
    $alive = Test-Alive $t
    Remove-Ticket $t "$Reason$(if ($alive) { " (holder pid $($t.pid) was still ALIVE)" })" 'break'
    Write-Output "broke ticket $($t.id) on $res (held by $($t.session) '$($t.purpose)', alive=$alive)"
  }
}

# ---- workspaces (ADR 0007, DEVBOX D6): a project is ACTIVE in one place at a time --------------
# One record per workspace in <system store>/workspaces/<name>.json: holder user + host + purpose. take by
# the same user@host renews; a different holder is refused (exit 3) unless -Force -Reason (journaled, the
# previous holder is named). release by the holder (or -Force -Reason). The record is the arbiter devsync
# and the devbox consult before syncing; it says nothing about files, git stays the source of truth.
function Invoke-Workspace {
  $wd = Join-Path $SysRoot 'workspaces'
  if (-not (Test-Path -LiteralPath $wd)) { New-Item -ItemType Directory -Force $wd | Out-Null }
  $who = "$([Environment]::UserName)@$(if ($env:AGENTQ_CLIENT_HOST) { $env:AGENTQ_CLIENT_HOST } else { [Environment]::MachineName })"
  $sub = if ($Sub) { $Sub } else { 'list' }
  if ($sub -eq 'list') {
    $rows = @(Get-ChildItem -LiteralPath $wd -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json -DateKind String } catch { $null } } | Where-Object { $_ })
    if ($Json) { ConvertTo-Json -InputObject @($rows) -Depth 4; return }
    if (-not $rows) { Write-Output '== WORKSPACES: none active'; return }
    Write-Output '== WORKSPACES'
    $rows | Format-Table name, holder, purpose, since -AutoSize | Out-String -Width 200 | Write-Output
    return
  }
  if (-not $WsName -or $WsName -notmatch '^[a-z0-9][a-z0-9._-]{0,63}$') { throw "agentq workspace ${sub}: -Name <lowercase workspace name> is required" }
  $f = Join-Path $wd "$WsName.json"
  With-Mutex "workspace-$WsName" {
    $cur = if (Test-Path -LiteralPath $f) { try { Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -DateKind String } catch { $null } } else { $null }
    switch ($sub) {
      'take' {
        if ($cur -and $cur.holder -ne $who) {
          if (-not $Force -or -not $Reason -or $Reason.Length -lt 8) {
            [Console]::Error.WriteLine("agentq: workspace $WsName is ACTIVE at $($cur.holder) since $($cur.since) ('$($cur.purpose)'). Flush + release it there first, or -Force -Reason '<why>'.")
            exit 3
          }
          Write-Journal @{ event = 'workspace-steal'; resource = "workspace:$WsName"; from = $cur.holder; to = $who; reason = $Reason }
        }
        $rec = [ordered]@{ name = $WsName; holder = $who; purpose = $(if ($Purpose) { $Purpose } else { '' }); since = $(if ($cur -and $cur.holder -eq $who) { $cur.since } else { Iso (Now) }); renewed = (Iso (Now)); session = $Session }
        Write-JsonAtomic $f $rec
        if (-not $cur -or $cur.holder -ne $who) { Write-Journal @{ event = 'workspace-take'; resource = "workspace:$WsName"; holder = $who; purpose = $rec.purpose } }
        Write-Output "workspace $WsName active at $who"
      }
      'release' {
        if (-not $cur) { Write-Output "workspace $WsName was not active"; return }
        if ($cur.holder -ne $who -and -not ($Force -and $Reason -and $Reason.Length -ge 8)) {
          [Console]::Error.WriteLine("agentq: workspace $WsName is held by $($cur.holder), not $who (-Force -Reason '<why>' to release it anyway)"); exit 3
        }
        Remove-Item -LiteralPath $f -Force
        Write-Journal @{ event = 'workspace-release'; resource = "workspace:$WsName"; holder = $cur.holder; by = $who; reason = $(if ($Reason) { $Reason } else { '' }) }
        Write-Output "workspace $WsName released"
      }
      default { throw "agentq workspace: sub-verb must be take|release|list (got '$sub')" }
    }
  }
}

function Invoke-Acquire {
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  if (-not $Purpose) { throw 'agentq acquire: -Purpose is required' }
  Assert-NotMarked $res
  $t = New-Ticket $res $Purpose "$($Rest -join ' ')" ($repo.Top)
  Write-Journal @{ event = 'queued'; resource = $res; ticket = $t.id; purpose = $Purpose }
  if ($NoWait) {
    $live = @(Get-Live $res)
    if ([array]::IndexOf(@($live | ForEach-Object id), $t.id) -ge (Get-Capacity $res)) {
      Remove-Ticket $t 'busy (-NoWait)' 'giveup'
      [Console]::Error.WriteLine("agentq: $res is busy (-NoWait gave up at once).")
      [Console]::Error.WriteLine("  next: drop -NoWait to queue, or agentq eval -Resource '$res' -Purpose '<what you want to do>' for a verdict + the exact command.")
      exit 3
    }
  } else { Wait-Turn $t $TimeoutMin $null }
  Write-Journal @{ event = 'start'; resource = $res; tickets = @($t.id); purpose = $Purpose }
  Write-Output $t.id
}

function Invoke-Release {
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  $t = @(Read-Tickets $res | Where-Object { $_.id -eq $Id })
  foreach ($x in $t) { Remove-Item -LiteralPath $x.file, "$($x.file).hb" -Force -ErrorAction SilentlyContinue }
  Write-Journal @{ event = 'done'; resource = $res; ticket = $Id; exit = 0 }
}

. (Join-Path $PSScriptRoot 'agentq-v2.ps1')
# Directed agent-to-agent messages (ask/reply/inbox + the inbox notice below). Loaded unconditionally so the
# notice can run on any working verb, not only on the three message verbs.
. (Join-Path $PSScriptRoot 'agentq-msgs.ps1')
if (-not $script:ReadOnly -and $Verb.ToLowerInvariant() -notin 'renew', 'lease-check', 'prune', 'probe', 'slo', 'eval', 'feedback', 'who') { Renew-ForCwd }
# Session renewal only for verbs that mean "this agent is working"; maintenance verbs (sweep, break,
# unlease, metrics, rotate) from the same session must not keep a lease alive they are judging.
if ($Verb.ToLowerInvariant() -in 'run', 'commit', 'publish', 'land', 'note', 'acquire', 'release', 'bump', 'propose', 'lease', 'backup', 'since') { Renew-ForSession }
# A notice is consumed when shown, so a read-only verb leaves it for the next working call
# (`status` lists the losses of the last 24 h from the journal anyway).
if (-not $script:ReadOnly -and $Verb.ToLowerInvariant() -notin 'lease-check', 'inbox') { Show-LeaseNotices; Show-MessageNotices }

# Agent registry (S18-09, 2026-10-17). Every agentq call records WHO called: the session, the AI
# client (from env + the process ancestry), the app that owns the shell, the repo and the last
# purpose, in coord/agents/<session>.json. Readers (Vitals, the hub) join it with tickets and
# leases by `session`, so "this build belongs to that Copilot Chat in that VS Code window" is a
# lookup, not a guess. Hooks are the trust surface and not ours to edit; this path is.
function Get-AgentClient {
  if ($env:AGENTQ_CLIENT) { return $env:AGENTQ_CLIENT }
  if ($env:CLAUDECODE -or $env:CLAUDE_CODE_ENTRYPOINT) { return 'claude-code' }
  if ($env:CODEX_SANDBOX -or $env:CODEX_HOME -or $env:CODEX_MANAGED_BY_NPM) { return 'codex' }
  if ($env:CODAI_AGENT -or $env:CODAI_SESSION_ID) { return 'codai' }
  if ($env:COPILOT_AGENT -and $env:TERM_PROGRAM -eq 'vscode') { return 'vscode-copilot' }
  if ($env:COPILOT_AGENT -or $env:COPILOT_SESSION_ID) { return 'copilot-cli' }
  if ($env:TERM_PROGRAM -eq 'vscode') { return 'vscode' }
  $null
}
function Register-Agent {
  if ($env:AGENTQ_NO_REGISTRY -eq '1') { return }
  try {
    $dir = Join-Path $Root 'agents'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $f = Join-Path $dir ((Safe $Session) + '.json')
    # ancestry: shell = our parent; app = first ancestor that is a known AI host (<= 8 hops, ~20 ms each)
    $me = Get-Process -Id $PID -ErrorAction Stop
    $shell = $me.Parent; $app = $null; $p = $shell; $hops = 0
    $hosts = '^(Code - Insiders|Code|codai-desktop|copilot|copilot-runtime|claude|Claude|codex|Cursor|Windsurf|WindowsTerminal)$'
    while ($p -and $hops -lt 8) { if ($p.ProcessName -match $hosts) { $app = $p; break }; $p = $p.Parent; $hops++ }
    $prev = $null
    if (Test-Path -LiteralPath $f) { try { $prev = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable } catch {} }
    $repoName = try { (Get-RepoInfo $Repo).Name } catch { $null }
    $client = Get-AgentClient
    if (-not $client -and $app) { $client = switch -regex ($app.ProcessName) { '^codai' { 'codai' } '^copilot' { 'copilot-cli' } '^(claude|Claude)$' { 'claude-code' } '^codex$' { 'codex' } '^Code' { 'vscode' } default { $null } } }
    $rec = [ordered]@{
      v = 1; session = $Session; client = $client
      app = $(if ($app) { $app.ProcessName } else { $null }); appPid = $(if ($app) { $app.Id } else { $null })
      appStart = $(if ($app) { Iso $app.StartTime } else { $null })
      shellPid = $(if ($shell) { $shell.Id } else { $null }); shellStart = $(if ($shell) { Iso $shell.StartTime } else { $null })
      model = $(if ($env:COPILOT_MODEL) { $env:COPILOT_MODEL } elseif ($env:COPILOT_PROVIDER_WIRE_MODEL) { $env:COPILOT_PROVIDER_WIRE_MODEL } else { $null })
      cwd = (Get-Location).Path; repo = $repoName
      firstSeen = $(if ($prev -and $prev.firstSeen) { "$($prev.firstSeen)" } else { Iso (Now) }); lastSeen = Iso (Now)
      calls = $(if ($prev -and $prev.calls) { [int]$prev.calls + 1 } else { 1 })
      lastVerb = $Verb.ToLowerInvariant(); lastPurpose = $(if ($Purpose) { $Purpose } elseif ($prev) { $prev.lastPurpose } else { $null })
      host = [Environment]::MachineName; user = [Environment]::UserName
    }
    $tmp = "$f.$PID.tmp"
    [IO.File]::WriteAllText($tmp, ($rec | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)); Move-Item -Force -LiteralPath $tmp -Destination $f
  } catch {}
}
if (-not $script:ReadOnly -and $Verb.ToLowerInvariant() -notin 'since', 'help', 'prune', 'probe', 'slo', 'sweep', 'eval', 'feedback', 'who') { Register-Agent }

# ---- help: ONE source of truth for discovery ------------------------------------------------
# Every verb in the switch below MUST have an entry here (tests/test-agentq-help.ps1 asserts it by
# parsing both from this file). `agentq help` is the index an agent reads in one step; `agentq help
# <verb>` is the usage. This is why `run` is the only verb an agent needs to remember.
$script:AqHelp = [ordered]@{
  'run' = @{ g = 'Queue & run'; u = 'run -Resource <build|install|commit|deploy:<target>|slot:<repo>:<slot>|any name> -Purpose "why" [-- <cmd>] [-Lane interactive|quick|gate|heavy|batch] [-Priority -50..50] [-MinFreeGB 6] [-TimeoutMin n] [-Where local|cloud|auto] [-Ws <ws>] [-NoWait]'; d = 'queue for a resource, hold it, run the command, release; a cloud run also leaves runs/<jobid>.log and one row in the repo run journal (docs/RUNS.md or RUNS.md), idempotent by job id'; e = 'agentq run -Resource build -Purpose "typecheck" -- pnpm typecheck' }
  'acquire' = @{ g = 'Queue & run'; u = 'acquire -Resource R [-Purpose p] [-Capacity n] [-NoWait]'; d = 'low-level: take one ticket and print its id (scripting; `run` does this for you)' }
  'release' = @{ g = 'Queue & run'; u = 'release -Resource R -Id <ticket> [-Reason "..."]'; d = 'low-level: give back a ticket taken with `acquire`' }
  'status' = @{ g = 'Queue & run'; u = 'status [<repo>] [-All] [-Json]'; d = 'who holds what, waiters, stale, marks, leases, releases, load'; e = 'agentq status --json | ConvertFrom-Json' }
  'log' = @{ g = 'Queue & run'; u = 'log [-Last 30] [-All] [-Json]'; d = 'recent journal: queued/start/done/fail/break/mark/note/commit' }
  'since' = @{ g = 'Queue & run'; u = 'since [-Hours 12] [-Json]'; d = 'what changed in this repo: journal + git log' }
  'prewarm' = @{ g = 'Queue & run'; u = 'prewarm [-Ws <ws>] [-Repo <r>] [-All] [-ActivityMin n] [-MaxResumesPerDay n] [-MaxTickSec n] [-Report] [-ReportDays n] [-Off] [-Quiet]'; d = 'resume a suspended warm workspace BEFORE the job that needs it, so the ~41 s resume is not paid by the first cloud gate; only SUSPENDED acts, only while this repo is working, capped per workspace per day; -All ticks every workspace (one describe each, newest activity first), -MaxTickSec stops a tick that is over budget, -Report reads the journal and says what the wakes bought'; e = 'agentq prewarm -All   |   agentq prewarm -Report' }
  'note' = @{ g = 'Queue & run'; u = 'note -Message "..." [-Repo <r>]'; d = 'free-form journal entry: handoff, "do not touch X"' }
  'lesson' = @{ g = 'Queue & run'; u = 'lesson -Message "..." [-Repo <r>] [-Kind <class>]'; d = 'record a durable, reusable lesson (symptom -> what you believed -> what proved it -> the fix) so future agents in this repo do not relearn it'; e = 'agentq lesson -Message "vertex 400s on lone surrogates after JSON.stringify: strip them post-stringify"' }
  'lessons' = @{ g = 'Queue & run'; u = 'lessons [-Repo <r>] [-Limit 30] [-Json]'; d = 'list recorded lessons, newest first (read-only)' }
  'timings' = @{ g = 'Queue & run'; u = 'timings [-Limit 5] [-Json] [-LogDir <dir>] [-AllSlots] [-Top n]'; d = 'per-suite gate wall times, slowest LAST run first (read-only; it reads the gate build logs, so it costs ~18 s on codai). The default dir is the CURRENT repo''s .copilot-tmp\build-logs; a repo whose real logs live in a leased slot needs -LogDir or -AllSlots'; e = 'agentq timings -LogDir "E:\gh\.wt\codai\land\.copilot-tmp\build-logs" -Top 10' }
  'approve' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'approve -Paths a,b -Purpose "why" [-Hours 2] [-MaxMin 10] [-Json]'; d = 'ask the OWNER to approve an edit ticket: a window states exactly which paths it unlocks, and Approve mints it here (exit 0 approved, 3 denied, 4 recorded for the hub/phone with -MaxMin 0, 5 the mint failed, 7 no answer)'; e = 'agentq approve -Paths "packages/x/**" -Purpose "fix the guard"' }
  'ask' = @{ g = 'Queue & run'; u = 'ask -To <repo:<name>|session:<term-id>|slot:<repo>:<slot>|any|owner> -Message "..." [-Resource <r>] [-Repo <r>]'; d = 'ask another LIVE agent a question; prints how many agents the address reaches, and a negative answer is not silent'; e = 'agentq ask -To repo:agentq -Message "is ps/bin/agentq.ps1 free to edit for 20 min?"' }
  'reply' = @{ g = 'Queue & run'; u = 'reply -Id <msg id> -Message "..."'; d = 'answer an ask (the asker replying again reopens the thread)' }
  'inbox' = @{ g = 'Queue & run'; u = 'inbox [-All] [-Id <msg id>] [-Json]'; d = 'the open messages addressed to me (repo/session/slot/any); -Id prints the whole thread' }
  'bump' = @{ g = 'Fairness & overrides (v3)'; u = 'bump [-Id <ticket> | -Session <id>] -By 20 -Reason "..."'; d = 'raise a waiting ticket in the scheduler order (MY ticket by default; -Session/-Id name one explicitly; cap bumpMax)' }
  'burst' = @{ g = 'Fairness & overrides (v3)'; u = 'burst [-Resource build:machine] [-By 1] [-Minutes 30] -Reason "..."'; d = 'temporary extra slot, refused when RAM/commit headroom is under 2x the gate' }
  'propose' = @{ g = 'Fairness & overrides (v3)'; u = 'propose [-Reason "..."]'; d = 'diagnose my wait and APPLY safe remedies (break dead/STALE >2x, bump long waits, short burst)' }
  'metrics' = @{ g = 'Fairness & overrides (v3)'; u = 'metrics [-Hours 24] [-Json]'; d = 'wait/hold p50/p90 per resource x lane x kind' }
  'probe' = @{ g = 'Fairness & overrides (v3)'; u = 'probe [-Force] [-Json]'; d = 'take a load sample now (start latency + seconds since input) -> == LOAD / == AGENTS'; e = 'agentq probe -Force' }
  'rotate' = @{ g = 'Fairness & overrides (v3)'; u = 'rotate'; d = 'archive the journal now (sweep does it above journalRotateMB)' }
  'commit' = @{ g = 'Commit'; u = 'commit -Purpose "why" -Message "type(scope): msg" -Paths a,b [-NoPush]'; d = 'add+commit ONLY those paths under commit:<repo>, trailers, fetch+merge+push with retry' }
  'mark' = @{ g = 'Marks'; u = 'mark -Resource R -State frozen|blocked|clear -Reason "..."'; d = 'freeze/block a resource: run and acquire refuse it and print the reason'; e = 'agentq mark -Resource deploy:codai:gateway -State frozen -Reason "incident: 500s since 08:12Z"' }
  'break' = @{ g = 'Marks'; u = 'break -Resource R [-Id <ticket>] -Reason "..."'; d = 'remove a stale/stuck/dead ticket (never a live, healthy holder)' }
  'lease' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'lease -Purpose "why" [-Slot task-2|scratch-1|release] [-Branch b] [-Ref r] [-Wait [-MaxMin n]] [-Hold [-HoldMin n]]'; d = 'take a worktree slot; prints the path (exit 0). -Wait polls, exit 7 = bound expired, 3 = frozen'; e = 'agentq lease -Purpose "long task" -Wait -MaxMin 5' }
  'claim' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'claim -LeaseId <id> -Claims "apps/x/**,packages/y/**"'; d = 'declare the paths my lease owns (advisory; replaces the list)' }
  'unlease' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'unlease -Repo <slot dir> [-Slot <slot>] -LeaseId <id> [-Reason "..."] [-Force -Reason "..."]'; d = 'give the slot back (backs up anything unpushed first); a foreign break while the holder chat is live needs -Force' }
  'renew' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'renew [-LeaseId <id>] [-Repo <r>]'; d = 'refresh my lease heartbeat (a long job OUTSIDE the slot needs -Hold)' }
  'recover' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'recover [-Repo r] [-Slot s] [-Ref <ref|sha|slot/stamp>] [-To <my slot path>] [-Apply]'; d = 'list the backups taken before a slot was reset / restore one; a take-over also notifies the previous holder'; e = 'agentq recover -Repo codai -Slot task-3' }
  'sweep' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'sweep [-WhatIf] [-Json]'; d = 'reap dead/stale tickets and leases, rotate the journal, prune state' }
  'who' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'who [<repo>] [-Json]'; d = 'one line per lease: is this slot really in use, by whom, is the holder alive' }
  'eval' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'eval -Resource <build:repo|install:repo|commit:repo|deploy:repo:target|slot:repo:slot> [-Sample] [-Json]'; d = 'instant verdict on preemption: PREEMPT-OK | WAIT | NEVER + the exact command to run'; e = 'agentq eval -Resource build:codai' }
  'feedback' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'feedback -Kind note|idea|bug|anomaly|praise -Message "..."'; d = 'tell the owner what worked or broke (journaled, shown on the hub)' }
  'lease-check' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'lease-check [-Json]'; d = 'diagnose my own lease binding (chat/session -> slot, liveness clock, work clock)' }
  'backup' = @{ g = 'Slots & leases (ADR 0001/0012)'; u = 'backup -Path <worktree> [-Slot <name>] -Reason "..."'; d = 'proof-of-work snapshot of a slot -> refs/backup/... plus a bundle' }
  'land' = @{ g = 'Land & release (ADR 0001)'; u = 'land -Branch <topic> -Onto <dev|main> -Purpose "why" [-Gate "<cmd>"] [-Also a,b] [-Force] [-RebaseOnConflict]'; d = 'land my branch: pre-gate the rebased result (my slot, or a scratch slot when started from the shared clone), then serialized merge+push (exit 5 conflict, 6 pre-gate)'; e = 'agentq land -Branch feat/x -Onto main -Purpose "ship" -Gate "pnpm typecheck"' }
  'publish' = @{ g = 'Land & release (ADR 0001)'; u = 'publish -Paths a,b -Message "type(scope): msg" -Purpose "why" [-Onto main] [-Base <ref>] [-Land] [-NoPush]'; d = 'commit my paths and, with -Land, land them in one step' }
  'release-begin' = @{ g = 'Land & release (ADR 0001)'; u = 'release-begin -Repo <r> -Target <t> -Sha <sha> [-Ref r] [-Follow branch] [-OwnerPid n]'; d = 'deploy-clean opens a release run (supersede-aware; see ADR 0001)' }
  'release-phase' = @{ g = 'Land & release (ADR 0001)'; u = 'release-phase -Phase <name> [-Unsafe]'; d = 'checkpoint of a release; a landing during a SAFE phase makes the next one exit 4 superseded' }
  'release-end' = @{ g = 'Land & release (ADR 0001)'; u = 'release-end -State done|failed|superseded'; d = 'close the release run' }
  'release-cancel' = @{ g = 'Land & release (ADR 0001)'; u = 'release-cancel -Target <t> -Reason "..."'; d = 'abandon a release record, with a reason' }
  'notify-landing' = @{ g = 'Land & release (ADR 0001)'; u = 'notify-landing -Repo <r> -Branch <b> [-Sha <sha>] [-Target <t>]'; d = 'tell running releases that a commit landed (called by commit/land)' }
  'workspace' = @{ g = 'Cloud workspaces (devcloud F2)'; u = 'workspace take|release|list -Name <ws>'; d = 'register or look up a warm cloud workspace used by run -Where cloud' }
  'prune' = @{ g = 'Health (ADR 0003/0006/0009)'; u = 'prune [-WhatIf] [-Days n] [-All] [-Json]'; d = 'remove state nobody needs any more (sweep runs it too)' }
  'doctor' = @{ g = 'Health (ADR 0003/0006/0009)'; u = 'doctor [-All] [-Src <checkout>/ps] [-Json] [-Only <check[,check]>] [-Quiet]'; d = 'health report read-only; exit 1 when a check fails. -Only runs just those checks (an unknown name exits 2 and prints the valid list), -Quiet prints the findings only. checks: stale-index-lock, empty-package-store, install-drift, config-drift, install-proof, stale-install, dead-owner, lease-hygiene, dead-keeper, marks, machine-memory, state-size, scheduled-tasks, git-autosync, daemons, cloud-lanes'; e = 'agentq doctor -Only cloud-lanes,install-drift -Quiet' }
  'slo' = @{ g = 'Health (ADR 0003/0006/0009)'; u = 'slo [-Hours 168] [-Json] [-Track]'; d = 'queue time, waits over 10 min, hook cost per day, slots lost with a live chat' }
  'scale' = @{ g = 'Health (ADR 0003/0006/0009)'; u = 'scale [-Json]'; d = 'why N/N is not a small pool: the machine-wide slot room, its formula and the live numbers'; e = 'agentq scale' }
  'flakes' = @{ g = 'Health (ADR 0003/0006/0009)'; u = 'flakes [-Id <test key or substring> -Reason "why"]'; d = 'quarantine report; -Id lifts a quarantine' }
  'store' = @{ g = 'Health (ADR 0003/0006/0009)'; u = 'store [-State status|sync|query|rebuild] [-Id <event>] [-Repo <name>] [-Hours N]'; d = 'SQLite index of the journal + job registry (the JSONL stays the source of truth)' }
  # 2026-11-28: the tracking/resume verbs. Each is a ONE-LINE pass-through to tools/track.mjs, the single
  # implementation of the tracking store (the module resolves it as <root>\tools\track.mjs and never
  # reimplements a query), so `agentq trackers` prints the same bytes and returns the same exit code as
  # `node tools/track.mjs status`. Arguments arrive after `--`, the only channel this parser leaves alone.
  'trackers' = @{ g = 'Tracking'; u = 'trackers [push [-Hub <url>] [-KeyFile <path>] [-DryRun] [-Repo <name>]] [-- --json]'; d = 'tracker index: repo/item counts and drift (tools/track.mjs status); push uploads it to the Codwen hub'; e = 'agentq trackers -- --json  |  agentq trackers push -DryRun' }
  'plan' = @{ g = 'Tracking'; u = 'plan -- set|show [--session <id>] [--goal s] [--json]'; d = 'the per-session plan record: goal, done means, next step, roster, jobs, todos'; e = 'agentq plan -- show --session $env:AGENTQ_SESSION' }
  'task' = @{ g = 'Tracking'; u = 'task -- add|claim|next|block|done|show|list [flags]'; d = 'a claimable task; claim is atomic across agents, next skips open dependencies'; e = 'agentq task -- list --json' }
  'help' = @{ g = 'Help'; u = 'help [<verb>]'; d = 'this index, or one verb''s usage and an example'; e = 'agentq help land' }
}
function Show-AgentqHelp([string]$For) {
  if ($For) {
    if ($script:AqHelp.Contains($For)) {
      $h = $script:AqHelp[$For]
      Write-Output "agentq $For - $($h.d)"
      Write-Output ''
      Write-Output "  usage:   agentq $($h.u)"
      if ($h.ContainsKey('e')) { Write-Output "  example: $($h.e)" }
      return
    }
    [Console]::Error.WriteLine("agentq: no verb '$For'")
  }
  Write-Output 'agentq - cross-agent coordination: builds, installs, commits, deploys, worktree slots.'
  Write-Output "  One verb to remember: run. Everything else: agentq help <verb>   (config: agentq-config.json)"
  $last = ''
  foreach ($k in $script:AqHelp.Keys) {
    $h = $script:AqHelp[$k]
    if ($h.g -ne $last) { Write-Output ''; Write-Output "== $($h.g)"; $last = $h.g }
    Write-Output ("  {0,-15} {1}" -f $k, $h.d)
  }
  Write-Output ''
  Write-Output 'READ-ONLY (never queue, never reap): status log since who metrics slo scale flakes doctor probe eval'
  Write-Output 'EXIT: 0 ok | 2 usage | 3 frozen/blocked/timeout | 4 release superseded | 5 land conflict | 6 land pre-gate | 7 lease -Wait bound expired'
  Write-Output 'DESIGN: 4 ADRs in docs/adr (0001 slots/leases/land, 0002 v3 scheduler, 0007 system store, 0009 orchestrator)'
}

switch ($Verb.ToLowerInvariant()) {
  # Agent-facing discovery mirror of $AqHelp. Keep the two in step (test-agentq-help.ps1 asserts it).
  'help' { Show-AgentqHelp $Sub; if ($Sub -and -not $script:AqHelp.Contains($Sub)) { exit 2 }; exit 0 }
  'run' { Invoke-Run }
  'commit' { Invoke-Commit }
  'status' { Show-Status }
  'log' { Show-Log }
  'since' { Show-Since }
  'mark' { Set-Mark }
  'break' { Invoke-Break }
  'note' {
    if (-not $Message) { throw 'agentq note -Message "..."' }
    $repo = Get-RepoInfo $Repo
    Write-Journal @{ event = 'note'; resource = $(if ($repo) { "note:$($repo.Name)" } else { 'note' }); message = $Message; repo = $(if ($repo) { $repo.Name } else { '' }) }
    Write-Output 'noted'
  }
  # A durable lesson any future agent can read back (`agentq lessons`). Another journal event next to
  # `note`, so it inherits the hash chain and the hub mirror for free; -Kind is an optional free class
  # (it reuses the parser's existing 'kind' slot - feedback and a lesson never run in the same process).
  'lesson' {
    if (-not $Message) { throw 'agentq lesson -Message "..."' }
    $rawRepo = $Repo   # $repo/$Repo are ONE slot (PowerShell is case-insensitive); capture before Get-RepoInfo
    $repo = Get-RepoInfo $rawRepo
    # -Repo may be a path (resolved to its repo name) or a bare repo name; use the name literally then.
    $repoName = if ($repo) { $repo.Name } elseif ($rawRepo) { "$rawRepo".ToLowerInvariant() } else { '' }
    $entry = @{ event = 'lesson'; resource = $(if ($repoName) { "lesson:$repoName" } else { 'lesson' }); message = $Message; repo = $repoName }
    if ($FbKind) { $entry.kind = $FbKind }
    Write-Journal $entry
    Write-Output 'lesson recorded'
  }
  'lessons' {
    $rawRepo = $Repo
    $repo = Get-RepoInfo $rawRepo
    $name = if ($repo) { $repo.Name } elseif ($rawRepo) { "$rawRepo".ToLowerInvariant() } else { $null }
    # Read a generous window so the event filter sees enough lessons, keep the newest -Limit ($Last), then
    # reverse so the newest prints first (the help text promises "newest first"; the file order is oldest).
    $items = @(Read-Journal ([math]::Max($Last * 10, 400)) $null $name | Where-Object { (JProp $_ 'event') -eq 'lesson' } | Select-Object -Last $Last)
    [array]::Reverse($items)
    if ($Json) { $items | ConvertTo-Json -Depth 5 }
    elseif (-not $items) { Write-Output '(no lessons)' }
    else { $items | ForEach-Object { Format-Entry $_ } }
  }
  # The per-suite gate wall times, read back from the gate build logs (bin\agentq-timings.ps1). NOT called
  # from `status`: reading codai's ~2400 logs costs 18 s, and `status` is on the hot path of every agent
  # turn. Read-only - it only reads logs, which is why 'timings' is in $script:ReadOnly above.
  'timings' {
    $t = Join-Path $PSScriptRoot 'agentq-timings.ps1'
    if (-not (Test-Path -LiteralPath $t)) { throw "agentq timings: missing module $t" }
    $n = if ($Last -is [int] -and $Last -gt 0) { $Last } else { 5 }
    $argv = @('-NoProfile', '-File', $t, '-Last', "$n")
    if ($Json) { $argv += '-Json' }
    if ($TimingsExtra.Count) { $argv += $TimingsExtra }
    $out = @(& pwsh @argv 2>&1)
    $code = $LASTEXITCODE
    $out | ForEach-Object { Write-Output "$_" }
    if ($code -eq 3) { Write-Output 'agentq timings: nothing recorded yet (no gate log has been read back)' }
    elseif ($code -ne 0) { throw "agentq timings: exit $code" }
  }
  # Trust-surface work. An agent CANNOT mint an edit ticket itself: `rules-ticket.ps1 -Issue` refuses a
  # redirected console, which is the point. So this asks the OWNER in a window, and the WINDOW mints it -
  # it is the only process in the chain that owns a real console (bin\agentq-approve.ps1).
  'approve' {
    $a = Join-Path $PSScriptRoot 'agentq-approve.ps1'
    if (-not (Test-Path -LiteralPath $a)) { throw "agentq approve: missing module $a" }
    if (-not @($Paths).Count) { [Console]::Error.WriteLine('agentq approve: -Paths a,b is required (the exact paths the ticket must authorise)'); exit 2 }
    $argv = @('-NoProfile', '-File', $a, '-Paths', ($Paths -join ','))
    if ($Purpose) { $argv += @('-Purpose', "$Purpose") }
    if ($MaxMinGiven) { $argv += @('-MaxMin', "$MaxMin") }
    # $Hours defaults to 12 in THIS file (the `since -Hours 12` default) while a ticket lives at most
    # 2 h, so only an explicitly LOWER value is forwarded - otherwise the clamp would warn on every call.
    if ($Hours -lt 12) { $argv += @('-Hours', "$Hours") }
    if ($Json) { $argv += '-Json' }
    & pwsh @argv
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
  }
  # A directed channel between agents (agentq-msgs.ps1). Next to `note`, which has no addressee, no answer
  # and no notification: an agent that needs a decision from the agent next door asks instead of guessing.
  'ask' { Invoke-Ask }
  'reply' { Invoke-Reply }
  'inbox' { Show-Inbox }
  'acquire' { Invoke-Acquire }
  'release' { Invoke-Release }
  'workspace' { Invoke-Workspace }
  'bump' { Invoke-Bump }
  'burst' { Invoke-Burst }
  'propose' { Invoke-Propose }
  'metrics' { Show-Metrics }
  'rotate' { Invoke-RotateJournal -Force }
  # OQ-004: take a load sample now (the sync loop calls this path once a minute) and print the verdict.
  'probe' {
    $a = Get-AdmissionConfig
    $p = Invoke-LoadProbe $Root $(if ($Force) { 0 } else { [double]$a.everySec }) 12 $(if ($env:AGENTQ_PROBE_SRC) { $env:AGENTQ_PROBE_SRC } else { 'agentq' })
    $v = Get-LoadVerdict $p ([double]$a.probeMs) ([int]$a.window) ([double]$a.staleSec)
    $idle = if ($p) { $p['idleSec'] } else { $null }
    if ($Json) { [ordered]@{ probeMs = $v.last; medianMs = $v.median; samples = $v.n; ageSec = $v.ageSec; thresholdMs = $v.thresholdMs; saturated = [bool]$v.saturated; inputIdleSec = $idle } | ConvertTo-Json -Compress }
    else { Write-Output ("start probe {0} ms; median of last {1}: {2} ms; limit {3} ms; {4}; input idle {5}" -f $v.last, $v.n, $v.median, $v.thresholdMs, $(if ($v.saturated) { 'SATURATED' } else { 'ok' }), $(if ($null -ne $idle) { "$idle s" } else { 'unknown' })) }
  }
  'prewarm' { Invoke-Prewarm }
  'lease' { Invoke-Lease }
  'claim' { Invoke-Claim }
  'unlease' { Invoke-Unlease }
  'renew' { Invoke-Renew }
  'recover' { Invoke-Recover }
  'sweep' { Invoke-Sweep }
  'who' { Invoke-Who }
  'eval' { Invoke-Eval }
  'feedback' { Invoke-Feedback }
  'lease-check' { Invoke-LeaseCheck }
  'backup' { Invoke-Backup }
  'release-begin' { Invoke-ReleaseBegin }
  'release-phase' { Invoke-ReleasePhase }
  'release-end' { Invoke-ReleaseEnd }
  'release-cancel' { Invoke-ReleaseCancel }
  'notify-landing' { Invoke-NotifyLanding }
  'land' { Invoke-Land; exit $script:LandExit }
  'publish' { Invoke-Publish; if ($DoLand) { exit $script:LandExit } }
  # ADR 0009 stage 0 (OQ-006, OQ-011): state pruning and a health report, each in its own file.
  'prune' { . (Join-Path $PSScriptRoot 'agentq-prune.ps1'); Invoke-Prune }
  'doctor' { . (Join-Path $PSScriptRoot 'agentq-doctor.ps1'); Invoke-Doctor; exit $script:DoctorExit }
  # ADR 0003 W4-4: SLO report from the journal (ready->landed p90, flake rate, lost work, queue waits, bypass).
  'flakes' { Invoke-FlakesVerb }
  'slo' {
    $sa = @((Join-Path $PSScriptRoot 'agentq-slo.mjs'), '--journal', $Journal, '--days', "$([math]::Max(1, [math]::Round($Hours / 24)))")
    if (-not $env:AGENTQ_NO_STORE) { $sa += @('--store', $Root) }
    # default path is unchanged (pass-through, --json only when asked)
    if (-not $Track) { if ($Json) { $sa += '--json' }; & node @sa; exit $LASTEXITCODE }
    # --track (idea 6): compute the metric, journal `slo-alert` when slotsLostLiveChat moved, and remember it.
    # The alert SINK (hub tile / mail) lives outside this repo; this is the in-repo signal.
    $sa += '--json'
    $slOut = @(& node @sa 2>&1 | ForEach-Object { "$_" }); $slCode = $LASTEXITCODE
    try {
      $now = [int]((($slOut -join "`n") | ConvertFrom-Json).slo.slotsLostLiveChat.value)
      $sf = Join-Path $Root 'slo-state.json'
      $prev = $null
      if (Test-Path -LiteralPath $sf) { try { $prev = [int]((Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json).slotsLostLiveChat) } catch {} }
      if ($null -ne $prev -and $now -gt $prev) {
        Write-Journal @{ event = 'slo-alert'; resource = 'slo'; metric = 'slotsLostLiveChat'; prev = $prev; now = $now; reason = "slots lost with a live chat increased ($prev -> $now), target = 0" }
        [Console]::Error.WriteLine("agentq: SLO ALERT slotsLostLiveChat $prev -> $now (target 0) - a slot was taken from a live chat")
      }
      if ($null -eq $prev -or $now -ne $prev) { [IO.File]::WriteAllText($sf, (@{ slotsLostLiveChat = $now; at = (Iso (Now)) } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)) }
    } catch { [Console]::Error.WriteLine("agentq: slo --track could not read the metric: $($_.Exception.Message)") }
    $slOut | ForEach-Object { Write-Output $_ }
    exit $slCode
  }
  # Item #10 (2026-11-26): the pool an agent reads as "N/N, too small" is DERIVED from the machine and
  # measured live. One step to see the formula and the numbers, instead of asking for more slots.
  'scale' { Show-Scale; exit 0 }
  # ADR 0006: SQLite index of the journal + job registry (rebuildable; JSONL stays the source of truth).
    # agentq store [-State status|sync|query|rebuild] [-Id <event>] [-Repo <name>] [-Hours N]
    'store' { $sub = if ($State) { "$State" } else { 'status' }; $sa = @((Join-Path $PSScriptRoot 'agentq-store.mjs'), $sub, '--home', $Root); if ($Id) { $sa += @('--event', $Id) }; if ($Repo) { $sa += @('--repo', (Split-Path -Leaf $Repo)) }; if ($sub -eq 'query') { $sa += @('--hours', "$Hours") }; & node @sa; exit $LASTEXITCODE }
  # THREE explicit cases, not one `{ $_ -in 'trackers','plan','task' }` clause: test-agentq-help.ps1 parses
  # this switch for `'<name>' {` and refuses a help key with no matching case (a verb an agent can read
  # about but not run), so a shared clause would leave all three checking as orphans.
  'trackers' { . (Join-Path $PSScriptRoot 'agentq-trackers.ps1'); Invoke-AgentqTrackerVerb -Verb 'trackers' -Arguments $Rest; exit $script:AgentqTrackExit }
  'plan' { . (Join-Path $PSScriptRoot 'agentq-trackers.ps1'); Invoke-AgentqTrackerVerb -Verb 'plan' -Arguments $Rest; exit $script:AgentqTrackExit }
  'task' { . (Join-Path $PSScriptRoot 'agentq-trackers.ps1'); Invoke-AgentqTrackerVerb -Verb 'task' -Arguments $Rest; exit $script:AgentqTrackExit }
    # An unknown verb is an agent guessing. Teach it instead of dumping the 148-line header and exiting
    # 2 with no hint (the `land` 7-turn waste, 2026-11-20). Same content, one screen, exit 2 = usage.
    default {
      [Console]::Error.WriteLine("agentq: unknown verb '$Verb'")
      [Console]::Error.WriteLine("  next: agentq help            (every verb, one line each)")
      [Console]::Error.WriteLine("        agentq help <verb>     (usage + example for one verb; e.g. agentq help land)")
      Write-Output ''
      Show-AgentqHelp
      exit 2
    }
}
