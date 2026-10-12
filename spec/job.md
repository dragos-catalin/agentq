# devcloud job contract — v1

One command, run on a warm workspace against an exact git state. Client:
`ps/bin/agentq-cloud.ps1` (and `agentq run -Where cloud`). Runner: `cloud/runner-agent.mjs` on the
workspace VM. Transport: one GCS bucket in the control project (`dragos-devcloud-devcloud-jobs`).
Objects under `jobs/` expire after 7 days (bucket lifecycle).

## Objects

| object | writer | when | content |
|---|---|---|---|
| `jobs/<id>/bundle` | client | before the spec | `git bundle` of `HEAD` minus the newest known sha that is an ancestor of HEAD (full HEAD bundle when none) |
| `jobs/<id>/patch` | client | before the spec | `git diff --cached --binary HEAD` of the working tree, untracked included, built in a temp index |
| `ws/<ws>/queue/<id>.json` | client | **last** | the spec (below); its arrival makes the job claimable |
| `jobs/<id>/claimed` | runner | on claim | `{at, host}` |
| `jobs/<id>/log` | runner | every ~2 s | the whole log so far (rewritten, not appended) |
| `jobs/<id>/result.json` | runner | **last** | `{v, id, exit, durSec, phases:{sync,install,run}, host, vcpu, finishedAt}` |
| `ws/<ws>/heartbeat` | runner | every 30 s | `{at, host, state: idle\|busy\|suspending, idleSec}` |
| `ws/<ws>/repos/<repo>.json` | runner | after each sync | `{repo, shas[≤30], at, host}` — commits this workspace has |

## Spec

```json
{ "v": 1, "id": "20261012-020511-a1b2c3", "repo": "codai", "sha": "<HEAD sha>",
  "bundle": true, "patch": true, "cmd": "pnpm --filter @codai/common typecheck",
  "timeoutSec": 3600, "lane": "gate", "purpose": "why", "session": "term-123",
  "noInstall": false, "submittedAt": "2026-10-12T02:05:11Z", "client": "HOST" }
```

- `id` = `yyyyMMdd-HHmmss-<6 hex>`; queue order is lexical, i.e. FIFO by submit time.
- `repo` = name of the common git dir's parent, lowercased (same key as agentq resources).
- `cmd` runs under `bash -lc` in the checkout with `CI=1`, `FORCE_COLOR=0`, and
  `TURBO_API/TURBO_TEAM/TURBO_TOKEN` for the devcloud turbo remote cache.

## Claim

The runner lists `ws/<ws>/queue/`, reads the first object and deletes it with
`ifGenerationMatch=<generation>`. Only the runner whose delete returns 204 owns the job, so several
runners can share one queue.

## Runner steps

1. `git init` the checkout once (`/work/<repo>`); `git fetch <bundle> HEAD:refs/devcloud/in/<id>`.
2. `git checkout -f --detach <sha>`; `git clean -ffdx` keeping `node_modules .turbo target .gradle .pnpm-store`.
3. `git apply --binary <patch>`.
4. Publish the known shas list.
5. `pnpm install --frozen-lockfile --prefer-offline` only when the sha256 of `pnpm-lock.yaml`
   differs from the last install in that checkout (skipped with `noInstall`).
6. Run `cmd` with the timeout (process group killed, exit 124).
7. Flush the log, write `result.json`.

## Idle and suspend

After `devcloud-idle-min` minutes (metadata, default 15) without a job the runner calls
`instances.suspend` on itself. The VM service account has the custom role `devcloudSelfSuspend`
(`compute.instances.get`, `compute.instances.suspend`) bound **on the instance only**. A jump in wall
time on the next loop tick means the VM was resumed: the idle clock restarts.

The client resumes a `SUSPENDED` VM (or starts a `TERMINATED` one) before uploading, so the
resume overlaps the delta upload.

## Exit codes (client)

Remote exit code; `3` = could not submit, or no result before `timeoutSec + 15 min`; `2` = usage.

## Journal

The client appends to `~/.codai/coord/journal.jsonl`: `cloud-queued`, then `cloud-done` (exit 0)
or `cloud-fail`, with `resource=cloud:<ws>`, `kind=cloud`, `lane`, `waitSec` (submit → claimed,
resume included), `holdSec` (remote duration), `resumeSec` when the VM was resumed, `phases`.
`agentq metrics` reads these next to local runs.

## Versioning

Additive fields keep `v: 1`. A field whose meaning changes, or a new required field, bumps `v`;
a runner rejects a spec with a `v` it does not know.
