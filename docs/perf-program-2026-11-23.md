# agentq performance program — 2026-11-23

**Goal.** Every operation agents run here — gate, hook, build, commit, land, deploy, install, test —
returns in seconds, never holds a lane blocked for minutes, and reports a per-run, per-lane
performance number that can be compared to a stored baseline and an average.

**Done means** (each provable by a command):

1. `agentq slo` → `queue wait total` < 1 h/day (today 21.1 h/day) and `readyToLandedP90Min` < 45 (today 175.3, FAIL).
2. No `land:<repo>` ticket is ever held while a gate runs (holds are publish/commit/push only).
3. `agentq perf --repo X --lane land --since 7d` prints p50/p90/max/avg per lane, with a stored baseline and a regression flag.
4. `agentq status` / `who` / `slo` / `doctor` each return in < 1 s with state at today's size.
5. Zero blocking cleanliness findings across the 24 active repos (`agentq status -All` clean, no lease pointing at a missing path).
6. `hook cost` < 2 h/day (today 8.60 h/day).
7. Every active repo has a measured baseline for its gate/build/typecheck/test commands.

## Verified baseline (measured 2026-11-23, `agentq slo`, 1-day window)

| metric                        | value                             | goal  | verdict |
| ----------------------------- | --------------------------------- | ----- | ------- |
| queue wait total              | 21.1 h/day                        | < 1 h | FAIL    |
| waits over 10 min             | 36                                | 0     | FAIL    |
| busiest queue                 | `land:codai` 17.9 h               | —     | —       |
| land failure rate             | 48.2 % (53/110)                   | low   | FAIL    |
| `readyToLandedP90Min`         | 175.3                             | < 45  | FAIL    |
| `lostWorkIncidents`           | 6                                 | 0     | FAIL    |
| hook cost                     | 8.60 h/day                        | < 2 h | FAIL    |
| lease-break / lease-expire    | 23 / 17 in 24 h                   | 0     | FAIL    |
| journal                       | 31 MB / ~18 k lines in window     | —     | —       |
| `agentq.db`                   | 154 MB SQLite, NOT the read model | —     | —       |
| coord\agents / jobs / notices | 2709 / 926 / 245 files            | —     | —       |

Land lifecycle, all-time (from the journal): `land-pregate-skipped` **432** vs `land-pregate-ok`
**100** vs `land-gate-skipped-green` 70 vs `land-gate-failed` 87. The pre-gate is skipped 4x more
often than it runs, and a skipped pre-gate moves the expensive gate _inside_ the exclusive
`land:<repo>` lock.

Historic worst cases seen in transcripts: `land-gate` 1474 s and 284 s; `land:codai` blocked 165 min;
a wedged land ticket holding the lock **with the gate already green** for 85.9 min (needed a manual
`agentq break -Id`); `agentq land` silently giving up at `-TimeoutMin 60`; 16/16 leases held at
idle 0.1 min.

## Root cause of the blocking (fixed today, live)

`Invoke-LandPregate` skipped whenever the caller's slot was dirty — which is the normal case, since
an agent working in its slot has uncommitted files. The gate then ran inside the cap-1
`land:<repo>` mutex, freezing the whole land queue for p90 20–40 min (max 3 h).

**Fix** (commit `717b117`, installed live, `ps/bin/agentq-v2.ps1`): a dirty caller slot now rents a
resettable **scratch slot** (`Get-PregateScratchSlot`, reset to `origin/<onto>`), runs the gate there,
leaves the caller's tree untouched and releases the slot; it skips only when no scratch can be had.
Scratch pool floor raised 3 → 5 (`scratchSlots`) because each land gate now consumes one.
Tests: `ps/tests/test-land-pregate.ps1` case 6 + new case 6b — `69 pass / 0 fail`, run twice
(direct and as the install gate); measured "land ticket held 3.2 s for the re-land".

## Bottlenecks, ranked (evidence-backed)

1. **Gate inside the cap-1 land mutex** — 284–1474 s per land × cap 1 → 165-min blocks, a 268.8-min retry loop. _Partly fixed today; the residual is any gate step still > 20 s._
2. **Wedged land holds the lock with the gate already green** — 85.9 min, heartbeat STALE, no `landed` event; needed a manual `break -Id`. Needs an auto-reap.
3. **`agentq land` wait dies silently at `-TimeoutMin 60`** and only reaps by pid liveness, so a deep queue just evaporates attempts. Needs re-enqueue-on-timeout.
4. **Read-only verbs re-enumerate the whole state dir per call** (`jobs\` 926, `agents\` 2709, `notices\` 245, `slots\*.jsonl`, 31 MB journal) — the "probe hangs on a recursive scan" symptom.
5. **Journal is streamed, never indexed**; **`agentq.db` (154 MB) is not used as the read model**, so the same facts are recomputed from the tree on every query.
6. **Lease pool exhaustion** — 16/16 held with holders idle 0.1 min → land exits 3. Release leases eagerly.
7. **Hook cost — root-caused 2026-11-23.** `hook-pre.ps1` is the only `preToolUse` hook and it logs one line
   per **tool call** to `coord\hooks\cost-*.jsonl`; `agentq-slo.mjs:439` (`computeHookCost`) sums `ms + startMs`.
   **Last 24 h: 41,776 calls = 17.20 h** (p50 **1347 ms**, p90 1923 ms, max 20.8 s); 12-day average 10.88 h/day over
   272,911 calls (the printed 8.60 is the 7-day window average). Split: in-script `ms` 11.56 h (67 %) + process
   spawn `startMs` 5.65 h (33 %). Top tools: `run_in_terminal` 7.89 h, `read_file` 4.25 h (71 % of all calls).
   Per call, inside the one process, also: the AXIOM node gate (112 ms, observe-only), `copilot-signal.ps1`
   which spawns a **detached** wscript+pwsh (~206 ms), `guard-tooluse.ps1` 61 KB (~249 ms), and a fresh
   `powershell.exe` (433 ms p50). Ranked fixes (min/day at 41,776 calls): gate AXIOM to write-tools only 78–210;
   short-circuit the signal DELETE 143; slim `guard-tooluse` 173; a resident daemon/node entry removes the
   5.65 h spawn share; fewer+bigger reads halve the rest. F1–F3 are local edits ≈ 6.5 h/day.
   **2026-11-26 follow-up - the metric above was partly a lie.** From 2026-11-25 the resident hook host ran
   `hook-pre.ps1` in its own process and that script derived `startMs` from `GetCurrentProcess().StartTime`,
   i.e. the HOST'S UPTIME: `agentq slo` printed `hook cost 318 162 h/day`, 7 874 of today's 21 489 lines
   carried a `startMs` over 1 h, max 29.2 h. The 5.65 h/day "process spawn" share above is therefore partly
   the server's age, not a spawn cost. Fixed at the source: the server passes `CODAI_HOOK_REQUEST_MS` per
   request (plus `CODAI_HOOK_RESIDENT=1`), `hook-pre.ps1` writes `startMs` **null** when a host gives no
   receipt time, `agentq-slo.mjs` FLAGS lines over 1 h (never clamps them) and names this fix, the resident
   tooling is now version-controlled in `ps/hooks/resident`, and `install.ps1` restarts the server after a
   guard change (the host parsed `hook-pre.ps1` once at startup - that staleness is why the first fix
   attempt did not take). Measured 08:15Z->08:20Z after the restart: 75 calls, `startMs` max 1 719 ms,
   avg 496 ms, total `ms + startMs` 166 s = ~2.2 s/call. At ~70 k calls/day the PHYSICAL hook cost is
   still tens of h/day: the ranked fixes below stand, and `< 2 h/day` is genuinely unmet, not unmeasurable.
8. **brivio staging builder — root-caused 2026-11-23: genuinely slow, NOT stuck.** The local `cpuSec` ~1050 only
   counts the node process streaming the remote VM log; the work runs on a spot n2d-standard-32 VM. ~90 min =
   ~4 min bundle/VM + **~60 min deploy phase** (~24 min Next.js web image build, turbo `@brivio/web:build` ~1454 s,

- ~28.6 min for the 4-service build/deploy/verify) + **~22 min e2e** (attempt + one retry). `MAX_RUN="90m"` never
  bites and the deploy succeeds. **It fails on the `@critical` e2e gate**, not the deploy:
  `invoice-lifecycle.spec.ts:157/173` ("found in the list by its number") is persistently red across 4 consecutive
  candidates and stays red on retry — deterministic, not a flake. Fixes: (A) fix that spec/product; (B) add a
  registry buildx cache (`--cache-from/to type=registry`) to `scripts/ha/build-and-push-web.mjs` and the service
  build in `deploy.mjs:883/949` — halves the wall time.

9. **Two writers on `coord\`** (20 s ticket heartbeat + 15 s `agentq-sync`) — contention shows as occasional STALE heartbeats.
10. **Gate chain tail** — the parallel gate chain is 8.74 s while the land gate is 284–1474 s, so the queue is dominated by the long suites, not the chain.

## Slices, in order (each independently testable)

1. **Auto-reap a wedged land**: if the gate is green and no `landed` event appears within `StaleMin`, self-`break` and re-acquire. `agentq-v2.ps1`, land finalize/reap. _(No more manual breaks.)_
2. **Re-enqueue on `-TimeoutMin` expiry** instead of exiting. `agentq.ps1`, wait loop.
3. **Never skip the pre-gate** — already delivered by `717b117`; add a journal assertion that `land-pregate-ok` ≥ `land-pregate-skipped`.
4. **One state snapshot per invocation** (jobs/agents/notices/leases read once, passed down) + a journal sidecar index (`<journal>.idx`: last offset + per-type counts) — kills bottlenecks 4 and 5.
5. **Serve `status`/`who`/`slo` from `agentq.db`** instead of re-deriving from disk.
6. **Release leases eagerly** on land exit (try/finally) and surface idle holders in `status`.
7. **`agentq perf`**: per-run, per-lane duration/outcome/wait recorded on every lane, a stored baseline + rolling average, and a regression flag. See the reporting design below.
8. **Profile `hook cost`** and move the expensive hooks off the commit path.
9. **Fix the brivio staging builder** (item 8 above) — it is the largest single local time sink found.
10. **Per-repo measured baseline** for gate/build/typecheck/test (done means #7). Start with one warm
    `agentq run -Resource build -- pnpm typecheck` + `pnpm lint` per repo: those two commands exist in every repo.

## Reporting design (what to build in slice 7)

Today: `agentq slo` derives p50/p90 from the journal; `coord\slots\<repo>--<slot>.jsonl` has per-slot
activity; `coord\journal.jsonl` has every event; the hub mirrors `agentq_*` tables every 15 s.

Missing per lane: a recorded **start**, **end**, **duration**, **outcome** (ok/fail/superseded/expired),
**holder**, and **wait time**. Design: add `startedAt`/`endedAt`/`outcome` to every queue ticket
record and emit one terminal event per lane run; aggregate into `coord\perf\<repo>.jsonl` (one line per
completed run) and derive `agentq perf [--repo R] [--lane L] [--since 7d]` printing
`lane | n | p50 | p90 | max | avg | fail% | waitP50 | vs baseline`. Store the baseline as
`coord\perf\baseline.json` (per repo+lane, rolled weekly) and raise a regression flag when
p90 > 1.5 × baseline p90 with n ≥ 10. Mirror the same rows to the hub tables the sync already writes.

## Lost work + lease churn — root-caused 2026-11-23

`lostWorkIncidents 6` is **inflated by re-counting**: 5 of 6 are the SAME failure repeating — a **broken
worktree** (`E:\gh\.wt\{brivio\scratch-3, codai\scratch-8}` had "no valid HEAD"), so `Backup-Slot` throws
(`agentq-v2.ps1:501`), `Expire-Lease` keeps the lease (`:705-710`) and the same slot re-fails every sweep
(scratch-8 ×3, scratch-3 ×2). The 6th = a backup-ref push refused by GitHub (codai/task-3; work survived as a
local bundle). `slotsLostLiveChat = 0`, so no live session ever lost work. Of the 23 lease-breaks: 13 dead-owner
shell reaps (ADR-0009 mode), 8 deliberate "slot no longer needed" after publish, 1 cede, 1 orphan. All 17
expiries were stale-idle (owner alive in only 2), 6 recovered with a ref, 11 clean.

**Fix:** in `agentq-v2.ps1` `Expire-Lease`, treat a _broken worktree_ backup failure as terminal — move the dir to
`E:\gh\.wt\_orphans\<repo>-<slot>-<ts>` and release the lease with `ref:""` instead of keeping it forever; keep
fail-closed for every other backup error. (Both known offenders were already cleared by hand on 2026-11-23 —
`codai/scratch-8` moved to `_orphans`, `brivio/scratch-3` verified gone with no lease — so the count is already 0
distinct losses; the code change stops the re-count and the permanent lease.)

## Open decisions / not done

- **Memory floors**: today 3 distinct (6 / 12 / 24 GB). Aligned the two configs to **12 GB**
  (`machineCapAdaptive.minFreeRamGB` and `minFreeCommitGB`, live + source) → now 2 floors (6 / 12),
  `doctor` down from 5 warnings to 2. The remaining 6 GB is the _queue_ floor, which ADR 0014 D3
  documents as a deliberately separate gate, so it was left alone. Machine: 191.8 GB RAM, 119 GB free.
- **`lostWorkIncidents` 6** and **`lease-break 23 / lease-expire 17`** need their own investigation.
- **The 154 MB `agentq.db`** is unused by the read path; either use it (slice 5) or delete it.
