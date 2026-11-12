# Orchestrator stage 0: what changed in the PowerShell tooling

Stage 0 of [ADR 0009](adr/0009-orchestrator-daemon-tasks-control-plane.md) (tracker rows OQ-001 to OQ-012 in
[TRACKER.csv](TRACKER.csv)). Everything here is in `ps/` and is installed by `ps/install.ps1`. The tracker holds the
evidence and what is still open for each row.

## Leases

- **Chat keep-alive.** The per-tool-call hook (`hooks/guard-tooluse.ps1`) binds a chat to the lease of a slot it works
  in: an edit inside the slot, or a command that names it. Every later tool call of that chat refreshes the lease. A
  chat active within `leaseDeadIdleMin` counts like a live owner shell. Reading a file in a slot does not bind, and
  neither do the inspection verbs of agentq.
- `status` shows `chatMin` and the state `chat`. The journal events `lease-expire` and `lease-break` carry `chats`,
  `chatIdleMin` and `byChat`.
- `AGENTQ_NO_CHAT_KEEPALIVE=1` turns it off.
- The `release when done` line printed by `lease` names `agentq.ps1`. The old line named a file that cannot run on its
  own.

## Landing

- **Pre-gate.** `agentq land` run from a leased task slot runs the gate on the rebased result in that slot before it
  takes the land ticket. A failing gate exits 6 before the queue. Config: `landPregate`, `landPregateRounds`.
  `AGENTQ_LAND_NO_PREGATE=1` turns it off. Journal: `land-pregate-ok`, `land-pregate-failed`, `land-pregate-skipped`.
- **Green ledger.** A tree that passed a gate command is remembered for `greenTtlHours` (168) and is not gated again in
  the queue. Journal: `land-gate-skipped-green`. `AGENTQ_NO_GREEN=1` turns it off.

## Admission

- **By load.** `agentq probe` measures the start latency of a trivial process. While the recent median is above
  `admission.probeMs`, agentq grants no new task lease and no second gate, heavy or batch build. Quick and interactive
  jobs are never held. A waiter held longer than `admission.maxHoldMin` is admitted anyway. The one build a saturated
  machine still starts is the first in rank, so a lower-priority waiter cannot start ahead of a higher-priority one.
- `status` prints the probe and the verdict on the line `== LOAD`. Journal: `admission-hold`, `admission-override`, and
  `loadWaitSec` on `acquired` and `lease`. `AGENTQ_NO_ADMISSION=1` opts one call out.
- **By owner presence and schedule.** Config `agentLimit` lets the machine-wide limit on task leases differ while the
  owner is at the keyboard (`present`), away (`away`), or away inside the night window (`night`). A value that is not
  set means `taskSlotsMachine`, so the shipped config changes no limit. `status` prints the limit in force and the
  reason on the line `== AGENTS`. Journal: `agent-limit-hold`. `AGENTQ_NO_AGENT_LIMIT=1` opts one call out.
- A lower limit stops nothing that already runs.

## State folder

- `agentq status`, `log`, `metrics` and `doctor` only read the state folder. Dead tickets are reaped by working verbs
  and by `sweep`.
- `agentq prune` (`-WhatIf`, `-Days`, `-All`, `-Json`) removes old agent, job, notice, release and batch files and idle
  queue folders. `sweep` runs it.
- A queue folder is created under the queue mutex, so `prune` cannot remove it between the check and the first write.
- `agentq doctor` (`-All`, `-Src`, `-Json`) reports stale index locks, empty package-store folders, install and config
  drift, dead owners and keepers, old marks, state size and scheduled tasks.
- `agentq slo` adds queue time, waits over 10 minutes, the land ticket hold, hook cost per day, start-probe buckets and
  slots lost while their chat was live.

## Hooks and install

- `ps/hooks/hook-pre.ps1` and its suite live in this repository and are installed from it. The hook appends one cost
  line per call to `hooks/cost-<day>.jsonl` in the state folder.
- The guard reads `sharedCloneMode` without a switch that Windows PowerShell 5.1 lacks. The editor starts the hook with
  5.1, so the configured mode was ignored there before.
- The shipped config sets `sharedCloneModeRepos` to `refuse` for the two repositories that have the most slots. Every
  other repository keeps the advisory.
- `ps/install.ps1`: `-Suites a,b` gates an install on chosen suites. `agentq-config.json` is merged: keys the installed
  copy has keep their local value, missing keys are added. `bin/agentq-install.json` records what was installed.

## Tests and CI

- `ps/tests/run-all.ps1` has `-Only`, `-Skip`, `-List`, `-LogDir` and `-TimeoutMin`. See
  [ps/tests/README.md](../ps/tests/README.md).
- `run-all.ps1` sets `AGENTQ_NO_ADMISSION=1` for every suite: a suite must not depend on how busy the machine is. The
  suites that test admission clear the variable and fake the probe.
- The `ps` job in CI runs every suite on a hosted Windows runner. It installs a pinned ripgrep release and checks its
  SHA-256, because the hosted image has none.
- The `jobs` suite reaps a dead holder with `sweep`; it relied on `status` doing it.
- Case 10b of the `git-autosync` suite gives the upstream commit its own date. Made in the same second as the local
  commit, it took the "replayed by hand" path and failed on a fast runner.
