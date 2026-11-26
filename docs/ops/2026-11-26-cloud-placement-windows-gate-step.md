# A land pre-gate's auto cloud placement ships a Windows-only `run-build.ps1` path to a Linux VM — the job dies `[devcloud] exit 64`

Status: **open — reported 2026-11-26**. Workaround (caller-side, no agentq change): set
`AGENTQ_WHERE=local` before `agentq land`.
Measured 2026-11-26 in `E:\gh\frontiers\linear-a`, workspace `ws-frontiers` (Linux), frontier jobs
`20261126-072021-34677b` and `20261126-072626-feb9ba`.

## 1. Symptom

Two consecutive `agentq land` attempts failed their pre-gate the same way. `agentq` placed the gate
step in the **cloud** (ws-frontiers), and the VM was handed a command whose argv begins with a
**Windows path**:

```
pwsh -NoProfile -File C:\Users\vladu\.copilot\hooks\run-build.ps1 -Root <slot> -Wait -TimeoutMin 120 ...
```

The Linux runner has `pwsh` installed (`cloud/workspace-startup.sh:83` apt-installs `powershell`), so
`bash -lc` starts PowerShell, which is asked to `-File` a path that cannot exist on Linux and exits a
**usage error: 64** — the job log ends `[devcloud] exit 64`, immediately and with no gate output.

- VERIFIED: `pwsh -NoProfile -File <nonexistent path>` exits **64** on this machine (ran it; the
  Linux branch of `cloud/runner-agent.mjs` reaches the same pwsh usage path).
- The land succeeds the moment the caller runs `AGENTQ_WHERE=local pwsh ... agentq land ...`: with the
  placement pinned to `local`, `run-build.ps1` runs on the workstation and never crosses to the VM.

## 2. The chain

```
agentq-v2.ps1 Invoke-GateRun            $env:AGENTQ_WHERE = 'auto'  (caller left it unset)
  -> & pwsh -File %USERPROFILE%\.copilot\hooks\run-build.ps1 -Command <the land gate>
       run-build.ps1 forwards -Where auto and re-enters:
       agentq run -Resource build -Where auto -- pwsh -NoProfile -File C:\...\run-build.ps1 -Command <gate>
         -> agentq.ps1 Resolve-Placement(where = 'auto')
              kind = Get-CmdKind(...) = 'gate-script'   (matches \.ps1 — cloud-ELIGIBLE)
              machine full / RAM low / saturated / historical p50 >= 240 s
              -> where = 'cloud'
         -> agentq-cloud.ps1 builds spec.cmd (POSIX-quoted) containing the WINDOWS path
         -> ws-frontiers is Linux -> bash -lc spec.cmd -> pwsh -File C:\... -> exit 64
```

No step in this chain inspects the argv for a host-specific path. That is the whole defect.

## 3. Root cause — anchors (re-read 2026-11-26; where the lines are now)

- `ps/bin/agentq.ps1:1561` — `$want = if ($Where) { $Where } elseif ($env:AGENTQ_WHERE) { ... } else { 'local' }`.
  An explicit `-Where` or a caller's `AGENTQ_WHERE` is honoured here (the opt-out the workaround uses).
  **Confirmed at the reported line.**
- `ps/bin/agentq.ps1:1566` — `if ($want -eq 'local') { return ... }`. **Confirmed at the reported line.**
- `ps/bin/agentq.ps1:1576` — the auto path's kind guard:
  `if ($res -notlike 'build:*' -or $kind -notin 'typecheck', 'test', 'lint', 'build', 'next-build', 'gate-script') { return local }`.
  Because `'gate-script'` is in the allow-list, a **`.ps1` gate is cloud-eligible**. (New anchor — the
  report did not name it, but it is the reason a gate can reach the cloud at all.)
- `ps/bin/agentq.ps1:1237` — `Get-CmdKind` returns `'gate-script'` for any command matching `\.ps1`.
- `ps/bin/agentq.ps1:1588` — `$minSec = ... $cfg['cloudAutoMinSec'] ... else 240.0`;
  `ps/bin/agentq-config.json:271` — `"cloudAutoMinSec": 240`. The p50 branch that flips a
  historically-slow kind to cloud.
- `ps/bin/agentq-v2.ps1:1963` — `function Invoke-GateRun(...)`.
- `ps/bin/agentq-v2.ps1:1964` — `$rb = ... Join-Path $env:USERPROFILE '.copilot\hooks\run-build.ps1'`
  (**the Windows path that ends up in the cloud argv**). **New anchor.**
- `ps/bin/agentq-v2.ps1:1973-1974` — `$prevWhere = $env:AGENTQ_WHERE; if (-not $prevWhere) { $env:AGENTQ_WHERE = 'auto' }`
  — sets `'auto'` **only when the caller left it unset**. **MOVED**: the report cited ~1940-1944; it is
  now **1973-1974** (the function itself starts at 1963).
- `C:\Users\vladu\.copilot\hooks\run-build.ps1:259,262,269` — `$agentq = Join-Path $env:USERPROFILE '.copilot\bin\agentq.ps1'`;
  `$self = @('-NoProfile','-File',$PSCommandPath, ...)`; `& pwsh @aqArgs -- pwsh @self`. `$PSCommandPath`
  is the Windows `run-build.ps1`, so the re-entered `agentq run` argv carries the Windows path.
  **Confirmed.**
- `cloud/runner-agent.mjs:140-150, 415-428` — a Windows target builds `winScript(spec)` and runs it with
  `pwsh -File <script>`; a Linux target runs `bash -lc spec.cmd`. `spec.cmd` is the POSIX-quoted join
  of the argv (`ps/bin/agentq-cloud.ps1:385`), which still contains the Windows path.
- `cloud/workspace-startup.sh:83` — the Linux image contains `pwsh` (`apt-get install ... powershell`),
  so the Windows path is not rejected as "command not found" — pwsh gets as far as a usage error, 64.

## 4. Repro (smallest sequence; forces the cloud branch deterministically)

Run from a repo that has a `cloudWorkspaces` entry (any `E:\gh\frontiers\*`, e.g. `linear-a`). This is
the exact production wrapper; `-Where cloud` pins the placement so the defect is deterministic:

```powershell
# spend one cheap, immediately-failing cloud job; watch the argv and the exit code
pwsh -NoProfile -File "$env:USERPROFILE\.copilot\hooks\run-build.ps1" -Where cloud `
     -Purpose 'repro: gate step with a Windows path in argv' -Command 'pwsh -NoProfile -Command "exit 0"'
# -> agentq run places it on ws-frontiers with argv containing C:\Users\vladu\.copilot\hooks\run-build.ps1
# -> log ends: [devcloud] exit 64
```

The non-spending variant — observe only the placement decision the journal records
(`agentq.ps1:1647` writes `placement(where, why, cmd)`), with no job submitted:

```powershell
$env:AGENTQ_WHERE = 'auto'
pwsh -NoProfile -File "$env:USERPROFILE\.copilot\bin\agentq.ps1" run -Resource build -Where auto `
     -Repo 'E:\gh\frontiers\linear-a' -Purpose 'repro: show placement' -TimeoutMin 1 `
     -- pwsh -NoProfile -File 'C:\Users\vladu\.copilot\hooks\run-build.ps1' -Command 'exit 0'
# journal line: "event":"placement", ...,"where":"cloud", ...,"cmd":"pwsh -NoProfile -File C:\Users\..."
```

Reproduce it end-to-end the way it was found, with no override: `agentq land` on such a repo while
`build:machine` is full (or RAM is below the gate, or the gate kind's local p50 is `>= 240 s`), then
re-run the same land with `AGENTQ_WHERE=local` and see it pass.

## 5. Fix (spec) — three options, one recommended

**(a) A job/gate declares its own placement, and auto must respect it.** Let a caller mark a run as
host-bound — e.g. `agentq run -Host local` / an `AGENTQ_REQUIRE_LOCAL=1` that `run-build.ps1` sets on its
own re-entry, or `Invoke-GateRun` passing `-Where local` for a gate whose command is a local script.
`Resolve-Placement` returns `local` whenever that flag is set. **File: `ps/bin/agentq.ps1`
(`Resolve-Placement`) + `ps/bin/agentq-v2.ps1` (the gate's re-entry).** Trade-off: correct and
future-proof, but adds a new knob and every wrapper that knows it is host-bound must set it — the
existing run-build re-entry is exactly such a wrapper.

**(b) Refuse to auto-place a command whose argv contains a host-specific path.** Before choosing
`cloud`, scan `$cmdLine` for `[A-Za-z]:\\` or a `.ps1` token and return `local` when the target is
Linux. **File: `ps/bin/agentq.ps1` (`Resolve-Placement`, the auto branch).** Trade-off: a heuristic —
it cannot catch every host-bound command, and a legitimate POSIX `.sh` gate is unaffected, but a
Windows workspace would need the inverse rule. Cheap and it fixes the observed case exactly.

**(c) Treat gate steps as local by default.** Drop `'gate-script'` from the cloud-eligible kind
allow-list at `agentq.ps1:1576`. **File: `ps/bin/agentq.ps1:1576`.** Trade-off: one-token change, but
it forbids a future _portable_ gate from ever using the cloud, and it is invisible — the p50 branch
would silently never fire for gates.

**Recommendation: (a)**, with (b) as a cheap belt-and-braces addition in the same change. (a) is the
only option that states the real invariant — _a gate that shells out to a local script is host-bound,
and auto placement must not override a declaration the caller already made_ — and it reuses the
mechanism `agentq land` already has (`AGENTQ_WHERE`, `agentq.ps1:1561`). (c) is a good immediate
one-line hotfix to stop the bleeding, but it should not be the final answer.

## 6. Two linked observations — same blind spot, NOT fixed here

These share the same root: **an external process cannot see a remote job's real state, so the tool
infers health from local silence.** Link them to this report; do not fix them in the same change.

**(i) The `WEDGED` marker fires on a HEALTHY cloud lane.** `run-build.ps1`'s wedge watch
(`run-build.ps1:528`: `elseif (-not $cloudBound -and -not $wedged -and ...)`) is meant to skip a
cloud-bound run, but `$cloudBound` (`run-build.ps1:127`) is true only when the effective placement is
literally `cloud` or `AGENTQ_PLACEMENT` is exported to it — and on the **auto → cloud** path run-build
holds `auto`, never sees agentq's resolved placement, and so marks the ticket WEDGED. Measured: the
gate pipes the child's output through `Tee-Object`, PowerShell flushes a piped stream in blocks, both
logs stay empty ~20 min, the wrapper prints `WEDGED: build output silent AND the process tree idle for
10 min`; the lane then ends `[devcloud] exit 0` in 202.4 s and the wrapper prints
`build output resumed (WEDGED cleared)`. A false positive on a lane that was working the whole time.

**(ii) The fix direction for both is the same.** Do not infer a remote job's health from local silence.
Publish and read the job's **own** state — the job directory in the bucket
(`gs://<ctl>-devcloud-jobs/jobs/<id>/…`) and the journal — the way `agentq-cloud.ps1:93` already
argues evidence should live (it moved a gate result out of a terminal buffer into the target repo for
this reason). A `WEDGED` verdict, and a placement decision, should both be able to ask the job what it
is doing instead of guessing from a quiet local log.

## 7. Reporting

- **VERIFIED**: every anchor in §3 re-read at the cited line; `pwsh -File <missing>` exits 64;
  `run-build.ps1` sets `AGENTQ_WHERE`-honouring `$whereEff` and only treats a literal `cloud` placement
  as cloud-bound; `Get-CmdKind` classifies `\.ps1` as `gate-script`; the Linux image installs `pwsh`.
- **VERIFIED via source**: the chain in §2 (each hop read at the cited line).
- **EXPECTED**: the two failing job logs themselves (`20261126-072021-34677b`,
  `20261126-072626-feb9ba`) were reported by the coordinator from the devcloud pool; this report
  re-derives the mechanism from source rather than re-running the jobs. The Linux-side `exit 64` is the
  same pwsh usage exit verified locally.
- File a tracker row for this (next free id in `docs/TRACKER.csv` is **OQ-073**) and an ADR only if (a)
  is adopted, since it adds a placement knob.
