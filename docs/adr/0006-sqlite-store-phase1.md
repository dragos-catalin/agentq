# ADR 0006: one SQLite store, phase 1 (journal index + jobs mirror) (ADR 0003 W4-3)

Status: accepted 2026-10-19 (owner decision via askQuestions: node:sqlite, phase 1 = journal index + jobs mirror with the read side for status and slo; tickets stay files).

## Context

- `journal.jsonl` gets ~3,000 lines a day (62,106 events in 3 weeks), rotates at 64 MB, and every reader (`slo`, `log`, `metrics`, Read-Journal, the hub sync) re-parses it: `agentq slo -Hours 168` parses the whole file on every call.
- Jobs live as one JSON file per job (2,428 files before W1-6 pruning). `jobs.ps1 list` reads all of them.
- Tickets and leases are files guarded by named mutexes. They work, and every live agent on the machine depends on them. Moving grants into SQLite is the end state of W4-3, but it rewrites the scheduler core.
- Node 26 ships `node:sqlite` (SQLite 3.53, WAL verified on this machine 2026-10-19). There is no native dependency to install.

## Decision

Phase 1 (this ADR):

1. `agentq-store.mjs` owns `<AGENTQ_HOME>/agentq.db` (WAL, `busy_timeout` 5 s, `BEGIN IMMEDIATE` for writes). Tables:
   - `journal(id INTEGER PRIMARY KEY, ts TEXT, event TEXT, repo TEXT, resource TEXT, session TEXT, line TEXT)` with indexes on `ts`, `(repo, ts)` and `(event, ts)`.
   - `ingest(file TEXT PRIMARY KEY, offset INTEGER, inode TEXT)`: byte offset per journal file, so ingestion is incremental and survives rotation (a rotated file is read to its end once).
   - `jobs(id TEXT PRIMARY KEY, label TEXT, state TEXT, started TEXT, ended TEXT, exit INTEGER, cwd TEXT, json TEXT, mtime REAL)`.
2. `node agentq-store.mjs sync` ingests new journal bytes and upserts changed job files (by mtime). It is idempotent, and it runs from the 30-minute prune task and before every store read.
3. Read side: `agentq slo` reads its window from the store (`SELECT line FROM journal WHERE ts >= ?`) when the store exists and is in sync; otherwise it falls back to the file. `agentq store status` prints the row counts, the last ingested ts, the lag in bytes and the db size. `agentq store query -Event <e> -Hours N [-Repo r]` returns journal rows as JSON lines (for agents and the hub mirror).
4. The JSONL files stay the source of truth in phase 1. The store is a rebuildable index: `agentq store rebuild` deletes it and re-ingests everything.
5. `AGENTQ_NO_STORE=1` disables every store read (pure file mode).

Phase 2 (a later ADR, its own gate): tickets, leases and grants in the store (`BEGIN IMMEDIATE` replaces the sched mutex), with file tickets still readable during migration and a dual-write period measured by `agentq slo`.

## Consequences

- No new runtime dependency. A corrupted db is never fatal: readers fall back to files and `rebuild` restores it.
- A write to the journal stays a single append. Ingestion lags by at most one sync.

## Verification

`test-store.mjs`: incremental ingest (second sync adds only new lines), rotation (old file finished, new file from 0), a bad line skipped, jobs upsert by mtime, query by event/repo/window, rebuild equals incremental, slo from store equals slo from file on the same fixture.
