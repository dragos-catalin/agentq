<#
  Install the ps/ tooling into ~/.copilot (the live location every hook and agent uses).
  Runs every test suite against THIS checkout first; refuses to install on red. Keeps a timestamped
  backup of each file it replaces in ~/.copilot/.backup/<ts>/. -Check = report drift only.

  -Suites a,b   run only these suites (names from tests/run-all.ps1 -List) instead of all of them:
                the full set takes hours on a busy workstation, so a small fix is gated by the suites
                that cover it. -SkipTests installs without any gate (say why in the commit / tracker).
  -RepoSuites   run the repo's persisted gate list instead (bin/agentq-config.json -> gateSuites.<repo>),
                the SAME list `landGate.<repo>` runs, so "the suites I usually run" lives in one place
                and cannot drift from what the land gate checks. -Suites and -RepoSuites are exclusive.
                The list is resolved by tests/run-all.ps1 (one implementation); a missing key refuses.
  -Parallel n   suites to run at once (default 4; 1 = the old one-after-another order). Measured on the
                2026-11-20 set: 8 suites 416 s serial -> 185 s at -Parallel 8. Suites that must own the
                machine (install, term interrupt, reap terminals, git-autosync, guard cloud) still run
                alone; everything else is safe to overlap because each suite uses its own temp home.
  -Full         run the whole suite even when the green record says this exact ps/ tree already passed.
  -Foreground   run the gate in THIS console instead of as a background job (see below).
                The GATE RUNS AS A REGISTERED BACKGROUND JOB (bin/run-tests-job.ps1): the idle-terminal
                reaper closed the calling terminal mid-gate on 2026-11-21 - 24 of 45 suites green, then
                silence, a free shell, and nothing installed. "The shell is free again" is not evidence
                the gate finished. A job gets its own hidden console (job-start.ps1), so nothing can reap
                it; the caller still sees a live log and the REAL exit code. A STALL or a wait-cap timeout
                is refused with its own message, never dressed up as "tests are red".
                -Foreground (or AGENTQ_INSTALL_FOREGROUND=1) restores the old in-console stream.
  The gate is skipped ONLY when a full green run recorded the SAME content hash (run-all.ps1 -LastGreen)
  and that run is under 24 h old: the suites run a function of ps/, so an unchanged tree needs no repeat.
  The decision and both hashes are printed - nothing is skipped silently.
  agentq-config.json is MERGED, never replaced: keys the installed copy already has keep their local
  value (slot counts, workspaces), new keys are added from the checkout (2026-10-19, twice: an install
  silently shrank the live slot caps).
  bin/agentq-install.json records what was installed (source dir, commit, SHA-256 per file);
  `agentq doctor` compares the live files against it.
  AGENTQ_INSTALL_DIR overrides the destination (tests).
#>
param([switch]$Check, [switch]$SkipTests, [switch]$Full, [string[]]$Suites, [switch]$RepoSuites, [int]$Parallel = 4, [switch]$Foreground)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$cfgKey = 'bin\agentq-config.json'
$map = [ordered]@{
  'bin\agentq.ps1' = 'bin\agentq.ps1'; 'bin\agentq-v2.ps1' = 'bin\agentq-v2.ps1'; 'bin\agentq-config.json' = 'bin\agentq-config.json'
    # 2026-11-25: ask/reply/inbox - the directed agent-to-agent channel (dot-sourced by agentq.ps1, so a
    # missing copy here makes every `agentq ask` fail in the installed tree while the checkout looks fine).
    'bin\agentq-msgs.ps1' = 'bin\agentq-msgs.ps1'
    'tests\test-agentq-msgs.ps1' = 'bin\test-agentq-msgs.ps1'
  'bin\worktree.ps1' = 'bin\worktree.ps1'; 'bin\worktree-prune-task.ps1' = 'bin\worktree-prune-task.ps1'; 'bin\agentq-sync.ps1' = 'bin\agentq-sync.ps1'
  'hooks\deploy-clean.ps1' = 'hooks\deploy-clean.ps1'; 'hooks\run-build.ps1' = 'hooks\run-build.ps1'; 'hooks\guard-tooluse.ps1' = 'hooks\guard-tooluse.ps1'; 'hooks\guard-dev-vm.ps1' = 'hooks\guard-dev-vm.ps1'; 'tests\test-dev-vm-guard.ps1' = 'hooks\test-dev-vm-guard.ps1'
  'tests\test-agentq.ps1' = 'bin\test-agentq.ps1'; 'tests\test-agentq-v2.ps1' = 'bin\test-agentq-v2.ps1'; 'tests\test-agentq-v3.ps1' = 'bin\test-agentq-v3.ps1'
  'tests\test-worktree-v2.ps1' = 'hooks\test-worktree-v2.ps1'; 'tests\test-guard-v2.ps1' = 'hooks\test-guard-v2.ps1'
  # 2026-11-25: a formatter may never run with its own DEFAULT config over a repo that has no config
  'tests\test-guard-format.ps1' = 'hooks\test-guard-format.ps1'
  # 2026-11-26: registered in run-all.ps1 in the same slice - a suite that is mapped but unregistered (or the
  # reverse) is 'runnable by hand and by nothing else', which is how three guard holes and the stale-ref
  # pre-gate bug shipped green. 'install wiring' pins the two lists together.
  'tests\test-guard.ps1' = 'hooks\test-guard.ps1'
  'tests\test-deploy-guard.ps1' = 'hooks\test-deploy-guard.ps1'
  # 2026-11-25: the formatter taxonomy BOTH hooks use. Without this entry the guard fell back to its
  # stub functions (Test-FormatterConfigured -> $false) and the rule was inert in production while its
  # suite was green in the checkout - "configured" is not "installed".
  'hooks\lib\FormatterConfig.ps1' = 'hooks\lib\FormatterConfig.ps1'
  # 2026-11-25: the other half of the rule - a file CREATED into a repo that owns formatter settings is
  # formatted FOR the agent (PostToolUse), instead of the agent being refused later.
  'hooks\post-create-format.ps1' = 'hooks\post-create-format.ps1'
  'tests\test-land-changelog.ps1' = 'bin\test-land-changelog.ps1'
  'bin\repo-migrate.ps1' = 'bin\repo-migrate.ps1'; 'tests\test-repo-migrate.ps1' = 'bin\test-repo-migrate.ps1'
  # background jobs: bounded wait + registry (mirrored by agentq-sync)
  'bin\agentq-jobs-lib.ps1' = 'bin\agentq-jobs-lib.ps1'; 'bin\wait-job.ps1' = 'bin\wait-job.ps1'; 'bin\job-start.ps1' = 'bin\job-start.ps1'
  'bin\job-run.ps1' = 'bin\job-run.ps1'; 'bin\jobs.ps1' = 'bin\jobs.ps1'; 'tests\test-jobs.ps1' = 'bin\test-jobs.ps1'
  # devcloud F2: cloud placement client + its tests
  # shared-clone fast-forward + park (scheduled task git-autosync)
  'bin\git-autosync.ps1' = 'bin\git-autosync.ps1'; 'tests\test-git-autosync.ps1' = 'bin\test-git-autosync.ps1'; 'tests\test-guard-shared.ps1' = 'hooks\test-guard-shared.ps1'; 'tests\test-autosync-wip-snapshot.ps1' = 'bin\test-autosync-wip-snapshot.ps1'
  'bin\agentq-cloud.ps1' = 'bin\agentq-cloud.ps1'; 'tests\test-agentq-cloud.ps1' = 'bin\test-agentq-cloud.ps1'; 'tests\test-guard-cloud.ps1' = 'hooks\test-guard-cloud.ps1'
  # Bounded prewarm of a suspended workspace before an agent needs it (see prewarm-cloud.ps1).
  'bin\prewarm-cloud.ps1' = 'bin\prewarm-cloud.ps1'; 'tests\test-prewarm-cloud.ps1' = 'bin\test-prewarm-cloud.ps1'
  # 2026-11-25: the verb/-All/hint suite was missing here AND in run-all.ps1, so the install gate could not
  # run it even though the installed tree is where the hint must work. Paired with the run-all.ps1 entries
  # in this same slice - 'install wiring' pins the two.
  'tests\test-agentq-prewarm-verb.ps1' = 'bin\test-agentq-prewarm-verb.ps1'
  # S18-08/09 (vitals ADR-0038): orphan terminal reaper, adaptive machine cap + agent registry tests
  'bin\reap-terminals.ps1' = 'bin\reap-terminals.ps1'; 'tests\test-agentq-adaptive.ps1' = 'bin\test-agentq-adaptive.ps1'
  # 2026-10-18: VS Code chat-terminal associations, so the reaper never interrupts an agent
  'bin\vscode-chat-terminals.mjs' = 'bin\vscode-chat-terminals.mjs'; 'tests\test-reap-terminals.ps1' = 'bin\test-reap-terminals.ps1'
  # ADR 0003 wave 1: publish, lease activity + notices + slot prep, PowerShell entry hardening
  'tests\test-agentq-publish.ps1' = 'bin\test-agentq-publish.ps1'; 'tests\test-agentq-lease3.ps1' = 'bin\test-agentq-lease3.ps1'; 'tests\test-agentq-args.ps1' = 'bin\test-agentq-args.ps1'
  # 2026-11-20: `agentq help` + the unknown-verb/flag teaching (the suite is drift-locked against the script)
  'tests\test-agentq-help.ps1' = 'bin\test-agentq-help.ps1'
  # 2026-11-26: `agentq lesson`/`lessons` (durable agent lessons) - verb inside agentq.ps1, suite beside it
  'tests\test-agentq-lessons.ps1' = 'bin\test-agentq-lessons.ps1'
  # ADR 0003 W2-4 job objects + W4-4 SLO report
  'bin\agentq-jobobject-lib.ps1' = 'bin\agentq-jobobject-lib.ps1'; 'bin\agentq-jobobject.ps1' = 'bin\agentq-jobobject.ps1'; 'bin\agentq-slo.mjs' = 'bin\agentq-slo.mjs'; 'bin\agentq-store.mjs' = 'bin\agentq-store.mjs'; 'tests\test-store.mjs' = 'bin\test-store.mjs'; 'bin\agentq-flakes.mjs' = 'bin\agentq-flakes.mjs'; 'tests\test-flakes.mjs' = 'bin\test-flakes.mjs'; 'tests\test-land-flakes.ps1' = 'bin\test-land-flakes.ps1'; 'tests\test-agentq-claims.ps1' = 'bin\test-agentq-claims.ps1'; 'tests\test-land-batch.ps1' = 'bin\test-land-batch.ps1'; 'tests\fake-gate.ps1' = 'bin\fake-gate.ps1'
  'tests\test-jobobject.ps1' = 'bin\test-jobobject.ps1'; 'tests\test-land-finalize.ps1' = 'bin\test-land-finalize.ps1'; 'tests\test-land-reclaim.ps1' = 'bin\test-land-reclaim.ps1'; 'tests\test-land-precheck.ps1' = 'bin\test-land-precheck.ps1'
  # 2026-11-27: the stale-base land guard - a merge resolution that reverts origin content with no
  # conflict. Registered in run-all.ps1 in the same slice; 'install wiring' pins the two together.
  'tests\test-land-stale-base.ps1' = 'bin\test-land-stale-base.ps1'
  # ADR 0008 (2026-11-11): post-land hook (agentq-v2.ps1 runs the landed tree's scripts/post-land.ps1 after the push)
  'tests\test-post-land.ps1' = 'bin\test-post-land.ps1'
  # 2026-11-28: the wall-clock bound on a network git verb (Invoke-GitNet / Invoke-GitBounded). A wedged
  # `git fetch` held a land for 10 minutes (and an earlier one 55) with no way to tell it from a hung job.
  # Registered in run-all.ps1 in the same slice; 'install wiring' pins the two together.
  'tests\test-git-net-timeout.ps1' = 'bin\test-git-net-timeout.ps1'
  # 2026-10-18: Ctrl+C + exit before any force-kill of a terminal
  'bin\console-signal.ps1' = 'bin\console-signal.ps1'
  # 2026-10-18: stop a stuck command, keep the terminal (Ctrl+C -> Y -> Ctrl+Break -> kill children)
  'bin\term-interrupt.ps1' = 'bin\term-interrupt.ps1'; 'tests\test-term-interrupt.ps1' = 'bin\test-term-interrupt.ps1'
  # ADR 0007 (2026-10-19): git-first workspace + devbox teams (were ad-hoc copies in ~/.codai/{git,devbox})
  'bin\git-publish.ps1' = 'bin\git-publish.ps1'; 'bin\git-wip-snapshot.ps1' = 'bin\git-wip-snapshot.ps1'
  'bin\devsync.ps1' = 'bin\devsync.ps1'; 'bin\devbox-bootstrap.ps1' = 'bin\devbox-bootstrap.ps1'; 'bin\devbox-team-sync.ps1' = 'bin\devbox-team-sync.ps1'
  'bin\devbox-teams.py' = 'bin\devbox-teams.py'; 'devbox\devbox-root.sh' = 'bin\devbox-root.sh'; 'devbox\devbox-user.sh' = 'bin\devbox-user.sh'
  'tests\test-devbox-tools.ps1' = 'bin\test-devbox-tools.ps1'; 'tests\test-devbox-teams.py' = 'bin\test-devbox-teams.py'
  # ADR 0009 stage 0 (2026-11): load probe + admission, prune, doctor, chat keep-alive, land pre-gate,
  # read-only status; hook-pre.ps1 now lives in this repository (OQ-010).
  'bin\agentq-probe.ps1' = 'bin\agentq-probe.ps1'; 'bin\agentq-prune.ps1' = 'bin\agentq-prune.ps1'; 'bin\agentq-doctor.ps1' = 'bin\agentq-doctor.ps1'
  'hooks\hook-pre.ps1' = 'hooks\hook-pre.ps1'; 'tests\test-hook-pre.ps1' = 'hooks\test-hook-pre.ps1'
  # 2026-11-26: the resident hook host finally has a home in the repo (it used to exist ONLY in
  # ~\.copilot\hooks\resident\, which is how the `startMs` defect outlived a fix). hookc.exe is a
  # compiled artifact (build-client.ps1), so only the text files travel here; resident-ensure.ps1 is the
  # version-controlled launcher + the restart that install.ps1 now performs after a guard/server change.
  'hooks\resident\resident-server.ps1' = 'hooks\resident\resident-server.ps1'
  'hooks\resident\resident-ensure.ps1' = 'hooks\resident\resident-ensure.ps1'
  'hooks\resident\hookc4.c' = 'hooks\resident\hookc4.c'
  'hooks\resident\build-client.ps1' = 'hooks\resident\build-client.ps1'
  'hooks\resident\verify-resident.ps1' = 'hooks\resident\verify-resident.ps1'
  'hooks\resident\README.md' = 'hooks\resident\README.md'
  'tests\test-lease-chat.ps1' = 'bin\test-lease-chat.ps1'; 'tests\test-land-pregate.ps1' = 'bin\test-land-pregate.ps1'; 'tests\test-land-wait.ps1' = 'bin\test-land-wait.ps1'; 'tests\test-land-pregate-stale-ref.ps1' = 'bin\test-land-pregate-stale-ref.ps1'
  # 2026-11-23: land-autoreap (a wedged holder whose gate is green) + land-requeue (put the ticket back at
  # the HEAD on window expiry, bounded by landRequeueMax). Paired with the run-all.ps1 entry.
  'tests\test-land-reap.ps1' = 'bin\test-land-reap.ps1'
  # 2026-11-24: reap the auto-generated `publish/*` source branch after a successful land. Paired with the
  # run-all.ps1 entry - 'install wiring' pins the two.
  'tests\test-land-reap-branch.ps1' = 'bin\test-land-reap-branch.ps1'
  # 2026-11-23: the `pregate lease reap` suite was in run-all.ps1 but missing from this map, so the wiring
  # gate failed on it three times (map drift, -File not a map key, gateSuites not fully installed).
  'tests\test-pregate-lease-reap.ps1' = 'bin\test-pregate-lease-reap.ps1'
  # 2026-11-24: a broken worktree (gitdir gone -> no valid HEAD) is orphaned ONCE (moved to _orphans,
  # lease released, files kept) instead of failing the backup and re-counting on every sweep. Paired with
  # the run-all.ps1 entry in this same commit - 'install wiring' pins the two.
  'tests\test-agentq-orphan-broken-slot.ps1' = 'bin\test-agentq-orphan-broken-slot.ps1'
  'tests\test-agentq-admission.ps1' = 'bin\test-agentq-admission.ps1'; 'tests\test-status-readonly.ps1' = 'bin\test-status-readonly.ps1'
  # 2026-11-28 (round 4): sat-report.ps1 and its classifier suite were in NEITHER list, so the suite ran
  # nowhere and could not fail. It resolves its subject as `$PSScriptRoot\..\bin\sat-report.ps1`, which is
  # exactly the installed layout once both are mapped to bin\. Paired with the run-all.ps1 entry in this
  # same commit - 'install wiring' pins the two (it failed on all three of its checks before this line).
  'bin\sat-report.ps1' = 'bin\sat-report.ps1'; 'tests\test-sat-report.ps1' = 'bin\test-sat-report.ps1'
  # 2026-11-27: the machine-wide gate bound (gate:machine) - the bound, its config knob, its floor and
  # its separation from build:machine. Paired with the run-all.ps1 entry in this same commit - 'install
  # wiring' pins the two, so a suite the installed gate cannot run is impossible.
  'tests\test-agentq-gate-machine.ps1' = 'bin\test-agentq-gate-machine.ps1'
  # 2026-11-21: the release `phase` is the last checkpoint, not the failed step - display + schema pinned
  'tests\test-release-phase-honesty.ps1' = 'bin\test-release-phase-honesty.ps1'
  'tests\test-agentq-prune.ps1' = 'bin\test-agentq-prune.ps1'; 'tests\test-agentq-doctor.ps1' = 'bin\test-agentq-doctor.ps1'
  # 2026-11-25: a cloud run leaves versioned evidence in the target repo (runs\<jobid>.log + one row in
  # the repo's RUNS.md). Paired with the run-all.ps1 entry in this same commit - 'install wiring' pins
  # the two, and the suite's in-flight exception in test-install-wiring.ps1 is dropped by this line.
  'tests\test-cloud-evidence.ps1' = 'bin\test-cloud-evidence.ps1'
  # 2026-11-25: `-Status -Json` (vitals ADR 0050). Paired with the run-all.ps1 entry in this same
  # commit - 'install wiring' pins the two, so a suite the installed gate cannot run is impossible.
  'tests\test-agentq-cloud-status.ps1' = 'bin\test-agentq-cloud-status.ps1'
  # 2026-11-26: the heal policy (repeated bounded backoff + the peer-in-flight guard). Paired with the
  # run-all.ps1 entry in this same slice - 'install wiring' pins the two.
  'tests\test-agentq-cloud-heal.ps1' = 'bin\test-agentq-cloud-heal.ps1'
  'tests\test-slo.mjs' = 'bin\test-slo.mjs'
  # 2026-11-28: OQ-004's second red as a ratchet (the floor file travels WITH the suite - the suite
  # resolves it beside itself, so an installed suite without it cannot run), and the freshness gate that
  # stops verify-resident.ps1 measuring a live copy other than this checkout's. Paired with the
  # run-all.ps1 entries in this same slice; 'install wiring' pins the two lists together.
  'tests\slo-second-red.test.mjs' = 'bin\slo-second-red.test.mjs'
  'tests\slo-second-red-baseline.json' = 'bin\slo-second-red-baseline.json'
  'tests\test-verify-resident-freshness.ps1' = 'bin\test-verify-resident-freshness.ps1'
  # 2026-11-23: `bump -Id|-Session` (a waiter can target its OWN ticket) + the `== MINE session ...` line
  # in `status`. Paired with the run-all.ps1 entry in this same commit - 'install wiring' pins the two.
  'tests\test-agentq-bump.ps1' = 'bin\test-agentq-bump.ps1'
  # 2026-11-21 (ADR 0014): slot take-over + `recover`, the commit/push split (D1), the per-session
  # fair share (D4). `test-land-default-gate.ps1` was in run-all but not in this map, so the installed
  # copy never carried it - the install gate could not run what it never installed.
  'tests\test-agentq-recover.ps1' = 'bin\test-agentq-recover.ps1'; 'tests\test-agentq-commit-fast.ps1' = 'bin\test-agentq-commit-fast.ps1'
  # 2026-11-26 (queue-time slice): land capacity + the bounded per-repo merge mutex, the per-CHAT
  # take-over note, and the comma-joined single-value argument guard. Paired with the run-all.ps1 entries
  # in this same slice and with gateSuites.agentq in bin\agentq-config.json - 'install wiring' pins all
  # three lists together.
  'tests\test-land-capacity.ps1' = 'bin\test-land-capacity.ps1'
  'tests\test-slot-takeover-chat.ps1' = 'bin\test-slot-takeover-chat.ps1'
  'tests\test-agentq-args-comma.ps1' = 'bin\test-agentq-args-comma.ps1'
  'tests\test-agentq-fairshare.ps1' = 'bin\test-agentq-fairshare.ps1'; 'tests\test-agentq-slotshare.ps1' = 'bin\test-agentq-slotshare.ps1'; 'tests\test-land-default-gate.ps1' = 'bin\test-land-default-gate.ps1'
  # 2026-11-26 (owner-ticked wave 20): the gate input-selection MODULE (a suite resolves it as ..\bin\<x>,
  # so an installed suite without it cannot run), the timings reader, and the proof-based reclaim verb -
  # each with its suite. Paired with the run-all.ps1 entries in this same slice; 'install wiring' pins the
  # two lists, so a suite the installed gate cannot run is impossible by construction.
  'bin\agentq-suite-inputs.ps1' = 'bin\agentq-suite-inputs.ps1'
  'tests\test-gate-input-selection.ps1' = 'bin\test-gate-input-selection.ps1'
  'bin\agentq-timings.ps1' = 'bin\agentq-timings.ps1'
  'tests\test-agentq-timings.ps1' = 'bin\test-agentq-timings.ps1'
  'bin\agentq-reclaim.ps1' = 'bin\agentq-reclaim.ps1'
  'tests\test-agentq-reclaim.ps1' = 'bin\test-agentq-reclaim.ps1'
  # The edit-ticket approval path: the CLI half waits for the owner's verdict, the window half mints the
  # ticket (it owns a real console, which is exactly what `rules-ticket.ps1 -Issue` requires).
  'bin\agentq-approve.ps1' = 'bin\agentq-approve.ps1'
  'bin\agentq-approve-gui.ps1' = 'bin\agentq-approve-gui.ps1'
  # 2026-11-28 (tracking/resume slice): the module agentq.ps1 dot-sources for `trackers|plan|task`, the
  # hook that injects the plan record on a new user prompt, and their two suites. The module resolves its
  # CLI as <install root>\tools\track.mjs, and track.mjs imports tracker-lint.mjs beside it, so a missing
  # tools entry kills the verb on a missing import while the checkout still looks complete.
  'bin\agentq-trackers.ps1' = 'bin\agentq-trackers.ps1'
  # The hook itself: without this line the module and its suites install and the resume hook never does,
  # so the installed suite went red looking for a file nobody shipped (found 2026-11-28).
  'hooks\user-prompt-resume.ps1' = 'hooks\user-prompt-resume.ps1'
  'tests\test-agentq-trackers.ps1' = 'bin\test-agentq-trackers.ps1'
  # A suite for a REGISTERED hook installs beside it in hooks\ - test-config-integrity.ps1 reads the
  # hook suites that sit there, so a suite parked in bin\ leaves the hook counted as untested.
  'tests\test-user-prompt-resume.ps1' = 'hooks\test-user-prompt-resume.ps1'
  'tests\test-agentq-approve.ps1' = 'bin\test-agentq-approve.ps1'
  # 2026-11-21: `agentq run` runs its child at the resolved repo root when the caller is OUTSIDE the
  # repo, and keeps the caller's nested directory when INSIDE (commit 37fdf67, "a brand-new slot
  # starts hollow").
  'tests\test-agentq-cwd.ps1' = 'bin\test-agentq-cwd.ps1'
  # 2026-11-21: `run-build.ps1 -Class web|scripts` (the second build resource for script-only builds).
  'tests\test-build-class.ps1' = 'bin\test-build-class.ps1'
  # 2026-11-26: the cloud-aware run-build suite + the saturated-placement suite. Both sat in tests\ with no
  # entry here and none in run-all.ps1, so no gate ever ran them. Paired with the run-all.ps1 entries in
  # this same slice - 'install wiring' pins the two, and the install gate could not run what it never had.
  'tests\test-runbuild-cloud-aware.ps1' = 'bin\test-runbuild-cloud-aware.ps1'
  'tests\test-agentq-saturated-placement.ps1' = 'bin\test-agentq-saturated-placement.ps1'
  # 2026-11-26: the gate-wrapper PLACEMENT rule itself (a Windows-only wrapper must stay off the pool).
  # Unit-level, offline, and driven through the LIVE bin\agentq-v2.ps1, so a later rename or a silently
  # inert form of the rule (the missing-@() bug that made it match nothing) fails the gate instead of
  # shipping. Paired with the run-all.ps1 entry in this same slice - 'install wiring' pins the two.
  'tests\test-gate-where-placement.ps1' = 'bin\test-gate-where-placement.ps1'
  # 2026-11-21: the gate itself runs as a registered background job (bin\run-tests-job.ps1), so a quiet
  # 30-minute suite can never be killed by the terminal reaper - which is exactly what happened to this
  # gate on 2026-11-21: 24 of 45 suites green, then silence, a free shell, and NOTHING installed.
  'bin\run-tests-job.ps1' = 'bin\run-tests-job.ps1'; 'tests\test-run-tests-job.ps1' = 'bin\test-run-tests-job.ps1'
  # 2026-11-22: the fleet-wide build-artefact cleaner - its liveness gate now cross-checks the
  # `agentq status -All -Json` lease list AND the per-slot lease files, and fails safe (skip, loud)
  # when neither is usable. Was live-only in ~/.copilot/bin and never carried by the repo before this.
  'bin\clean-build-artifacts.ps1' = 'bin\clean-build-artifacts.ps1'; 'tests\test-clean-build-artifacts.ps1' = 'bin\test-clean-build-artifacts.ps1'
  # 2026-11-27: the machine-local litter sweeper (nightly task codai-stray-reaper) existed ONLY as an
  # unversioned file in ~\.copilot\bin, so a reinstall could not restore it and no gate could reach it.
  # Paired with the run-all.ps1 entry in this same slice - 'install wiring' pins the two lists together.
  'bin\stray-reaper.ps1' = 'bin\stray-reaper.ps1'; 'tests\test-stray-reaper.ps1' = 'bin\test-stray-reaper.ps1'
  # 2026-11-27: the other half of the same sweeper - the task (re)registration. It lived only in
  # ~\.copilot\bin too, so a lost codai-stray-reaper definition had no way back (the original was a
  # hand-typed schtasks line and the hidden-run.vbs wrapper is not recoverable from the reaper itself).
  # Pinned by the same suite, which checks it byte-for-byte against the live copy and that it still
  # declares the task name, the wrapper and a read-back of the registration.
  'bin\install-stray-reaper-task.ps1' = 'bin\install-stray-reaper-task.ps1'
  # 2026-11-22: static guard for the script-scope clobber class (a top-level `$null` reset after a real
  # value). A suite in run-all belongs in this map too, or the install gate cannot run what it never
  # installed - the same gap `test-land-default-gate.ps1` had (see the note above).
  'tests\test-script-scope.ps1' = 'bin\test-script-scope.ps1'
  # 2026-11-22 (objective (c)): the rest of the drift the new `install wiring` suite found - 8 files a
  # gate suite references that this map never carried, so the INSTALLED gate could not run those suites
  # at all (it runs from ~/.copilot, where those files did not exist). The tool counts double: without
  # `bin\shared-clone-janitor.ps1` even the checkout cannot run `shared janitor`.
  'bin\shared-clone-janitor.ps1' = 'bin\shared-clone-janitor.ps1'
  'tests\test-agentq-shared-commit.ps1' = 'bin\test-agentq-shared-commit.ps1'
  'tests\test-agentq-lease-liveness.ps1' = 'bin\test-agentq-lease-liveness.ps1'
  'tests\test-land-install.ps1' = 'bin\test-land-install.ps1'
  'tests\test-agentq-sync.ps1' = 'bin\test-agentq-sync.ps1'
  'tests\test-install.ps1' = 'bin\test-install.ps1'
  'tests\test-shared-clone-janitor.ps1' = 'bin\test-shared-clone-janitor.ps1'
  'tests\test-install-wiring.ps1' = 'bin\test-install-wiring.ps1'
  # 2026-11-23: elastic scratch pool + resource-derived machine task-slot budget
  'tests\test-slot-budget.ps1' = 'bin\test-slot-budget.ps1'
  # 2026-11-27: the SPAWN SHAPE of a lease (perf). Paired with the run-all.ps1 entry in this same
  # commit - 'install wiring' pins the two.
  'tests\test-lease-spawns.ps1' = 'bin\test-lease-spawns.ps1'
  # 2026-11-28: the CP437 trap (a captured-then-rewritten file silently loses its non-ASCII characters).
  # Paired with the run-all.ps1 entry in this same commit - 'install wiring' pins the two.
  'tests\test-text-encoding.ps1' = 'bin\test-text-encoding.ps1'
  # 2026-11-25: a journal write that loses a race must never abort the operation it describes, and the
  # land PRE-gate must run at Normal like the queued land gate. Paired with the run-all.ps1 entry in
  # this same commit - 'install wiring' pins the two.
  'tests\test-journal-write-race.ps1' = 'bin\test-journal-write-race.ps1'
  # 2026-11-25: the anti-regression ratchet for POOL-delegating land gates, plus the allow-list it
  # reads (the installed suite lives in bin\, so the JSON must too). Paired with the run-all.ps1 entry
  # in this same commit - 'install wiring' pins the two.
  'tests\test-land-gate-pool.ps1' = 'bin\test-land-gate-pool.ps1'
  'tests\land-gate-pool.allow.json' = 'bin\land-gate-pool.allow.json'
}
$dst = if ($env:AGENTQ_INSTALL_DIR) { $env:AGENTQ_INSTALL_DIR } else { Join-Path $env:USERPROFILE '.copilot' }
# Config merge: the installed file keeps every value it has; values only the checkout has are appended.
# Nested maps merge one level deep (a `landGate` per-repo entry, a `pinned` list): an installed entry
# wins, a new one from the checkout is added. A top-level-only merge could never deliver a new per-repo
# default - 2026-11-21: `landGate.codai` was added to the checkout and silently dropped because the
# installed copy already had a `landGate` key, so the live config never carried the gate.
# EXCEPT `landGate` itself: a land gate is a REPO policy, not a machine value, so the CHECKOUT owns it
# and the installed copy only contributes repos the checkout does not name (2026-11-25).
# Returns the merged text, or $null when nothing is missing (file left untouched).
function Merge-ConfigMap([string]$prefix, $to, $from) {
  $o = [ordered]@{}
  foreach ($k in $to.Keys) {
    $path = if ($prefix) { "$prefix.$k" } else { "$k" }
    $tv = $to[$k]; $fv = if ($from.ContainsKey($k)) { $from[$k] } else { $null }
    $bothArr = ($tv -is [Collections.IList]) -and -not ($tv -is [string]) -and ($fv -is [Collections.IList]) -and -not ($fv -is [string])
    if ($bothArr) {
      # An ARRAY grows: it keeps the installed order and gains the checkout's items. Treating it as a
      # scalar ("the installed copy wins") means a new list item NEVER reaches the live config - 2026-11-23:
      # `gateSuites.agentq` gained the six land suites in the checkout, the merge kept the installed
      # 17-name list, and the gate therefore ran without the very suites that cover the land engine.
      $add = @($fv | Where-Object { $tv -notcontains $_ })
      $o[$k] = @($tv) + $add
      if ($add.Count) { $script:CfgAdded = @($script:CfgAdded) + @("$path += $($add -join ', ')") }
    } elseif ($path -eq 'landGate' -and $fv -is [Collections.IDictionary] -and $tv -is [Collections.IDictionary]) {
      # Installed-wins is WRONG for a gate, and the old code had a second defect on top of the value:
      # it reported only ADDED keys, so a checkout that changed an EXISTING gate rewrote nothing at all.
      # 2026-11-25: the checkout moved `landGate.vmui` to the devcloud pool gate, the installed copy kept
      # `pnpm typecheck`, and the live config never carried the change - the same class of silent drop as
      # the 2026-11-21 incident above, for an existing key instead of a missing one. Measured: an install
      # into a scratch AGENTQ_INSTALL_DIR left `pnpm typecheck` in place.
      # Here the checkout is the base (it wins) and the installed copy adds only the repos it alone names.
      # Build the map here rather than recursing: the recursion reports every installed-only key as an
      # ADDITION, which made `-Check` report drift on every later run (a repo named only locally can
      # never be "added" twice) and broke the "a re-install changes nothing" invariant.
      $g = [ordered]@{}
      foreach ($rk in $fv.Keys) { $g[$rk] = $fv[$rk] }
      foreach ($rk in $tv.Keys) { if (-not $g.Contains($rk)) { $g[$rk] = $tv[$rk] } }
      foreach ($rk in $fv.Keys) {
        if (-not $tv.ContainsKey($rk)) { $script:CfgAdded = @($script:CfgAdded) + @("$path.$rk = $($fv[$rk])") }
        elseif ("$($tv[$rk])" -ne "$($fv[$rk])") { $script:CfgChanged = @($script:CfgChanged) + @("$path.$rk = $($fv[$rk])") }
      }
      $o[$k] = $g
    } elseif ($fv -is [Collections.IDictionary] -and $tv -is [Collections.IDictionary]) {
      $o[$k] = Merge-ConfigMap $path $tv $fv
    } else { $o[$k] = $tv }
  }
  foreach ($k in $from.Keys) {
    if (-not $to.ContainsKey($k)) {
      $o[$k] = $from[$k]
      $script:CfgAdded = @($script:CfgAdded) + @($(if ($prefix) { "$prefix.$k" } else { "$k" }))
    }
  }
  $o
}
function Get-MergedConfig([string]$from, [string]$to) {
  $s = Get-Content -LiteralPath $from -Raw | ConvertFrom-Json -AsHashtable
  $d = Get-Content -LiteralPath $to -Raw | ConvertFrom-Json -AsHashtable
  $script:CfgAdded = @()
  $script:CfgChanged = @()
  $o = Merge-ConfigMap '' $d $s
  # A CHANGED value is as much work as an added key: without this the merged text was discarded and the
  # live file was left untouched, so a gate change could never be delivered.
  if (-not (@($script:CfgAdded).Count + @($script:CfgChanged).Count)) { return $null }
  ($o | ConvertTo-Json -Depth 8) + "`n"
}
# --- green record freshness (begin) ---------------------------------------------------------------
# Is <Path> a full-green record written less than MaxHours ago? ps/tests/run-all.ps1 writes it and the
# install below reads it to skip a repeat of the exact content. `at` comes back from ConvertFrom-Json
# as a [datetime] (PS 7 converts ISO-8601 strings), and `"$($g.at)"` then stringifies it in the
# MACHINE's culture - Get-Date cannot re-parse that outside en-US, so $fresh stayed false and install
# ran all 45 suites (~36 min) for a tree that had just passed them (2026-11-21, this machine: the
# record held "2026-11-21T01:36:38" and Get-Date was handed "11/21/2026 01:36:38"). Take the value as
# it is; parse a string with the invariant culture. Anything unreadable is NOT fresh (fail closed).
function Test-GreenRecordFresh([string]$Path, [double]$MaxHours = 24) {
  if (-not (Test-Path -LiteralPath $Path)) { return $false }
  try {
    $g = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    if (-not $g -or -not $g.ContainsKey('at') -or -not $g['at']) { return $false }
    $v = $g['at']
    if ($v -is [datetime]) { $at = $v }
    elseif ($v -is [datetimeoffset]) { $at = $v.DateTime }
    else { $at = [datetime]::Parse("$v", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    (((Get-Date).ToUniversalTime() - $at.ToUniversalTime()).TotalHours -lt $MaxHours)
  } catch { $false }
}
# --- the install gate ANNOUNCES itself (2026-11-28) -------------------------------------------------
# Measured: three concurrent installs waited on `Global\agentq-install-gate` for 17 min, 1,9 h and 2,5 h
# and printed NOTHING - the only line about the gate came AFTER the wait, so a wedged holder was
# indistinguishable from a wedged install and every agent re-diagnosed it by hand from scratch. Two
# halves: the holder publishes WHO it is (a marker beside the installed manifest) and the waiter says
# what it is waiting for, naming the holder, under a cap in minutes that a full suite fits comfortably
# (43 suites ~11 min on the pool, measured 2026-11-27). Both are pure functions so the `install` suite
# pins the protocol instead of grepping for a sentence.
function Get-InstallGateWaitMin { param([int]$CapMin = 12) if ($CapMin -lt 3) { return 3 } ; return $CapMin }
function Format-InstallGateWait {
  param([int]$WaitMin, $Holder)
  $who = if ($Holder -and $Holder.pid) { "held by pid $($Holder.pid) since $($Holder.at) ($($Holder.src))" }
         else { 'no holder published a marker (an older install, or the holder died)' }
  return "install gate: waiting up to $WaitMin min - $who"
}
# --- green record freshness (end) -----------------------------------------------------------------
$drift = @()
foreach ($k in $map.Keys) {
  $a = Join-Path $src $k; $b = Join-Path $dst $map[$k]
  if (-not (Test-Path -LiteralPath $a)) { throw "install: $k is in the map but not in this checkout" }
  if ($k -eq $cfgKey -and (Test-Path $b)) { if ($null -ne (Get-MergedConfig $a $b)) { $drift += $k }; continue }
  if (-not (Test-Path $b) -or (Get-FileHash $a).Hash -ne (Get-FileHash $b).Hash) { $drift += $k }
}
# Two files the tracking verbs need live OUTSIDE ps\: tools\track.mjs, and the tools\tracker-lint.mjs it
# imports, sit at the REPOSITORY root. That is where ps\bin\agentq-trackers.ps1 finds them in a checkout,
# but the installed module looks beside itself, so they are installed to <dst>\bin - the same place
# agentq-store.mjs and agentq-slo.mjs already live. The map cannot carry them: every map source must
# exist under ps\, which is exactly what this installer's own suite copies into a throwaway tree. So they
# get this explicit arm, kept out of $map (the manifest count is pinned to that map) and out of $drift
# (whose ordering step indexes $map). A source that is absent is SKIPPED in silence - the suite's
# snapshot legitimately lacks the repository root, and a warning there would read as a defect.
$outMap = [ordered]@{ '..\tools\track.mjs' = 'bin\track.mjs'; '..\tools\tracker-lint.mjs' = 'bin\tracker-lint.mjs' }
$outDrift = @()
foreach ($k in $outMap.Keys) {
  $a = Join-Path $src $k
  if (-not (Test-Path -LiteralPath $a)) { continue }
  $b = Join-Path $dst $outMap[$k]
  if (-not (Test-Path -LiteralPath $b) -or (Get-FileHash -LiteralPath $a).Hash -ne (Get-FileHash -LiteralPath $b).Hash) { $outDrift += $k }
}
if ($Check) {
  if ($drift -or $outDrift) { "DRIFT: $((@($drift) + @($outDrift | ForEach-Object { "out:$_" })) -join ', ')"; exit 1 }
  'in sync'; exit 0
}
if (-not $SkipTests) {
  if ($RepoSuites -and $Suites) { throw 'install: pass either -Suites or -RepoSuites, not both' }
  # Serialize with other installs (2026-11-25). Three installs ran the FULL suite at once, each with
  # -Parallel 4: the suites share machine resources and the real .wt / lease state, and two of them went
  # red only because a sibling run was in flight (`test-agentq-v2.ps1` and `test-land-batch.ps1` both pass
  # when run alone). A red suite makes install REFUSE to install, so contention means nobody installs --
  # the installed agentq stayed stale for hours. The gate is held for the whole test phase only.
  $gate = $null; $gotGate = $false
  $gateMarker = $null
  if ($env:AGENTQ_INSTALL_NO_GATE) { 'install gate: disabled by AGENTQ_INSTALL_NO_GATE' }
  else {
    try {
      $gate = New-Object Threading.Mutex($false, 'Global\agentq-install-gate')
      $gateMarker = Join-Path $dst 'bin\agentq-install-gate.holder.json'
      $holder = $null
      if (Test-Path -LiteralPath $gateMarker) { try { $holder = Get-Content -LiteralPath $gateMarker -Raw | ConvertFrom-Json } catch { $holder = $null } }
      $waitMin = Get-InstallGateWaitMin
      # BEFORE the wait, never after it: 45 min of silence is how three installs were left looking healthy.
      Format-InstallGateWait -WaitMin $waitMin -Holder $holder
      $t0 = Get-Date
      $gotGate = $gate.WaitOne($waitMin * 60 * 1000)
      $waitedSec = [int]((Get-Date) - $t0).TotalSeconds
      if ($gotGate) {
        if ($waitedSec -ge 5) { "install gate acquired after $waitedSec s of waiting" }
        else { 'install gate acquired (the test suite runs one install at a time)' }
        [IO.File]::WriteAllText("$gateMarker.new", (@{ pid = $PID; at = (Get-Date).ToString('o'); src = $src } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
        Move-Item "$gateMarker.new" $gateMarker -Force
      }
      else { "WARNING: another agentq install has held the gate for $waitMin min - running the suite ungated (that holder may be stuck)" }
    } catch [System.Threading.AbandonedMutexException] {
      # The previous holder died without releasing - it was killed, or it wedged and was reaped. .NET hands
      # the mutex to US and throws. Treat that as ACQUIRED (we hold it, and the finally releases it) and say
      # it out loud: a dead holder is an incident, not noise. Measured 2026-11-28: a wedged `ps/install.ps1`
      # held this gate for 2 h 40 min at 2 s of CPU while three installs queued behind it in silence.
      $gotGate = $true
      'install gate acquired: the previous holder died without releasing it (abandoned mutex)'
    } catch {
      $gate = $null; $gotGate = $true
      "WARNING: install gate unavailable ($($_.Exception.Message)) - running the suite ungated"
    }
  }
  try {
  $raArgs = @()
  if ($Suites) { $raArgs += @('-Only', (@($Suites | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ',')) }
  if ($RepoSuites) { $raArgs += '-RepoSuites' }
  if ($Parallel -gt 1) { $raArgs += @('-Parallel', "$Parallel") }
  # Instant repeat: a full green run of THIS content is already the gate (run-all.ps1 writes the hash).
  $alreadyGreen = $false
  if (-not $Suites -and -not $RepoSuites -and -not $Full) {
    $gf = Join-Path (Split-Path -Parent $src) '.copilot-tmp\last-green.json'
    $fresh = $false
    $fresh = Test-GreenRecordFresh $gf
    if ($fresh) {
      & pwsh -NoProfile -File (Join-Path $src 'tests\run-all.ps1') -LastGreen
      if ($LASTEXITCODE -eq 0) { $alreadyGreen = $true }
    }
  }
  if ($alreadyGreen) { Write-Host 'install: tests SKIPPED - ps/ is byte-identical to the tree that passed (use -Full to force)' }
  else {
    # The gate runs as a REGISTERED BACKGROUND JOB by default: it gets its own hidden console, so the
    # idle-terminal reaper cannot kill a suite that prints nothing for 20 min (2026-11-21: it did, and
    # the install quietly did not happen). -Foreground (or AGENTQ_INSTALL_FOREGROUND=1) keeps the old
    # behaviour for a shell that is already safe/attended.
    $useJob = -not $Foreground -and -not $env:AGENTQ_INSTALL_FOREGROUND
    if ($useJob) { & pwsh -NoProfile -File (Join-Path $src 'bin\run-tests-job.ps1') -RunAll (Join-Path $src 'tests\run-all.ps1') -Cwd (Split-Path -Parent $src) @raArgs }
    else { & pwsh -NoProfile -File (Join-Path $src 'tests\run-all.ps1') @raArgs }
    $code = $LASTEXITCODE
    if ($code -eq 2) { throw 'install: the gate STALLED (its job log went quiet while the process was alive) - not installing; read the job log, then re-run' }
    if ($code -eq 3) { throw 'install: the gate was still running when the wait cap expired - not installing; re-check the job id printed above, then re-run' }
    if ($code) { throw 'install: tests are red - not installing' }
  }
  } finally {
    if ($gate -and $gotGate) {
      # The marker is only useful while the gate is held: leaving it behind would name a holder that is
      # gone - and the marker is exactly what the next waiter prints to find the holder.
      try { Remove-Item -LiteralPath $gateMarker -Force -ErrorAction SilentlyContinue } catch { }
      try { $gate.ReleaseMutex() } catch { }
    }
  }
}
$bk = Join-Path $dst ".backup\$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
# Files the destination does not have yet go first: agentq.ps1 dot-sources its companions at start, so a
# new agentq.ps1 must never be live before the new files it loads (an agentq call in that gap would fail).
$drift = @($drift | Where-Object { -not (Test-Path (Join-Path $dst $map[$_])) }) + @($drift | Where-Object { Test-Path (Join-Path $dst $map[$_]) })
foreach ($k in $drift) {
  $a = Join-Path $src $k; $b = Join-Path $dst $map[$k]
  if (Test-Path $b) { $t = Join-Path $bk $map[$k]; New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null; Copy-Item $b $t }
  New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
  if ($k -eq $cfgKey -and (Test-Path $b)) {
    $merged = Get-MergedConfig $a $b
    if ($null -ne $merged) {
      [IO.File]::WriteAllText("$b.new", $merged, [Text.UTF8Encoding]::new($false)); Move-Item "$b.new" $b -Force
      "merged $($map[$k]): $(if (@($script:CfgAdded).Count) { "added $($script:CfgAdded -join ', ')" })$(if (@($script:CfgAdded).Count -and @($script:CfgChanged).Count) { '; ' })$(if (@($script:CfgChanged).Count) { "changed $($script:CfgChanged -join ', ')" }) (other keys keep their local value)"
    }
    continue
  }
  # atomic replace: a hook firing mid-copy must never see half a file
  Copy-Item $a "$b.new" -Force; Move-Item "$b.new" $b -Force
  # Copy-Item preserves alternate data streams, so a Zone.Identifier ("downloaded from the Internet")
  # on the SOURCE travels to the installed copy and RemoteSigned then refuses to run it: the 2026-11-20
  # "File C:\Users\vladu\.copilot\bin\git-autosync.ps1 cannot be loaded. The file ... is not digitally
  # signed." — a live daemon that silently cannot start, with a clean-looking install. Unblock-File
  # afterwards: the source is our own repo, never untrusted.
  Unblock-File -LiteralPath $b -ErrorAction SilentlyContinue
  "installed $($map[$k])"
}
# The out-of-map tools, same atomic replace and the same backup rule. They go LAST on purpose: the module
# agentq.ps1 dot-sources is already in place above, so an agentq call in the gap between them cannot see a
# module without its tool.
foreach ($k in $outDrift) {
  $a = Join-Path $src $k; $b = Join-Path $dst $outMap[$k]
  if (Test-Path -LiteralPath $b) { $t = Join-Path $bk $outMap[$k]; New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null; Copy-Item $b $t }
  New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
  Copy-Item $a "$b.new" -Force; Move-Item "$b.new" $b -Force
  Unblock-File -LiteralPath $b -ErrorAction SilentlyContinue
  "installed $($outMap[$k])"
}
# What was installed, for `agentq doctor` (a hand edit of an installed file shows up as a hash mismatch).
$files = [ordered]@{}
foreach ($k in $map.Keys) { if ($k -ne $cfgKey) { $files[$map[$k]] = (Get-FileHash -LiteralPath (Join-Path $dst $map[$k]) -Algorithm SHA256).Hash } }
$sha = "$(& git -C $src rev-parse HEAD 2>$null)".Trim()
$dirty = [bool]@(& git -C $src status --porcelain -- . 2>$null | Where-Object { $_ }).Count
$manifest = [ordered]@{ src = $src; sha = $sha; dirty = $dirty; at = [DateTime]::UtcNow.ToString('o'); files = $files }
$mf = Join-Path $dst 'bin\agentq-install.json'
[IO.File]::WriteAllText("$mf.new", ($manifest | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false)); Move-Item "$mf.new" $mf -Force
if ($env:AGENTQ_INSTALL_DIR) { "install: $($drift.Count + $outDrift.Count) file(s) into $dst; backup in $bk"; exit 0 }
# The sync loop is a long-running process: it keeps running the OLD code until restarted (2026-10-12).
if ($drift | Where-Object { $_ -in 'bin\agentq-sync.ps1', 'bin\agentq-probe.ps1', 'bin\agentq-jobs-lib.ps1' }) {
  try {
    $syncTask = Get-ScheduledTask -TaskName 'agentq-sync' -ErrorAction SilentlyContinue
    if ($syncTask) {
      $needle = (Join-Path $dst 'bin\agentq-sync.ps1').ToLowerInvariant()
      foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)".ToLowerInvariant().Contains($needle) -and "$($_.CommandLine)" -match '-Loop\b' })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
      }
      Start-ScheduledTask -TaskName 'agentq-sync'
      'restarted the agentq-sync loop (it was running the previous code)'
    }
  } catch { "WARNING: could not restart agentq-sync: $($_.Exception.Message) - restart the scheduled task by hand" }
}
# The resident hook host runs hook-pre.ps1 IN-PROCESS and reads the guard text ONCE at startup, so a new
# hook-pre.ps1 (or a new server) is NOT live until the host is replaced. 2026-11-26: a fixed hook-pre.ps1
# kept recording the host's UPTIME as startMs (`agentq slo` read 318 162 h/day) precisely because the
# running host still held the old text. resident-ensure.ps1 -Restart fixes that as part of the install.
if ($drift | Where-Object { $_ -eq 'hooks\hook-pre.ps1' -or $_ -like 'hooks\resident\*' }) {
  try { & (Join-Path $dst 'hooks\resident\resident-ensure.ps1') -Restart } catch { "WARNING: could not restart the resident hook server: $($_.Exception.Message)" }
}
# legacy test that encoded the retired ad-hoc naming
$old = Join-Path $dst 'hooks\test-worktree-tools.ps1'
if (Test-Path $old) { New-Item -ItemType Directory -Force (Join-Path $bk 'hooks') | Out-Null; Move-Item $old (Join-Path $bk 'hooks\test-worktree-tools.ps1') -Force; 'retired hooks\test-worktree-tools.ps1 (superseded by test-worktree-v2.ps1)' }
# ADR 0007: the WIP snapshot task runs the agentq copy (was ~/.codai/git/wip-all.ps1)
$wipTask = Get-ScheduledTask -TaskName 'codai-git-wip-snapshot' -ErrorAction SilentlyContinue
if ($wipTask -and "$($wipTask.Actions[0].Arguments)" -notmatch 'git-wip-snapshot\.ps1') {
  # hidden-run.vbs (wscript, window style 0): -WindowStyle Hidden still flashes a console under an
  # interactive token (owner complaint 2026-10-19).
  $wipArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $dst 'bin\git-wip-snapshot.ps1')`" -All"
  $vbs = 'E:\gh\vmui\scripts\hidden-run.vbs'
  $a = if (Test-Path $vbs) { New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$((Get-Command pwsh).Source)`" $wipArgs" } else { New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-WindowStyle Hidden $wipArgs" }
  Set-ScheduledTask -TaskName 'codai-git-wip-snapshot' -Action $a | Out-Null
  'task codai-git-wip-snapshot -> bin\git-wip-snapshot.ps1 -All'
}
# gateSuites is a POLICY list, and the merge above deliberately keeps the installed value of a key that
# already exists there (that rule protects slot caps and workspace maps, which are machine-local). For
# this key the rule is wrong: adding a suite to the source left the land gate on this machine reading the
# old list until the installed config was edited by hand - measured 2026-11-26, source 29 entries,
# installed 27, and the land gate reads the INSTALLED one. So append what is missing, keep every existing
# entry, and name what was added.
$dstCfgPath = Join-Path $dst $cfgKey
try {
  $srcCfg = Get-Content -LiteralPath (Join-Path $src $cfgKey) -Raw | ConvertFrom-Json
  $dstCfg = Get-Content -LiteralPath $dstCfgPath -Raw | ConvertFrom-Json
  $wantSuites = @($srcCfg.gateSuites.agentq)
  $haveSuites = @($dstCfg.gateSuites.agentq | ForEach-Object { "$_" })
  $missingSuites = @($wantSuites | Where-Object { $haveSuites -notcontains "$_" })
  if ($missingSuites.Count) {
    $dstCfg.gateSuites.agentq = @($haveSuites + $missingSuites)
    ($dstCfg | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $dstCfgPath -Encoding utf8
    "gateSuites.agentq: appended $($missingSuites -join ', ') (the installed registry had an older list)"
  }
} catch { "WARNING: could not append the gateSuites entries: $($_.Exception.Message)" }

# The prewarm task runs the agentq copy too (registered 2026-11-25). It has to be re-pointed by PATH,
# not by file name: a task naming E:\gh\agentq\ps\bin\prewarm-cloud.ps1 passes a name check while running
# the SOURCE checkout - measured live 2026-11-26, that is exactly what the registered task did, so every
# unattended tick ran uncommitted code. Read back after the write, because Set-ScheduledTask returning
# without an error says nothing about what the task now names.
$pwTask = Get-ScheduledTask -TaskName 'codai-workspace-prewarm' -ErrorAction SilentlyContinue
$pwWant = Join-Path $dst 'bin\prewarm-cloud.ps1'
if ($pwTask) {
  $pwArgs = "$($pwTask.Actions[0].Arguments)"
  $pwNamed = [regex]::Match($pwArgs, '-File\s+"?([^"]+?)"?(\s|$)')
  if (-not ($pwNamed.Success -and ($pwNamed.Groups[1].Value.Trim().TrimEnd('\') -ieq "$pwWant".TrimEnd('\')))) {
    $pwExe = if ("$($pwTask.Actions[0].Execute)") { "$($pwTask.Actions[0].Execute)" } else { 'pwsh.exe' }
    $pwFixed = if ($pwNamed.Success) { $pwArgs.Remove($pwNamed.Groups[1].Index, $pwNamed.Groups[1].Length).Insert($pwNamed.Groups[1].Index, $pwWant) } else { '' }
    if ($pwFixed) {
      Set-ScheduledTask -TaskName 'codai-workspace-prewarm' -Action (New-ScheduledTaskAction -Execute $pwExe -Argument $pwFixed) | Out-Null
      $pwNow = [regex]::Match("$(@((Get-ScheduledTask -TaskName 'codai-workspace-prewarm').Actions)[0].Arguments)", '-File\s+"?([^"]+?)"?(\s|$)')
      if ($pwNow.Success -and ($pwNow.Groups[1].Value.Trim().TrimEnd('\') -ieq "$pwWant".TrimEnd('\'))) { 'task codai-workspace-prewarm -> bin\prewarm-cloud.ps1' }
      else { "WARNING: task codai-workspace-prewarm still names '$($pwNow.Groups[1].Value)' - re-point it by hand (bin\prewarm-cloud.ps1 -RepairTask from the installed copy)" }
    } else { "WARNING: task codai-workspace-prewarm names no -File, so it could not be re-pointed: $pwArgs" }
  }
}
"install: $($drift.Count) file(s); backup in $bk"
