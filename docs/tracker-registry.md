# Tracker registry — operator README

How to make a repo's existing tracker readable by the fleet, and how to check it.
The **design** (layers, live state, resume protocol) is `docs/tracking-and-resume.md`.
This file is the practical companion: the file shape, the two commands, the
onboarding recipe, and the traps that cost real time while onboarding 13 repos.

## What a registry is

One committed file per repo: `<repo>/.agentq/trackers.json`. It adds no tracker of
its own — it says **how to read the tracker files the repo already has**. Because
it is committed, the mapping survives every clone, slot, machine and agent.

```json
{
  "version": 1,
  "repo": "myrepo",
  "trackers": [
    {
      "id": "plan",
      "file": "plan/plan.csv",
      "format": "csv",
      "columns": { "id": "ID", "title": "Title", "status": "Status", "notes": "Notes" },
      "idPattern": "^[A-Za-z]{1,8}-?\\d{1,6}[a-z]?$",
      "status": { "map": { "in progress": "in-progress", "wip": "in-progress", "done ": "done" } },
      "index": { "kind": "plan", "order": 1 }
    }
  ]
}
```

- `columns` names the **physical** header cells (after `trim()`), not a canonical spelling.
- `status.map` must cover **every** token the file actually contains. An unmapped token is
  a drift finding, never silently accepted.
- `idPattern` is OPTIONAL and is a _guard_, not documentation — see below.
- Write it LF, **no BOM**, 2-space indent, trailing newline, and format it with the
  repo's OWN prettier config when that repo has one.

## The two commands

```powershell
# lint one repo: prints counts, then one line per drift; EXIT CODE = number of findings
node E:\gh\agentq\tools\tracker-lint.mjs --root E:\gh\myrepo

# rebuild the merged cross-repo index (a rebuildable VIEW, never a truth)
node E:\gh\agentq\tools\tracker-lint.mjs --root E:\gh\a --root E:\gh\b
#   → $AGENTQ_HOME | ~/.codai/coord/trackers/index.json
```

Exit codes: `0` clean, `N` = N drift findings, `2` = no registry found.
**Pass explicit roots.** `--scan --all` resolves its base from `$HOME/gh` and finds 0
repos where the fleet actually lives on `E:` — always name the repos.

Two spellings, and only one of them is a flag list:

- `--root <repo>` — **repeat it**, one repo per occurrence. This is the form to use.
- `--scan <dir> <dir> …` — the directories are **positional**, not repeated flags; it is
  a directory walk, so it is what a discovery script uses, not what a human uses.

`onboard-tracker.mjs` in the same directory is the **writer** (it emits the registry from a
CSV); `tracker-lint.mjs` is the **judge**. Run the writer, then run the judge and quote its
exit code. A writer that reports `wrote <file>` has proved nothing about the file.

### `index.kind` is a closed vocabulary

Across the whole fleet the only values in use are **`plan`**, **`audit`** and **`product`**.
Do not invent a fourth spelling for a tracker that is really one of these — a new kind
silently splits a view that an operator reads as one list. The same rule applies to
`columns`: the keys seen fleet-wide are `category, decision, evidence, group, id, kind,
notes, status, title`, and nothing else.

## `idPattern`: add one, or deliberately do not

`idPattern` catches `bad-id-shape` (a truncated or pasted id) and is what makes
`dangling-narrative-ref` trustworthy. Add it only when a shape **accepts every id in
the file**. Then re-run the lint: a pattern that is too tight invents findings, which
is worse than having no pattern.

Leave the field out when a tracker's ids are genuinely free text. A pattern loose
enough to accept `A (b) = c > d` also accepts any prose, so it guards nothing —
a vacuous guard is worse than an absent one.

## Onboarding recipe (one repo, one writer)

1. `rg --files -g '*.csv'` in the repo; for each candidate read the **first record** and
   use it as the header row (a `#` banner line is data to the linter, not a comment).
2. Fill `columns`, then derive `status.map` from the distinct tokens in the status
   column — not from what the tracker's prose says it should contain.
3. Lift ids with the existing helper (`E:\gh\.copilot-tmp\measure-idwalls.mjs <root> <regex>`)
   and only then add `idPattern`.
4. Run the linter until it exits 0. Record the exact command and the exit code — an
   agent that reports "clean" without a number has reported nothing.
5. Commit the file the moment it is written. In a shared clone an untracked deliverable
   can disappear between two turns; a registry that is not committed is not onboarded.
6. Land it (branch → main/dev) and verify **by content**:

```powershell
git -C <repo> fetch -q origin
git -C <repo> rev-parse HEAD:.agentq/trackers.json      # mine
git -C <repo> rev-parse origin/main:.agentq/trackers.json  # landed
# equal blob ids = the landed blob is byte-for-byte mine. Do not use merge-base --is-ancestor.
```

## Traps measured while onboarding 13 repos (2026-11-28)

- **A PowerShell pipeline can lie.** `... | Select-String ...` over the linter's output
  printed `repo: 0 item(s)` with exit 0 and mojibake — a vacuous green. Redirect to a file
  and read the file, or run it as a child process and use its exit code.
- **BOM and CRLF.** Write LF/no-BOM. A CRLF or BOM habit will read as drift on a machine
  whose `core.autocrlf` differs from yours.
- **Generated canonical CSVs must stay byte-exact.** Editing a tracker that is regenerated
  from a source (`*-CANONICAL.csv`) moves the canonical too; restore it on the correct side
  (the generator, or byte-exact) instead of committing a whitespace-only rewrite.
- **Case-colliding status keys** (`backlog`/`BACKLOG` → `todo`, `done`/`DONE` → `done`) are
  harmless to a case-sensitive reader and a hazard only to a case-insensitive one.
- **Not every repo has prettier.** Format only where a config exists; where the binary is
  absent, leave the file as emitted rather than applying a tool's defaults.
- **Two files with duplicated ids are not registrable.** Where a CSV repeats one id 25×
  (and has an empty id), leave it out and say so — registering it would make every id-based
  finding meaningless.

## Repairing a torn CSV source (do it in place, and fail closed)

Some trackers are torn: a record whose notes field contains a newline, so the physical row
count no longer matches the record count and a naive reader sees a header in the middle of
the file. The linter will report it. Repair the **source** CSV, in place, rather than
teaching the registry to tolerate it.

Two rules keep that repair honest:

- **A re-serialiser must refuse to write when nothing needed repair.** If it rewrites every
  file it is pointed at, the diff is unreviewable and a no-op looks like a fix. Report
  `already well-formed` and write nothing.
- **Never repair from hardcoded line offsets.** A tracked file moves under you; offsets are
  wrong the moment a sibling commits. Parse the records and re-emit them.
- **`git status` clean is not proof of structural health.** A file can be byte-identical to
  the index and still be torn. The linter is the measurement; `git diff` is not.

## Onboarding at machine scale

To find every repo that has trackers (and every one that has a registry but a stale one),
walk one level under `E:\gh` and the nested roots (`E:\gh\frontiers\*`) rather than
guessing names: `E:\gh\.copilot-tmp\find-registries.ps1` is the working implementation.
It prints, per repo, whether `.agentq/trackers.json` exists.

One trap cost a whole pass: the merged index lives at `<stateDir>/trackers/index.json`, and
a discovery script that rebuilt that path with a **second** `Split-Path` ate the
`index.json` segment — every repo then read as "no registry". Print the path you are about
to read and `Test-Path` it before trusting an absence.

## Why the pointer rollout was reverted (measured, do not retry)

A repo's pre-push hook judges the **whole tree**, not the paths you staged. Two repos proved
it end to end: `afti`'s `scripts/hooks/pre-push.mjs` runs `pnpm typecheck` over everything,
and `marcai` had a sibling agent's **untracked** `packages/domain/src/reference.test.ts`
that failed with TS6133. In both cases a docs-only change could not be pushed.

So a cross-repo doc edit ("point every repo's agent file at its registry") **cannot be
automated from a shared clone**. It was rolled out to 38 repos and reverted byte-exactly
(`git show HEAD:<path>` written back with the file's own line endings, never
`git checkout --`). The content now lives here, in the canonical doc, and the machine-level
version is a written proposal for the owner. If you want it in a repo, land it in that repo,
in isolation, with its own gate.

## Coverage at the time of writing (2026-11-28)

Agents, repos and counts live in the merged index (`~/.codai/coord/trackers/index.json`),
which is the thing to read — do not copy numbers from this file, they age.
