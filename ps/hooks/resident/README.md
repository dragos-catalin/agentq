# resident hook host

The resident hook host removes the per-call `powershell.exe` spawn from the preToolUse path: instead of
VS Code starting a fresh interpreter for every tool call, `hookc.exe` (the client the harness runs)
connects to a named pipe served by `resident-server.ps1` (the host), which runs the guard **in its own
process** and answers over the pipe. Measured 2026-11-25 in the acceptance rig: 1535 ms classic vs
433 ms resident, 3.55x, installed form ~520 ms.

| file                  | role                                                                                                                                                                                                              |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `resident-server.ps1` | the host: owns `\\.\pipe\codai-hookc`, runs the guard text in-process, replies with the binary frame the C client expects.                                                                                        |
| `hookc.exe`           | the client the harness invokes (built from `hookc4.c`). Connects to the pipe; on ANY failure it falls back to `powershell.exe -File hook-pre.ps1`, i.e. exactly what ran before this existed.                     |
| `hookc4.c`            | the client source.                                                                                                                                                                                                |
| `build-client.ps1`    | builds `hookc.exe` from `hookc4.c` (needs a C compiler, e.g. mingw `gcc`).                                                                                                                                        |
| `verify-resident.ps1` | the acceptance check: corpus parity between the classic and resident paths, deny-is-deny, the installed bare-argv form, the rude-client recovery, the deadline. Run after ANY change to the server or the client. |
| `resident-ensure.ps1` | start the host if it is not listening (silent), or `-Restart` replace a running one. Called by `session-start.ps1` and by `install.ps1` after a code change.                                                      |

## Why it is in the repository now

Until 2026-11-26 these files existed **only** in `~\.copilot\hooks\resident\` — outside version control
and outside `install.ps1`'s map. That is how a defect survived: `hook-pre.ps1` computed `startMs` from
`GetCurrentProcess().StartTime`, but on this path that is the **host's uptime**, not the call's start,
so `agentq slo` summed the server's uptime into `hook cost` and printed **318 162 h/day**.

Two consequences are baked into the code and the comments:

1. **A host must pass the request's receipt time.** `resident-server.ps1` sets `CODAI_HOOK_RESIDENT=1`
   once, and `CODAI_HOOK_REQUEST_MS=<epoch ms>` around each request; `hook-pre.ps1` turns that into
   `startMs`. Hosted **without** a number the field is written `null` — the header's contract is
   _"without a number the field is null, not a lie"_ — never the host's uptime.
2. **The host reads the guard text ONCE at startup.** Editing `hook-pre.ps1` (or the server) changes
   nothing until the host is replaced. `install.ps1` now restarts it via `resident-ensure.ps1 -Restart`;
   do the same by hand after editing either file.

`agentq slo` also flags (never clamps) a `hook cost` line whose `startMs` exceeds 1 h, naming this
directory, so the defect cannot be silently mis-read again.

## Installing / building

`install.ps1` copies the text files above (the map under `hooks\resident\`). `hookc.exe` is a compiled
artifact and is **not** in the map: build it once per machine with `build-client.ps1` (or copy an
existing one), then `resident-ensure.ps1` will start the host at the next session start.
