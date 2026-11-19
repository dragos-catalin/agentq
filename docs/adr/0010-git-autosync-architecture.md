# ADR 0010 — git-autosync: the shared-clone fast-forwarder, and why it can never lose work

Status: accepted (2026-11-19). Tool: `ps/bin/git-autosync.ps1` (installed to `~/.copilot/bin/git-autosync.ps1`),
scheduled task `git-autosync`, tests `ps/tests/test-git-autosync.ps1` (suite name `git-autosync`).

## Context

Every repo has ONE shared clone (`E:\gh\<repo>`) that several agents read and write at once, plus leased
worktrees under `E:\gh\.wt\<repo>\<slot>`. Agents commit and push from the worktrees, so the shared
clone's branch silently drifts behind its upstream and shows "ahead N / behind M" where the N are
duplicates already on origin. Nobody may hand-`git pull`/`reset` a shared clone: that destroys whatever
another agent has uncommitted in it, and it has already happened once (2026-11-18: 195 dirty + 50
untracked files discarded by a `reset --hard` whose safety guard failed open — see the falsy-array trap
below).

`git-autosync` is the single component allowed to move a shared clone's branch. It runs as a scheduled
task over 24–25 repos and must be safe against arbitrary concurrent edits by other agents.

## Decision: the guarantees

The tool may move a branch **only** when all of these hold, and it enforces them in this order per repo:

1. **No operation in flight.** `index.lock`, `MERGE_HEAD`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`,
   `BISECT_LOG`, `rebase-merge`, `rebase-apply` present → skip. Detached HEAD, no upstream → skip.
   An `agentq commit:<repo>` ticket held → skip.
2. **No real unpushed commit is ever dropped silently.** `git cherry up HEAD` '+' entries are unpushed
   work. They are either (a) replayed onto upstream in the object store and landed via `agentq land`
   (only for `ReplayRepos`), or (b) in `LocalCommitRepos` (vitals policy) held, or (c) otherwise refused
   with a named reason. A commit is dropped only when (i) it is a **twin** — same author email + subject
   upstream and every file it touches was either written upstream already or rewritten by the twin — or
   (ii) `-ParkConflictingCommits` and it **conflicts**, and in BOTH cases only after the whole state is
   backed up and the backup push is verified with `ls-remote`. `-Superseded` drops a commit whose every
   path is byte-identical upstream, after rebuilding the chain and asserting the tree is unchanged.
3. **A dirty path is resolved, never discarded.** For each path the move would change:
   - already equal to the upstream blob → staged from upstream;
   - equal to an **intermediate** upstream blob, or whitespace/EOL-only vs HEAD → **superseded** (blob
     kept in the object store, id in the log line);
   - 3-way merge clean (EOL-normalised) → **merged**, result written back **uncommitted** after the move;
   - otherwise → **park**, but only when the file is idle ≥ `-ParkIdleHours` (default 1) AND no live
     agent session touched it in the last 30 min (`who-owns-file.ps1`; a _failing_ check counts as
     active, i.e. fail-closed). Otherwise → **hold** (refuse), naming the files.
4. **Backup before any write.** Any park/merge resolution first writes the WHOLE dirty state (tracked +
   untracked) as a commit on a temp index, to `refs/backup/shared-clone/<repo>-<ts>`, plus a thin local
   bundle, plus a push to the backup destination. Private repos → origin; **public or unknown → the
   private `-BackupUrl`** repo, because a backup branch on a public origin publishes WIP drafts. If the
   push's `ls-remote` does not return the local sha, **nothing is parked and nothing is moved**.
5. **The move itself is `git read-tree -m -u HEAD <target>`** — exactly what `git checkout` does: it
   updates only files that changed upstream and are clean locally, and KEEPS every other staged/unstaged
   change. The branch ref is then moved with `git update-ref ... <target> <old>` (old-value compare), so
   a concurrent writer loses the race instead of being clobbered. The pre-move tip is kept in
   `refs/backup/autosync/<branch>`.
6. **Recovery surfaces that outlive the tool**: `refs/backup/shared-clone/*` (whole dirty state),
   `~/.codai/parked/<repo>/<ts>/` with a `MANIFEST.tsv` and byte copies, `refs/backup/wt/<repo>/<slot>/*`
   (per-slot lease/`agentq backup` snapshots), `refs/backup/autosync/<branch>`, and per-repo bundles.

### The PowerShell trap that broke this once (do not reintroduce)

`@() -notmatch 'x'` filters a collection and yields an EMPTY array, which is **falsy** in `if`. A guard
written as `if ($array -notmatch $sha) { abort }` therefore does not abort when `$array` is empty — it
fails OPEN. Write guards as `if (-not $x)` / `if ($x.Count -eq 0)` / `if (-not (… | Select-Object -First 1))`.
The same class as `$null -notmatch …`. The current script uses the safe forms; keep it that way.

## Decision: the daemon runs ONE PASS PER TICK (2026-11-19)

The scheduled task runs the script **without `-Loop`**, on a **2-minute repetition trigger** (plus
at-logon). Reasons, measured:

- A long-lived `-Loop` process keeps the copy of the script it loaded at start. On 2026-11-18 the
  per-repo status snapshot landed at 07:37 while the loop (started 05:16) was running; for the next
  20 h the loop kept syncing (log lines at 01:45Z) but **never wrote a status again** — `-Status`
  showed all 24 repos "stale" and read as "the daemon is dead", costing a diagnosis round.
- One pass per tick means every tick reads the current code: an edit is live on the next tick, and the
  snapshot's age is a truthful signal.
- `MultipleInstances=IgnoreNew` skips a tick whose predecessor still runs; `ExecutionTimeLimit=30 min`
  (~5× a measured full pass) ends a wedged pass so IgnoreNew cannot wedge every later tick;
  `StartWhenAvailable` runs a tick missed to a reboot or sleep.

`-Loop` remains for a manual run (and its mutex, `Global\git-autosync-loop`, is taken only then).
`-InstallLoop` restores the long-lived model for anyone who wants warmth, with the freeze documented.
`-Install` stops whatever model is live first, including a loop started outside the task.

## Decision: status must be truthful

`~/.codai/git-autosync-status.json` holds the per-repo verdict of the last pass. Two fixes:

- **Ghost keys** are dropped on a full pass (`$Repo.Count -gt 1`): the map previously only grew, so a
  key written when the repo list held something else lingered forever and rendered as a live verdict
  (a phantom repo `a` sat in the table for weeks). A single-repo run (manual/test) still merges, so it
  never wipes the rest of the table.
- **Freshness is reported**, not just per-repo ages: `-Status` prints the newest verdict age and
  `FRESH`/`STALE` (`> 15 min` with a repeating trigger means ticks are not landing), the task's last
  run + result + next run, and marks any key not in the configured repo list.

`-Doctor` is the one-command answer to "is it doing its job now": task installed + repeating,
last result, snapshot freshness, ghost keys, and how many long-lived loops are running. Exit 3 on any
FAIL. Use it instead of hand-reading 25 repos.

## Consequences

- The shared clone's branch is never left ahead of upstream by more than the work autosync cannot
  classify; every refusal is named in the log and the status snapshot.
- Access to `E:\gh\<repo>` source in a shared clone is refused by ADR 0004 (source work happens in a
  leased slot), so autosync is the only writer of the shared clone's branch and working tree.
- Onboarding a repo or changing its policy (replay / local-commit / fetch throttle / park-conflicts) is
  a config edit (`agentq-config.json` → `autosync`), not a code change.
- Verification: `git-autosync.ps1 -Status`, `-Doctor`, `-Check`-style install drift via
  `ps/install.ps1`, and `ps/tests/test-git-autosync.ps1` (24 scenario groups: dirty edits kept, twins
  parked, conflicts refused vs opted-in park, untracked copies of upstream-added files, mode changes,
  whitespace/reflow, public-repo backup routing, backoff, owner-active hold).
