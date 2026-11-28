# Changelog

All notable changes to `@codai/agentq`. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased] - ps scheduler v3 (ADR 0002)

### Added

- The hook cost ledger names the agentq **verb**, not only the tool: a row is now
  `{ts, ms, startMs, tool, verb, deny, session}` and `sat-report.ps1` sums the day per verb. The question a
  per-verb budget cannot answer today is "what does one `status` cost beside one `land`" - a measured day held
  10 463 `run_in_terminal` rows and no verb, so the round-4 table had to be collected by hand with a `git.cmd`
  shim on PATH. The verb comes from one regex over the raw payload, for the tools that carry a command only (a
  megabyte `apply_patch` payload is not scanned), with no `ConvertFrom-Json` and **no process spawn** - the
  metric of that round IS the spawn count, so instrumentation that spawned would erase its own measurement. The
  field is always present and empty when the command runs no agentq, when the tool runs no command, and when a
  flag precedes the verb (`agentq.ps1 -Purpose x land` records nothing rather than guessing `x`); its value is
  bounded to `[A-Za-z0-9-]{1,24}` and lowercased, so it can never carry a quote or a backslash into the JSON
  line. `sat-report.ps1` prints the per-verb table (calls, served, spawned, avg ms) plus
  `VERB COVERAGE rows=… with-verb=…` from the same single pass over the file; `agentq-slo.mjs` and
  `agentq-prune.ps1` needed no change (`JSON.parse` by name, and a file-NAME match). Guards: `sat-report` 16/16
  with the three `status` fixture rows in three different cost classes, and `hook-pre` gains 11 cases - the six
  shapes that must be recognised (installed path, repo path, quoted path, `-v2`, the node CLI, uppercase) and
  the four that must stay empty (another command, a script named but not run, a flag before the verb, a read
  tool), plus "every line of the run carries the field".
- `agentq land` refuses a topic whose merge resolution would silently revert `origin/<onto>`. The class is real
  and was an inch from landing on 2026-11-27: a branch whose tip is a merge of a base already inside main, hand
  resolved back to the old content - it deleted `ps/tests/test-agentq-gate-machine.ps1` (143 lines) and cut
  `run-all.ps1` by 12, `guard-tooluse.ps1` by 18/-3, `install.ps1` by 4, `CHANGELOG.md` by 13. The precheck that
  existed only sees `merge-tree` CONFLICTS, so a clean merge that drops main's bytes was invisible to it. The
  rule is deliberately **not** "the topic merged a base that is already in main" - merging `origin/main` into
  your branch is a legitimate workflow and that naive rule refuses it (fixture B pins that). It fires only when
  the merged tree loses content `origin/<onto>` still has, on a path whose origin side is unchanged since the
  merge base, where the tip's resolution deviates from the clean auto-merge of its own parents. Bounded to a
  handful of git calls, only when the tip is a merge, and none of them on the `lease`/`status`/`since` paths;
  escape hatch `AGENTQ_LAND_NO_STALEBASE=1`, named in the refusal and journaled as `land-stale-base`. Suite:
  `ps/tests/test-land-stale-base.ps1` - four fixtures (reverting branch refused and naming the path; a
  legitimate merge of main allowed; an intentional deletion allowed; a real two-sided merge allowed), and
  mutation-tested: disabling the check turns fixture A green, so it is not decorative.

- MCP: the whole surface is reachable through the server, not only the daemon. 23 new tools - `agentq_since`/`_status`/`_run`/`_note`/`_break`/`_propose`/`_workspace`, `agentq_lease`/`_unlease`/`_land`/`_publish`/`_sweep`, `job_start`/`job_wait`/`job_list` and `cloud_submit`/`cloud_status`/`cloud_workspaces`/`cloud_suspend`/`cloud_resume`/`cloud_reset`/`cloud_log`/`cloud_result` - each wrapping the script a person would call, with named parameters, the script's own exit codes, and a required reason on the destructive ones. Spawning goes through the new `src/pws.ts` (argv arrays, captured pipes, `pwsh` with a `powershell.exe` fallback, a timeout that reports code 124). 30 tools in total; `buildMcpServer` is exported so a test can register against an in-memory transport.

- `-Lane interactive|quick|gate|heavy|batch` and `-Priority` on `run` / run-build: waiters are ranked by priority with aging instead of strict FIFO.
- `agentq-cloud.ps1 -Status -Json`: one read-only JSON document describing every workspace in the cloud registry - state, heartbeat age, idle seconds and queue depth per workspace, plus the names of any the registry could not reach and why. A value that could not be measured is `null`, never `0`, so a client cannot mistake "not measured" for "idle". This is the machine-readable half of `status`, and what a client reads instead of parsing the human table (Vitals' Projects tab, vitals ADR 0050). The MCP's `cloud_status` can ask for the same document with `json: true` instead of one workspace's table. Read-only `gcloud` reads only: nothing is started, stopped, resumed or queued, and the human `status` output is unchanged.
- Atomic multi-resource grant: a run waiting for `build:machine` no longer holds `build:<repo>`.
- Soft slots: quick-lane burst slots; non-batch jobs run beside batch holders (batch runs at Idle priority).
- Idle-yield watchdog: a holder whose process tree is idle stops counting against the machine cap (`idle-yield` / `idle-resume` events).
- `agentq bump`, `agentq burst`, `agentq propose` overrides — reason required, journaled, rate-limited.
- `agentq metrics` (wait/hold p50/p90 per resource × lane × kind) and `agentq rotate` (journal archive; automatic in sweep).
- Journal: `acquired`, `waitSec`/`holdSec`/`lane`/`kind` on done/fail, `commit-failed`, `land-push-failed`.
- Config knobs in `agentq-config.json` (machineCap, gateMachineCap, quickBurst, agingMin, idleYieldMin, idleCpuSec, bumpMax, burstMax, burstMaxMin, overridesPerHour, journalRotateMB).
- Post-land hook ([ADR 0008](docs/adr/0008-post-land-hook.md)): after `agentq land` has pushed, the pushed tree's `scripts/post-land.ps1` (when it exists) is started detached and hidden, once per push (a batch is one push), with `AGENTQ_POSTLAND_REPO`, `AGENTQ_POSTLAND_BRANCH` and `AGENTQ_POSTLAND_SHA`. It runs the pushed commit's copy, outlives the land's job object, and can neither fail nor delay the land. Journal: `post-land`, `post-land-failed`. `AGENTQ_NO_POSTLAND=1` turns it off.
- Orchestrator stage 0 ([ADR 0009](docs/adr/0009-orchestrator-daemon-tasks-control-plane.md), tracker OQ-001 to OQ-012; details in [docs/orchestrator-stage-0.md](docs/orchestrator-stage-0.md)): chat keep-alive for slot leases, land pre-gate in the slot and a green ledger, admission by load and by owner presence, `agentq probe`, `prune` and `doctor`, more numbers in `agentq slo`, `hook-pre.ps1` installed from this repository, an installer that merges the config, and the suites in CI.
- `git-autosync -ParkConflictingCommits` (fleet config `autosync.parkConflictingCommits`): a local commit
  whose patch conflicts with upstream is parked exactly like a twin - backed up (local ref + a push verified
  with `ls-remote` before anything is dropped), dumped as a `.patch` beside a `MANIFEST.tsv` in the park
  root, then dropped from the branch, so the clone moves instead of refusing until its owner rebases.
  Default off: the refusal is unchanged, and `-WhatIf` reports what would be parked. 2026-11-18: codai's
  shared main sat 15 commits ahead for days with autosync refusing, and no one owned the rebase.
- A repo's own land gate: `landGate.<repo>` in `bin/agentq-config.json` (agentq runs its suite list) and
  `gateSuites.<repo>` for the list itself, resolved by `run-all.ps1 -RepoSuites` (exit 2 on a missing key or a
  name that is not a suite, never a silent run-everything). `install.ps1 -RepoSuites` runs the same list before
  installing, so "the suites we run" has one home instead of an agent's scratch script. The static guard
  `install wiring` compares the suite table with `install.ps1`'s map; it found 8 files a gate suite needs that
  the map never carried (`bin\shared-clone-janitor.ps1` and 7 test files), and its first run proved main was
  broken for every clean checkout: `run-all` registered `release phase honesty` and `install` mapped its file
  while the file itself stayed untracked since 9541a44, so a fresh clone threw
  `install: tests\test-release-phase-honesty.ps1 is in the map but not in this checkout`.

- The pre-gate also runs for a land started from the **shared clone**: with no tree of its own it takes a
  scratch slot for the length of the gate and gives it back (journal `land-pregate-slot-released`), and when no
  scratch slot is free, or the one it got has a failed install, it skips the pre-gate with the reason journaled
  instead of gating an unprepared tree or silently letting the queue pay for the discovery. Config
  `landPregateFromMain` (default true), `landPregateScratchWaitMin` (default 1, 0 = skip at once). Measured the
  day before: a land of the gate slice spent its whole queue-side gate on a defect that came from main, which an
  in-slot pre-gate catches before queueing.
- `agentq slo` counts that released slot per repo (`pregateSlotReleased`, table column `preSlot`): a land that
  took a scratch slot for its pre-gate is visible in the ticket summary instead of only in the journal.
- `install wiring` gained two file-level checks and their mutation: every suite's own `-File` is a map key (a
  suite the installer never carries cannot gate anything - the `test-land-default-gate.ps1` gap, generalised),
  and every map **destination** is unique and resolves inside the install root (a duplicate silently loses a
  file, an escaping one writes outside `~/.copilot`). Measured on today's map: 98 destinations, 52 suites.
- `agentq-cloud.ps1 -Status -Json`: a **read-only** JSON surface for every devcloud workspace in the
  registry (`{"v":1,"at":<ISO>,"workspaces":[{ws,vm,project,zone,state,heartbeatAt,heartbeatAgeSec,
idleSec,queueDepth}],"unavailable":[{ws,why}]}`), on stdout and nothing else - the verb Vitals waits
  for (vitals ADR 0050, `DevcloudPanel.tsx`, docs/codwen-projects-page.md §6.3). `state` folds the VM
  status (`suspended`/`stopped`/`suspending`) with the heartbeat (`idle`/`busy`); a figure that cannot be
  measured is `null`, NEVER `0`, and a workspace with no readable heartbeat is `null` there and named in
  `unavailable` with the reason. Only `gcloud compute instances describe` and `gcloud storage cat|ls` -
  no suspend/resume/reset/submit and no journal write. `-Status` without `-Json` is the human table of
  before, unchanged. New suite `tests/test-agentq-cloud-status.ps1` pins the shape, the null rule (a
  mutation that turns a missing heartbeat into `0` is red) and the `ConvertFrom-Json` round-trip.

### Fixed

- **A `guard format` worker could die mid-shard and leave the gate red with no failing assertion behind it.**
  Measured in the cloud land-gate pool on 2026-11-28: the run that took `sec=14` (against `sec=6` for the two
  green pool runs either side of it) reported `guard format exit=1 pass=53 fail=2` as `FAIL group block-3
  exited non-zero exit=1` plus `FAIL required check not exercised: case prettier --write --config (no cfg)` -
  one check short of 54, and the missing one was the LAST case of the last shard. A worker writes its id file
  from its own `finally`, so a case that never runs is a check the coverage ratchet can never see, and the
  gate goes red for something that was never asserted. The shape is a spawn that never happened: `& $Exe`
  raises a TERMINATING error when the child cannot be started, and the `$ErrorActionPreference = 'Continue'`
  that `Hook` restores for the call does not cover it. Every case now goes through `Hook-Case`: **retry once**
  - a real regression throws on both attempts, a resource hiccup does not - and if it throws twice, **FAIL
  that case with the exception type and message**, reporting BOTH of its ids so a warn case cannot also trip
  the ratchet. Mutation-checked in a copy: forcing both attempts to throw gives 43 FAIL lines naming
  `RuntimeException: synthetic spawn failure` with **zero** `required check not exercised` lines, and forcing
  only the first attempt to throw still gives `checks=54 pass=54 fail=0`.

- **The `PowerShell suites` job was red on `main` for four independent reasons, none of them a defect in the
  code it judged.** Baseline run 46080801888 finished `suites=92 failed=4` on a commit whose tooling was fine,
  so every land after it inherited a red it did not cause. (1) **`jobs`** pinned the sync contract at 14
  properties while the contract has carried 15 since 2026-11-25 (`agentq-jobs-lib.ps1:224` names `placement`),
  so the exact-field `Compare-Object` always found a difference; `placement` is now in the list. (2) **`worktree
v2`** read the process table with `-ErrorAction SilentlyContinue`, so a failed or degraded CIM query produced
  an EMPTY list - "no process references this slot" for every slot - and a slot whose process was very much
  alive was parked on the runner. The read is now fail-closed in one place (`Get-ProcLineMap` + `InUseReason`):
  an unreadable table, or zero rows without an exception, means IN USE and the report says which. The fixture
  no longer polls the same facility the guard uses to see its sleeper: the sleeper writes a marker only it can
  write, and the assertion requires both the slot to survive and the output to name it. (3) **`git-autosync`**
  read the doctor's exit code through `pwsh -NoProfile -Command "& '<script>'"`, which maps a legitimate
  `exit 3` to 1 (measured: the same script gives 3 through `-File` and 1 through `-Command`, while an `exit 0`
  script gives 0 both ways), so the assertion was unfalsifiable for the one verdict it exists to accept - on a
  hosted runner, which has no scheduled task, the doctor legitimately reports FAIL. It now uses `-File`, and the
  doctor itself wraps its report so a terminating error becomes `FAIL doctor could not complete: …` and exit 3
  instead of PowerShell's default 1; new control 13g forces exactly that line to throw in a copy and requires
  `DOCTOR:` and an exit code of 0 or 3. (4) **`autosync wip snapshot`** builds its mutation baseline from
  history (`git log -S`), which `actions/checkout`'s default `fetch-depth: 1` hides, and the red blamed a
  missing `*.prefix.bak`; the job now fetches full history (the repo is small) and the message names the shallow
  checkout and its fix. All four are pinned by an `Ok`/`Check` that reports the value it judged, so the next red
  of this kind carries its own diagnosis.
- **`sat-report.ps1`'s classifier suite existed and ran nowhere.** It was in neither `ps/tests/run-all.ps1`'s
  suite map nor `ps/install.ps1`'s, so the `VERB COVERAGE` assertions that came with the per-verb ledger could
  never fail - a guard nobody executes is a comment. Nothing audited the two lists in that direction (the
  README's "each `test-*` file in this folder is one suite" is a description, not a check), and the suite had
  never been reachable by name either. Registering it in one list and not the other is the same defect one step
  over, which is how it was caught: `install wiring` went RED on all three of its checks (`1 missing:
test-sat-report.ps1`, "every suite -File is a map key", "`gateSuites.agentq` is a valid, fully installed gate
  list") and GREEN at `pass=19 fail=0` once the file was mapped. The suite resolves its subject as
  `$PSScriptRoot\..\bin\sat-report.ps1`, which is exactly the installed layout, so `bin\sat-report.ps1` and its
  test are mapped together. Proven by running the three suites through the sanctioned runner
  (`run-all.ps1 -Only 'hook pre,sat report,install wiring'`): `hook pre` 60/60, `sat report` 16/16,
  `install wiring` 19/19, `RUNALL_EXIT=0`; before the map edit the same command ended `failed=1`.
- **Nine `gateSuites.agentq` suites could never be SKIPPED, because the pool's input map had no entry for
  them.** `Select-AqSuites` fails open on an unknown name: with no globs it always runs the suite, so every
  gated change paid for `lease spawns`, `land capacity`, `land stale base`, `agentq reclaim`, `agentq approve`,
  `takeover chat`, `args comma`, `gate input selection` and `agentq timings` no matter what had actually
  changed. The map now has **44 entries for the 44 suite names (0 missing, 0 extra)**, each pointing at the
  module its suite actually drives, and the proof run reports `Proved=True run=2 skip=42`: **nine suites moved
  from "always runs" to "skippable"**, measured per name by touching each glob and asserting the suite is
  selected (`pass=18 fail=0`).

- **`since` reaped dead tickets and ate the caller's lease-loss notice, although the brief calls it
  READ-ONLY.** It ends in `Show-Status`, and it was not in the `$script:ReadOnly` set, so it ran as a working
  verb: `Get-Live` dropped every dead ticket before `agentq sweep` could report it, and `Show-LeaseNotices` /
  `Show-MessageNotices` consumed the notice the caller was supposed to see on its next working call. The verb
  is the FIRST call of nearly every task boot, so the loss was fleet-wide and silent - and `Register-Agent`
  already excluded `since`, i.e. the code was half-way to the documented contract. `since` is now in the
  read-only set, which also stops it rewriting the machine capacity, sampling the adaptive cap, dropping an
  expired burst and sampling the load probe. Session liveness is unchanged (line ~2674 renews the session for
  `since` explicitly). Found by the new guard in `ps/tests/test-status-readonly.ps1`, not by reading the code:
  the suite went 3 FAILED with the verb as it was and ALL PASS with it moved, on the same fixture.

- **`agentq since` spawned git twice to do one log.** `rev-parse --abbrev-ref '@{u}'` existed only to pick the
  NEXT spawn's argument, and its output was never printed. The log now asks git for the upstream itself
  (`log '@{u}'`), with the `HEAD` fallback keeping the no-upstream case at the same two spawns as before, so
  the change only ever removes one. Measured with a `git.cmd` shim first on PATH on the same fixture:
  **4 spawns before, 3 after** (`rev-parse` to resolve the repo + `rev-parse --abbrev-ref '@{u}'` + `fetch` +
  `log` -> `rev-parse` + `fetch` + `log`), with
  byte-identical output in both the has-upstream and the no-upstream case.

- A hung child in `ps/tests/test-lease-spawns.ps1` can no longer hang a gate. Every fixture child now has a
  bounded wait (override `AGENTQ_TEST_CHILD_BOUND_SEC`); on timeout the child is KILLED, its stdout, stderr and
  elapsed time are printed, the suite FAILS, and its `%TEMP%\aqspawn-*` tree is still removed (retried, and then
  asserted gone). Before this, the suite produced no verdict for hours while the 15-minute re-lease wait was
  live, so a red test looked like a wedged gate. Proven by pointing a child at `Start-Sleep 600`: 18 s to a red
  verdict with the diagnostic, instead of a hang.

- **Landing into the cloud pool waited the full three-minute staleness window on the first job after a
  suspend.** A resumed VM does not re-run its startup script, so a runner frozen across the suspend looks
  exactly like a healthy-but-busy one and the client only asked after `-StaleClaimMin` (3 min) had passed:
  measured 2026-11-27, land #5 spent 217 s in `queue->claim`, 180 s of it exactly that window and 37 s of
  reset+claim. The base of the heal doubling is now short (~30 s) **only when THIS run performed the
  wake**; a VM this run did not wake keeps the conservative floor, and `Test-CloudPeerBusy` still refuses
  to reset under a peer. New `-WakeFirstHealMin` / `cloudWakeFirstHealMin` (default 0.5 min); the policy
  is the pure `Get-HealFirstIntervalMin`, driven by `ps/tests/test-agentq-cloud-heal.ps1` (behaviour, not
  a text pin - the previous checks passed even with the three-minute window restored). Reachable from the
  MCP as well (`cloud_submit.wakeFirstHealMin`, the sibling of the already-exposed `staleClaimMin`).
- **`agentq` was silently opted OUT of land batching - the one repo whose gate is the entire 43-suite pool
  run (~11 min).** The default list is `codai` + `brivio`, so a repo named nowhere batches nothing, and two
  agents landing `agentq` at the same time run TWO full gates back to back: measured 2026-11-27,
  `fix/lease-reuse-hot-path` and `perf/lease-spawn-stale-base` gated 43 suites twice within four minutes,
  and the second land also paid 412 s waiting for `verify:agentq`. The shipped config now names
  `agentq`, so a holder absorbs up to three waiting land tickets of the same `-Onto` into ONE gate and ONE
  push (bisected if the batch fails, quarantined topics excluded). Pinned by `ps/tests/test-land-batch.ps1`
  - deleting the key returns silently to the two-gates-per-pair behaviour.
- **A half-reverted `poolParallel` knob made every `agentq` land fail at the gate.** The revert removed the
  key from `agentq-config.json` but left the reader in `ps/devcloud/gate.ps1` and the assertions in
  `ps/tests/test-land-gate-pool.ps1`, so the composed tree a land gates on failed with
  `FAIL the repo pins a poolParallel in 4..8 ... value=` and refused the push (land #7: `LAND_EXIT=6`,
  22,7 min and 43 suites spent, nothing pushed). Restored as ONE consistent state: the key is back, pinned at
  **4** - the width measured tonight (`-Parallel 4` vs `8` = 1035,7 s vs 1049,2 s, i.e. noise, so widening the
  pool is not the lever) - the reader keeps its rule-C-safe position AFTER the dot-source re-assert, and the
  assertions pass again (`land gate pool` 52 pass, was 51/1).
- **A re-lease that NAMES a slot my own session already holds waited out the whole scratch staleness bound
  (15 min).** `-Slot scratch-N` skipped D5's reuse-before-renting fast path, which only fired for an UNNAMED
  request: it fell into `New-Lease`, found the slot held by my own still-fresh session and NOT stale, and
  polled until `leaseScratchIdleMin` (15 min) expired it - every poll hand-building a string of every held
  lease. Measured in `ps/tests/test-lease-spawns.ps1`: **905 s** at `-Parallel 4` and **906 s** at `-Parallel 8`
  (constant, so contention is not the cause), while every other suite in the same runs is 2-60 s - that ONE
  wait was **87% of the devcloud pool gate (1044 s)** and of every land pre-gate that rents through it.
  `Get-SlotReuse` now takes the explicit slot, so a named re-lease of my own CLEAN slot returns at once (the
  same reuse, only reached through `-Slot`). `Test-GitClean` still refuses a dirty slot, which keeps the old
  wait-then-take-over path and its backup, and `-Wait` is still excluded, so the pre-gate - which RESETS the
  slot it rents - is unaffected. Verified: the same suite on the same machine, **10 s**, `PASS (11)`
  (906 s -> 10 s), with the reuse leg still resolving the repo in ONE combined `rev-parse` and ZERO
  `worktree list`/`prune` spawns.
- **Nothing bounded a genuinely wedged pool suite.** `devcloud/pool-suites.ps1` called `run-all.ps1` with no
  `-TimeoutMin`, so a hung suite held its pool slot until the job's own infrastructure timeout. It now passes
  `-TimeoutMin 20` - ~10x the honest worst case (slowest suite 60 s, whole 16-suite run < 2 min) - so a wedge
  is reported as a failed suite WITH its log (the `-LogDir` echo) instead of a silent hold. The static ratchet
  in `test-land-gate-pool.ps1` now pins both `-TimeoutMin` and an explicit `-Parallel`, so changing either is
  a deliberate edit rather than an accident.

- **`With-Mutex` capped the wait at 30 s and then threw the answer away.** The `WaitOne(30000)` result was
  discarded, so a caller that LOST the race sat in the wait for the full 30 s of dead time and then ran the
  body anyway - the mutex is not held by then, so the 30 s bought nothing at all. Every `land capacity` pool
  run reported `sec=30` while its own assertions take ~1 s, and a local land that contended twice took
  **64.7 s** = 2x30 + work. The wait is now bounded by `$env:AGENTQ_MUTEX_WAIT_MS` (default 30000, so
  production behaviour is unchanged), a `mutex-timeout` journal event records an exhausted wait, and a test
  can shrink the bound instead of sleeping 30 s to exercise the timeout path.
- **`SLOT SHARE` printed the bare slot name, so the same slot in two repos read as one duplicate lease.**
  Slot names repeat per repo (`codai\scratch-1` beside `marcai\scratch-1`); a 2026-11-27 report of "duplicate
  leases" was two repos with the display as the only defect. It now prints `[<repo>/<slot> <role>]`.
- **`devcloud/gate.ps1` hardcoded the pool suite concurrency in four places** (the `-LocalOnly` run, its
  echo, and both `$inner` argv shapes). There is now a `-PoolParallel` parameter (default 4, the value every
  measurement was taken at) threaded through all four, and a help entry recording that 4 -> 8 is inside the
  noise because the suites are contention-bound on one pool checkout. The parameter also exposed a scoping
  trap worth naming: gate.ps1 dot-sources `ps/bin/agentq-suite-inputs.ps1`, whose OWN `param()` block
  declares `[int]$PoolParallel = 4` - and dot-sourcing does not scope a sourced script's parameters, it
  assigns them into the CALLER's scope. So `-PoolParallel 7` was accepted and then read back as **4**, with
  no assignment anywhere in the file to grep for (the variable printed 7 at the top of the script and 4
  thirty lines later). The knob is re-asserted from `$PSBoundParameters` after the dot-source, and a static
  ratchet fails the suite if that re-assert is ever removed - otherwise the parameter is silently inert.

- **The scheduled terminal reap never finished, so no terminal was ever reaped.** `reap-terminals.ps1` called
  `console-signal.ps1` with no timeout; console-signal wedges inside `AttachConsole`, so the reaper blocked there
  **before** the grace/force steps, and every 30-minute run leaked two processes that never exited (11 stuck pairs,
  +2 per run = 96/day) while the population stayed flat at ~460 shells / ~46 GB. The signal step is now bounded by
  the new `-SignalTimeoutSec` (default 25): `Start-Process -PassThru`, `WaitForExit(ms)`, `taskkill /T /F` on
  timeout, and the reap continues. Verified live: the same command that had run **477 s and produced nothing** now
  finishes in **79 s** with `killed: 278, forced: 278`, freeing **279 processes and 26 GB**.
- `console-signal.ps1`'s Ctrl+C does not actually close an idle shell, so every reap is a force-kill
  (`graceful: 0, forced: 278`). Not fixed - noted so nobody reads `forced` as a defect of the timeout above;
  force-killing is acceptable because chat foreground terminals and terminals younger than `-MinAgeHours` are
  never candidates.

- `agentq land` (and `publish -Land`) now reaps its own auto-generated `publish/*` SOURCE branch after a
  landed push - and only that: a human-named branch, the target itself, and the branch a working slot is on
  are kept. Origin had accumulated **466** `publish/*` branches, **201** provably already merged into `main`
  (every commit's patch-id present); `publish` mints `publish/<session>-<ts>` and nothing ever deleted it
  (one session alone left ~100). A topic absorbed into a batch is reaped by the holder that landed it (the
  waiter returns early on the batch result). A failed delete is journaled (`land-reap-failed`) and never fails
  the land; the delete uses `git push --no-verify` because husky's client pre-push runs a CODE gate
  (`scripts/ci/check-rollout-vm-hardening.mjs`) that cannot apply to deleting a ref. Output: one
  `reaped publish/x (landed into <target>)` or `kept publish/x: <reason>` line.
- Land pre-gate no longer stands aside for a dirty CALLER slot. A land started from the slot its chat is
  still working in has uncommitted files by definition, and the pre-gate used to SKIP there - which pushed
  the whole gate (p50 7 min, p90 20-40 min, max 3 h) back INSIDE the cap-1 `land:<repo>` mutex. Measured:
  171 of the `land-pregate-skipped` journal lines in 48 h said exactly "the slot has uncommitted or untracked
  files" (138 codai + 33 brivio), and the queue holder was seen spending 49 of its 99 minutes running gates
  under the mutex. It now rents the resettable scratch slot for the gate (the same `Get-PregateScratchSlot`
  the shared-clone path uses; reset to `origin/<onto>` so it can never judge files that are not the topic's),
  leaves the caller's tree untouched, and releases it when the gate is done. It skips only when no scratch
  can be had either.
- Shared-clone guard (ADR 0004): `sharedCloneMode: refuse` now **really denies** a source write instead of
  returning `WARNING (allowed)`. The axiom D-40 soft path downgraded the documented refusal, and the journal
  proves the writes went through anyway: 710 `shared-write` events for codai (mode `refuse`) between
  2026-11-12 and 2026-11-18 - which is exactly what kept the shared clone drifting and `git-autosync`
  refusing (2026-11-18: 15 unpushed commits, 174 dirty files behind a "refuse" that did nothing). The
  refusal now uses `Deny-Exit -HardBlock` (skips the D-40 downgrade); an `axiom-override:` no longer lifts
  it, and the journaled `CODAI_SHARED_CLONE_WRITE_OK=1` is the only one-off escape. `warn` and `off` are
  unchanged, and docs/plan/markdown/.copilot-tmp stay writable in the shared clone.

### Changed

- `agentq lease` resolves its result with one git spawn fewer per arm: `head` is taken from the repo
  resolution's existing combined `rev-parse` (which now also asks for `--short HEAD`) instead of a second
  `rev-parse` of its own. Measured in `ps/tests/test-lease-spawns.ps1` on the same slot in the same session:
  **fresh 8 -> 7, reuse 4 -> 3**. `head` is the short HEAD of the repo the lease was resolved against: it is
  display-only - no machine reader, and not a field of the on-disk lease record - but a caller that leases from
  OUTSIDE a slot it already holds now sees its own HEAD there rather than that slot's. `Get-RepoInfo` also
  decides "is this a repo" by the number of output lines rather than `$LASTEXITCODE`, because an unborn HEAD
  makes the new directive exit 128 while still printing the lines it always printed.

- `agentq status`, `log`, `metrics` and `doctor` only read the state folder; dead tickets are reaped by working verbs and by `sweep`.
- The guard honours `sharedCloneMode` under Windows PowerShell 5.1 (it was ignored in the editor).
- A chat that releases its own slot from a script file is recorded as the releasing chat (`byChat`); before, only an `unlease` typed in the command counted.
- The repository passes `prettier --check .` again (formatting only): four committed files (`ps/tests/README.md`
  and three documents under `docs/`) were not in prettier 3's canonical form, so `pnpm lint` - the first step of
  CI - was red on main. Measurement trap behind the miss: prettier 3 honours `.gitignore`, so a `--check` run on
  a path under `.copilot-tmp/` prints "All matched files use Prettier code style!" for _any_ content; the verdict
  needed `--ignore-path` pointing at an empty file AND a control file that must fail.
- run-build default `-TimeoutMin` 25 → 240; deploy-clean release-slot lease wait follows `QueueTimeoutMin`.
- Lease activity includes git index/HEAD writes in the slot (work from another shell no longer expires).
- agentq-sync publishes v3 holders first so the hub's position model stays correct.
- **One measured budget for task and scratch slots, instead of two independent ones.** `Get-SlotRoom`
  derives the machine-wide room from the live numbers (`(free disk - 20 GB) / 8 GB` and
  `(free commit - minFreeCommitGB) / 2 GB`, whichever is smaller) and `Get-TaskSlotBudget` subtracts the
  machine-wide scratch leases, so a scratch slot and a task slot now cost the same room and cannot
  together exceed the machine. Scratch floor 5 -> 8, ceiling 8 -> 12. A refused scratch lease reports the
  measured offer and room instead of a bare "it is still held", and the refusal is journaled
  (`scratch-alloc-denied`, `slot-admission-denied`) only when the allocation is really refused.
  Measured live 2026-11-26: 26/26 reported slots were in fact 20 scratch + 15 task + 1 land against a
  measured room of 30, i.e. the machine was over-subscribed rather than leaking slots.
- **The lease chat grace is read from config instead of being hardcoded.** `agentq-slo.mjs` fixes
  `TARGETS.liveChatIdleMin` at 30, `agentq-v2.ps1` says in a comment that 30 must match it, and the code
  default had already been raised to 30 - but BOTH config copies still pinned `leaseChatGraceMin: 20`, and a
  key present in the config beats the default, so that raise had never taken effect. A lease whose chat had
  been idle 20-30 min was therefore expired by the reaper and then counted by the SLO as an avoidable loss
  (`slotsLostLiveChat`, target 0, 34 in OQ-001). Both copies are now 30, and the two `status` display sites
  read the same knob (`$chatWin`) instead of a hardcoded 30, so the table can no longer call a lease `chat`
  one moment before the reaper takes it. Suites: `test-agentq-lease-liveness.ps1` (13 checks) ALL PASS,
  `test-lease-chat.ps1` (40 checks) ALL OK.
- **`agentq scale` - one step to see why `N/N` is not a small pool.** The slot budget is derived from the
  machine and re-measured on every call; an agent that reads `26/26` takes it for a fixed, too-small setting
  and asks for more slots. The new READ-ONLY verb prints the formula with the live numbers (disk and commit
  room, the task cap, the scratch offer, what is held) and states the part that is easy to misread: a
  per-repo `N/N` is the LANES, not the machine, because `build:<repo>` tickets are independent and only
  `build:machine` (max 2) is shared. `-Json` returns the same as an object; `agentq help scale` documents it.
- **Six `git` processes fewer per re-lease, and a re-lease no longer pays for a registration check.**
  `Get-RepoInfo` asked `rev-parse` twice (top-level, then common dir); the two directives are independent,
  so one process now prints both lines in argument order - a saving paid at the start of EVERY verb, not
  only `lease`. A slot that is already registered is recognised by reading `gitdir:` out of the slot's own
  `.git` file instead of running `git worktree list --porcelain`, and the unconditional `git worktree prune`
  moved into the branch that actually adds a worktree. Measured with a `git.cmd` shim, same slot, 6 leases:
  10.33 -> 7.5 `git` spawns per lease (-27.4 %), `worktree list` 6 -> 0, `worktree prune` 6 -> 1. Pinned by
  the new `ps/tests/test-lease-spawns.ps1` (11 checks), which fails if the combined directive is split and
  whose mutation arm proves the check is not vacuous.
- **A `lease` no longer hands a repo-info OBJECT to `git` - the reason the message notices degraded in
  silence.** `$repo` and `$Repo` are ONE variable in PowerShell (names ignore case), so a script-scope
  `$repo = Get-RepoInfo $Repo` leaves `$Repo` holding the object; the next `Get-RepoInfo $Repo` stringified
  it into `-C "@{Top=...; Common=...; Name=...}"`, which git rejects, so the caller got `$null` and said
  nothing. `Get-RepoInfo` now returns a repo-info object handed to it, which fixes the class in one place
  rather than the one call site. Found by the shape assertion above, red on the re-lease arm before the fix.
  The same bug cost every READ verb that assigns `$repo` before a callee reads `$Repo`, so the fix is not
  lease-only: measured with the same shim, `git` spawns per run are `status` 2 -> 1 (-50 %), `since` 6 -> 4
  (-33 %, and its `-C "@{...}"` line is gone) and `who` 0 -> 0. The suite also deletes its
  `%TEMP%\aqspawn-<pid>-<hex>` fixture tree in a `finally`, guarded by an exact match on the leaf it minted
  from its own pid, because a killed run used to leave that tree behind for the nightly sweep and a pattern
  guard would have let one of two concurrent runs delete the other's live tree.
- **A machine-wide bound on heavy gates (`gate:machine`), pinned by a suite whose mutation arm goes red.**
  A heavy land pre-gate took only `verify:<repo>` - cap 1 PER REPO - so N repos ran N ~90-fork gates at
  once (13 concurrent gates measured on this machine, 2026-11-26). `Expand-Resources` now adds
  `gate:machine` to any `verify:*` primary in the gate/heavy/batch lanes, and its cap is read from config
  (`gateMachineCap`, default 3, floor 1) rather than from the queue's sticky `capacity` file: a sticky file
  must not be able to raise a machine-wide bound, and a bound that stops all progress is not a bound. A
  plain `build:machine` run is never gated by it. Pinned by the new
  `ps/tests/test-agentq-gate-machine.ps1` (16 checks in 7 cases, ~51 s, deliberately NOT in
  `gateSuites.agentq` because it spawns and waits on holders): blinding the `Get-Capacity` branch turns it
  red on exactly the two checks that state "the cap is config, not a file" - raising `gateMachineCap` to 2
  must admit the same command, and a hand-written `queues\gate_machine\capacity` of 9 must be ignored
  (3 FAILED, exit 1) - while the floor-1 case stays green, so the arm is a semantic mutation, not a syntax
  break.
- `gateMachineCap` is pinned explicitly in the shipped `agentq-config.json` (3, the value that was
  previously only the code default), and `gate:machine` is listed in the README's resource list and in
  `spec/acp-lock.md`'s resource conventions, so the resource is discoverable outside the source tree.

### Security

- `zod` 4.6.7 (GHSA-mrhx-c7xc-m3w5) and the fixed releases of five transitive packages; `pnpm audit` is clean (it reported 14 findings, three of them high).

## [0.2.0] - 2026-10-06

### Added

- `agentq hook <claude|codex|copilot|vscode>`: pre-tool hook that reads the agent's payload on stdin and routes build, install, deploy and commit shell commands through `agentq run` (mode `rewrite`, default) or denies them with the command to run instead (mode `deny`). Frozen or blocked resources are denied in every mode. Fails open: on any error it prints nothing and exits 0.
- `agentq hook-config <agent>`: prints the snippet that registers the hook for Claude Code, Codex, GitHub Copilot CLI or VS Code Copilot.
- Rules file (`$AGENTQ_HOOK_RULES`, `$AGENTQ_HOME/hooks.json`, `<repo>/.agentq/hooks.json`) for extra matches; a repository file can add rules or tighten to `deny`, never switch the guard off.
- Environment: `AGENTQ_HOOK_MODE`, `AGENTQ_HOOK_RULES`, `AGENTQ_HOOK_BIN`.
- Library exports for the pure hook functions (`decideHook`, `classifyCommand`, `buildRewrite`, `hookConfig`, ...).

## [0.1.0] - 2026-10-06

### Added

- ACP-Lock 0.1 daemon: FIFO tickets with capacity, leases, pid liveness, freeze marks and a hash-chained JSONL journal over JSON-RPC on 127.0.0.1 with a bearer token.
- CLI: `daemon`, `run`, `status`, `mark`, `break`, `note`, `log`, `verify-journal`, `mcp`.
- MCP server exposing the same operations as tools.
- Library: `connect`, `hold`, `call`, `startDaemon`, `Coordinator`.
