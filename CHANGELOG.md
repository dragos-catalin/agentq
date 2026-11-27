# Changelog

All notable changes to `@codai/agentq`. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased] - ps scheduler v3 (ADR 0002)

### Added

- MCP: the whole surface is reachable through the server, not only the daemon. 23 new tools - `agentq_since`/`_status`/`_run`/`_note`/`_break`/`_propose`/`_workspace`, `agentq_lease`/`_unlease`/`_land`/`_publish`/`_sweep`, `job_start`/`job_wait`/`job_list` and `cloud_submit`/`cloud_status`/`cloud_workspaces`/`cloud_suspend`/`cloud_resume`/`cloud_reset`/`cloud_log`/`cloud_result` - each wrapping the script a person would call, with named parameters, the script's own exit codes, and a required reason on the destructive ones. Spawning goes through the new `src/pws.ts` (argv arrays, captured pipes, `pwsh` with a `powershell.exe` fallback, a timeout that reports code 124). 30 tools in total; `buildMcpServer` is exported so a test can register against an in-memory transport.

- `-Lane interactive|quick|gate|heavy|batch` and `-Priority` on `run` / run-build: waiters are ranked by priority with aging instead of strict FIFO.
- `agentq-cloud.ps1 -Status -Json`: one read-only JSON document describing every workspace in the cloud registry - state, heartbeat age, idle seconds and queue depth per workspace, plus the names of any the registry could not reach and why. A value that could not be measured is `null`, never `0`, so a client cannot mistake "not measured" for "idle". This is the machine-readable half of `status`, and what a client reads instead of parsing the human table (Vitals' Projects tab, vitals ADR 0050). The MCP's `cloud_status` can ask for the same document with `json: true` instead of one workspace's table. Read-only `gcloud` reads only: nothing is started, stopped, resumed or queued, and the human `status` output is unchanged.
- Atomic multi-resource grant: a run waiting for `build:machine` no longer holds `build:<repo>`.
- Soft slots: quick-lane burst slots; non-batch jobs run beside batch holders (batch runs at Idle priority).
- Idle-yield watchdog: a holder whose process tree is idle stops counting against the machine cap (`idle-yield` / `idle-resume` events).
- `agentq bump`, `agentq burst`, `agentq propose` overrides — reason required, journaled, rate-limited.
- `agentq metrics` (wait/hold p50/p90 per resource × lane × kind) and `agentq rotate` (journal archive; automatic in sweep).
- Journal: `acquired`, `waitSec`/`holdSec`/`lane`/`kind` on done/fail, `commit-failed`, `land-push-failed`.
- Config knobs in `agentq-config.json` (machineCap, quickBurst, agingMin, idleYieldMin, idleCpuSec, bumpMax, burstMax, burstMaxMin, overridesPerHour, journalRotateMB).
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
