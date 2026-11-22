# Changelog

All notable changes to `@codai/agentq`. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased] - ps scheduler v3 (ADR 0002)

### Added

- `-Lane interactive|quick|gate|heavy|batch` and `-Priority` on `run` / run-build: waiters are ranked by priority with aging instead of strict FIFO.
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
- `install wiring` gained two file-level checks and their mutation: every suite's own `-File` is a map key (a
  suite the installer never carries cannot gate anything - the `test-land-default-gate.ps1` gap, generalised),
  and every map **destination** is unique and resolves inside the install root (a duplicate silently loses a
  file, an escaping one writes outside `~/.copilot`). Measured on today's map: 98 destinations, 52 suites.

### Fixed

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
