# Pre-gate scratch slots leak, and the leak is unreapable — the land queue's real bottleneck

Status: **fixed** — `Get-PregateScratchSlot` stamps the rented lease with the land pid, its start time and a deadline (`landPregateLeaseMin`, default 45); `Read-Leases` reaps it the moment the land process is gone or the deadline passes (test `ps/tests/test-pregate-lease-reap.ps1`).
Measured 2026-11-23 17:55–18:25 local, repo `codai`, resource `land:codai`.

## 1. Symptom

- `origin/main` did not move for 90+ minutes (`HEAD 9bbb3bf01f` fetched twice, 45 min apart), while 9–13
  land tickets were queued and a holder was alive.
- Journal, same 90 min: **10 × `{"event":"timeout","reason":"timed out after 60 min"}`** and only 1 `acquired`.
- Every waiter acquired after `waitSec` **2185–3466 s (36–58 min)**; the holder then ran
  `run-build.ps1 -Wait -TimeoutMin 120 -- pnpm gate:platform` **inside the cap-1 land mutex**, and
  `gate:platform` measured **888 s (15 min)**. 58 + 15 > 60 ⇒ the land is killed at the cap during its own
  gate, never pushes, and the next waiter repeats the cycle. Attrition, not a deadlock (`propose` refuses,
  a `break` is unjustified: `cpuSeconds` rising, `hb` fresh).

## 2. The chain

```
pre-gate needs a CLEAN, INSTALLED tree it can borrow        (Test-GitClean $sp)
  caller's own slot dirty?                        48 x/day -> must RENT a scratch slot
     scratch rental: "no scratch slot was free (lease exit 7)"  28 x/day
        -> land-pregate-skipped  -> the ~15 min gate runs INSIDE the cap-1 lock
           -> waiters die at the 60 min cap -> the land process never reaches
              Release-PregateSlot -> its rented scratch slot LEAKS -> pool saturates -> back to the top
```

Journal distribution for 2026-11-23 (197 pre-gate/gate events):
`76 land-pregate-skipped` (48 `the slot has uncommitted or untracked files`, 28 `not run from a leased task
slot, and no scratch slot was free for the pre-gate (lease exit 7)`), `16 land-pregate-ok`,
`12 land-gate-skipped-green`, `31 land-gate-skipped`, `17 land-gate-failed`.
All-history reason distribution (432 skips) is the same two causes: 238 dirty slot, 157+28 no leased/scratch slot.

## 3. The leak — verified

`~/.codai/coord/leases/codai/scratch-5.json`:

```json
{
  "leaseId": "95a1e6a7",
  "repo": "codai",
  "slot": "scratch-5",
  "role": "scratch",
  "path": "E:\\gh\\.wt\\codai\\scratch-5",
  "branch": "",
  "purpose": "DSC-0061 land pre-gate (topic publish/term-31060-20261123135601)",
  "session": "term-31060",
  "pid": 31060,
  "procStart": "2026-11-23T04:12:50.7987170Z",
  "created": "2026-11-23T15:08:09.9957617Z",
  "host": "DRAGOS",
  "claims": []
}
```

- **Its pre-gate is gone.** No running process lands `publish/term-31060-20261123135601` (running lands:
  `...152413`, `...152356`, `...143532`, `snwave-net2`, `dsctrack`, `dsc0065`, `...150303`, `...150935`).
- **It was never released.** No `land-pregate-slot-released` journal entry for `codai/scratch-5`; the
  releases that did happen are `brivio/scratch-2`, `brivio/scratch-3`, `agentq/scratch-1`.
- **It cannot expire.** `hb` is 0.3 min because the heartbeat is per **session** (~`Get-LeaseExtraBeat`), and
  session `term-31060` (pid 31060) is alive — so `sweep` sees a healthy lease forever.
- `claims` is empty: nothing on the lease marks it as a borrowed-for-a-gate slot.

## 4. Blast radius

The `scratchSlots` pool is elastic (floor 5 / ceiling 8). It was extended all day —
`created` 00:46, 01:01, 05:44, 13:51, 15:08, 15:33, 15:34, 15:56 — so the leak stayed invisible until
**8/8 leased at once** (7 with `hb` 0.3–0.4 min). From that moment no pre-gate can run at all, every land
pays its gate inside the cap-1 mutex, and the queue can only advance by waiters expiring.

## 5. Fix (spec)

Two small, independent parts; the first is the one that actually stops the leak.

**(a) Make a pre-gate lease reapable by itself.** When `Get-PregateScratchSlot` takes a slot, stamp the
lease with the pre-gate's own identity and a deadline instead of relying on the session heartbeat:

```powershell
# in Get-PregateScratchSlot, right after the lease JSON is parsed and validated:
$until = (Now).AddMinutes($(if ($c.ContainsKey('landPregateLeaseMin')) { [int]$c['landPregateLeaseMin'] } else { 30 }))
# claim it on the lease (claims[] already exists in the schema and is unused here), as a CHILD process so a
# refusal cannot end the land:  agentq lease-claim -Repo <path> -LeaseId <id> -Claim "pregate:$pid:$until"
```

then teach the staleness test that a `pregate:` claim wins over the session heartbeat:

```powershell
# whether this lease is a borrowed pre-gate tree (never the owner's working tree)
$pg = @($l['claims'] | Where-Object { $_ -like 'pregate:*' }) | Select-Object -First 1
if ($pg) {
  $parts = "$pg" -split ':'
  $ownerAlive = $parts.Count -ge 2 -and (Test-PidAlive ([int]$parts[1]))     # the PRE-GATE pid, not the session
  $expired    = $parts.Count -ge 3 -and (Now) -gt (ParseUtc $parts[2])
  if (-not $ownerAlive -or $expired) { $stale = $true }                     # despite a fresh session hb
}
```

`Release-PregateSlot` should clear the claim on the normal path (it already unleases), so a good pre-gate is
unchanged; only an abandoned one becomes reapable. Sweep then frees it and the pool recovers by itself.

**(b) Optional, wanted, smaller:** when the pre-gate cannot rent a slot, say so once per land with the
_number_ of scratch slots leased and their oldest `created` (`landPregateScratchWhy` currently reports only
`lease exit 7`), so a saturated pool is visible in the log instead of looking like bad luck.

Config: `landPregateLeaseMin` (default 30 — comfortably above `gate:platform` p50 7.2 min and its 888 s p95).

## 6. Test to add (extend `ps/tests/test-land-pregate.ps1`)

- a scratch lease carrying `pregate:<dead pid>:<past utc>` must be **reaped** by sweep even though its
  session heartbeat is fresh;
- a scratch lease carrying `pregate:<live pid>:<future utc>` must **not** be reaped;
- a normal (claim-less) scratch lease keeps today's behaviour — mutating the claim test off must turn the
  first case red (mutation check, ADR 0002 / the repo's own habit).

## 7. Scope: the mechanism is general, the observation is codai-only

Measured over all repos (`pool-audit.ps1`, 18:18 local — every lease file under `~/.codai/coord/leases/`
plus the journal's `land-pregate-slot-released` events):

| repo   | scratch slots leased | pre-gate leases released | leak pattern                                        |
| ------ | -------------------- | ------------------------ | --------------------------------------------------- |
| codai  | **8 / 8**            | 0                        | **yes — `scratch-5`, age 71 min, no release event** |
| brivio | 0                    | 7                        | no                                                  |
| agentq | 0                    | 7                        | no                                                  |

So state it precisely: the rented-pre-gate design and the 60-min waiter cap are machine-wide, and brivio /
agentq exercise it correctly (14 releases in the journal), but the only repo where the pool is saturated —
and therefore the only one that can leak today — is codai. Do not sell this as a fleet-wide outage.

## 8. The pool is not only leaking, it is held as dev trees — so a bigger ceiling would not help

The audit also shows what occupies the other seven slots:

```
scratch-1  933 min   K2 wave 5: 11-col tracker evidence gate
scratch-2  918 min   codwen cutover: merge origin/main into the 3 local clones
scratch-3  634 min   phone shake gate: sustained/reversal detector
scratch-4  148 min   restore ask-attachments + host fixes + tab filets
scratch-6   46 min   r7 extend GPU deadline gate to every creator
scratch-7   45 min   r7 extend GPU deadline gate to every creator
scratch-8   22 min   sessions list audit: morphing transitions + customisation
```

Six of the eight are long-lived work trees (one has been held for **15.5 h**), not gates borrowing a tree for
a minute. `scratchSlots*` was designed as an elastic pool for _borrowed_ trees; in practice it is used as a
second tier of task slots, so the pre-gate is starved by design and only the leak makes it fatal. Consequences
for the fix:

- raising `scratchSlotsMax` alone buys nothing — the pool refills;
- part (a) below (a self-expiring pre-gate lease) recovers the leaked slot and prevents recurrence, but a
  saturated pool still forces `land-pregate-skipped`;
- so the durable pair is **(a)** + **(b')**: log/refuse loudly when the pre-gate cannot rent because the pool
  is _fully_ occupied by non-pre-gate leases (naming the oldest holder), instead of the opaque
  `lease exit 7`. That turns a silent tax into an operator decision.

Config: `landPregateLeaseMin` (default 30 — comfortably above `gate:platform` p50 7.2 min and its 888 s p95).
