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

### Changed

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
