# agentq

A queue for coding agents that share one machine or one repository.

## Problem

Run two or three agents in the same repo and they collide on things worktrees do not isolate: the incremental build cache (`.next`, `.turbo`, `*.tsbuildinfo`), the package store during `pnpm install`, the git index during a commit, the deploy target, the machine's RAM. Each tool has its own lock file, if any. Those locks race, carry no reason, are invisible to other tools and outlive the process that took them. Nobody can answer "who holds the deploy, why, and since when", and nobody can freeze production during an incident so that every agent respects it.

agentq is the coordinator I have run on my own machine since September 2026 across five repos and several concurrent agents, extracted from a PowerShell script into a cross-platform daemon with an open protocol.

## Approach

- **Resources** are plain strings: `build:<repo>`, `build:machine` (capacity 2), `install:<repo>`, `commit:<repo>`, `deploy:<repo>:<target>`.
- **FIFO tickets** with a capacity per resource. No priorities, no overtaking.
- **Leases**: a ticket expires unless it heartbeats. A holder whose process died is released at once. Waiting extends the lease, so a long queue never looks stale.
- **Freeze marks**: `agentq mark -r deploy:web:prod --state frozen --reason "incident: 500s since 08:12Z"`. New tickets are refused with the reason; current holders finish.
- **Journal**: every acquire, release, expiry, break, mark and note is appended to a hash-chained JSONL file. `agentq log` shows what others did; `agentq verify-journal` proves nothing was edited.
- **Protocol**: [ACP-Lock 0.1](spec/acp-lock.md), JSON-RPC 2.0 over local HTTP with a bearer token, and the same operations as MCP tools.

```text
agentq run -r build:web -p "typecheck after zod bump" -- pnpm typecheck
agentq status web
agentq mark -r deploy:web:prod --state frozen --reason "incident: 500s since 08:12Z"
agentq note "handoff: do not touch apps/api until migration 0124 lands"
agentq log --limit 20
```

The first command starts the daemon in the background if none is running. State lives in `~/.agentq` (override with `AGENTQ_HOME`).

### MCP

Agents without a shell can coordinate through MCP:

```jsonc
// .vscode/mcp.json
{ "servers": { "agentq": { "command": "npx", "args": ["-y", "@codai/agentq@0.2.0", "mcp"] } } }
```

Tools: `acp_acquire`, `acp_wait`, `acp_release`, `acp_status`, `acp_mark`, `acp_note`, `acp_journal`. Tickets taken through MCP belong to the MCP server process and are released when the session ends.

### Hooks

A pre-tool hook makes agents use the queue without being told to. Before the agent runs a shell command, `agentq hook <agent>` reads the payload on stdin, classifies the command and either **rewrites** it to `agentq run -r <resource> -p <purpose> -- <command>` (default) or **denies** it with the exact command to run instead. Commands that need no resource pass through untouched.

`agentq hook-config <claude|codex|copilot|vscode>` prints the snippet below; it never writes your files.

**Claude Code** — `~/.claude/settings.json` or `.claude/settings.json` ([reference](https://code.claude.com/docs/en/hooks)):

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash|PowerShell", "hooks": [{ "type": "command", "command": "agentq hook claude", "timeout": 30 }] }
    ]
  }
}
```

**Codex** — `~/.codex/config.toml` ([reference](https://developers.openai.com/codex/hooks)). Hooks run only when enabled and trusted: add the feature flag, then approve the hook once with `/hooks`.

```toml
[features]
hooks = true

[[hooks.PreToolUse]]
matcher = "^Bash$"

[[hooks.PreToolUse.hooks]]
type = "command"
command = "agentq hook codex"
timeout = 30
```

**GitHub Copilot CLI** — `~/.copilot/hooks/agentq.json` or `.github/hooks/agentq.json` ([reference](https://docs.github.com/en/copilot/reference/hooks-reference)). The hook answers with `modifiedArgs` (rewrite) or `permissionDecision: "deny"`. Payloads in the PascalCase variant (`tool_name`/`tool_input`) get a Claude-style answer.

```json
{
  "version": 1,
  "hooks": {
    "preToolUse": [
      {
        "type": "command",
        "matcher": "bash|powershell",
        "bash": "agentq hook copilot",
        "powershell": "agentq hook copilot",
        "timeoutSec": 30
      }
    ]
  }
}
```

**VS Code Copilot** (local agent) — `.github/hooks/agentq.json` ([reference](https://code.visualstudio.com/docs/agents/reference/hooks-reference)). There is no matcher: the hook ignores every tool but `run_in_terminal`. VS Code ignores exit code 2, so denial is JSON only, and it silently drops an `updatedInput` that does not match the tool's schema, so the hook returns the full original input with only `command` replaced. The terminal is pwsh on Windows and bash elsewhere.

```json
{ "hooks": { "PreToolUse": [{ "type": "command", "command": "agentq hook vscode", "timeout": 15 }] } }
```

**What gets queued.** The command is split into simple commands on `&&`, `||`, `;`, `|`, `&` and newlines (quotes respected; a heuristic, not a shell parser). Env assignments, `sudo`/`env`/`time` and runners (`npx`, `bunx`, `pnpm exec`, `pnpm dlx`) are skipped before matching.

| Kind      | Programs and subcommands                                                                                                                                                                                                                     |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `install` | `pnpm` install/i/add/remove/update · `npm` install/i/ci · `yarn` (bare)/install/add · `bun` install/add · `pip` install · `python -m pip` install · `uv` sync · `cargo` fetch                                                                |
| `build`   | `pnpm`/`yarn`/`bun` build or run build (also `build:*`, `-r`, `--filter X`) · `npm` run build · `turbo` build · `next` build · `vite` build · `tsdown` · `cargo` build · `gradlew` assemble*/build/bundle* · `docker` build · `dotnet` build |
| `deploy`  | `vercel` deploy or `--prod` · `docker` push · `gcloud` run deploy / run services replace\|update / run jobs deploy / builds submit · `terraform` apply · `pulumi` up · `wrangler` deploy · `fly` deploy · `npm`/`pnpm`/`cargo` publish       |
| `commit`  | `git` commit · `git` push                                                                                                                                                                                                                    |

The resource is `<kind>:<repo>`, or `deploy:<repo>:prod` when the command mentions `--prod` or `production` (else `deploy:<repo>:default`). `<repo>` is the folder that owns `git rev-parse --git-common-dir`, so every worktree of one repository shares the resource. When several segments match, the most significant kind wins (deploy > build > install > commit) and the others are named in the purpose, which reads `<agent> hook: <first 80 chars>`.

No output (the command runs as is) when: the mode is `off`, the command already starts with `agentq` (or `npx @codai/agentq`), or `AGENTQ_HELD` already contains the resource — that is, the agent is inside an `agentq run`.

**Modes.** `AGENTQ_HOOK_MODE=rewrite|deny|off`, default `rewrite`. Rewritten commands stay valid in the agent's shell: a single simple command is passed straight to `agentq run`; anything with shell syntax runs as `bash -c '<original>'` or `pwsh -NoProfile -Command '<original>'` (single quotes escaped for that shell, and pwsh re-raises the native exit code). `AGENTQ_HOOK_BIN` replaces the `agentq` prefix, e.g. `npx -y @codai/agentq@0.2.0`. A resource with a freeze mark is **denied in every mode** with the mark's reason, when a daemon is running (checked with a 1.5 s timeout, never autostarted).

**Rules file.** Extra matches are a regular expression on the simple command's text:

```json
{
  "mode": "rewrite",
  "rules": [
    { "match": "^make (dist|release)", "kind": "build" },
    { "match": "^./ship", "kind": "deploy", "target": "prod" }
  ]
}
```

Read from `$AGENTQ_HOOK_RULES`, `$AGENTQ_HOME/hooks.json` (user level) and `<repo root>/.agentq/hooks.json` (repo level). Rules from all of them add up. Only user-level files and `AGENTQ_HOOK_MODE` choose the mode: a repo file may tighten it to `deny` but can never turn the guard `off`.

### Library

```ts
import { connect, hold } from "@codai/agentq";

const ep = await connect();
const h = await hold(ep, { resource: "deploy:web:prod", owner: { session: "ci-42", purpose: "release 2.3.0" } });
try {
  await deploy();
} finally {
  await h.release();
}
```

## Threat model

agentq coordinates **cooperating** agents. It is a traffic light, not a lock on the door.

**Protects against**

- Accidental concurrency: two builds corrupting one cache, two deploys racing, a commit sweeping another agent's staged files.
- Orphaned locks: dead holders are reaped by pid, silent ones by lease expiry.
- Lost context: every decision has a purpose or reason in the journal, and editing or deleting a journal line is detected.
- Other local origins: the daemon listens on 127.0.0.1 only, requires a 256-bit bearer token from a 0600 discovery file, and rejects any request carrying an `Origin` header, so a web page cannot drive it.

**Does not protect against**

- A process that ignores agentq. The hooks narrow this from "an agent forgets" to "an agent must evade a pattern", but they are a heuristic over shell text: aliases, functions, scripts that build or deploy inside (`./release.sh`), `sh -c`/`eval`/encoded-command obfuscation and any non-shell tool (an MCP server, a file-writing tool plus a watcher) bypass them.
- Hook failures. The hook fails open: an internal error, a malformed payload or a timeout (Claude Code and Copilot CLI let the call through on hook timeout) means the command runs unqueued. It never blocks an agent because agentq itself is broken.
- A hostile repository weakening the guard: it cannot — repo rules can only add matches or tighten to `deny`. It can still add noisy rules that queue harmless commands.
- Another process running as the same OS user: it can read the token. Use a per-user state directory on shared hosts.
- Self-declared identity: `session` and `purpose` are not authenticated in 0.2.
- A malicious daemon: the hash chain detects later tampering with the file, not a coordinator that lies. Signed entries are planned.

## Roadmap

- A Cursor hook.
- Signed journal entries and a multi-host binding with authenticated sessions.
- A read-only team dashboard fed from the journal.

## Status

0.2: daemon, CLI, MCP server, library and pre-tool hooks for Claude Code, Codex, GitHub Copilot CLI and VS Code Copilot work and are tested on Linux and Windows. The protocol is a draft; method names may change before 1.0. See [CHANGELOG.md](CHANGELOG.md). Part of the agent tooling at [dragoscatalin.ro/lab](https://dragoscatalin.ro/lab). MIT licensed.
