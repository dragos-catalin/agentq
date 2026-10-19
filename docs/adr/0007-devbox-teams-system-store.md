# ADR 0007: devbox teams — system agentq, per-user agentq, repo permissions from Unix groups

Date: 2026-10-19. Status: accepted (owner decisions in chat, 2026-10-19).

## Context

The workstation is CPU-bound by editors and agents, not builds (32 cores, 17.7 busy idle). The answer is a
shared Linux devbox (`ws-devbox`, c4d-standard-32, europe-west4-b) that VS Code Remote and codai attach to.
Once more than one person (and their agents) work on it, three things must hold:

1. machine resources (build slots, RAM gate, worktree slots) are arbitrated **across people**, not per person;
2. a person's private state (jobs, chat terminals, notices, keys, `.env`) stays private;
3. a repo a person may not see is invisible to them **and to their agents** — enforced by the kernel, not by a
   prompt or a convention.

Before this ADR the git-first and devbox tools lived as ad-hoc copies in `~/.codai/{git,devbox}` and codai's
`.copilot-tmp`, untested and uninstallable.

## Decision

### Tools move into agentq (`ps/bin`, installed by `ps/install.ps1`, tests in `run-all`)

| tool                                                       | role                                                                                                              |
| ---------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `git-publish.ps1`                                          | G1-G5: make a folder a private repo, sops+age secrets, snapshot branch for WIP, never rewrites                    |
| `git-wip-snapshot.ps1`                                     | G6: temp-index snapshot of active shared clones + slots to `refs/wip/<host>/<slot>/latest`; `-All` = the 2 h task |
| `devsync.ps1`                                              | Mutagen sync PC <-> devbox, never `.git`, remote modes 0660/2770, takes workspace lease `ws`                      |
| `devbox-bootstrap.ps1` + `ps/devbox/devbox-{root,user}.sh` | provision: tools, agentq system install, clones, secrets                                                          |
| `devbox-teams.py`                                          | root on the devbox: users, repo groups, `/work/<repo>` 2770, system store                                         |
| `devbox-team-sync.ps1`                                     | PC: hub members -> desired state -> `devbox-teams apply` over ssh                                                 |

### Two stores

- **User store** `~/.codai/coord` (or `AGENTQ_HOME`): jobs, notices on Windows, agent registry, prep state.
- **System store** `/var/lib/agentq` (exists iff `system.json` is there, root-provisioned): `queues`, `marks`,
  `leases`, `releases`, `workspaces`, `journal.jsonl` + `journal.d/<repo>.jsonl`. Group `devbox-users`, 2770,
  default ACL `g::rwX`. Repo-scoped dirs (`queues/<kind>_<repo>`, `leases/<repo>`, `batches/<repo>`,
  `journal.d/<repo>.jsonl`) belong to the repo group `r-<repo>`: an outsider cannot read the purposes, commands
  or lease paths of a repo they cannot see, and cannot queue on it.
- `system.json` `policy` (machineCap, slot counts) overrides any user's `agentq-config.json`: nobody raises the
  machine cap for themselves. Root's `agentq-sweep.timer` (10 min) judges stale leases of every user (root reads
  every user's job registry).
- Windows workstation / tests: no system store -> `$SysRoot = $Root`, the old single-store layout, unchanged.
- Cross-user named mutexes (`Global\agentq-*`) exclude across Linux users (probe 2026-10-19: held by user A,
  user B `WaitOne(0)` = false, true after release), so the same locking code serves both stores.

### Permissions = Unix accounts + groups

- One Linux account per person: hub `linux_username` (`u-<8hex>`, same as codaid); the machine owner keeps `dev`.
  Accounts created by the tool carry GECOS `devbox-teams`; no other account is ever modified.
- One group per repo, `r-<repo>`. `/work/<repo>` (moved from `/work/gh/<repo>`, symlink kept) is `root`-agnostic,
  group `r-<repo>`, setgid **2770**, default ACL `d:g::rwX,d:o::---`; `core.sharedRepository=group`; the team
  paths are `safe.directory` system-wide. Slots live in `/work/.wt/<repo>` with the same group.
- Agents run as their human (VS Code server, codaid, terminals are that user's processes), so a repo the
  human cannot read is unreadable by their agents. `umask 0007` via `/etc/profile.d/agentq.sh`; homes 0750.
- Roles: owner/maintainer/developer -> the group; viewer -> nothing (as codaid). Removed from one repo -> that
  group only (sessions HUP'd). Removed everywhere -> account locked + expired, ssh keys moved aside, processes
  killed, **home kept** (never deleted by the tool). Re-added -> unlocked.
- devcloud runner jobs on an interactive workspace use `/work/.jobs/<repo>` (metadata `devcloud-jobs-dir`), so a
  job's `checkout -f` + `clean -ffdx` never touches a team repo.

### Source of truth: hub `environment_members`

- One hub environment per devbox repo: provider `byo`, name `devbox:<vm>:<repo>` (project `devbox-<repo>`).
  The environment's owner maps to `dev`; members with a `linux_username` map to their account; others skipped.
- `devbox-team-sync.ps1` runs on the owner's PC (the hub key stays in DPAPI) as task `devbox-team-sync`
  every 15 min (a non-RUNNING devbox is a logged `skip`, exit 0 — it suspends itself after 30 min idle), and pushes the desired state (no secrets: names, roles, the hub SSH CA public key) to
  `sudo devbox-teams apply`. `devbox-teams` validates strictly (only the owner or `u-<8hex>` names, no root).
  The hub SSH CA public key goes into `TrustedUserCAKeys`, so hub-issued member certificates log in.

## Consequences

- `/work/<repo>` replaces `/work/gh/<repo>` as the canonical path (symlinks keep old paths working).
- A sync that runs only while the PC is on: membership changes apply within 15 min of the PC being up; the
  current state stays enforced on the devbox meanwhile (it is plain Unix state).
- Shared read-only caches (pnpm store, turbo remote cache) remain shared; working trees, `.env`, credentials
  never are.

## Verification

- `ps/tests/test-devbox-tools.ps1` (31 checks: publish/wip on local bare remotes, devsync plan, team-sync
  mapping + skip while the devbox is suspended, workspace lease, system-store routing), `ps/tests/test-devbox-teams.py` (16 planner cases),
  mutation-checked.
- Live on ws-devbox: a test member without access to a repo cannot list it, read a file, read its journal or
  queue on it — neither from their shell nor from a process they start (agent stand-in).
