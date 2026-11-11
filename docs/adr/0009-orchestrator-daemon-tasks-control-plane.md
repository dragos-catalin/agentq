# ADR 0009: from queue to orchestrator: local daemon, task model, codai control plane

Date: 2026-11-11. Status: accepted (owner decisions in chat, 2026-11-11). Tracker: `docs/TRACKER.csv` (OQ-\*).

Number 0008 is taken by the post-land hook ADR, which is still on its branch.

## Context

agentq coordinates builds, installs, commits, deploys, worktree slots and landing for many coding agents on one
workstation. It is a queue: every action is started by an agent. The owner wants an orchestrator that knows the
work, assigns it, limits load, asks for decisions, and is visible and controllable from every codai app.

Measured from the journal, 7 days to 2026-11-11 (31,793 events):

| What                             | Value                                                                           |
| -------------------------------- | ------------------------------------------------------------------------------- |
| Agent time waiting in queues     | 65.9 h (9.4 h a day); 126 waits longer than 10 min                              |
| Most expensive queue             | land for one repo: 18.7 h, p90 12.5 min, max 2.1 h                              |
| Lands                            | 271 landed, 81 failed (23 %)                                                    |
| Land failures by cause           | repo A: 46 of 62 in the land gate; repo B: 19 of 19 in pre-push                 |
| Runs that failed under a ticket  | builds 24 %, deploys 15 to 30 %                                                 |
| Slots lost while possibly in use | 185 `lease-break`, 40 `lease-expire`, 3 failed backups (the one SLO that fails) |
| Writes in shared clones          | 6,220 (ADR 0004 is still in warn mode)                                          |
| Agents at the time of writing    | 26 agent shells in 30 min, 215 PowerShell processes, CPU 99 %                   |
| Cost of one agentq call          | a new process parsing 2,862 lines; `status -All` 4 s                            |
| Cost of the per-tool-call hook   | about 15,000 calls a day at about 2 s each (estimate from medians)              |

What the code lacks today:

1. No task model. Tickets, leases and jobs carry a purpose text, not a task id, state, assignee or acceptance.
2. No assignment. agentq never starts or addresses an agent.
3. No limit on agents. Caps exist for builds and task slots only.
4. Weak identity. A session is `term-<pid>`; one chat produces dozens (3,831 sessions in 7 days).
5. No dependencies between work items, no cost budget, no approvals inbox.
6. State lives on one machine (files and local mutexes). The hub mirror is one-way; only marks come back.
7. No resident process, API or event stream. Waiters poll every 1.5 s.
8. Two cores. The TypeScript package in `src/` (daemon, MCP) is FIFO-only and unused on the workstation.
9. The PowerShell suites do not run in CI.

Outside systems reviewed (2025 to 2026): Claude Code agent teams (shared task list, self-claim, worktree lock),
Gas Town with Beads (git-backed work items with dependencies, a batching and bisecting merge queue, health
monitors), kanban launchers (one worktree per task, diff review), cloud agents (one VM per agent, pull request
out), and merge queue products. Lessons that match our data:

- Separate agents; do not make them collaborate. Our own matched-cost test found a team no better than one agent.
- At a 20 % failure rate per change, a batch of 10 passes 10.7 % of the time. Gains come from checking before the
  queue, bisection, and independent lanes for changes that do not overlap.
- Rare everywhere: routing the human's attention by priority, cost per task, and preventing conflicts before merge.

## Decision

1. **Architecture.** One resident agentq daemon per machine (TypeScript, SQLite in WAL mode, a local API and an
   event stream). It owns that machine's resources: tickets, lanes, caps, slots, jobs, landing. The PowerShell
   verbs stay and become thin clients. The codai platform is the control plane: tasks across machines, the
   fleet view, commands and notifications. Local locking never depends on the network.
2. **Order.** Quick wins on the current PowerShell code first, measured against the table above; then the daemon.
3. **Tasks: hybrid model.**
   - A tracker row in the repo stays the definition of a task (title, acceptance, evidence, final state) and
     changes in the same commit as the code, as today.
   - Live state (who claimed it, slot, attempt, why blocked, what it depends on) lives in agentq, not in git.
     A claim written to a tracker would wait in the landing queue, and one malformed tracker cell has already
     blocked every land in a repo.
   - A small file per repo, `.agentq/trackers.json`, names the id and status columns of each tracker and maps
     its status words to four common states: open, in progress, blocked, done. Trackers today differ in both
     (173 tracker files across two repos, more than ten status words).
   - Work without a tracker row is a native task in the same model.
4. **The per-tool-call hook becomes the first client of the daemon.** The check itself takes about 135 ms; the
   process starts are almost all of the 2 s. Guard decisions must stay identical (parity suite) and the hook
   edit needs the owner's rules ticket.
5. **Dispatcher.** agentq starts agents on ready tasks, up to an agent limit and a daily budget, locally or on
   cloud workspaces. For the first week it only proposes; the budget is then set from the measured cost per task.
6. **Commands from the apps** (operator only, journaled): freeze and unfreeze a resource; answer approvals and
   questions; change priority and order; stop a job or free a slot (confirmation, backup first); start an agent
   on a task; pause all new work on a machine.
7. **Dashboards** in the codai apps: hub (extend the existing page), desktop (other machines too), phone
   (screen, widget, quick tile, push), watch (tile and approve), TV (ambient board), with one read API, one
   event stream and one command route on the gateway.
8. **Product.** Internal first. Multi-tenant concerns (organisations, authenticated agent identity, billing)
   get their own ADR before any customer use.

## Stages and how each is judged

| Stage | Content                                                                                                                                                                                                                                          | Judged by                                                                                                                                                                          |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0     | Lease kept alive by the hook; land gate run in the slot before queueing, skipped for a tree that already passed; agent admission by load and by owner presence; pruning and a read-only `status`; shared clone on refuse; suites in CI; `doctor` | slots lost with a live chat = 0; land wait under 5 h a week and land failures under 10 % for the busiest repo; process-start probe median under 500 ms in 95 % of 5-minute buckets |
| 1     | Daemon with SQLite, local API, events; verbs as clients; hook as a client; warm slots; Linux and macOS                                                                                                                                           | hook median under 700 ms; `status` under 300 ms; both cores pass one parity suite                                                                                                  |
| 2     | Tracker index, atomic claim, `next`, dependencies, conflict forecast from path claims, handoff objects, task timeline; independent landing lanes                                                                                                 | no task worked by two agents; ready-to-landed p90 under 30 min                                                                                                                     |
| 3     | Dispatcher (propose, then launch), budget, needs-you inbox, stuck-chat detector, cost per task, cloud overflow, cloud resource registry with expiry, auto-rebase, arena, scorecards, emergency lane                                              | cost per landed task known; no cloud resource alive past its expiry; inbox items answered from a phone                                                                             |
| 4     | Gateway API, stream and commands; hub, desktop, phone, watch, TV, iOS widget, editor status bar; daily mail report; flaky-test board                                                                                                             | every command works from two apps; state on screen within 5 s of the event                                                                                                         |
| 5     | Organisations, identity, billing                                                                                                                                                                                                                 | own ADR                                                                                                                                                                            |

## Not verified

- Whether the installed agent CLIs can run a whole task unattended with the same hooks and rules as the editor.
- Whether the editor can start a hook without a PowerShell process (a bare start costs about 0.4 s); the 700 ms
  target assumes it cannot.
- Slot wait times (the journal does not carry them in a form that could be summed).
- The hook cost is an estimate from medians, not a sum.

## Consequences

- Two implementations run side by side until stage 1 ends; the parity suite is the gate for each verb moved.
- ADR 0002 (TypeScript daemon behind the shim), ADR 0003 wave 4 and ADR 0006 phase 2 are carried out by stage 1.
- The task index reads trackers; it never writes them. Evidence and final state stay reviewable in git.
- Starting agents automatically spends money without a person pressing a key, so the budget and the pause-all
  command ship before the first automatic launch.
- The dashboards live in the codai repo and are tracked here until that repo opens its own rows.
