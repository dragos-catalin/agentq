# 0012 — Lease liveness is WORK IN THE SLOT (and the reap that follows)

Status: accepted (2026-11-19). Supersedes the chat-keepalive wording of ADR 0009 stage 0 for the
staleness rule; the rest of ADR 0009 stands.

## Context

A slot lease used to be kept alive by "the owner shell is up" (pid + heartbeat) and, after ADR 0009,
by "the chat bound to the slot made any tool call". Both measure the WRONG thing. Measured 2026-11-19:

- `agentq who` on the workstation: **17 leases, 0 stale**. Several slots had been idle **5–7 h** while
  the machine was fully used — each held by a bound chat that kept polling, so it stayed "alive" until
  `leaseMaxIdleMin` (24 h). The scheduled reap (`copilot-worktree-prune`, every 30 min) was running and
  `agentq sweep` reported `expired=0` — correctly, per the rule, but usefully? No.
- `slo`: `slotsLostLiveChat = 12` (target 0) — slots taken while a chat was "live" but not working there.

The bug is the model, not the timer: "the chat is busy" is not "someone works in this slot".

## Decision

**Liveness is work in the slot.** Per lease, `Read-Leases` takes the newest of three beats:

- `<lease>.json.hb` — an agentq call for that lease's repo/session, or `agentq renew`;
- `<lease>.json.work` — written ONLY by a tool call that NAMES the slot (the guard);
- the slot's own git activity (`.git/worktrees/<slot>/{index,HEAD,logs/HEAD}`), ignoring the first 2 min.

`idle = now − beat`. Threshold `deadIdle`: `land` 3 · `scratch` `leaseScratchIdleMin` (15) · owner pid
alive `leaseOwnerIdleMin` (90) · else `leaseIdleMin` (45). A bound `<lease>.json.chat` younger than
`leaseChatGraceMin` (20, 0 for scratch) is a short grace. `holdUntil` (`lease -Hold`) suppresses
staleness. Then

```
stale = !held && ((idle > deadIdle && chatOld) || idle > leaseMaxIdleMin)
```

A chat that only makes **unrelated** calls no longer keeps the slot: the guard refreshes `<lease>.json.chat`
only when the call NAMES the slot (ideas 1+7), so the grace expires once the chat stops working there and
the lease is reclaimed. `leaseMaxIdleMin` drops 1440 → **360** (6 h) so even a slot that keeps getting
trivial touches is reclaimed within a workday.

## Reaping, made auditable and reclaimable

- `agentq sweep` (already scheduled every 30 min by `copilot-worktree-prune` → `worktree-prune-task.ps1`)
  expires every stale lease (`Backup-Slot` first, fail-closed) and now **journals `lease-kept`** for a
  lease past its threshold that a chat grace or `-Hold` keeps — so `expired=0` is explainable.
- `agentq who [<repo>] [-Json] [-StaleOnly] [-IdleHours N]` is the read-only triage verb; each row carries
  `why` (held | recent work | chat grace | stale) alongside `idleMin`/`chatIdleMin`.
- `agentq lease -Reclaim -Reason '…'` takes a slot whose ONLY protection is a chat grace (idle past its
  threshold, not held). It backs the holder up first and journals `lease-reclaim`; it is refused without
  `-Reason`, like `break`.
- `agentq slo -Track` compares `slotsLostLiveChat` to a stored value and journals `slo-alert` when it
  moves. The alert SINK (hub tile / mail) lives outside this repo and is not wired here.

## Consequences

- A slot is freed as soon as its last REAL work ages out, not when the chatting agent finally leaves.
- Two long-lived chats can no longer pin two slots while working elsewhere.
- The rule is stricter: a genuine long job that runs OUTSIDE its slot must say so — `lease -Hold`
  (`-HoldMin`, default `holdDefaultMin` 180) — or keep touching the slot.
- Suites that lease more than one slot from one session must either give each "agent" its own
  `$env:AGENTQ_SESSION` or pass `-Slot task-N` (the deliberate override; ADR 0012 also refuses a second
  task lease in one session unless `-Wait`). Ripple left red elsewhere by this rule (test-agentq-v2,
  test-agentq-doctor) is tracked separately.
- Tests: `ps/tests/test-lease-chat.ps1` (chat vs work clock), `ps/tests/test-agentq-lease-liveness.ps1`
  (work clock, owner ladder, chat grace, scratch, second-lease refusal, `-Hold`, `who` + `why`/filters,
  the 6 h cap, `-Reclaim`).
