# ADR 0008: post-land hook - `agentq land` starts the landed tree's `scripts/post-land.ps1` after the push

Status: accepted 2026-11-11 (requested by brivio ADR-0339 D14: a landing on `dev` must start the staging builder without an agent remembering to).

## Context

- `agentq land` already runs two repo-owned scripts from the landed tree: `scripts/land-resolve.ps1` during a pick and `scripts/land-finalize.ps1` before the push (ADR 0003 W3). Both run BEFORE the push and can refuse the land.
- Nothing runs AFTER the push. A repo that wants "every landing starts X" (brivio: the scheduled task that builds a staging candidate) depended on each agent doing it by hand, or on a polling timer.
- A land often runs under `agentq run` (the land gate, a job script). Since ADR 0003 W2-4 that process tree sits in a Windows Job Object with kill-on-close, so anything a land starts dies when the run returns.

## Decision

1. After a land has PUSHED, when the pushed tree contains `scripts/post-land.ps1`, agentq starts it with PowerShell 7, detached and hidden, and does not wait for it. No config key: the file's presence is the switch.
2. **Once per push.** The call sits in the single `if ($pushed)` block of `Invoke-LandSet`, which every successful push goes through (first try, flake retry, `--no-verify` after quarantined flakes). A batch of absorbed lands (W2-5) is one push and so one run, at the pushed tip. A bisected batch that ends in two pushes runs it twice, once per pushed tip. A land that pushes nothing (already upstream, conflict, gate, finalize, oversize, refused push) runs nothing.
3. **Never part of the land.** The land's exit code, output and duration do not depend on the script: a missing file, a script that throws, exits non-zero or hangs, and a start that fails all leave the land as it was. The whole hook is inside one `try/catch`; its return value is discarded. What the land does wait for is the start itself: reading one blob and one process-creation call (measured 65-120 ms; the WMI call has a 30 s timeout, after which the start counts as failed).
4. **Which copy runs: the pushed commit's.** The blob `<sha>:scripts/post-land.ps1` is read from the object database (`git cat-file blob`, bytes copied unchanged) into `<AGENTQ_HOME>/post-land/<repo>/<utc>-<sha12>-<id>/post-land.ps1`. Not the land slot (the next landing resets it) and not the main clone's working tree (it can lag behind origin, or carry someone's uncommitted edit). Run directories older than one day are deleted at the start of the next hook run, never by the run itself, so nothing races the detached process.
5. **Environment** (nothing secret): `AGENTQ_POSTLAND_REPO` = the main clone (parent of the common git dir, the same notion as `<repo>` in resource names), `AGENTQ_POSTLAND_BRANCH` = the `-Onto` branch, `AGENTQ_POSTLAND_SHA` = the pushed tip (full sha). Working directory = the main clone. A generated launcher (`run.ps1`, same directory) sets them, runs the script and appends its output and `EXIT=<code>` to `output.log` there.
6. **Detached and hidden.** On Windows the process is created through WMI (`Win32_Process.Create`, `ShowWindow = 0`): its parent is the WMI provider host, so it is in none of our job objects, and its console window is never shown. Measured 2026-11-11 from a process inside a kill-on-close job without `BREAKAWAY_OK` (what `Enter-AgentqJob` creates): a child started the way `job-start.ps1` does it (ShellExecute + Hidden) died with the job; `CreateProcess` with `CREATE_BREAKAWAY_FROM_JOB` was refused (win32 5); the WMI child survived. Consequence: the script gets the user's logon environment (PATH, USERPROFILE, TEMP), not the land's environment; the three variables come from the launcher. On Linux/macOS: `nohup ... &` through `/bin/sh`.
7. **Journal.** `post-land` (repo, branch, sha, pid of the started process) when it was started; `post-land-failed` (reason) when it could not be started. Nothing when the tree has no such script. The script's own failure is not a journal event: it is in `output.log`.
8. **Opt-out.** `AGENTQ_NO_POSTLAND=1` skips the hook (no process, no event).
9. **Scope.** `agentq land`, and so `agentq publish ... -Land`. Not `agentq commit` pushes.

## Consequences

- A repo script that needs the land's context must take it from the three variables; it cannot read the land's environment (`AGENTQ_HELD`, session, lane).
- The script is trusted exactly as much as the commit that was just pushed: anyone who can land can change what runs on the landing machine after the next land. That is already true for `land-finalize.ps1` and `slot-prep.ps1`.
- The existing land suites create repos without `scripts/post-land.ps1`, so they start no process and need no opt-out.
- A hook that hangs holds nothing of agentq's (no ticket, no lease, no job object). It is the repo's script's job to bound its own run time.

## Verification

`ps/tests/test-post-land.ps1` (temporary origin + clone, isolated `AGENTQ_HOME`): the hook runs once per land with the three variables, from the copy under `AGENTQ_HOME`, in a process created with show-window = hidden; a land that CHANGES the script runs the new content while the main clone's working tree still has the old one; a script that exits 1, throws, or sleeps 600 s leaves the land at exit 0, and the land returns while the sleeping hook is still running; that hook is still alive after a land that ran under `agentq run` (kill-on-close job object) has ended; no script, the opt-out and a refused push start nothing and journal nothing; a start that fails is journaled as `post-land-failed` and the land still exits 0; a batch of two absorbed lands is one run at the batch tip; run directories older than a day are removed by the next run; the journal has `post-land` with the sha and the pid. Mutants (hook before the push, waiting for the child, the working-tree copy, no opt-out, a plain child process, a visible window, once per topic, no journal, no cleanup, a start failure that propagates) are each killed by a named check.
