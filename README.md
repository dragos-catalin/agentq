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
{ "servers": { "agentq": { "command": "npx", "args": ["-y", "@codai/agentq@0.1.0", "mcp"] } } }
```

Tools: `acp_acquire`, `acp_wait`, `acp_release`, `acp_status`, `acp_mark`, `acp_note`, `acp_journal`. Tickets taken through MCP belong to the MCP server process and are released when the session ends.

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

- A process that ignores agentq. Enforce it where it matters with a pre-tool hook that refuses `deploy`/`build` commands outside `agentq run`.
- Another process running as the same OS user: it can read the token. Use a per-user state directory on shared hosts.
- Self-declared identity: `session` and `purpose` are not authenticated in 0.1.
- A malicious daemon: the hash chain detects later tampering with the file, not a coordinator that lies. Signed entries are planned.

## Roadmap

- Hooks for Claude Code, Copilot, Codex and Cursor that route build/deploy commands through `agentq run`.
- Signed journal entries and a multi-host binding with authenticated sessions.
- A read-only team dashboard fed from the journal.

## Status

0.1: daemon, CLI, MCP server and library work and are tested on Linux and Windows. The protocol is a draft; method names may change before 1.0. Part of the agent tooling at [dragoscatalin.ro/lab](https://dragoscatalin.ro/lab). MIT licensed.
