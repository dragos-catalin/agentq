# Background jobs: keep working, wait only when blocked

Agents stalled for hours on background work: a sync terminal "moved to background", a polling loop
in a shared terminal, a `run-build` child hung at `Terminate batch job (Y/N)?` after a foreign Ctrl+C,
a waiter regex (`^RB_EXIT`) that never matched. These tools replace all of that.

Rule: launch long work as a registered job, **keep working on independent items**, and wait only when
everything left depends on the job: one bounded `wait-job` (≤ 10 min, stall detection). Past 2× the
estimate or 5 min of silent log, the job is SUSPECT: investigate, do not wait longer.

## Usage

```powershell
$b = "$env:USERPROFILE\.copilot\bin"

# start (hidden own console, stdin = empty file, log <cwd>\.copilot-tmp\jobs\<id>.log, ends with EXIT=<n> + DONE)
pwsh -NoProfile -File "$b\job-start.ps1" -Label 'web typecheck' -Command 'pnpm --filter web typecheck' -Cwd E:\gh\codai -ExpectedMin 8
pwsh -NoProfile -File "$b\job-start.ps1" -Label gate -File .copilot-tmp\gate.ps1 -ExpectedMin 20 arg1 'arg two'

# bounded wait (exit 0 DONE, 1 FAILED, 2 STALLED + diagnostics, 3 TIMEOUT = still running)
pwsh -NoProfile -File "$b\wait-job.ps1" -JobId <id>
pwsh -NoProfile -File "$b\wait-job.ps1" -Log <path> -Done 'RB_EXIT=|DONE|EXIT=' -Fail 'Traceback|BUILD FAILED' [-Pid <n>] [-MaxMin 10] [-StallMin 5] [-EveryS 15]
pwsh -NoProfile -File "$b\wait-job.ps1" -Pid <n>

# registry
pwsh -NoProfile -File "$b\jobs.ps1" list [-All] [-Json]
pwsh -NoProfile -File "$b\jobs.ps1" show <id> [-Tail 30]
pwsh -NoProfile -File "$b\jobs.ps1" kill <id>
pwsh -NoProfile -File "$b\jobs.ps1" prune [-Days 7]
pwsh -NoProfile -File "$b\jobs.ps1" orphans [-Kill]
```

- `-Done` / `-Fail` are pipe-separated **literal** substrings (ordinal). `^RB_EXIT` matches the text
  `^RB_EXIT`; it is not a regex. A line `EXIT=<n>` / `RB_EXIT=<n>` with n ≠ 0 means FAILED.
- `-MaxMin` is capped at 10. STALLED prints the last 30 log lines, the pid's process tree with CPU
  seconds and working set, flags `Terminate batch job (Y/N)`, and shows `agentq status -All` when the
  log mentions a queue.
- `jobs list` states: `running`, `suspect` (runtime > 2× expected, or log silent > 5 min), `done`,
  `failed`, `killed`, `dead` (pid gone or recycled, no EXIT marker).
- `jobs orphans` reports pwsh/node/cmd processes running `.copilot-tmp` scripts, run-build or agentq
  with no live VS Code / copilot ancestor (scheduled-task children are excluded), plus DEAD and
  ownerless registry jobs. It never kills without `-Kill`.

## Registry

`<AGENTQ_HOME or ~/.codai/coord>/jobs/<id>.json`:
`{id,label,command,file,args,cwd,repo,pid,pidStart(UTC ticks),log,expectedMin,startedAt,state,ownerPid,host,exitCode,endedAt}`.
`agentq-sync` mirrors it as `jobs: [{id,label,command(≤500),cwd,repo,host,pid,state,exitCode,expectedMin,startedAt,endedAt,lastOutputAt,log}]`
(computed state, last 7 days, no env values). A gateway that does not know `jobs` ignores the field.

## run-build

- `-TimeoutMin` default is 240 (was 25: a busy queue made it give up and lose its place).
- The build child runs hidden in its own console with stdin from an empty file, so a foreign Ctrl+C
  cannot reach it and no prompt can block it.
- `-WedgeMin` (default 10): build log silent this long → `<ticket>.wedged` beside the agentq ticket,
  shown as `WEDGED(<n>m)` in `agentq status`, cleared when output resumes.
