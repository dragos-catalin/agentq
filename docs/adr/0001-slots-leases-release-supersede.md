# ADR 0001: Fixed worktree slots, leases, release supersede and a landing queue

- Status: accepted (2026-10-06)
- Scope: every repo under `E:\gh` on this machine, all agent harnesses (VS Code Copilot, Copilot CLI, Claude Code)
- Implementation: PowerShell tooling in `ps/` of this repo, installed to `~/.copilot/{bin,hooks}` by `ps/install.ps1`. The TS daemon (`src/`) stays protocol-compatible and gets the same concepts in a later step.

## Context

Several agents work on the same machine and often in the same repo. Before this decision:

- Worktrees had ad-hoc names (`v3-dmarc`, `org-move`, `sentry11`, `deploy-mjs`, `deploy-1..6`). 14 worktrees in 11 repos, plus orphan non-git dirs.
- Nothing recorded who was *using* a worktree. On 2026-10-06 an owner-requested cleanup deleted a live worktree of another agent and the `deploy-1` slot in the middle of a staging release (`git rev-parse --git-common-dir: not a git repository`).
- Release scripts had side locks agentq could not see (brivio `deploy-mjs.lock`, its own worktree). A release always ran to completion on the sha it started with, even when a newer landing made it obsolete.
- Landing (rebase, CHANGELOG/version conflicts, push) was improvised per agent, in the shared clone or in a random worktree.
- Known agentq bug classes: a waiter's heartbeat went stale while waiting, phantom holds, `break` without an id removing a live holder (fixed 2026-09-30, kept under test).

## Decision

### 1. Slots: fixed names, fixed place

Every worktree lives at `E:\gh\.wt\<repo>\<slot>` (`<repo>` = folder of the common git dir, lower case). Only these slot names exist:

| Slot | Count | Role | Created by | Typical holder |
|---|---|---|---|---|
| `release` | 1 per repo (configurable, e.g. codai 2: `release`, `release-2`) | `release` | `deploy-clean.ps1` | a deploy/release run |
| `land` | 1 per repo | `land` | `agentq land` | the landing queue |
| `task-1..3` | 3 per repo, **10 machine-wide** | `task` | `worktree.ps1 lease` | a feature agent |
| pinned (`db-live`, `qa-prod`, ...) | listed in `agentq-config.json` | `pinned` | `worktree.ps1 lease -Slot <name>` | long-lived tools |

A slot is **created on demand and reused**. A leased task slot is reset to the requested ref before it is handed over (after the previous holder's state was released clean or backed up). Disk cost per slot: pnpm's store is on the same volume (`E:\.pnpm-store`), so `node_modules` are hardlinks. The real per-slot cost is the checkout plus build output (measured in the migration report).

Raw `git worktree add/remove`, `rmdir`/`Remove-Item` of a leased slot, and cleanup scripts that do not check leases are blocked by `guard-tooluse.ps1`.

### 2. Leases: agentq is the source of truth

A lease is `~/.codai/coord/leases/<repo>/<slot>.json` plus a heartbeat file `<slot>.json.hb`:

```json
{ "leaseId":"a1b2c3d4", "repo":"brivio", "slot":"task-2", "role":"task", "path":"E:\\gh\\.wt\\brivio\\task-2",
  "branch":"feat/x", "purpose":"why", "session":"term-1234", "pid":1234, "procStart":"ISO", "created":"ISO" }
```

- **Owner** = the agent's terminal shell (the nearest ancestor shell that is not an agentq or worktree script). Agents have no long-lived process of their own, so liveness combines pid and activity.
- **Activity** renews the heartbeat:
  - any tool call whose command or file path touches the slot (the guard hook touches `.hb`, at no measurable cost);
  - any agentq call made with `-Repo` inside the slot;
  - `worktree.ps1 renew`.
- **Stale** = (owner pid dead **and** idle > 2 h) **or** idle > 24 h. A waiter in a long build queue keeps its lease because the guard and agentq renew it.
- **Expiry** (the `copilot-worktree-prune` task, every 30 min, and on demand when a lease is requested):
  1. Snapshot every tracked and untracked non-ignored change into a commit with a temporary index (`GIT_INDEX_FILE` copy, `add -A`, `write-tree`, `commit-tree` with HEAD as parent). This is never a stash: stashes are shared by all worktrees of a repo.
  2. Push it to `refs/backup/wt/<slot>/<yyyyMMdd-HHmm>` on origin. That namespace is not a branch, so it triggers no CI (verified on GitHub 2026-10-06). Repos without a remote get a local `refs/backup/...` plus a bundle in `E:\gh\.wt\_bundles`.
  3. Verify the ref exists remotely, then release the lease and journal `lease-expire` with the backup ref.
  4. The directory stays. The next holder gets a reset slot.
- **Removal or prune never touches a leased slot**, whatever its git state. An unleased slot is removed only if it is clean, its HEAD is on a remote, it has no process referencing it and it has been idle for 7 days (task/pinned); `release`/`land` are kept for reuse.
- **Break** is by id only: `worktree.ps1 unlease -Slot <s> -LeaseId <id> -Reason ...`. The state is backed up exactly as on expiry.

### 3. Release runs and supersede

A release run holds `deploy:<repo>:<target>` and the `release` slot. Its state is `~/.codai/coord/releases/<repo>__<target>.json`:
`runId, sha, ref, follow, phase, preemptible, committed, phaseAt, state, supersedeSha, pendingSha, pid, procStart, session, started`.

**Phases and checkpoints.** The release script calls `agentq release-phase -Phase <name> [-Unsafe]` on entering each phase. The call is a no-op exit 0 outside a release run, so scripts still work standalone.

| Phase | Preemptible | Example (brivio `release.mjs`) |
|---|---|---|
| `prepare` | yes | deploy-clean checkout, env copy, `pnpm install` |
| `preflight` | yes | preconditions, freeze, contract guard, `pnpm preflight` |
| `build` / `test` | yes | image builds that are not yet pushed, unit/e2e against nothing shared |
| `staging` | **no** (`-Unsafe`) | staging migrate + traffic |
| `e2e-staging` | no | writes fixtures to the staging DB |
| `tag` | no | annotated tag push |
| `migrate` / `prod` / `promote` | no | prod migrate, traffic shift |
| `verify` / `record` | no | attest, manifest, GitHub deployment |

`committed` becomes true on the first `-Unsafe` phase and never goes back.

**Landing during a release.** `agentq commit` (after a successful push), `agentq land` and `agentq notify-landing` call `Notify-Landing(repo, branch, sha)`. For each running release of that repo with `follow == branch`:

- `committed == false`: `supersedeSha = sha`, `state = preempting`. At its next checkpoint the release gets **exit 4** (`SUPERSEDED`) and must stop without further side effects. `deploy-clean -Follow` restarts the run on the newest tip.
- `committed == true`: `pendingSha = sha`, which is overwritten by every newer landing, so there is at most one pending run. When the run ends successfully, `deploy-clean -Follow` starts **one** new run at `pendingSha`. A failed run never auto-starts the next one; the failure is a stop signal.
- No running release: nothing happens.

**Coalescing.** A second `deploy-clean -Follow` for the same repo and target while a run is active does not queue a duplicate: it records its tip as supersede or pending (by the rule above) and exits 0 with `coalesced into run <id>`.

**Who may preempt:** only `Notify-Landing` (that is, a landing on the followed branch) and `agentq release-cancel -Reason` from a human. Nobody can preempt a committed run. A freeze mark on `deploy:<repo>:<target>` refuses new runs, and a running one finishes.

### 4. Landing queue

`agentq land -Branch <topic> -Onto <dev|main> [-Gate '<cmd>'] -Purpose ...` serialises landing per repo:

1. Take `land:<repo>` (FIFO), then lease the `land` slot. The lease is owned by the `land` process, so it dies with it.
2. `fetch`, detach at `origin/<onto>`.
3. **Dedupe**: `git cherry origin/<onto> origin/<topic>`. Commits already upstream as patches (`-`) are skipped. If nothing is left: `already landed`, exit 0.
4. Cherry-pick the remaining commits in order. Conflicts:
   - if the repo has `scripts/land-resolve.ps1` (or `.mjs`), run it with the conflicted paths (repo-documented rules for CHANGELOG, `package.json` version, allowlists);
   - otherwise `CHANGELOG.md` gets `git merge-file --union`.
   - Anything else aborts the pick with exit 5 and a list of the conflicted files. Leftover conflict markers are checked before every continue, so markers are never committed.
5. Gate: `-Gate` runs in the `land` slot through `run-build` (`build:<repo>` + `build:machine`).
6. `git push origin HEAD:<onto>`, never forced. If the push is rejected because the remote moved, go back to step 2 (at most 3 rounds).
7. `Notify-Landing`, journal `land` with the shas, release the slot (it stays clean at the landed sha).

Parallel agents work in parallel task slots; only landing is serial.

### 5. Machine-wide safety

- `build:machine` capacity 2 + free RAM >= 6 GB **and free commit charge >= 12 GB** (2026-09-30: OOM with 50 GB RAM free).
- Task slot cap 10 machine-wide, 3 per repo.
- No global git config writes by any tool. All resources are per repo except `build:machine`.
- Side locks are folded into agentq: brivio `deploy-mjs.lock` is skipped when `AGENTQ_HELD` contains `deploy:brivio`, and `deploy.mjs` builds services from `DEPLOY_WORKTREE` instead of creating its own worktree.

### 6. Visibility

`agentq status` shows queues, marks, **leases** (slot, role, holder, branch, age, idle, STALE) and **releases** (target, sha, phase, committed, supersede/pending). `agentq-sync` sends `leases[]` and `releases[]` to codai, and the hub `/ops/agentq` shows them (codai migration 0137).

## Failure modes

| Failure | Detection | Handling |
|---|---|---|
| Agent dies mid-task in a slot | pid dead + idle 2 h | auto backup to `refs/backup/wt/...`, lease released, slot reused |
| Agent alive but forgot the slot | idle 24 h | same as above |
| Cleanup deletes a slot in use | guard blocks `rmdir`/`Remove-Item`/`worktree remove` on leased paths; prune checks the lease first | refused with the holder's name |
| Two agents in one slot | lease is exclusive; `lease` refuses a held slot | second agent gets another task slot or waits |
| Release preempted mid-migrate | impossible: `committed` is sticky after the first unsafe phase | landing becomes `pendingSha` |
| Ten landings during one release | coalesced to one `pendingSha` | exactly one follow-up run |
| Release process killed | pid dead | release file marked `failed` on the next read, deploy ticket reaped; no auto-restart |
| Waiter heartbeat stale while queued | `Wait-Turn` beats its own and every held ticket | covered by tests 8–9 |
| Phantom hold (ticket created before its turn) | sequential acquisition | test 8 |
| `break` hits the wrong ticket | `-Id` required when ambiguous | test 10 |
| Landing conflict | cherry-pick conflict | repo resolver, union CHANGELOG, else exit 5 with files, nothing pushed |
| Remote moved during landing | push rejected | re-fetch and re-pick, max 3 |
| Commit charge exhausted | gate before `build:machine` | waits, journaled reason |
| Lease file corrupt | parse fails | treated as held (fail closed), shown as `unreadable` |

## Consequences

- Agents must ask for a slot (`worktree.ps1 lease`) instead of inventing a name. `worktree.ps1 new -Name x` keeps working but only for registered slot names.
- Release scripts gain a one-line checkpoint call per phase. Scripts without it are treated as one unsafe phase after `prepare`: they can be preempted only while deploy-clean is still preparing.
- The deploy pool `deploy-1..6` is retired. Concurrent deploys of different targets in one repo use `release-2` where configured.

## Verification (2026-10-06)

- Suites: `ps/tests/run-all.ps1` - agentq v1 30, v2 51, worktree/deploy-clean 18, repo-migrate 11, guard 19 (incl. 3 mutation tests: each rule disabled -> its cases stop blocking). brivio `scripts/release/agentq-phase.test.mjs` (in `release:test`, 126/126) with 4 mutations killed.
- Live demo on brivio (`.copilot-tmp/demo/demo.ps1`, dry-run release command, throwaway followed branch): agents A and B leased `task-3`/`task-2` in parallel; deploy-clean leased `release` and ran run 1 @2c0d371 to `preflight`; `agentq land` of A -> `demo:preempt`, run 1 stopped "SUPERSEDED before staging" (exit 4); run 2 @bbeeeeb started automatically, entered `staging` (committed); `land` of B -> `demo:pending`; run 2 finished, run 3 @b7ee1dc (newest tip) ran once; slots released clean. No lock surgery, nothing lost.
- Migration of every repo in `E:\gh`: `docs/migration-2026-10-06.md`.
- Live findings fixed during rollout: guard read `rmdir X; Get-ChildItem E:\gh\.wt` as a recursive delete of the wt root (now per-statement); unlease left the agent's branch checked out in the slot (now detached); `land` re-picked a union-merged CHANGELOG commit (now `-x` + trailer dedupe).
