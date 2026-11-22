# Shared-clone hygiene — never edit the shared clone

A **shared clone** is the long-lived checkout every agent works in: `E:\gh\codai`, `E:\gh\brivio`, and the
other repos whose `agentq-config.json` marks them `sharedCloneMode: refuse`. Treat it as a **read-only**
workspace. Source edits, tracker edits and commits belong in a **leased slot**, never here.

## Work in a leased slot

```powershell
# take one (prints the path + a leaseId)
agentq lease -Purpose '<why>'
#   -> E:\gh\.wt\<repo>\task-N      (a linked worktree; edit, build, commit, push here)
# give it back when the work is pushed
agentq unlease -Repo <slot> -LeaseId <id>
```

## Why

`git-autosync` fast-forwards the shared clone to `origin/main` on a schedule. It **cannot move while the
tree is dirty or an unpushed local commit exists** — it prints
`refuse: <N> local edit(s) collide with incoming and are still being edited` and the clone (and everyone
reading it) stays pinned at a stale HEAD. **One live edit in the shared clone pins it for everyone.**
A commit made in the shared clone is worse: an unpushed commit blocks the same fast-forward, and
`git-autosync` will revert colliding drafts.

## If no slot is free — do not leave new files in the shared clone

- **Publish immediately** (works in a `sharedCloneMode=refuse` clone, where `commit` and `land` are
  refused): `agentq publish -Paths a,b -Message 'type(scope): msg' -Purpose '<why>' -Onto main`.
- **Or keep scratch in `.copilot-tmp/`** (gitignored; never tracked).

## Trackers: `plan/*-CANONICAL.csv` are generated — never hand-edit the canonical

- Write an **append-only fragment**: `plan/<tracker>-CANONICAL.rows/<date>-<id>-<slug>.csv`
  (first line = the exact header of `_base.csv`; one row per line; only the rows you own).
- **Regenerate** the canonical with `node scripts/ops/tracker-union.mjs` (the fragments are the truth,
  the canonical is derived). Gate: `pnpm gate:tracker-union`. Runbook: `docs/runbooks/tracker-union.md`.
- A fragment landed **without** the regenerated canonical turns `gate:tracker-union --check` red on `main`.

## Guardrails

- `ps/hooks/guard-tooluse.ps1` **WARNS** (warn tier, not deny) on a raw `git commit` in a shared clone and
  on writing a `plan/*.csv` in a shared clone — it names the verb to use instead.
- `ps/bin/shared-clone-janitor.ps1` can **salvage** an unowned dirty set: back it up, `agentq publish` it,
  then path-scoped clean. **Dry-run by default**; act with `-Apply`. It never discards anything it did not
  publish, and it skips a repo with a live writer, an active `commit:`/`land:` ticket or a rebase in flight.
