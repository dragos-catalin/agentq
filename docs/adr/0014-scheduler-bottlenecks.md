# 0014 — Scheduler bottlenecks: the defects, their evidence, and the options

Status: **partially accepted** (2026-11-21). Defects 1 and 6 are fixed, implemented and covered by
mutation-checked suites (see the notes under each); defect 2 turned out to be already fixed by b858cf2.
Defects 3–5 still need an owner decision (3 is mechanical, 4 and 5 change fair-share semantics); the
numbers below are measured, not estimated. Complements ADR 0002 (lanes), ADR 0012 (lease liveness = work
in the slot) and ADR 0013 (working without waiting).

## Context — where queue wait actually is

Seven-day window, `~/.codai/coord/journal.jsonl` (`agentq slo`, `agentq metrics`):

| resource              | wait  | acquisitions |
| --------------------- | ----- | ------------ |
| commit:codai          | 9.2 h | 1021         |
| land:brivio           | 6.3 h | 104          |
| build:watch-faces     | 5.2 h | 65           |
| deploy:brivio:release | 5.0 h | 20           |
| build:mmo             | 3.9 h | 306          |
| land:codai            | 2.2 h | 394          |

Total 36.8 h/7 d (5.3 h/day), 53 waits > 10 min, `land` failure rate 23.2 % (115/495). `build:machine`:
765 acquisitions, 654 waited (85 %), sum 11.4 h, p50 2 s / p90 13 s — i.e. many _short_ waits, which the
lane mechanism already keeps cheap (`quick` p90 5 s vs `gate` p90 33 s), so **"quick waits behind heavy"
is refuted** and is not a defect. Timeout fires 1×/7 d, so the aging clock almost never decides anything.

## Defect 1 — `commit:<repo>` holds its ticket across fetch+merge+push, including the pre-push gate

**FIXED 2026-11-21 (variant B, cap 2 instead of 1).** `commit:<repo>` now covers only `git add` +
`git commit`: the index is what needs mutual exclusion, and it is released the moment HEAD moves
(`Drop-Ticket`). The push phase holds a new, first-class resource `push:<repo>` (capacity 2,
`$DefaultCapacity['push:*']`), so the pre-push gates of two peers run concurrently and a commit never
queues behind someone else's gate. Measured on a scratch repo with an 8 s pre-push hook: a peer's
`agentq commit -NoPush` took **10 s while a gate was running before the fix, < 3.5 s after**.
Regression suite `ps/tests/test-agentq-commit-fast.ps1` (12 assertions, mutation-checked).
The same test found a latent bug the new concurrency exposes: a lost push race is reported as
`! [remote rejected] HEAD -> main (failed to update ref)`, which the retry classifier did not match, so
the loser threw and its commit stayed local; the classifier now accepts `failed to update ref` and
`cannot lock ref` as races and retries with fetch+merge+push.

## Defect 6 — a take-over reset the slot and told nobody (the work was saved, invisibly)

Every take-over resets the worktree (`Initialize-Slot`: `reset --hard` + `clean -fd`) and every reset is
preceded by `Backup-Slot`, which fails closed — so nothing was ever actually discarded. It was invisible:
on 2026-11-20 21:59 a new lease `a52655c9` took `codai/task-3` while the previous holder's unsaved work was
still in it. The journal shows the backup
(`refs/backup/wt/codai/task-3/20261120-215948-8a2e`, `a221d13d`), it is on origin, and `prune` never touches
`refs/backup/*` — but `Invoke-Lease` discarded the ref with `[void]`, `Add-LeaseNotice` fires only for
`lease-expire`/`lease-break`, and there was no way to ask about backups. The holder concluded its work was
lost and rebuilt it. Same pattern in that day's earlier take-overs (04:29 ×3, 06:58).

**FIXED 2026-11-21.** A take-over is now loud and recoverable: `Publish-SlotTakeover` journals
`lease-takeover`, appends to a per-slot history (`<store>/slots/<repo>--<slot>.jsonl`) that outlives the
lease record, notifies the previous holder through the existing notice channel, and prints a note naming
the ref, the short sha and the exact restore command (also printed if the lease fails after the backup).
The fallback to the slot-history ref covers the common case where the reclaim/expire already saved the work.
`agentq recover [-Repo r] [-Slot s] [-Ref <ref|sha|slot/stamp>] [-To <my slot>] [-Apply]` lists every backup
newest-first with the holder history, previews a restore without writing, and restores into a **leased slot
only** — it refuses the shared clone and a slot held by another live session unless `-Force`.
Suite `ps/tests/test-agentq-recover.ps1` (25 assertions, mutation-checked: 12 FAIL without the call).
`for-each-ref` note: it matches with `FNM_PATHNAME`, so `refs/backup/wt/<repo>/*` returned **0 of 1607**
refs (only `<repo>/<slot>/*` works); the lister uses `/**` and selects the slot in PowerShell.

`commit:codai` is the single largest waiter (9.2 h/7 d, 1021 acquisitions ≈ 32 s of hold each, on a 1-deep
queue). The hold covers the pre-push gate (a repo-wide hook), which is the long part; a second committer
waits for a _gate it does not benefit from_.

Options

- **A (small):** keep cap 1 but make the gate optional per call (`-NoGate` for trivial commits) — cheap,
  but pushes risk to the pusher.
- **B (better):** split the resource into `commit:<repo>` (index + commit, cap 1, short) and `push:<repo>`
  (fetch/merge/push + gate, cap 1). The gate then serializes only real pushes, and two agents can prepare
  commits concurrently. Cost: two verbs to acquire, an agentq-internal change.
- **C:** let the gate run _outside_ the ticket and re-acquire before push — risks a stale merge base.

## Defect 2 — `land:<repo>` is a single serialized slot, but only its last phase needs to be

**NOT A DEFECT — already option A since b858cf2 (ADR 0009 stage 0), verified in the code 2026-11-21.**
`Invoke-Land` calls `Invoke-LandPregate` at line **1928** and only creates the ticket at **1932**, so the
expensive, independent part has always run _before_ the queue: the gate runs in the **caller's own leased
slot** (`$sp`), on a `commit-tree` of the rebased result, and the slot is put back afterwards. On failure it
journals `land-pregate-failed` with the message "BEFORE the queue - nothing queued, nothing pushed", so a
red pre-gate costs the waiting agents _no_ queue time — the opposite of what this row claimed. It is on by
default (`Get-LandPregateOn`: absent config key ⇒ `$true`; `AGENTQ_LAND_NO_PREGATE=1` opts out) and a tree
that already passed the gate is not gated twice (`Set-GreenTree`/`Test-GreenTree`). `land:<repo>` therefore
only serializes merge+push: 394 acquisitions in 2.2 h/7 d ≈ **20 s of hold each**, not 104 agents queueing
behind one slow gate. The 23.2 % figure is the _gate_ failure rate (real red gates), not wait — the two
must not be read as one number.

What is left to improve here is small and not scheduler-related: a `land` that fails can leave the caller
on the pre-gate detached commit only if the restore fails (journalled as `land-pregate-restore-failed` with
the exact `git checkout` to run).

## Defect 3 — three overlapping memory authorities on the second build

`build:machine` has (i) an adaptive cap (min 2, max 4), (ii) a free-RAM gate (`minFreeGB 6`), and (iii) the
admission probe. Memory pressure _lowers_ the adaptive cap (at 24 GB free) **and** trips the RAM gate, so
the same condition is counted twice and the cap can flap. `build:machine` refused/queued 85 % of calls.

Read against the code on 2026-11-21, the defect is real but its shape is different, and one part of the
description is wrong: the thresholds are **not** the same condition counted twice — they are three
different numbers for one quantity, owned by three places, with none of them documented together:

| free RAM / commit below                                               | effect                                                                | where                                             |
| --------------------------------------------------------------------- | --------------------------------------------------------------------- | ------------------------------------------------- |
| 24 GB                                                                 | adaptive cap −1 (floor `min` 2)                                       | `machineCapAdaptive.minFreeRamGB/minFreeCommitGB` |
| 12 GB (`2 × MinFreeGB`)                                               | `burst` and `propose` refuse to raise the cap                         | `agentq.ps1` 975 / 1009                           |
| 6 GB (`MinFreeGB`, a **global default**, absent from the config file) | a `build:machine` waiter is not admitted; `run` offloads to the cloud | `agentq.ps1` 1264 / 1195                          |

So the _entry_ gate (6 GB) is looser than the _burst_ gate (12 GB): a job can be admissible and still be
refused the extra slot that would let it start beside a holder. The admission probe is a fourth authority
and the only one that reacts to load instead of memory. Two things are **not** defects, checked: the probe
sample is refreshed at most every 20 s (`admission.everySec`) and the adaptive cap at most every 15 s, both
through shared files, and the `Test-FreeRam` CIM query runs at most once per 1.5 s poll and only when the
queue position already allows admission (`Test-Admissible` evaluates the gate last, after `$ok`) — i.e.
only inside the low-RAM window. The 85 % refuse/queue figure is dominated by _load_ admission and by the
queue, not by the memory gate.

Options

- **A (recommended):** one authority — the cap, computed once from measured free RAM at admission time,
  with the hard gate kept only as a floor (admit nothing below the floor, never refuse for a second reason).
  Concretely: one `Get-MachineMemory` returning `{ freeRamGB; freeCommitGB; tier; capDelta; allowNew;
allowRaise; why }` from ONE config block that holds all three thresholds, read by every call site (cap,
  admission, burst, propose, cloud offload) instead of comparing raw numbers, plus one row in
  `agentq status` / `doctor` printing the tier and the numbers behind it. The `× 2` disappears with it.
- **B:** drop the adaptive part, keep the fixed gate — simpler, loses the ramp-up on an idle machine.

## Defect 4 — no per-session or parent/child grouping

`New-Ticket` records `session = term-<pid>`; `Register-Agent` has no parent field, so a subagent is an
independent session with its own tickets. Measured: one session held 5 task leases, another 3; nothing in
the scheduler can weigh "this agent already holds two slots" or "these two tickets are the same job".

Options

- **A:** ticket carries `parent` (the lead's session) and fair-share counts _per session group_.
- **B:** only per-session counting (no parent) — cheaper, misses subagents (they have their own pid).
- **C:** explicit `-Group <id>` passed down by the lead — needs discipline at call sites.

## Defect 5 — aging (+1/min) cannot outrun bump (+50 instant) and the 60-min timeout

`agingMin 5`, `bumpMax 50`, default timeout 60 min. Measured: timeout fired 1×/7 d — the clock is
decoration. Either aging must decide (steeper rate, or a score that combines wait, priority and group
fair-share), or bump should be bounded relative to the head of the queue.

Options

- **A:** score-based verdict (wait × weight, group-fair) with a published rule — the "instant algorithmic
  preemption verdict" of ADR 0013.
- **B:** keep FIFO, raise aging to +5/min and cap bump at +20 — one-line change, less fair.

## Decision needed

Which of the remaining ones is in scope for the next tranche, and for each chosen one, the **A/B/C**
variant. They are independent: 3 is mechanical, 4 and 5 change fair-share semantics and want an explicit
choice. (1 and 6 are done; 2 was never real — the code already did the right thing, see above.)

## Resolved on 2026-11-21 (owner-ticked scope)

**D3 — one memory authority.** `Get-MachineMemory` (`agentq.ps1`) is the single reader of the three
thresholds and returns the live numbers next to them; `Test-FreeRam`, the adaptive cap, `burst` and
`propose` go through it, and `agentq doctor` prints one `machine-memory` row that says whether the three
numbers still agree. The **values are deliberately unchanged** (queue 6 / burst 12 / adaptive 24): collapsing
them to one number decides which builds start, and that is the owner's scheduling policy, not a refactor.
The row now reports honestly — see the two defects below.

**D4 — per-session fair share.** Implemented in `Test-Admissible`, active only while **≥ 2 sessions
compete** on a resource with **cap ≥ 2** (so a single session, or cap 1, behaves exactly as before):

- the rank order is **interleaved by round** over sessions (`Sort-BySession`) — round 1 takes each
  session's first waiter, round 2 its second — so one agent's fan-out cannot sit as a block in front of
  another session's single waiter;
- a session already holding `ceil(cap / sessions)` slots is **not ranked at all**, so the slot a holder
  just freed goes to the other session instead of idling under a ticket that would be refused anyway;
  the refusal is journaled **once** (`event: fair-share`, with session, held, cap, share) and the 30 s
  wait message says `session fair share: …`.
- Config: `fairShare: true|false | { enabled, maxPerSession }` (default on, share derived); one call can
  opt out with `AGENTQ_NO_FAIRSHARE=1`.

`ps/tests/test-agentq-fairshare.ps1` (23 checks) proves the helpers, the interleave, the refusal and the
window: with the feature **on** the other session takes the freed slot (`wait-b -> third-a` in the journal),
with it **off** the outranking request takes it (`third-a -> wait-b`). Mutation-checked: disabling the
eligibility filter turns `6c` red. Parent/child grouping (option A of D4) is **not** implemented — a
subagent still has its own session; the per-session rule already fixes the starvation it was written for.

**D5 — the precedence rule is published, not changed.** The rule (unchanged in code) is:

> rank = lane base + `-Priority` (clamped ±50) + `bump` (clamped `bumpMax`) + aging, where
> aging = `5 × floor(waited / agingMin)` — i.e. **+1 per minute waited at the default `agingMin 5`**.

The consequence is now written down instead of being folklore: at the default `bumpMax 50`, one `bump`
is worth **50 minutes** of waiting, so a bumped ticket outruns any waiter under ~50 min. Two dials move
that: raise `agingMin`-relative weight or lower `bumpMax`. It is published in `agentq help` and here;
no default was changed, because that changes who starts first on a shared machine.

**Ungated lands are now visible.** The 2026-11-21 repo readiness pass found **94 of 95** repos declare no
`landGate` and 80 have no pre-push hook either, so their lands merge and push with no check at all.
Nothing is refused (an ungated land still beats a land that never happens): the land journals
`land-ungated` and prints one line naming the repo, `-Gate "<cmd>"` and the `landGate` config key.

## Two defects found while implementing D3 (both took down every `agentq run`)

1. `Get-MachineMemory` began with `if ($null -eq $script:MmFloors)` and `$script:MmFloors` was never
   declared. Under `Set-StrictMode` that **read** throws — `The variable '$script:MmFloors' cannot be
retrieved because it has not been set` — so every `agentq run` exited 1 before doing anything.
   Fixed by declaring it next to the other script globals; the guarantee is now a comment on the
   declaration, not a memory.
2. `$floors = @($queueGB, $queueGB * 2, …) | Sort-Object -Unique` did not compute what it reads like:
   **inside `@(...)` the comma binds tighter than `*`**, so the expression is `($queueGB, $queueGB, …) * 2`
   — the list repeated, doubling every value's weight and making `unified` false for a machine whose three
   numbers were identical (`Cannot convert the "System.Object[]" … to type "System.UInt32"`). Fixed with
   parentheses; the doctor row now prints 3 real floors (6/12/24) for this machine.
   Lesson recorded because it is easy to repeat: in PowerShell `@($a, $b * 2)` is **not** `@($a, ($b * 2))`.

3. Both defects were **invisible to the test suite**, which is the more expensive half of the story.
   The doctor wrapped its checks in a catch-all, so a `Get-MachineMemory` that threw produced no
   `machine-memory` row at all — and a check that emits nothing cannot fail an assertion. `agentq doctor`
   looked healthy, the suite was green, and the same function was killing every `agentq run` in
   production. Two consequences, both applied:
   - A check must never be able to _silently vanish_. The suite now asserts that with the switch off a
     `machine-memory` row is produced again (pass or warn, never absent) — the absence was the bug.
   - `machine-memory` reads the real machine, so it cannot live inside a fixture suite that asserts exact
     warning counts: it gained `AGENTQ_DOCTOR_NO_MEMORY=1` (symmetric with `AGENTQ_DOCTOR_NO_TASKS=1`)
     and the suite sets it. Floor value `0` means "that gate is not configured" and is no longer counted
     as a distinct floor, which is what turned the row into noise on a machine with one gate off.
     The suite's own summary-count assertion was a hard-coded constant that broke twice for the same
     reason (a check added, a check skipped); it now counts the checks that **actually ran**.
