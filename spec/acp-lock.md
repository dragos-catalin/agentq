# ACP-Lock 0.1 — Agent Coordination Protocol for shared resources

Status: draft, 2026-10-05. Reference implementation: `agentq` (this repository).
Keywords MUST, SHOULD and MAY are used as in RFC 2119.

## 1. Problem

Several coding agents (and humans) work in one repository or on one machine at the same time. They share things that cannot be used concurrently: an incremental build cache, a package-manager store, the git index, a deploy target, the machine's RAM. Worktrees isolate files but nothing tells agent B that agent A is mid-deploy, that production is frozen during an incident, or why a lock exists.

Today every tool invents its own lock file. Those locks are poll-and-race, carry no reason, are not visible to other tools and are left behind when a process dies. ACP-Lock defines one small protocol that any agent harness, script or MCP client can speak.

## 2. Model

- **Resource**: a lowercase string of `:`-separated segments matching `^[a-z0-9][a-z0-9._/-]*(:[a-z0-9._/-]+)*$`. Conventions: `build:<repo>`, `build:machine`, `install:<repo>`, `commit:<repo>`, `deploy:<repo>:<target>`. `<repo>` SHOULD be the name of the repository's common git directory parent, so every worktree of a repository shares its resources.
- **Capacity**: how many tickets may hold a resource at once. Default 1. Set on acquire; the last value set wins.
- **Ticket**: one request for a resource. Fields: `id`, `resource`, `seq`, `owner`, `created`, `expires`, `leaseMs`. Tickets are ordered by `seq`, a counter that only increases (per coordinator). The first `capacity` live tickets of a resource **hold** it; the rest **wait**. Order MUST be FIFO: a later ticket never overtakes an earlier live one.
- **Owner**: `{ session, purpose, pid?, host? }`. `purpose` is REQUIRED and non-empty; other agents read it to decide whether to wait, ask or break.
- **Lease**: a ticket lives until `expires`. Any heartbeat or wait call extends it by `leaseMs`. An expired ticket is removed and journalled with reason `lease expired`. When `pid` is given and the coordinator is on the same host, a dead pid MAY remove the ticket at once.
- **Mark**: `{ resource, state: frozen | blocked, reason, session, at }`. A marked resource refuses new tickets with error `-32001` and the mark in `data`. Existing holders are not revoked: a freeze stops new work, it does not kill running work.
- **Journal**: an append-only log of every state change (§6).

## 3. Transport

JSON-RPC 2.0. Two bindings are defined:

1. **Local HTTP**: `POST http://127.0.0.1:<port>/rpc`, header `Authorization: Bearer <token>`. The coordinator writes a discovery file `<state-dir>/daemon.json` = `{ url, token, pid, protocol }` with mode 0600. Requests carrying an `Origin` header MUST be rejected (a web page must not drive the coordinator). Bodies over 64 KiB MAY be rejected.
2. **MCP**: the same operations exposed as MCP tools named `acp_<method>` (`acp_acquire`, `acp_wait`, `acp_release`, `acp_status`, `acp_mark`, `acp_note`, `acp_journal`). The MCP server owns the tickets it acquires and heartbeats them while the session lives.

## 4. Methods

| Method              | Params                                                           | Result                                      |
| ------------------- | ---------------------------------------------------------------- | ------------------------------------------- |
| `acp.hello`         | —                                                                | `{ protocol: "acp-lock/0.1", pid }`         |
| `acp.acquire`       | `resource`, `owner`, `leaseMs?`, `capacity?`                     | `TicketView` (`held`, `position`)           |
| `acp.wait`          | `ticket`, `timeoutMs?` (≤ 30000)                                 | `TicketView` once held or at timeout        |
| `acp.heartbeat`     | `ticket`                                                         | `TicketView`                                |
| `acp.release`       | `ticket`, `exit?`                                                | `{ ok: true }`                              |
| `acp.break`         | `ticket`, `reason`, `session`                                    | the removed `Ticket`                        |
| `acp.mark`          | `resource`, `state: frozen\|blocked\|clear`, `reason`, `session` | `Mark` or `null` on clear                   |
| `acp.note`          | `message`, `session`, `resource?`                                | `JournalEntry`                              |
| `acp.status`        | `resource?` (exact, prefix segment or repo name)                 | `ResourceStatus[]` (holders, waiters, mark) |
| `acp.journal`       | `after?` (seq), `limit?`, `resource?`                            | `JournalEntry[]`                            |
| `acp.verifyJournal` | —                                                                | `{ entries, ok, brokenAt? }`                |

`acp.wait` is a long poll: it returns as soon as the ticket becomes held, and every call extends the lease. A client that wants to hold a resource loops `acquire` → `wait` until `held`, then heartbeats at least every `leaseMs / 3` until `release`.

`break` and `mark` MUST carry a non-empty reason. `break` SHOULD only be used on a ticket whose owner is gone or wedged; clients SHOULD pass the exact ticket id they diagnosed (never "the first ticket"), because the holder can change between a status read and a break.

## 5. Errors

| Code     | Meaning                                                |
| -------- | ------------------------------------------------------ |
| `-32001` | resource is frozen or blocked (`data` = the `Mark`)    |
| `-32002` | unknown ticket (expired, released or broken)           |
| `-32602` | invalid params (resource name, missing purpose/reason) |
| `-32601` | method not found                                       |
| `-32700` | parse error                                            |

CLIs SHOULD map `-32001` and give-up timeouts to process exit code 3.

## 6. Journal

Each entry: `{ seq, ts, event, session, resource?, ticket?, purpose?, reason?, message?, state?, exit?, prev, hash }`. Events: `queue`, `acquire`, `release`, `expire`, `break`, `mark`, `unmark`, `note`.

`hash = sha256(canonical(entry without hash))`, where canonical JSON sorts object keys and omits undefined values. `prev` is the previous entry's `hash`, or 64 zeros for the first. Editing or deleting any line breaks verification from that line on. A coordinator MUST NOT rewrite past entries.

The journal is how agents learn what others did: "who froze deploy and why", "which build has been holding for 50 minutes", "handoff: do not touch apps/x until the migration lands".

## 7. Security considerations

- The local binding trusts any process that can read the discovery file. On a multi-user host the state directory MUST be private to the user.
- `session` and `purpose` are self-declared. ACP-Lock coordinates cooperating agents; it is not an authorisation system. A remote (multi-host) binding MUST authenticate clients and SHOULD bind `session` to the authenticated identity.
- The hash chain detects tampering after the fact; it does not prevent a coordinator from lying. Signing entries with the coordinator's key is left to a later version.
- Denial of service: any client can queue many tickets. Implementations MAY cap live tickets per session.

## 8. Not in 0.1

Multi-host coordinators and federation, signed journal entries, per-resource ACLs, priorities (FIFO only by design), and a standard MCP capability flag. Feedback goes to the agentq issue tracker.
