# Tracking and resume — one plan, one tracker, resumable everywhere

This is the design for how work is tracked and resumed across agents, machines,
cloud workspaces and clients. It exists because of two measured failures:

1. **A stop loses the plan.** A chat that stops (crash, sleep, a handover, a
   second window) and is told "continue" re-derives the next step from a
   transcript instead of reading it. It does not re-dispatch its subagents, does
   not re-attach to in-flight jobs, and often takes the wrong next step. The
   plan was never written down; only the transcript held it.
2. **The status has no single source.** Every repo keeps its own tracker in its
   own shape (vitals `docs/tracker.csv`, agentq `docs/TRACKER.csv`, brivio ~50
   `*_TRACKER.csv`, codai ~40 `plan/*.csv`), each read by its own gate or by
   nobody. Nothing shows the fleet at once and nothing checks that two copies
   agree.

The cure is one shape, one status vocabulary, one live-state store, one view —
and a rule that the plan is written **before** work starts, not reconstructed
after it stops.

## The model

```
  git (the definition)              the live state (agentq)         the view
  ────────────────────              ─────────────────────           ────────
  <repo>/.agentq/trackers.json  ──►  $STATE/trackers/index.json  ──► Vitals Tracking page
        │                                   ▲   ▲                         │
        └── docs/tracker.csv (native,       │   │                    (read-only; no
            hand-edited, unchanged)  ───────┘   │                     second truth)
                                               │
  $STATE/chats/<session>.plan.json ────────────┘  ──► continue / resume, 'agentq plan'
  $STATE/tasks/<id>.json          (claim | next | block | done | handoff)
                                               │
                                               └──► Codwen account mirror (optional)
```

- **Git holds the definition.** A repo keeps whatever tracker file it already
  has; it adds one small `.agentq/trackers.json` that says how to read it. The
  mapping is committed, so it survives every clone, slot and machine. There is
  no forced migration — the mapping is the single source of truth for _how the
  tracker is read_, and it is the only new file a repo must add.
- **agentq holds the live state.** The cross-repo index, the session plans and
  the claimable tasks live under the agentq state dir, keyed by the same ids the
  committed trackers use. This is what a second machine, a cloud workspace or a
  client reads.
- **Vitals holds the view.** The desktop Tracking page reads the index
  read-only. It never writes project state and never becomes a second truth.

`$STATE` is the agentq state dir (`~/.codai/coord`, overridable with
`AGENTQ_HOME` for tests). Nothing in this design hardcodes a machine path.

## Layer 0 — the schema (`spec/tracker.schema.json`, `spec/plan.schema.json`)

One row shape every tracker reduces to — the common core is already present in
every existing file under some spelling:

| unified    | vitals       | agentq     | codai         | brivio          |
| ---------- | ------------ | ---------- | ------------- | --------------- |
| `id`       | id           | id         | id            | id              |
| `group`    | slice        | stage      | area          | epic/us         |
| `title`    | title        | title      | title         | title           |
| `status`   | status       | status     | status        | status          |
| `evidence` | verification | acceptance | gate+evidence | (column varies) |
| `notes`    | detail       | notes      | notes         | notes           |

Plus optional `owner`, `priority`, `paths`, `deps`, `commit`, `updated`.

**One status vocabulary.** `todo · in-progress · blocked · review · done ·
dropped · deferred`. Each repo maps its own tokens onto it in
`.agentq/trackers.json` (`status.map`). A token with no mapping is a drift
finding, never silently accepted — this is the loudest drift the survey found
(`in-progress` vs `in progress`, eight brivio words, free text in codai).

## Layer 1 — the per-repo mapping (`<repo>/.agentq/trackers.json`)

Declares, per tracker file: its `file`, `format`, the `columns` map, the
`idPattern`, and the `status.map`. It is small, committed, and the only thing a
new repo must add to be visible everywhere. Schema: `spec/tracker.schema.json#/$defs/trackerRegistry`.
Working examples: `agentq/.agentq/trackers.json`, `vitals/.agentq/trackers.json`.

## Layer 2 — the live state (agentq)

- **Session plan** — `$STATE/chats/<sessionId>.plan.json`: `goal`, `doneMeans[]`,
  `constraints[]`, `next[]`, `roster[]`, `jobs[]`, `todos[]`, `handoff`,
  `handoffPath`. Schema: `spec/plan.schema.json#/$defs/plan`. This is the record a
  resume reads; it is one file, not eleven scattered ones.
- **Tasks** — `$STATE/tasks/<id>.json`: claimable units (`claim`, `next`, `block`,
  `done`, `show`). Modelled on the messages template already in `ps/bin`. This is
  where **atomic claim** (two agents never get the same id), **dependencies**
  (`next` never returns a task with an open dep) and **handoff-as-an-object** live
  — OQ-031…OQ-034.

## Layer 3 — the cross-repo index (`agentq tracker scan`)

`tools/tracker-lint.mjs --scan` reads every repo's mapping, validates each
tracker, and writes one merged index to `$STATE/trackers/index.json` (schema:
`tracker.schema.json#/$defs/trackerIndex`). It is a **rebuildable view**, never a
truth: delete it and the next scan rebuilds it. Findings it reports today:
arity (a field pasted/dropped), duplicate id, bad id/group shape, unmapped
status, dangling narrative reference. These are exactly the defects the survey
found ungated: agentq's own `TRACKER.csv` is not covered by any gate today, and
nothing checks that two repos agree.

## Adding a repo to the index — `--scan` rewrites, it does not merge

`--scan` builds the index from exactly the directories it is handed and writes
that as the whole file — `const index = { version: 1, generatedAt, repos }`,
then a bare `writeFileSync`. It never reads the old index back and folds it in,
so a scan of one new root is a **replacement, not an addition**: every repo
already in the index disappears. The forms, quoted from the tool's usage header:

```
node tracker-lint.mjs [--root <dir>] [--json]        validate one repo
node tracker-lint.mjs --scan <dir> [<dir> ...]       scan repos, write index
node tracker-lint.mjs --scan --all [--json]          scan every child of $HOME/gh
```

`--scan --all` is not the general answer either: it expands to the children of
`$HOME/gh`, so a repo under `E:\GitHub` (cursuri) is never picked up.

Onboard a root by naming every root you intend to keep — the ones already in the
index plus the new one — in a single call:

```powershell
$idx   = Get-Content "$HOME\.codai\coord\trackers\index.json" -Raw | ConvertFrom-Json
$roots = @($idx.repos.root) + 'E:\GitHub\cursuri' | Sort-Object -Unique
node E:\gh\agentq\tools\tracker-lint.mjs --scan @roots
```

Then verify against the snapshot you scanned: no root that was in it has gone,
and the new root is present. The index is shared live state several agents
write, so the root set can move between reading it and scanning it; if a root
vanished, a sibling onboarded a repo in that window — re-read the index and
re-run with the union, never rescan the changed set alone. Getting it wrong is
silent in the scan and loud a minute later: `track.mjs status` lists fewer repos
than it did a moment ago, because the scan replaced the index with only what it
was given.

## Layer 4 — the view (Vitals Tracking page)

Reads `$STATE/trackers/index.json` (via the host) and renders repos → trackers →
items, with per-status counts, drift/sync/status warnings, and a locality
indicator (local-only vs Codwen account connected). It is the desktop sibling of
the codai hub. See the codai and Vitals notes for the implementation contract.

## Layer 5 — the cloud mirror (Codwen account)

Optional and owner-scoped: the index (or a summary) is mirrored to the Codwen
account so the same status is visible from the hub and the other clients. The
project-health SSOT already exists on codai main (`GET /v1/platform/projects`,
schema `projects-health.ts`, migrations 0222/0223); the tracker mirror extends
that surface rather than starting a new one. A project that is also a local
workspace is **linked**, never **merged** (one owner per fact).

## The resume protocol — the part that fixes "Continue"

1. **Leave a plan before you build or dispatch.** Before the first file edit or
   the first `runSubagent`, the agent writes `goal` + `doneMeans` + `next[]` +
   the `roster[]` it intends to dispatch. This is the rule the whole protocol
   rests on; encoded as a prompt directive and, where enforceable, a hook.
2. **The Stop hook updates it.** On a stop, the plan's `todos`/`roster`/`jobs` are
   reconciled from the transcript (reusing the todo-extraction already in the
   stop classifier) and `updatedAt` moves.
3. **A prompt-submit hook consumes it.** `ps/hooks/user-prompt-resume.ps1` is installed at
   `~/.copilot/hooks/` and registered in `codai-hooks.json` under the editor's config key
   **`userPromptSubmitted`** — the editor's own alias table maps that to its canonical
   `UserPromptSubmit` event, while a typed `userPromptSubmit` is not a key at all and is
   ignored without a diagnostic (read out of the editor bundle on 2026-11-28; the accepted
   vocabulary is in that hook's header). It detects a resume word, reads the plan, and
   injects `goal + next[0..] + pending roster + jobs` — so the agent does the same next
   step and re-dispatches the same subagents instead of guessing.
   Open on this machine (2026-11-28): `~/.copilot/hooks/test-config-integrity.ps1` still
   lists only `preToolUse, postToolUse, sessionStart, Stop` as known-firing, so its
   `hook registration` check flags this event until that live-only list is extended (an
   owner-ticket edit — the gate has no repo mirror and no agent may write the trust surface).
4. **`agentq plan`** prints the same record from a terminal, and the Vitals page
   shows it, so a person can see what "continue" will do before typing it.

The plan file is the one place a resume reads; the todo list, the subagent roster
and the in-flight jobs are fields in it, not three separate memories.

## Why this is the right long-term shape

- **One fact, one owner.** The committed tracker owns _what the work is_; agentq
  owns _where it is now_; the client only reads. No copy is a second truth, so no
  sync can diverge into two answers.
- **Portable by construction.** The mapping is in git, so the definition travels
  with the repo to any machine, slot, cloud workspace or clone; the live state
  travels with the agentq state dir.
- **Cheap to verify.** One command (`node tracker-lint.mjs --root <repo>`, or
  `--scan --all`) answers "is the tracker healthy" in milliseconds and exits with
  the finding count, so it drops into any gate.
- **Reusable.** A new repo is onboarded by writing one ~20-line mapping file; no
  code, no schema change.

## Roadmap (maps onto the existing OQ tracker — this is not new scope)

| step                               | tracker row      | what                                 |
| ---------------------------------- | ---------------- | ------------------------------------ |
| schemas + mapping format + linter  | (this work, new) | Layer 0/1/3 foundations              |
| tracker mapping for the fleet      | **OQ-030**       | add `.agentq/trackers.json` per repo |
| claim / next / block / done        | **OQ-031/032**   | Layer 2 tasks                        |
| conflict forecast from path claims | **OQ-033**       | `paths` on tasks                     |
| handoff as an object               | **OQ-034**       | `handoff` + `handoffPrompt`          |
| task timeline / flight recorder    | **OQ-035**       | journal ↔ plan                       |
| hub / Vitals / clients             | **OQ-060…066**   | Layer 4/5                            |
| resume-on-prompt hook              | new              | the `UserPromptSubmit` gap           |

## Open decisions

- **Where tasks are claimable from** — agentq state only, or also mirrored into
  the committed repo (so a claim survives even without the state dir)?
- **Cloud mirror granularity** — the whole index, or a summary + per-project
  drill-down on demand?
- **How strict the resume hook is** — inject-only (never blocks the prompt), or
  refuse to proceed when the plan is missing/stale.
- **Whether `tracker-lint` becomes a hard gate** in each repo's land gate, or an
  advisory `agentq doctor` check first.
