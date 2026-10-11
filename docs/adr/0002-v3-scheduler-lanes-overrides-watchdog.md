# ADR 0002: v3 scheduler — lanes, priority, atomic grants, overrides with a reason, idle watchdog

Status: accepted, 2026-10-11. Program: devcloud (`E:\gh\vmui\docs\devcloud\PLAN.md`, rows DC-010..021).

## Context

This ADR is based on an audit of 15 days of journal (2026-09-27 → 10-11, 33.8k events). The scripts are in `E:\gh\codai\.copilot-tmp\aq-audit\`.

| Problem | Measured |
|---|---|
| `build:<repo>` held while its run waited for `build:machine` | 969 runs, 96.5 h |
| `build:machine` waits > 10 s | 102 h total |
| …of which with fewer than 2 holders (RAM/commit gate, reap lag) | 49 h |
| Timeouts caused by run-build's default `-TimeoutMin 25` | 58 of 71 timeouts |
| Commit tickets that ended without a commit and without a journaled reason | ~30 % |
| Land failures with exit 7 (push refused) that were journaled | none |
| Leases expired while the work was still alive in another shell | 24 |

Root causes in the design:
- The queue was strict FIFO: a 5 s lint waited behind a 3 h gate.
- Tickets were held incrementally, one resource at a time.
- Liveness meant "the pid is alive", so a hung or idle child was never detected.
- The capacity of 2 was hard-coded.
- Timeouts were hard-coded.
- There were no metrics.

## Decision

1. **Lanes and priority instead of FIFO.**
   - Lane bases: `interactive` 100, `quick` 80, `gate` 50, `heavy` 30, `batch` 10.
   - Effective priority = lane base + `-Priority` (±50) + bumps + aging.
   - Aging adds +5 for every `agingMin` waited, so batch work cannot starve.
   - Ties break on seq.
2. **Explicit `held` flag on v3 tickets.**
   - Holding is no longer inferred from queue position.
   - Legacy tickets (no `v`) still hold by position among legacy tickets, so an install mid-traffic is safe.
3. **Atomic multi-resource grant (`Wait-All`).**
   - A run creates all its tickets up front.
   - None is granted until every one is admissible.
   - The check and the grant happen under `Global\agentq-sched`.
   - A ticket whose sibling is blocked is marked `ready=false`, and other waiters backfill past it.
4. **Soft slots on `build:machine`:**
   - `quick` and `interactive` get `quickBurst` extra slots.
   - Non-batch work may run beside batch holders. Batch runs at Idle CPU priority, so this is soft preemption without killing anything.
   - `burst` overrides add slots temporarily.
5. **Idle-yield watchdog.**
   - It samples the CPU time of the run's process tree every 60 s.
   - If the tree burned less than `idleCpuSec` over `idleYieldMin`, it sets `yielded=true` and journals `idle-yield`. The machine slot then stops counting against the cap, while the repo ticket stays held for correctness.
   - When CPU use returns, it sets `idle-resume`.
6. **Overrides with a reason** (≥ 8 characters, journaled, at most `overridesPerHour` per session):
   - `bump`: raise my waiting ticket, capped at `bumpMax`.
   - `burst`: temporary extra capacity. Refused unless free RAM and commit headroom are at least twice the gate; capped by `burstMax` / `burstMaxMin`.
   - `propose`: diagnoses the wait and applies only safe remedies (break a holder STALE for more than 2× `StaleMin`, bump my own waits over 10 min, open a 20 min burst when RAM allows).
7. **Metrics.**
   - Journal events gain `acquired` (with `waitSec`) and, on done/fail, `holdSec`, `waitSec`, `lane` and `kind`.
   - `agentq metrics` reports p50/p90 per resource × lane × kind.
   - New journaled failures: `commit-failed` / `push-failed` with a reason, and `land-push-failed` (exit 7).
8. **Journal rotation**: `rotate`, or automatically during sweep above `journalRotateMB`. agentq-sync resets its byte offset when the file shrinks.
9. **Lease activity**: index/HEAD writes in the slot's git dir, made more than 2 min after the lease was created, count as activity.
10. **Config knobs** move to `agentq-config.json`: `machineCap`, `quickBurst`, `agingMin`, `idleYieldMin`, `idleCpuSec`, `bumpMax`, `burstMax`, `burstMaxMin`, `overridesPerHour`, `journalRotateMB`.
    - run-build's default timeout becomes 240 min.
    - deploy-clean's release-lease wait becomes max(30, 3 × QueueTimeoutMin).

## Consequences

- The hub derives roles from position. agentq-sync publishes v3 holders first (waiters get seq + 1e9), sends capacity = max(cap, holders), and prefixes `[lane]` to the purpose. Native lane/prio columns in the hub are DC-060.
- `Global\agentq-sched` serialises scheduling decisions machine-wide. Each check is a few file reads, which is cheap relative to the 1.5 s poll.
- Not done here, tracked as devcloud F2:
  - the TypeScript daemon (`node:sqlite`) behind this shim
  - `-Where cloud|auto` placement

## Verification (2026-10-11)

- `tests/test-agentq-v3.ps1`: 21/21 pass. It covers:
  - priority order and no hold while waiting
  - quick burst and running beside batch
  - yielded holders not counting, and the real idle watchdog
  - override reason and budget
  - metrics fields and commit-failed journaling
  - rotate and propose
- v1 30/30, v2 51/51, worktree 18/18, guard 19/19 also pass.
- Live check: a `-Lane quick` run on the real coord dir started in 3 s while `build:machine` had 2 holders, and `agentq metrics` reported it.
