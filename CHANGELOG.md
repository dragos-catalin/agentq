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
- Orchestrator stage 0 ([ADR 0009](docs/adr/0009-orchestrator-daemon-tasks-control-plane.md), tracker OQ-001 to OQ-012):
  - Chat keep-alive: the per-tool-call hook binds a chat to the lease of a slot it works in and refreshes it on every later tool call of that chat. A chat active within `leaseDeadIdleMin` counts like a live owner shell. `status` shows `chatMin` and the state `chat`; `lease-expire` and `lease-break` carry `chats`, `chatIdleMin` and `byChat`. `AGENTQ_NO_CHAT_KEEPALIVE=1` turns it off.
  - Land pre-gate: `agentq land` run from a leased task slot runs the gate on the rebased result in that slot before it takes the land ticket; a failing gate exits 6 before the queue. Config `landPregate`, `landPregateRounds`; `AGENTQ_LAND_NO_PREGATE=1` turns it off. Journal: `land-pregate-ok`, `land-pregate-failed`, `land-pregate-skipped`.
  - Green ledger: a tree that passed a gate command is remembered for `greenTtlHours` (168) and is not gated again in the queue (`land-gate-skipped-green`). `AGENTQ_NO_GREEN=1` turns it off.
  - Admission by load: `agentq probe` measures the start latency of a trivial process. While the recent median is above `admission.probeMs`, no new task lease and no second gate, heavy or batch build is granted; a waiter held longer than `admission.maxHoldMin` is admitted anyway. The one build a saturated machine still starts is the first in rank, so a lower-priority waiter cannot start ahead of a higher-priority one. `status` prints the probe and the verdict. Journal: `admission-hold`, `admission-override`, and `loadWaitSec` on `acquired` and `lease`.
  - Agent limit by owner presence and night schedule (config `agentLimit`): the machine-wide limit on task leases can differ while the owner is at the keyboard, away, or away at night. Values that are not set mean `taskSlotsMachine`, so the default config changes no limit. `status` prints the limit in force and the reason. Journal: `agent-limit-hold`.
  - `agentq prune` (`-WhatIf`, `-Days`, `-All`, `-Json`): removes old agent, job, notice, release and batch files and idle queue folders; `sweep` runs it.
  - `agentq doctor` (`-All`, `-Src`, `-Json`): stale index locks, empty package-store folders, install and config drift, dead owners and keepers, old marks, state size, scheduled tasks.
  - `agentq slo` adds queue time, waits over 10 minutes, the land ticket hold, hook cost per day, start-probe buckets and slots lost with a live chat.
  - `ps/hooks/hook-pre.ps1` and its suite now live in this repository and are installed from it. The hook appends one cost line per call to `hooks/cost-<day>.jsonl`.
  - `ps/install.ps1`: `-Suites a,b` gates an install on chosen suites; `agentq-config.json` is merged (local values kept, missing keys added); `bin/agentq-install.json` records what was installed.
  - `ps/tests/run-all.ps1`: `-Only`, `-Skip`, `-List`, `-LogDir`, `-TimeoutMin`; the `ps` job in CI runs every suite on a Windows runner (it installs a pinned ripgrep release and checks its SHA-256, because the hosted image has none).
  - Shared clone: the shipped config sets `sharedCloneModeRepos` to `refuse` for the two repositories that have the most slots; every other repository keeps the advisory. An install merges the config, so a machine that already has the key keeps its own value.

### Changed

- `agentq status`, `log`, `metrics` and `doctor` only read the state folder. Dead tickets are reaped by working verbs and by `sweep`, not by `status`.
- A queue folder is created under the queue mutex, so `prune` cannot remove it between the check and the first write.
- The guard reads `sharedCloneMode` without a switch that Windows PowerShell 5.1 lacks; in the editor the configured mode was ignored before.
- The `release when done` line printed by `lease` names `agentq.ps1` (the old line named a file that cannot run on its own).
- `run-all.ps1` sets `AGENTQ_NO_ADMISSION=1` for every suite: a suite must not depend on how busy the machine is. The suites that test admission clear it and fake the probe.
- Tests: the `jobs` suite reaps a dead holder with `sweep` (it relied on `status` doing it); case 10b of `git-autosync` gives the upstream commit its own date (made in the same second as the local one it took the "replayed by hand" path and failed on a fast runner).
- run-build default `-TimeoutMin` 25 → 240; deploy-clean release-slot lease wait follows `QueueTimeoutMin`.
- Lease activity includes git index/HEAD writes in the slot (work from another shell no longer expires).
- agentq-sync publishes v3 holders first so the hub's position model stays correct.

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
