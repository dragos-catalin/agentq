# Migration report: E:\gh to ADR 0001 slots (2026-10-06)

Tools: `ps/bin/worktree.ps1 migrate -All` (worktrees + orphan dirs) and `ps/bin/repo-migrate.ps1` (main clones).
Rule applied everywhere: nothing removed without a verified backup; working trees and indexes of main
clones untouched; repos with agent activity in the last 2 h got backups only (no branch/stash deletion,
except stashes > 12 h old, backed up first). Restore: `git fetch origin <ref>` then `git checkout -b rescue FETCH_HEAD`;
bundles: `git clone <bundle>` or `git fetch <bundle> 'refs/*:refs/restored/*'`.

## Worktrees and orphan dirs under E:\gh\.wt

| Was | Action | Backup |
|---|---|---|
| vitals/storage (19 dirty, 159 h idle) | removed | `refs/backup/wt/vitals/legacy-storage/20261006-025920-9169` (26 files) |
| vitals/turbo (23 dirty, 148 h idle) | removed | `refs/backup/wt/vitals/legacy-turbo/20261006-025939-1995` (23 files) |
| vitals/deploy-1 (2 dirty) | removed | `refs/backup/wt/vitals/legacy-deploy-1/20261006-031513-f044` |
| vitals/release (orphan, no .git) | removed | `_bundles/vitals-orphan-release-20261006-055956.zip` |
| watch-faces/deploy-1 (2 untracked) | removed | `refs/backup/wt/watch-faces/legacy-deploy-1/20261006-025959-21d6` |
| vmui/ci (1 dirty) | removed | `refs/backup/wt/vmui/legacy-ci/20261006-031530-8741` |
| device-pairing/uniffi (1 dirty) | removed | `refs/backup/wt/device-pairing/legacy-uniffi/20261006-031423-bae7` |
| dragoscatalin/lab-oss-02 (2 dirty) | removed | `refs/backup/wt/dragoscatalin/legacy-lab-oss-02/20261006-031431-f514` |
| dragoscatalin/org-move (orphan) | removed | `_bundles/dragoscatalin-orphan-org-move-20261006-055914.zip` |
| agentcfg-audit/gate, agentq/hooks, brivio/deploy-1, brivio/v3-dmarc, selfie-screen/deploy-1 | removed | none needed (clean, HEAD on origin) |
| afti/e2e-prod, afti/sentry11, caelia/sentry11, money/sentry11 (orphans) | removed | `_bundles/<repo>-orphan-<dir>-*.zip` |
| notalone/ci (orphan, all files on origin) | removed | none needed |
| brivio/_broken-deploy-1-202610060357 (empty node_modules only) | removed | none needed |
| dashy/pairing-crate, dragoscatalin/v3-contact | kept | active < 2 h (another agent); migrate again later |

Standard slots after migration: brivio `task-1..3`, `release`, `land`; agentq `task-1`; codai `task-1`.

## Main clones (`repo-migrate.ps1`, report `~/.codai/repo-migrate-report.jsonl`)

| Repo | Dirty state backup | Stashes (backed up, dropped) | Branches deleted (tip on origin) | Bundle (`E:\gh\.wt\_bundles`, no origin / retired) |
|---|---|---|---|---|
| afti | `refs/backup/main/afti/20261006-030544` | - | - | - |
| bancai_v1 | `refs/backup/main/bancai_v1/20261006-030943` | - | - | `bancai_v1-20261006-030943.bundle` |
| base_template | `refs/backup/main/base_template/20261006-030943` | - | - | `base_template-20261006-030943.bundle` |
| bfut | `refs/backup/main/bfut/20261006-030544` | - | - | - |
| brivio | - | - | - | - |
| bts | `refs/backup/main/bts/20261006-030943` | - | - | `bts-20261006-030943.bundle` |
| bts2 | `refs/backup/main/bts2/20261006-030943` | - | - | `bts2-20261006-030943.bundle` |
| bts3 | `refs/backup/main/bts3/20261006-030943` | - | - | `bts3-20261006-030943.bundle` |
| caelia | `refs/backup/main/caelia/20261006-030544` | - | - | - |
| cautai | `refs/backup/main/cautai/20261006-030943` | - | - | `cautai-20261006-030943.bundle` |
| circuit-tracks-mwrty | `refs/backup/main/circuit-tracks-mwrty/20261006-030544` | - | - | - |
| circus | `refs/backup/main/circus/20261006-030544` | - | - | - |
| codai | `refs/backup/main/codai/20261006-030820` | 7 -> `refs/backup/stash/codai/*` | - | - |
| codai.v1 | `refs/backup/main/codai.v1/20261006-030544` | - | - | - |
| controlai | `refs/backup/main/controlai/20261006-030943` | - | - | `controlai-20261006-030943.bundle` |
| dashy | `refs/backup/main/dashy/20261006-030820` | - | - | - |
| devbox | `refs/backup/main/devbox/20261006-030544` | - | - | - |
| doomscroll-blocker | `refs/backup/main/doomscroll-blocker/20261006-030544` | - | - | - |
| dragoscatalin | `refs/backup/main/dragoscatalin/20261006-030820` | - | - | - |
| ducolo | `refs/backup/main/ducolo/20261006-030943` | - | - | `ducolo-20261006-030943.bundle` |
| evocrm | - | - | - | `evocrm-20261006-030943.bundle` |
| facturai.v1 | `refs/backup/main/facturai.v1/20261006-030943` | - | - | `facturai.v1-20261006-030943.bundle` |
| hide | `refs/backup/main/hide/20261006-030544` | - | - | - |
| idei-seap | `refs/backup/main/idei-seap/20261006-030943` | - | - | `idei-seap-20261006-030943.bundle` |
| jucai | `refs/backup/main/jucai/20261006-030544` | - | - | - |
| marcai | `refs/backup/main/marcai/20261006-030544` | - | - | - |
| memorai | `refs/backup/main/memorai/20261006-030943` | - | - | `memorai-20261006-030943.bundle` |
| metu | - | 2 -> `refs/backup/stash/metu/*` | - | - |
| mmo | `refs/backup/main/mmo/20261006-030544` | - | feat/keep-alive-activity | - |
| notai | `refs/backup/main/notai/20261006-030544` | - | - | - |
| pgp | `refs/backup/main/pgp/20261006-030544` | - | - | - |
| renovate-config | `refs/backup/main/renovate-config/20261006-030544` | - | - | - |
| selfie-screen | `refs/backup/main/selfie-screen/20261006-030820` | - | - | - |
| starvibe | `refs/backup/main/starvibe/20261006-030943` | - | - | `starvibe-20261006-030943.bundle` |
| titi | - | - | - | - |
| trade-simulator | `refs/backup/main/trade-simulator/20261006-030943` | - | - | `trade-simulator-20261006-030943.bundle` |
| vitals | `refs/backup/main/vitals/20261006-030820` | - | - | - |
| vmui | `refs/backup/main/vmui/20261006-030820` | - | - | - |
| vsrchat | `refs/backup/main/vsrchat/20261006-030544` | - | dependabot/npm_and_yarn/all-deps-19c2687005 | - |
| vwebacm | `refs/backup/main/vwebacm/20261006-030943` | - | - | `vwebacm-20261006-030943.bundle` |
| watch-faces | `refs/backup/main/watch-faces/20261006-030820` | - | - | - |

Not touched: no repo was reset or cleaned. Dirty main clones keep their files; the backup ref is the safety net.
Bundles total ~1.16 GB. Disk: `E:` free 445.7 GiB at 04:20 -> 459.2 GiB after migration = ~13.5 GiB freed (approximate: other agents write to E: concurrently; node_modules are pnpm-store hardlinks, so most of it is checkouts + build output).