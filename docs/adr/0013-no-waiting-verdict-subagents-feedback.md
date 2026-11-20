# 0013 — Working with agentq without waiting: preemption verdict, subagent rule, feedback channel

Status: accepted (2026-11-20). Complements ADR 0012 (lease liveness = work in the slot) and ADR 0002
(lanes). Does not change any resource capacity.

## Context

Measured 2026-11-19/20, seven-day window (journal + `agentq metrics` + `agentq slo`):

- **Queue wait is not where the pain is.** Total wait 52.9 h/7 d (7.6 h/day) in the first window,
  36.8 h (5.3 h/day) in the second; 53–71 waits over 10 min. It concentrates in **`commit:<repo>`
  (9.2 h), `land` (6.3 h brivio), `build:watch-faces` (5.2 h), `deploy:brivio:release` (5.0 h)** — a
  serialized high-value resource, not the lane/aging machinery. Aging (+1/min) decided a wait once in
  7 days (`timeout=1`): preference is not the lever, **capacity and hold time are**.
- **The hook is the biggest single cost**: 5.33 h of CPU/day, more than every queue wait combined.
- **Subagents queue.** The dominant pattern reported by agents: _"all 11 codai slots are held by live
  sessions (lease timed out; sweep freed 0); the shared clone hard-blocks source writes"_ — a subagent
  burning its whole session on a wait for a pool its **parent already holds a slot in**.
- **Agents spend minutes discovering whether they may preempt.** They read `status`, guess at a pid,
  and often `break` the wrong ticket (recorded incident: a live release holder was broken).
- **Feedback about agentq itself has nowhere to go.** Anomalies and "next time do X" notes from agents
  end up in a repo tracker or a scratch file, where the next agent working on agentq never reads them.

## Decisions

### 1. `agentq eval -Resource <r>` — one instant, read-only preemption verdict

Before breaking anything, an agent asks. `eval` answers with ONE of four verdicts and the exact command:

| Verdict      | Meaning                                                               | Action printed                        |
| ------------ | --------------------------------------------------------------------- | ------------------------------------- |
| `FREE`       | no holder                                                             | proceed                               |
| `WAIT`       | holder alive and working                                              | wait, or `propose`                    |
| `PREEMPT-OK` | pid gone, OR no children + ~0 CPU for >5 min, OR heartbeat > 2× stale | the exact `agentq break -Id <ticket>` |
| `NEVER`      | the command is a deploy/release/land/terraform/pulumi                 | do not break; wait or ask the owner   |

`-Sample` spends 0.9 s sampling the holder's CPU to separate "wedged" from "busy". For a `slot:` resource
the verdict is about the LEASE: `STALE-RECLAIM` (with the `unlease` command) or `WAIT`.

`eval` is **read-only and side-effect free**: it never breaks, never renews, and is excluded from agent
registration and lease renewal, so an agent can run it from any session as often as it likes.

### 2. A subagent must never queue

`CODAI_SUBAGENT=1` (set by the harness for subagents) or `AGENTQ_FAIL_FAST=1` turns every _unnamed_
lease into a 60-second bounded probe (`-Wait -MaxMin 1`). On expiry the message says, in order:

1. `agentq eval -Resource <r>` — whether a holder can be preempted, and the command;
2. `agentq propose -Reason '…'` — the sanctioned auto-remedy (breaks a hung holder, bumps own tickets);
3. **SUBAGENT: do not wait. Hand the work back to the parent** (`agentq note -Message 'blocked on <r>: <what is left>'`) and end the turn.

The parent owns the slot; the subagent works INSIDE the parent's slot or takes a `scratch-N` slot
(ADR 0012, not counted against the caps). Rationale: the parent is the only party that can decide to
re-plan, and a subagent holding a slot while its parent waits is the worst allocation on the machine.

### 3. `agentq feedback` — the tool's own inbox

`agentq feedback -Kind note|idea|bug|anomaly|praise -Message '…'` writes one JSON file under
`~/.codai/coord/feedback/` (journaled as `feedback`) and prints how the next agent reads it.
`agentq feedback [-Last n] [-Json]` lists them, newest first.

Notes about the TOOL belong to the tool, not to a task tracker, so they live next to the coordinator
where the next agent working on agentq finds them first. This is the sanctioned channel for
"anomaly happened", "this could be better", "this cost me an hour".

### 4. Capacity is the lever, not preference

Because aging decides ~once a week, the expensive resources get attention instead:
`quickBurst` 1→2 (two sub-2-minute jobs run beside a gate), `machineCapAdaptive.max` 4→6 (the
machine's own load probe still gates it, so this only helps when the box is idle enough), and
`leaseIdleMin` 45 / `leaseOwnerIdleMin` 90 (ADR 0012) so a slot is never held for hours by a chat that
moved on. Explicitly NOT done: giving `quick` and `heavy` separate sockets on `build:<repo>` — measured
4.5 min/7 d, so it is a design smell, not a throughput problem.

## Consequences

- An agent blocked on a slot gets an actionable answer in one call instead of a discovery loop, and
  never breaks a release by mistake (`NEVER`).
- A subagent returns to its parent with a note instead of holding a slot and a session for an hour.
- Feedback about agentq accumulates where the next agent looks; `agentq doctor` and `agentq since`
  remain the other two surfaces.
- `agentq eval` must stay read-only. Any future "auto-break" behaviour belongs in `propose`, which is
  bounded, journaled and rate-limited — never in `eval`.

## Verification

`ps/tests/test-agentq-lease-liveness.ps1` (work clock, scratch, hold, who), `test-agentq-admission.ps1`
(session-scoped task lease), `test-lease-chat.ps1` (chat grace + `.work`), `test-agentq-doctor.ps1`
(`lease-hygiene`), `test-land-install.ps1` (one session per simulated agent). `install.ps1 -Suites …`
is the gate; all suites must be green before install.
