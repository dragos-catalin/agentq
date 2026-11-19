# ADR 0011 — Daemon health record (the `daemons` contract)

Status: accepted (2026-11-19)

## Context

Several long-lived tools (today: `git-autosync`) run as scheduled tasks and must be observable from
outside the machine — the codai gateway / hub mirror `~/.codai/coord` and render a health view, and the
operator needs one command that says whether a daemon is doing its job. Each tool already answers a
`-Doctor` question in prose; the missing pieces were a _machine_ form and a place to keep its history.

## Decision

**A daemon exposes its health as one JSON line on stdout, `-Doctor -Json`, and exits 3 when it has a
FAIL (else 0).** The record is frozen (consumed by the gateway and hub — do not rename a key):

```json
{
  "name": "git-autosync",
  "at": "<ISO-8601 UTC>",
  "verdict": "ok | warn | fail",
  "okCount": 0,
  "warnCount": 0,
  "failCount": 0,
  "lines": ["OK ...", "WARN ...", "FAIL ..."],
  "failStreak": 0,
  "history": [{ "at": "<ISO-8601 UTC>", "verdict": "ok | warn | fail" }]
}
```

- `lines` ≤ 60 entries, each ≤ 400 chars (the full human report is unbounded; the record is a window).
- `history` ≤ 48 entries, **newest LAST**.
- `verdict` is derived from the counts: `fail` if `failCount > 0`, else `warn` if `warnCount > 0`,
  else `ok`. `okCount` counts the non-problem lines.

**The record is persisted to `<coord>/daemons/<name>.json` by `agentq-sync`**, which runs each
configured daemon with `-Doctor -Json` once per pass, appends to `history` (cap 48), advances
`failStreak` (increment on `fail`, reset to 0 otherwise) and writes the merged record back. The daemon
list is fleet policy in `agentq-config.json` (`autosync.daemons`, default `["git-autosync"]`); the same
array is sent in the `agentq-sync` push body. A daemon that fails to run is skipped — never a push
failure.

`git-autosync -Doctor` also journals its verdict **once per change** (event `daemon-doctor`, with the
counts) into the coord journal, and stores the last recorded verdict in
`~/.codai/git-autosync-state.json` (`lastDoctorVerdict`) so a per-minute `-Doctor` cannot drown the
journal. `-VerifyBackups -Json` returns the companion object `{ at, exit, unreadable, repos:[{repo,
readable, total, unreadable:[...]}] }`.

`agentq doctor` reads `<coord>/daemons/*.json` and folds each daemon's verdict into its own report
(`fail` → problem, `warn` → warning); it never re-runs the daemon tool for this.

## Consequences

- One shape (`{ name, at, verdict, okCount, warnCount, failCount, lines, failStreak, history }`) is the
  whole contract; every surface (hub daemons view, `agentq doctor`, `agentq-sync -Status`) reads it.
- Adding a daemon is a config edit plus a tool that supports `-Doctor -Json`.
- History is bounded and local; the hub mirror is the archive.
