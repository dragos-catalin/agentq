# ADR 0003: agentq v4 - publish, durable leases, ready slots, faster gates, conflict-free versions

Status: accepted 2026-10-18 (owner decisions via a research + brainstorm round). Wave 1 implemented; waves 2-4 are the plan.

## Context

Research on 2026-10-18 (scripts and raw output: `E:\gh\codai\.copilot-tmp\agq-research\`):

| Signal | Measured |
| --- | --- |
| Journal | 62,106 events over 3 weeks, 11,001 sessions, busiest day 8,618 events |
| Runs that fail | 21.6 % (2,084 of 9,664) |
| codai commit tickets, last 7 days | 669 acquired: 270 commits, 168 commit-failed, 101 push-failed |
| codai land outcomes | 264 landed, 55 push refused (exit 7), 24 conflicts |
| brivio land outcomes | 179 landed, 42 conflicts, 6 push refused |
| build:codai wait | p90 350 s, 32 h of waiting in 7 days |
| Leases expired with the owner gone | 61 of 62 |
| Lease failed on checkout | 54 (stale index.lock / leftovers) |
| cloud-fail | 566, from a dead workspace and a StrictMode bug, against 78 cloud-done |
| Hand-written temp-index "plumbing commit" scripts | about 18, with repeated bugs (reverting landed work, CRLF flips, mojibake) |
| CHANGELOG/version collisions on land | about 8, plus 3 GH001 (CHANGELOG 118 MB) and 4 poisoned land slots |
| Timeout-class test flakes in gates | 52 in 2 weeks |

## Decisions

### Wave 1: quick wins (implemented 2026-10-18)

| Id | Change | Evidence |
| --- | --- | --- |
| W1-1 | Cloud: a result without `phases` no longer throws after a successful run. A workspace that answers 404 is down for 2 h, not 15 min. | 150 false cloud-fail + 215 retries against a deleted VM |
| W1-2 | `agentq publish -Paths a,b -Message -Purpose [-Onto] [-Base] [-Land] [-NoPush] [-Force]`. Commits only the given paths onto the CURRENT `origin/<onto>` tip in a throwaway index (caller index and HEAD untouched). Blobs come from `hash-object --path`, so EOL/attributes match a normal commit, and modes come from the tip. A revert guard refuses (exit 5) when the result would drop lines that landed after the caller's base. Pushes a fresh `publish/<session>-<ts>` topic, verifies it with `ls-remote`, and with `-Land` lands it and deletes the topic. | Replaces ~18 hand-written scripts. Test suite `test-agentq-publish.ps1`, 19 checks |
| W1-3 | A lease is also active while (a) a live ticket runs with its repo inside the slot, (b) a running job's cwd or command names the slot, or (c) any agentq call comes from the lease's session or names `-LeaseId`. `renew -LeaseId` works from anywhere. An expired or foreign-broken lease leaves a notice that the owner's next agentq call prints once, with the restore recipe. `status` lists lease losses of the last 24 h. | 24 + 9 leases lost while work was alive |
| W1-4 | Ready slots. On lease, a stale `index.lock` with no git process is removed, and a failed checkout retries once with a forced checkout. Then `Prepare-Slot` runs: the repo hook `scripts/slot-prep.ps1 -Worktree -Main` if present, else for pnpm repos a frozen install under `install:<repo>` when the lockfile changed, plus `.husky/_` copied from the main clone. State goes to `<slot>/.agentq-prep.json`. A prep failure never fails the lease: it warns and journals `slot-prep-failed`. | 54 lease checkout failures, ~19 fresh-slot failures |
| W1-5 | PowerShell entry hardening: `-Paths` accepts `a,b`, a `string[]` from an in-process call, and several values. A command after a lost `--` gets an explicit message. | ~19 argument-trap incidents |
| W1-7 | (open) `hooks/guard-tooluse.ps1` contains a second copy of the command-guard section after the write-guard `Deny-Exit` (lines ~558-927 repeat ~66-450). Likely unreachable. It is the security hook, so removing it needs its own change with the guard suites plus a mutation check, not a housekeeping edit. | Found 2026-10-18 |
| W1-6 | Housekeeping: `jobs.ps1 prune -Days 7` runs in the 30-minute prune task. README no longer says FIFO. ADR 0001 slot counts point to config. | 2,428 job files, docs contradicting v3 |

### Wave 2: gate speed and reliability (planned)

| Id | Change | Expected effect |
| --- | --- | --- |
| W2-1 | Land gate = `turbo run <tasks> --affected` with `TURBO_SCM_BASE=origin/<onto>`. Root config, lockfile or turbo.json changes mean a full run. A full run every night (and every N lands) bisects and reverts a culprit. | Gate 20-40 min down to minutes for 1-3 package changes (EXPECTED; measure) |
| W2-2 | One turbo cache shared by every slot and the land slot (devcloud remote cache, or a local cacheDir). | Tasks already green in the agent's slot are cache hits in land |
| W2-3 | Flake ledger: gate results (JUnit or vitest JSON) per tree hash. A test that flips on the same tree is quarantined (runs, does not block). Exactly one automatic retry only for infra-pattern failures ("Failed to start forks worker", hook timeouts, EBUSY/EPERM), journaled as `flake`. | Removes most of the 52 timeout failures per 2 weeks |
| W2-4 | Windows Job Objects for every queued run: CPU weight by lane (land gate highest), memory cap, kill-on-close, CPU accounting into the journal. | Gates stop failing because other agents saturate the CPU; orphan children die with their holder |
| W2-5 | Land batching: 2-4 queued topics combined (merge-tree, no working tree), one gate, bisection on failure. Optimistic acceptance when a later batch that contains a failed one passes. Batch size adapts to the measured failure rate. | More lands per gate hour |
| W2-6 | Re-verify against the tip before queueing: `land` refuses early, in the agent's slot, when the topic does not apply cleanly on the current tip. | Conflicts found before the serial land slot |

### Wave 3: version and CHANGELOG conflicts disappear (planned, needs repo changes in brivio and codai)

| Id | Change |
| --- | --- |
| W3-1 | Changelog fragments: each change adds `changes/<ts>-<slug>.<type>.md`. No commit edits CHANGELOG.md or the version. |
| W3-2 | The version and CHANGELOG are assigned at land/release time by one step (`agentq land` calls the repo's `scripts/assemble-changelog`), so two agents can never claim the same version. |
| W3-3 | Pre-commit hooks in brivio and codai stop requiring a bump per commit and require a fragment instead. The union merge driver for CHANGELOG is removed. |

### Wave 4: architecture (planned, each gets its own ADR before building)

| Id | Change |
| --- | --- |
| W4-1 | The shared clone is read-only for agents: all edits happen in leased slots. The guard warns, then refuses, writes outside a slot (autosync keeps the clone current for reading). |
| W4-2 | Advisory path claims: `lease -Claims 'apps/hub/**,packages/ui/**'`. Overlapping claims are shown at lease time and ordered in the land queue. |
| W4-3 | One SQLite store (WAL, `BEGIN IMMEDIATE`) for tickets, leases, jobs and the journal index. Atomic grants, no stray lock files, one source for status, metrics and the hub mirror. File tickets stay readable during migration. |
| W4-4 | SLO dashboard on hub `/ops/agentq`: failure rate p by cause, gate runs per landed change, ready-to-landed p50/p90, share of changes that bypassed the queue, lost-work incidents, flake rate. Targets: ready-to-landed p90 < 45 min, flake-caused gate failures < 2 %, zero lost work. |

### More ideas from the brainstorm (not yet decided)

- `agentq doctor`: one command checks a repo/slot (stale locks, index vs HEAD, hooks present, node_modules matching the lockfile, leases and tickets of dead sessions) and prints the fix.
- Structured results for every verb: `-Json` on commit/land/publish/lease with exit, phase, failing task and the untrimmed failing assertion plus the log path. Agents parse it instead of grepping logs.
- `agentq claim <tracker-id>` before starting work: refuses when the id is already landed on origin or claimed by another live lease (3 duplicate-work incidents).
- Land preview: `agentq land -DryRun` shows picks, predicted conflicts and which gates `--affected` would run.
- Session handoff: `agentq handoff -To <session>` moves a lease, its tickets and its notices to another session (subagents returning early).
- Heartbeat-free liveness for chat agents: liveness from the VS Code chat-terminal association (`vscode-chat-terminals.mjs`) instead of the shell pid.
- Release gating by SLO: a release waits when the last N lands on its branch show a failing nightly.
- One native entry point (a small compiled shim) that removes every PowerShell argument trap.

## Consequences

- Agents should use `agentq publish` instead of temp-index scripts, and `agentq renew -LeaseId` (or any agentq call) during long waits outside the slot.
- Repos can add `scripts/slot-prep.ps1` to make leased slots fully ready (codai: build `codai-sdk` dist).
- Waves 2-4 change repo hooks and CI and are done repo by repo, each measured before and after.
