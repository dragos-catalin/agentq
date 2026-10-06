# Changelog

All notable changes to `@codai/agentq`. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

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
