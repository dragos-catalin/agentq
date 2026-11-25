# The agent contract — how to work inside this repo

Written for the agents that maintain agentq itself (an `AGENTS.md` at the root is blocked by the
trust-surface guard; this file is the same content in a normal doc until the owner issues a ticket — see
_Proposing a change to the trust surface_ at the end).

agentq is the coordinator every other repo's agents queue through. `ps/` is the PowerShell build that is
**installed** into `~/.copilot/` and runs on this machine; `spec/`, `src/` and the npm package are the
TypeScript daemon direction (ADR 0009, still early).

Public repository: no secrets, no private repo names, no machine-specific paths in docs or tests.

## The contract

1. **Never edit the installed copy** (`~/.copilot/bin/*.ps1`, `~/.copilot/hooks/*.ps1`). Change `ps/**`
   here, then install. The installed copy is not tracked; a hand edit is lost on the next install and
   invisible to review.
2. **Install:** `pwsh -NoProfile -File ps\install.ps1` (`-Check` dry run, `-Full` force the suite,
   `-SkipTests`, `-Parallel n`). It merges `bin/agentq-config.json` into the installed config — keys the
   installed copy already has keep their local value, so a local override is legitimate, not drift. It
   **skips** the suite only when `ps/` is byte-identical to the tree that passed a full green run, and it
   prints both hashes: nothing is skipped silently.
3. **Tests:** `pwsh -NoProfile -File ps\tests\run-all.ps1 [-Only name] [-Skip name:reason] [-Parallel n]
[-List] [-LastGreen]`. A full green run writes `.copilot-tmp\last-green.json` (the hash of every file
   under `ps/`). **A `ps/**` write while a run is in flight voids the record** — the run prints
   "green record: NOT written" instead of claiming a tree that never passed. So: finish editing, then run.
4. **Every new behaviour needs a suite, and the suite needs a mutation check** — disable the new call and
   watch the suite fail, then restore. A green that survives the mutation is vacuous. Assert on the
   contract, never on an empty string (`-match [regex]::Escape($x)` with `$x` empty is always true), and
   assert that each expected verdict class actually occurs.
5. **Suites are hermetic.** Never assume how busy the machine is (`run-all` sets `AGENTQ_NO_ADMISSION=1`),
   never order steps with `Start-Sleep` — wait for a stop file — and never assert an absolute duration
   close to the operation's own runtime. A holder in a test waits for a file, not 90 s.
6. **Commit pathspec-only.** This repo is shared with other agents the same way every other repo is:
   `agentq commit -Purpose <why> -Message <msg> -Paths a,b` — never `git add -A` / `commit -a`, never
   `git checkout -- <file>` or `reset --hard`. Foreign uncommitted files stay staged and untouched.
7. **Per-repo policy belongs in `bin/agentq-config.json`** (`sharedCloneModeRepos`, `landGate`,
   `cloudWorkspaces`, `pinned`), never as an `if ($repo -eq 'codai')` in a code path. The one verb that
   may refuse a specific repo is the shared-clone guard, and it reads that map.
8. **Exit codes are a contract**: 0 ok · 2 usage · 3 frozen/blocked/timeout · 4 release superseded ·
   5 land conflict · 6 land pre-gate · 7 `lease -Wait` bound · 8 oversized changelog · 9 land finalize ·
   10 land deps. Never invent a new one; document a new one in `agentq help` and the ADR.
9. **Work handed to a slot is sacred.** Never delete or rewrite `refs/backup/**`: those refs (and the
   bundles beside them) are the only copy of work taken out of a slot, and `prune` deliberately leaves
   them alone. A take-over must say what it saved — `Publish-SlotTakeover` journals `lease-takeover`,
   appends to `slots/<repo>--<slot>.jsonl`, notifies the previous holder and prints the ref, the short
   sha and the exact restore command. Anything that resets a tree without that is a data-loss bug from
   the user's side even when the bytes were saved.
10. **A design decision goes to `docs/adr/NNNN-<slug>.md`** before the code, and it must record what was
    measured. A correction is an edit to that ADR, not a new one: mark the row FIXED with the date, the
    measurement and the suite name, or mark it NOT A DEFECT with the code evidence that says so. Read the
    code before believing an ADR row — ADR 0014's "land is fully serialized" had been false for months
    (the pre-gate already ran before the ticket) and its "commit holds the ticket across the gate" was
    true but understated (measured 10 s vs < 3.5 s once the phases were split).
    `docs/TRACKER.csv` carries OQ- ids for planned work.

## Precedence — who wins

When two sources disagree, this is the order. It is the answer to "the gate refused me, is that a
bug?"; check the levels above yours before blaming the code.

1. **A mark beats everything.** `frozen` / `blocked` on a resource refuses run, commit and deploy with
   exit 3. No flag, env var or config key below overrides it — with ONE exception, on `land:<repo>`
   marks only: a mark older than `landFreezeMaxMin` (config `landFreezeMaxMin`, default 30 min,
   `-1` disables) is EXPIRED, and the next land removes it itself, says so and journals
   `freeze-expired`. Every other mark (`incident` / `provider` / `deploy` / `slot`) never expires and
   is lifted only by `agentq mark -State clear -Reason '<why>'`, once the thing that caused it is
   actually over. A frozen resource is never bypassed "because the test needs it".
2. **The harness env vars are for hermetic suites, never for a real run.** `AGENTQ_NO_*`,
   `AGENTQ_FAKE_*`, `AGENTQ_TEST_SKIP`, `AGENTQ_NO_ADMISSION` exist so `run-all.ps1` does not depend on
   how busy the machine is. They may skip an _admission_ gate inside a suite; they may not relax a
   refusal, and a shell that is doing real work must not set them. `AGENTQ_HELD` is read, not typed: it
   is how a parent agentq tells a nested gate that the `commit:<repo>` ticket is already held.
3. **A CLI flag beats the config for that one invocation** (`-MinFreeGB`, `-Parallel`, `-Wait` /
   `-NoWait`, `-Lane`, `-NoPush`). A flag changes one run; it never changes the default for the next.
4. **Per-repo policy beats the generic default, and lives only in `bin/agentq-config.json`**
   (`sharedCloneModeRepos`, `landGate`, `cloudWorkspaces`, `pinned`, `releaseSlots`, `fairShare`). A repo
   named in that map gets its rule; every other repo gets the default. Adding `if ($repo -eq '…')` to a
   code path is the bug this level exists to prevent.
5. **`ps/bin/agentq-config.json` (source) → the installed copy.** On install, a key the installed copy
   already has keeps its **local** value and only new keys arrive, so a local override is legitimate and
   not drift — `install.ps1 -Check` prints what would change, and the green record's file hash is over
   `ps/**` only. Consequence: a behaviour that depends on a config value must be pinned by a test that
   sets it, or it will silently differ between machines.
6. **The working agreement beats the tool.** `~/.claude/rules/multi-agent-coordination.md` (and this
   file, in this repo) is the contract; agentq is the mechanical enforcement of it. When they disagree,
   the rule is right and agentq has a bug: fix the code and add the suite, do not route around the gate.

## PowerShell and Windows traps that have cost hours here

- Hooks run under **`powershell.exe` 5.1**, so anything touching `[ProtectedData]` needs
  `Add-Type -AssemblyName System.Security` first; a pwsh 7 check therefore proves nothing about the hook.
- **Never put a backtick in an `rg` pattern inside a one-liner**: the parser never closes the string and
  the terminal is stranded at `>>`. Validate one-liners with
  `[Parser]::ParseInput($cmd,[ref]$t,[ref]$e)` when they are not trivial, and move anything with braces
  into a `.ps1` under `.copilot-tmp/`.
- `"slot:$repoName:$slot"` is a parse error (`$slot:` reads as a scope) — write `${repoName}`.
- `rg 'x' ps/tests/*.ps1` fails on Windows (`os error 123`); use `-g '*.ps1'`.
- `[IO.File]::ReadAllText('relative')` resolves against the **shell process** cwd, not the caller's.
- `git for-each-ref` matches with `FNM_PATHNAME`: a single `*` never crosses a `/`, so
  `refs/backup/wt/<repo>/*` matches **nothing** (0 of 1607 refs, measured 2026-11-21) while
  `refs/backup/wt/<repo>/<slot>/*` matches. Use `/**` and select the slot in PowerShell.
- Files destined for Linux (cloud YAML, `.sh`) must be LF with no BOM.
- Long runs go through `job-start.ps1`/`wait-job.ps1` (bounded), not a blocking terminal call, and their
  output goes to a log that is read afterwards.

## Git traps that have cost hours here

- **A pathspec commit refuses an untracked path.** `git commit --only -- <path>` (what `agentq commit`
  ends up doing) fails with `pathspec did not match` when the file was never staged; stage it first
  (`git add -- <path>`). `agentq commit` does the add itself, so this only bites a hand-written commit.
- **A commit that failed leaves the branch where it started — already pushed.** After a refused commit on
  a throwaway branch, the remote ref still names the base commit, so landing that branch looks like "no
  work". Delete it (`git push origin --delete <branch>`) before pushing the real branch.
- **Do not re-commit an old worktree.** A parked worktree at a detached HEAD shows the same edits as
  again-staged files; `git diff origin/main --numstat -- <path>` per path is the cheap proof. Every path
  answering `IDENTICAL to main` except yours means only your files are unlanded, and the parked copies
  must not be committed a second time (measured 2026-11-25: five tracked files were byte-identical to
  main while appearing as staged changes).
- **Check your own diff before blaming the gate.** `install.ps1 -Check` names the drifted artefacts; if
  the ones it lists are not yours, they are another agent's uncommitted work and installing them would
  publish a half-finished snapshot machine-wide. Report the drift, do not clear it for them.

## Where the numbers live

`~/.codai/coord/journal.jsonl` is the hash-chained record of every acquire, release, expiry, break, mark
and note; `agentq log`, `agentq status -All`, `agentq slo` and `agentq doctor` read it. Quote a measured
number from it (with the resource and the window) instead of an estimate — ADR 0014 exists because a
queue that "felt slow" turned out to be one resource holding its ticket across a gate it did not need.

## Proposing a change to the trust surface

Rules, instructions, hooks, skills and agent files (including an `AGENTS.md` here) are guarded: an agent
cannot write them, and the guard says so instead of failing silently. Two legitimate paths:

1. **A proposal file** — `~/.copilot/rules/proposals/<ulid>.proposal.json` with
   `{ rule, reason, evidence[], created_by }`, plus the exact snippet to apply. The owner reviews it.
2. **A ticket** — only the owner can issue one, interactively, and it is bound to their identity:
   `pwsh -NoProfile -File "C:\Users\vladu\.copilot\hooks\rules-ticket.ps1" -Issue -Scope '<glob>' -Hours 2`.
   Write the glob as an absolute path; the matcher has no `{a,b}` alternation and anchors `**/` to the
   current repo. **A quoted comma list is the trap**: `-Scope 'a.ps1,b.ps1'` is stored as ONE glob that
   still contains the commas, so it matches nothing while `-Show` prints `VALID` (measured 2026-11-25,
   three re-issues wasted). Pass an array of separate entries (`-Scope @('a.ps1','b.ps1')`) or one
   directory glob (`-Scope 'hooks\*.ps1'`), and prove coverage with
   `scripts/ops/forensics/ticket-scope.ps1` in the codai checkout before writing anything.
