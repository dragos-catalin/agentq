# The resident hook client

The harness starts a fresh interpreter for every `preToolUse` call, so the classic path pays a
PowerShell process start on each hook (~306 ms measured for `powershell.exe -NoProfile`, ~395 ms for
`pwsh`). The resident path removes that cost: `hookc.exe` connects to a long-lived host over the named
pipe `\\.\pipe\codai-hookc`, the host runs the guard **in its own process** and answers over the pipe.
On **any** failure — no pipe, a busy pipe past the connect budget, a short write/read, the deadline —
the client falls back to exactly what ran before (`powershell.exe -NoProfile -ExecutionPolicy Bypass
-File hook-pre.ps1`), byte-for-byte, so a client that cannot reach its server never becomes a skipped
guard.

Rig measurement (2026-11-25, `README.md`): 1535 ms classic vs 433 ms resident = 3.55x; installed form
~520 ms.

## File roles

All live in `ps\hooks\resident\` in the repo and in `~/.copilot/hooks/resident/` when installed.

| file                     | role                                                                                                                                                                                                                                                                             |
| ------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resident-server.ps1`    | the host: owns `\\.\pipe\codai-hookc`, hosts the guard text in-process (`HostMode subst`), replies with the binary frame the C client expects.                                                                                                                                   |
| `hookc.exe` / `hookc4.c` | the client the harness invokes, and its source. Connects to the pipe; falls back on any failure.                                                                                                                                                                                 |
| `build-client.ps1`       | builds the client from `hookc4.c` (needs mingw `gcc`). `-Check` compiles to a temp name and compares bytes, so source↔binary drift is detectable. Default output name is `hookc4.exe`; the live name the host launcher looks for is `hookc.exe`, so build with `-Out hookc.exe`. |
| `resident-ensure.ps1`    | starts the host if the pipe is not listening (silent), or `-Restart` replaces a running one. Called by `session-start.ps1` and by `install.ps1` after a guards change.                                                                                                           |
| `verify-resident.ps1`    | the acceptance check (below).                                                                                                                                                                                                                                                    |
| `dummy-silent.ps1`       | a peer that accepts a connection and never answers — the only fixture that can prove the client's own deadline.                                                                                                                                                                  |

The host reads the guard text **once** at startup, so editing `hook-pre.ps1` or the server changes
nothing until the host is replaced (`resident-ensure.ps1 -Restart`).

## The acceptance measure

```powershell
powershell -NoProfile -File ps/hooks/resident/verify-resident.ps1 [-N 5] [-BindMs 30000]
```

Flags are real (`param()` block): `-N 5` timing calls, `-TimeoutMs 10000` client budget,
`-DeadlineMs 3000` the tight silent-peer budget, `-BindMs 30000` how long to wait for the host to bind.
It prints one verdict block and writes `verify-resident.out.txt`.

**Run it on a quiet machine.** The point of the measure is latency, so it compares classic against
resident averages; a concurrent gate changes both numbers and a loaded box can go red against the
machine, not the client. Measured 2026-11-28: the same unchanged copy printed `ALL PASS: True` at
17.7-18.7 busy cores of 32 and went red at 21.7. Treat ~19 busy cores as the practical ceiling.

Two thresholds in that block used to judge the machine and had to be rewritten:

- the concurrency case now demands (a) the host **claims** a pool of at least two instances and (b) at
  least **two** callers are served without a spawn — never against the burst, and not against the pool
  count either. Measured: a burst-relative count (`>= 5 of 6`) went red at 4/6; a pool-anchored one
  (`served >= instances`) went red at 2/6 while the same host served 5/6 twenty minutes later; a pool of
  one serves 1/6 **and 2/6**, so the CLAIM is what catches the regression and the served floor only
  corroborates that the claimed pool is used in parallel.
- a call that **fell back** no longer counts as a parity difference. The client's own notice (`hookc:
server busy past the connect budget (win32 121) - falling back`) is 71 characters, over the
  40-character diff window, so one busy instance used to produce TWO reds (`parity` and `pipeUsed`) and
  print a line that contradicted itself: `classic ALLOW resident ALLOW same=False`. `pipeUsed` is the
  single owner of "the resident path was not used".

A FRESHNESS gate runs **before** any host is started or killed. It hashes this script and the copy in
the source root and refuses (non-zero, one line, nothing spawned) when they differ, so a stale install
can never publish a verdict about a revision nobody has; finding no source copy at all is a refusal too
unless `-AllowUnprovenSource` says otherwise. `-CheckSource` runs only that gate (a suite or an installer
can assert freshness without touching the pipe).

The client is resolved as `hookc.exe` first and `hookc4.exe` second (a dev tree has only the build
name). A client **older than `hookc4.c`** is reported as a WARNING in the verdict rather than refused:
the installed binary is what the harness runs, and the freshness gate covers the script, not the binary.

Read the busy-core count before and during, e.g.

```powershell
(Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
```

The verdict is the last two lines; `ALL PASS: True` means every property held:

```
VERDICT corpus=8/8 parity=True classicUnchanged=True pipeUsed=True deny=True fallback=True deadline=True encOnly=0 installedForm=True emptyPayload=True rudeClient=True concurrent=True
  ALL PASS: True
```

(`parity` is semantic on purpose: the resident path runs the guard under PowerShell 7 while the
classic path spawns `powershell.exe` 5.1, and the two engines serialise the same JSON with a different
key order and a different rendering of Romanian characters. The harness compares the _decision_ plus
its rule/tier/path tokens, never the byte layout.)

## What the measure does to the machine

- It kills every holder of the pipe name (`resident-server.ps1`, `dummy-silent`, anything matching
  `codai-hookc`), clears `server.log`, then starts **its own** host on the **same** pipe — the default
  name, because the installed form is a bare `"command": "<...>\hookc.exe"` with no arguments.
- Its test host is capped: the run starts it with `-MaxRequests 200`, so it exits after 200 requests.
  The live host that `resident-ensure.ps1` starts is **uncapped**, so the capped one is not a
  substitute for it.
- Case 4 stops all `resident-server.ps1` processes and case 5 uses and stops the silent dummy, so the
  run leaves **no** host running. The live host must be restarted afterwards.
- While it runs, hooks from an open editor window fall back to the classic path (the live host is gone
  and, for a window, a silent dummy holds the pipe until a request times out), so live tool calls pay
  the classic spawn until the host is restored.

### Restore recipe (checkable)

Run this as a saved `.ps1` — the live path may not appear in a terminal command (see Traps):

```powershell
& "$env:USERPROFILE\.copilot\hooks\resident\resident-ensure.ps1" -Restart
Start-Sleep -Seconds 2
# 1. the pipe exists
$pipe = @([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -like '*codai-hookc*' })
"pipe holders: $($pipe.Count)"
# 2. exactly one host is running resident-server.ps1
$hosts = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
    Where-Object { "$($_.CommandLine)" -like '*resident-server.ps1*' })
"host processes: $($hosts.Count)"
# 3. the host reports the expected pool size in its own listening line
$log = Join-Path $env:USERPROFILE '.copilot\hooks\resident\server.log'
(Get-Content $log | Where-Object { $_ -match 'listening on' } | Select-Object -Last 1) -match 'instances=(\d+)' | Out-Null
"instances in log: $($Matches[1])"     # the launcher opens the default pool of 4
# 4. a served request is visible only here: expect a fresh 'req N' line ending 'exit 0'
(Get-Content $log | Where-Object { $_ -match '\breq \d+ ' } | Select-Object -Last 1)
```

## Traps

- A guard in this fleet refuses a terminal command whose text names a `~/.copilot/hooks/**` path, so
  any such path must live **inside a script file** (every live-path step above is shipped as a `.ps1`,
  never as a one-liner).
- A killed mutation run can leave the mutation in the tree; a harness must restore in a `finally` and
  assert the hash. For the client, `build-client.ps1 -Check` is that assertion (source vs on-disk
  binary).
- The host's **own `server.log` is the only place a served request is visible** — the process is
  started hidden, so an uncaught error prints to a console nobody sees. Read the log, not stdout.
- No helper in a restore script may share a name with a default PowerShell alias (`Kill`, `Sv`, `Ps`,
  `Sc`, `Gc`, `Where`, `Cat`, `Rm`, `Sleep`, …): a function is shadowed by its alias, silently. Real
  incidents: a `function Kill` never ran (aliased `Stop-Process`), a `function Sv` lost its `-Scope 2`.
- `Get-Process` exposes **no `CommandLine`** in pwsh 7, so that filter matches nothing and would start
  a duplicate host. Find the host with `Get-CimInstance Win32_Process`.
- Pool depth is fixed by the **first** instance that creates the pipe; `HOOKC_POOL=1` requests the
  broken single-instance shape on purpose (a single instance is the regression — ~16% of calls fell
  back while it was serving).
- The client waits at most `min(budget, 900 ms)` for a busy instance, then falls back; a caller queued
  past the pool is the queue doing its job, not a defect.
- The N0/ro-RO locale renders thousands with `.` — a log line reading `total 3.402 ms` is 3402 ms.
- A stale host left on the same pipe silently answers a whole run; the rig kills holders and requires
  the log's pid to equal the process it started, and refuses loudly otherwise.

## Verify the doc is true

Compare the installed revision with the repo source **by hash** (save as a `.ps1`; the live path is not
allowed in a terminal command):

```powershell
$repo = 'ps\hooks\resident'                                   # run from the repo root
$live = Join-Path $env:USERPROFILE '.copilot\hooks\resident'
foreach ($f in 'resident-server.ps1','resident-ensure.ps1','build-client.ps1','verify-resident.ps1','hookc4.c','README.md') {
    $a = (Get-FileHash (Join-Path $repo $f) -Algorithm SHA256).Hash
    $b = (Get-FileHash (Join-Path $live $f) -Algorithm SHA256).Hash
    '{0,-22} {1}  {2}' -f $f, $a.Substring(0,12), $(if ($a -eq $b) { 'same' } else { "LIVE DIFFERS ($($b.Substring(0,12)))" })
}
```

And the client source↔binary drift, which names no guarded path:

```powershell
pwsh -NoProfile -File ps/hooks/resident/build-client.ps1 -Check   # prints VERDICT: in sync / STALE
```

The running host also names its own revision in the log's `listening on … script=… (N chars, parsed in
M ms) pid=… instances=…` line, so a live reading can be matched against the source it was parsed from.
