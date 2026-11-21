# Repo readiness report - the `E:\gh` fleet and the agentq config

Generated: 2026-11-21 02:29 local - single read-only pass.

Scope: every candidate repo on `E:\gh` plus the two `agentq` config copies. **Read-only**: no `git fetch`, no `checkout`, no commit, no build, no test; nothing under `E:\gh\agentq\ps\**` was executed. Clone positions are read from existing local refs only (no network).

Legend: **VERIFIED** = a command was run and its output is quoted below. **EXPECTED** = reasoned from code/config, not directly exercised.

## Summary

| # | Finding | Count |
| --- | --- | --- |
| 1 | Candidate repos (config keys union E:\gh\*.git) | **95** |
| 2 | Repos with **no** landGate in config | **94** |
| 3 | Repos with **no** landGate **and no** pre-push hook (nothing gates a push) | **80** |
| 4 | Repos with no pre-push hook | **80** (of 95) |
| 5 | Repos with no pre-commit hook | **76** (of 95) |
| 6 | Repos with no upstream configured | **2** |
| 7 | Main clones not level with origin/<branch> | **3** |
| 8 | Config keys present in one copy but not the other | **0** |

## 1. Candidate set

**VERIFIED** - repo-named keys collected from every repo-keyed map in `E:\gh\agentq\ps\bin\agentq-config.json` (`releaseSlots`, `pinned`, `landGate`, `sharedCloneModeRepos`, `cloudWorkspaces`, `cloudRegistry`):

```text
CFG_REPO_KEYS = brivio, codai, devbox, marcai, vitals, vitals-win, watch-faces
```

**VERIFIED** - top-level `E:\gh\<X>` directories that are git working trees (NOT recursive), and the union:

```text
(Get-ChildItem E:\gh -Directory).Count                                   -> 111
(... | Where-Object { Test-Path (Join-Path $_.FullName .git) }).Count    -> 94    (WITH_GIT)
union(CFG_REPO_KEYS, WITH_GIT).Count                                     -> 95
```

| Metric | Count |
| --- | --- |
| `E:\gh` subdirectories (all) | 111 |
| … that are a top-level git tree (`E:\gh\<X>\.git` exists) | 94 |
| Config repo keys | 7 (`brivio`, `codai`, `devbox`, `marcai`, `vitals`, `vitals-win`, `watch-faces`) |
| **Total distinct candidates** | **95** (94 on disk + itals-win, config-only) |

**VERIFIED** - the single config key that is not a local directory is `vitals-win` (a cloud workspace name; `E:\gh\vitals-win` does not exist, so its `git`/hook probes are `-`).

## 2. Per-repo table

Commands per repo `r` (read-only, never fetch):

```text
git -C E:\gh\<r> rev-parse --abbrev-ref --symbolic-full-name '@{u}'    # upstream, else the exact error
git -C E:\gh\<r> rev-list --left-right --count "origin/<branch>...HEAD"  # "<behind> <ahead>"
Test-Path E:\gh\<r>\.husky\pre-push   ; Test-Path E:\gh\<r>\.git\hooks\pre-push
Test-Path E:\gh\<r>\.husky\pre-commit ; Test-Path E:\gh\<r>\.git\hooks\pre-commit
```

`origin/<branch>...HEAD` is printed as `<left> <right>` = `<commits only on origin> <commits only on HEAD>`; `21 0` = main clone is 21 commits BEHIND the last-fetched `origin/<branch>`; `46 46` = diverged. No fetch was done, so values reflect the refs present at collection time.

Hooks: **husky** repos run hooks via `core.hooksPath=.husky`, so `.git/hooks/*` does not exist. **lefthook** repos install real `.git/hooks/*` shims that call the lefthook binary (their config lives in `lefthook.yml`). `-` = no such hook.

| Repo | Upstream (exit) | origin...HEAD | landGate | pre-push | pre-commit | SCM list | .wt slots |
| --- | --- | --- | --- | --- | --- | --- | --- |
| abridge | origin/main | 0 0 | - | - | - | - | - |
| activity-tracker | origin/main | 0 0 | - | - | - | - | - |
| afti | origin/main | 0 0 | - | husky: node scripts/hooks/pre-push.mjs | husky: node scripts/hooks/pre-commit.mjs | - | 0 |
| agentcfg-audit | origin/main | 0 0 | - | - | - | - | 0 |
| agentq | origin/main | 0 0 | - | - | - | - | 2 |
| alegeri2025 | origin/main | 0 0 | - | - | - | - | - |
| anaf-personal | origin/main | 0 0 | - | - | - | - | - |
| axiom | origin/main | 0 0 | - | - | - | - | 2 |
| bancai | ERR(128): fatal: no upstream configured for branch 'main' | 0 0 | - | - | - | - | - |
| bancai v1 | origin/main | 0 0 | - | - | - | - | - |
| base_template | origin/main | 0 0 | - | - | - | - | - |
| bfut | origin/feat/profitability-improvements | 0 0 | - | - | - | - | - |
| brivio | origin/dev | 0 0 | `pnpm land:gate` | husky: node scripts/pre-push.mjs | husky: node scripts/pre-commit.mjs | `refuse` | 13 |
| brivio.v1 | origin/main | 0 0 | - | - | - | - | - |
| bts | origin/main | 0 0 | - | - | - | - | - |
| bts2 | origin/feat/calendar-spread-pnl-funding | 0 0 | - | - | - | - | - |
| bts3 | origin/main | 0 0 | - | - | - | - | - |
| caelia | origin/main | 0 0 | - | - | - | - | 4 |
| cautai | origin/main | 0 0 | - | - | - | - | - |
| circuit-tracks-mwrty | origin/main | 0 0 | - | - | - | - | - |
| circus | origin/main | 0 0 | - | - | - | - | - |
| codai | origin/main | 21 0 | - | husky: GATE_BASE="origin/main" | husky: node scripts/commit-lock-acquire.mjs | `refuse` | 17 |
| codai-lr17 | origin/main | 0 0 | - | husky: GATE_BASE="origin/main" | husky: node scripts/commit-lock-acquire.mjs | - | - |
| codai-mcp-src | origin/main | 0 0 | - | - | - | - | - |
| codai.v1 | origin/main | 0 0 | - | - | - | - | - |
| controlai | origin/main | 0 0 | - | husky: . "$(dirname -- "$0")/_/husky.sh" | husky: . "$(dirname -- "$0")/_/husky.sh" | - | - |
| corporate | origin/main | 1 0 | - | - | - | - | 1 |
| crypto-backtesting | origin/main | 0 0 | - | - | - | - | - |
| cursuri-studiai | origin/main | 0 0 | - | - | - | - | - |
| dashy | origin/main | 0 0 | - | - | - | - | 0 |
| devbox | origin/main | 0 0 | - | - | - | - | - |
| device-pairing | origin/main | 0 0 | - | - | - | - | 0 |
| dexai | origin/main | 0 0 | - | husky: pnpm run type-check && pnpm run build | husky: pnpm lint-staged | - | - |
| discord-csvote | origin/main | 0 0 | - | - | - | - | - |
| domains | origin/main | 0 0 | - | - | - | - | - |
| doomscroll-blocker | origin/main | 0 0 | - | - | - | - | 0 |
| dragoscatalin | origin/main | 0 0 | - | husky: node scripts/pre-push.mjs | husky: node scripts/pre-commit.mjs | - | 0 |
| ducolo | origin/main | 0 0 | - | - | - | - | - |
| editai | origin/main | 0 0 | - | - | - | - | - |
| efactura-ro | origin/main | 0 0 | - | - | - | - | - |
| evocrm | origin/feat/v2-datuvia | 0 0 | - | husky: set -e | husky: set -e | - | - |
| explorai | origin/main | 0 0 | - | - | - | - | - |
| facturai | origin/main | 0 0 | - | - | - | - | - |
| facturai.v1 | origin/main | 46 46 | - | - | - | - | - |
| gta-nexus | origin/main | 0 0 | - | husky: set -e | husky: set -e | - | 0 |
| HIDE | origin/main | 0 0 | - | husky: if [ "${HIDE_SKIP_PUSH_CHECKS:-0}" = "1" ]; then | husky: if ! git diff --cached --name-only --diff-filter=ACMR \ | - | - |
| idei-seap | origin/main | 0 0 | - | - | - | - | - |
| inferance | origin/main | 0 0 | - | - | - | - | - |
| invitatii | origin/main | 0 0 | - | - | - | - | - |
| istanbuldentalclinic | origin/main | 0 0 | - | - | - | - | - |
| jucai | origin/main | 0 0 | - | - | husky: . "$(dirname "$0")/_/husky.sh" | - | - |
| lietome | origin/main | 0 0 | - | - | - | - | 1 |
| mancai | origin/main | 0 0 | - | - | - | - | - |
| marcai | origin/main | 0 0 | - | lefthook (git shim) | lefthook (git shim) | - | 5 |
| mcp-lock | origin/main | 0 0 | - | - | - | - | - |
| memorai | origin/main | 0 0 | - | - | - | - | - |
| metu | origin/main | 0 0 | - | - | husky: node scripts/commit-lock-acquire.mjs | - | 1 |
| mmo | origin/main | 0 0 | - | - | husky: node apps/extension/scripts/check-version.mjs --staged | - | 1 |
| money | origin/main | 0 0 | - | - | - | - | 2 |
| notai | origin/main | 0 0 | - | husky: node scripts/pre-push.mjs | husky: pnpm exec lint-staged \|\| exit 1 | - | - |
| notalone | origin/main | 0 0 | - | - | - | - | 0 |
| pgp | origin/main | 0 0 | - | - | - | - | - |
| primaria-deschisa | ERR(128): fatal: no upstream configured for branch 'main' | fatal: ambiguous argument 'origin/main...HEAD': unknown revision or path not in the working tree. Use '--' to separate paths from revisions, like this: 'git <command> [<revision>...] -- [<file>...]' | - | - | - | - | - |
| primes | origin/main | 0 0 | - | - | - | - | - |
| prompt-cache-doctor | origin/main | 0 0 | - | - | - | - | - |
| radar-firme | origin/main | 0 0 | - | - | - | - | - |
| renovate-config | origin/main | 0 0 | - | - | - | - | - |
| rent-a-car | origin/main | 0 0 | - | - | - | - | - |
| reports | origin/main | 0 0 | - | - | - | - | - |
| resolve-smoke | origin/main | 0 0 | - | - | - | - | - |
| scrin | origin/main | 0 0 | - | lefthook (git shim) | lefthook (git shim) | - | - |
| scripts | origin/main | 0 0 | - | - | - | - | - |
| selfie-screen | origin/main | 0 0 | - | - | - | - | 0 |
| song-similarity | origin/main | 0 0 | - | - | - | - | - |
| starvibe | origin/main | 0 0 | - | - | - | - | - |
| stripe-firebase | origin/main | 0 0 | - | - | - | - | - |
| swami | origin/main | 0 0 | - | - | - | - | 2 |
| titi | origin/dev | 0 0 | - | lefthook (git shim) | lefthook (git shim) | - | 2 |
| trade-simulator | origin/main | 0 0 | - | - | - | - | - |
| ttk-live | origin/main | 0 0 | - | - | - | - | - |
| unscroll-rules | origin/main | 0 0 | - | - | - | - | 0 |
| vicam | origin/main | 0 0 | - | - | - | - | - |
| viitorul-gorjului | origin/main | 0 0 | - | - | - | - | - |
| vitals | origin/main | 0 0 | - | - | git: exec pwsh -NoProfile -ExecutionPolicy Bypass -File "scripts/hooks/pre-commit.ps1" "$@" | - | 3 |
| vitals-win | (config-only; not on disk) | - | - | - | - | - | - |
| vmui | origin/main | 0 0 | - | - | - | - | 2 |
| vscode-tasks2 | origin/main | 0 0 | - | - | - | - | - |
| vsrchat | origin/main | 0 0 | - | husky: echo "🏗  vsrchat pre-push: building affected packages…" | husky: echo "🔎 vsrchat pre-commit checks…" | - | - |
| vwebacm | origin/main | 0 0 | - | - | - | - | - |
| watch-faces | origin/main | 0 0 | - | - | - | - | 2 |
| wdw-cosmology | origin/main | 0 0 | - | - | - | - | - |
| workflows | origin/main | 0 0 | - | - | - | - | - |
| workspace | origin/main | 0 0 | - | - | - | - | - |
| workspace-ai | origin/main | 0 0 | - | - | - | - | - |
| wptheme-register | origin/main | 0 0 | - | - | - | - | - |

Global `sharedCloneMode` = `warn` in BOTH config copies. Per-repo overrides exist only for `sharedCloneModeRepos`: `codai` = `refuse`, `brivio` = `refuse`; every other repo inherits the global `warn`.

## 3. Gaps

### 3.1 What agentq does when a land has no gate (**VERIFIED**, from code)

A repo has no `landGate` unless it appears under `landGate` in config. Only `brivio` is listed there (`"landGate": { "brivio": "pnpm land:gate" }`), so **94 of 95 candidates have no configured land gate**.

`agentq-v2.ps1` resolves `$Gate` in `Invoke-Land` (lines 1902-1908):

```text
1902:   if (-not $Gate) {
1903:     $lg = (Get-Config)['landGate']
1904:     if ($lg -and $lg.ContainsKey($repo.Name) -and "$($lg[$repo.Name])") { $Gate = "$($lg[$repo.Name])"; Write-Output "land: default gate for $($repo.Name): $Gate" }
1905:   } elseif ($Gate -eq 'none') {
1906:     Write-Journal @{ event = 'land-gate-skipped'; resource = $res; branch = $Branch; reason = $why; repo = $repo.Name }
1907:     $Gate = $null
1908:   }
```

With no `-Gate` argument and no `landGate` entry, `$Gate` stays empty (`$null`). Both places that would run a gate are guarded on `$Gate`:

```text
1925:   if ($Gate) {                      # pre-gate (OQ-002), run in the caller slot before queueing
1775:     if ($Gate) {                    # in-queue gate: Test-GreenTree ... Invoke-GateRun ... Set-GreenTree
```

**Correction to the task premise.** With an empty `$Gate`, `Invoke-GateRun` is **never reached** - it is not called with an empty `-Command`. Both gate call sites are inside `if ($Gate)`, so for a repo without a `landGate` a bare `agentq land` runs **no agentq gate at all** (neither the pre-gate nor the in-queue gate). The only thing that can block such a push is the repo's own `pre-push` hook, if it has one.

For completeness, `Set-GreenTree` (lines 1503-1517) **writes nothing** when the gate is empty - it returns on the first line:

```text
1503: function Set-GreenTree([string]$repoName, [string]$tree, [string]$gate, [int]$sec, [string]$where) {
1504:   if (-not $tree -or -not $gate -or $env:AGENTQ_NO_GREEN -eq '1') { return }
```

and `Invoke-GateRun` (lines 1527-1533) is what a non-empty gate would run:

```text
1527: function Invoke-GateRun([string]$dir, [string]$purpose) {
1528:   $rb = if ($env:AGENTQ_RUN_BUILD) { $env:AGENTQ_RUN_BUILD } else { Join-Path $env:USERPROFILE '.copilot\hooks\run-build.ps1' }
1530:   & pwsh -NoProfile -File $rb -Root $dir -Wait -TimeoutMin 120 -Purpose $purpose -Command $Gate
1531:   $script:GateExit = [int]$LASTEXITCODE
```

So a gate only ever runs when the caller passes `-Gate "<cmd>"` or the repo is listed under `landGate`. The two "green ledger" readers (`Get-GreenTree` line 1489, `Test-GreenTree` line 1495) also return `$null` for an empty gate, so an empty gate cannot be mistaken for a cached pass. **EXPECTED** (reasoned from the code paths quoted above; not exercised by running a land).

### 3.2 Repos with no `landGate` (94)

**VERIFIED** - every candidate except `brivio` (the only repo with a configured gate). List: abridge, activity-tracker, afti, agentcfg-audit, agentq, alegeri2025, anaf-personal, axiom, bancai, bancai v1, base_template, bfut, brivio.v1, bts, bts2, bts3, caelia, cautai, circuit-tracks-mwrty, circus, codai, codai-lr17, codai-mcp-src, codai.v1, controlai, corporate, crypto-backtesting, cursuri-studiai, dashy, devbox, device-pairing, dexai, discord-csvote, domains, doomscroll-blocker, dragoscatalin, ducolo, editai, efactura-ro, evocrm, explorai, facturai, facturai.v1, gta-nexus, HIDE, idei-seap, inferance, invitatii, istanbuldentalclinic, jucai, lietome, mancai, marcai, mcp-lock, memorai, metu, mmo, money, notai, notalone, pgp, primaria-deschisa, primes, prompt-cache-doctor, radar-firme, renovate-config, rent-a-car, reports, resolve-smoke, scrin, scripts, selfie-screen, song-similarity, starvibe, stripe-firebase, swami, titi, trade-simulator, ttk-live, unscroll-rules, vicam, viitorul-gorjului, vitals, vitals-win, vmui, vscode-tasks2, vsrchat, vwebacm, watch-faces, wdw-cosmology, workflows, workspace, workspace-ai, wptheme-register.

Consequence (**EXPECTED**, from 3.1): a bare gentq land in any of these runs no agentq gate; only the repo's own pre-push hook, if present, can block the push. 14 of them still have a pre-push hook; the remaining 80 have neither (see 3.3).

### 3.3 Repos with no `landGate` AND no `pre-push` hook (nothing gates a push)

**VERIFIED** - 80 repos. For each, landGate is empty and both Test-Path pre-push probes are false, so neither agentq nor a git pre-push hook stops a bad push. List:

```text
abridge, activity-tracker, agentcfg-audit, agentq, alegeri2025, anaf-personal, axiom, bancai, bancai v1, base_template, bfut, brivio.v1, bts, bts2, bts3, caelia, cautai, circuit-tracks-mwrty, circus, codai-mcp-src, codai.v1, corporate, crypto-backtesting, cursuri-studiai, dashy, devbox, device-pairing, discord-csvote, domains, doomscroll-blocker, ducolo, editai, efactura-ro, explorai, facturai, facturai.v1, idei-seap, inferance, invitatii, istanbuldentalclinic, jucai, lietome, mancai, mcp-lock, memorai, metu, mmo, money, notalone, pgp, primaria-deschisa, primes, prompt-cache-doctor, radar-firme, renovate-config, rent-a-car, reports, resolve-smoke, scripts, selfie-screen, song-similarity, starvibe, stripe-firebase, swami, trade-simulator, ttk-live, unscroll-rules, vicam, viitorul-gorjului, vitals, vitals-win, vmui, vscode-tasks2, vwebacm, watch-faces, wdw-cosmology, workflows, workspace, workspace-ai, wptheme-register
```

### 3.4 Repos with no upstream (2)

**VERIFIED** - `git -C E:\gh\<r> rev-parse --abbrev-ref --symbolic-full-name '@{u}'` exits 128 for both, with the exact messages:

```text
E:\gh\bancai
  exit 128: fatal: no upstream configured for branch 'main'
  (git rev-list --left-right --count "origin/main...HEAD" -> 0 0: a local origin/main ref exists, no upstream is set)

E:\gh\primaria-deschisa
  exit 128: fatal: no upstream configured for branch 'main'
  (git rev-list --left-right --count "origin/main...HEAD" -> exit 128:
   fatal: ambiguous argument 'origin/main...HEAD': unknown revision or path not in the working tree.)
```

### 3.5 Non-zero clone positions (main clone vs last-fetched origin)

**VERIFIED** (`git rev-list --left-right --count "origin/<branch>...HEAD"`, no fetch):

```text
diverged: facturai.v1 [46 behind / 46 ahead]
behind  : codai [behind 21] ; corporate [behind 1]
ahead   : 
```

All other repos report `0 0` (level with the last-fetched `origin/<branch>`). `codai`/`corporate` are behind; `facturai.v1` is fully diverged (46/46). Because no fetch was performed these are not authoritative about the live remote - they describe the local refs only (**EXPECTED** for the true remote position).

### 3.6 Worktree slots present under `E:\gh\.wt\<repo>`

**VERIFIED** (`Get-ChildItem E:\gh\.wt\<repo> -Directory`):

```text
afti=0  |  agentcfg-audit=0  |  agentq=2  |  axiom=2  |  brivio=13  |  caelia=4  |  codai=17  |  corporate=1  |  dashy=0  |  device-pairing=0  |  doomscroll-blocker=0  |  dragoscatalin=0  |  gta-nexus=0  |  lietome=1  |  marcai=5  |  metu=1  |  mmo=1  |  money=2  |  notalone=0  |  selfie-screen=0  |  swami=2  |  titi=2  |  unscroll-rules=0  |  vitals=3  |  vmui=2  |  watch-faces=2
```

### 3.7 Config keys missing from one copy + the default each would receive (**VERIFIED**)

Source copy: `E:\gh\agentq\ps\bin\agentq-config.json` (39 keys). Installed copy: `%USERPROFILE%\.copilot\bin\agentq-config.json` (39 keys).

- Keys in source but **missing from installed**: NONE
- Keys in installed but **missing from source**: NONE

Both copies carry the **same 39 keys**, so **no key falls back to the `agentq-v2.ps1` defaults** in either copy. The differences are VALUE overrides only (legitimate, per the task):

| Key | Source (`ps\bin`) | Installed (`~\.copilot\bin`) |
| --- | --- | --- |
| `taskSlotsPerRepo` | `10` | `11` |
| `taskSlotsMachine` | `22` | `26` |
| `leaseMaxIdleMin` | `360` | `1440` |
| `machineCapAdaptive` | `{"min":2,"max":6,"cpuHigh":85,"cpuLow":55,"minFreeRamGB":24,"minFreeCommitGB":24,"everySec":15}` | `{"min":2,"max":4,"cpuHigh":85,"cpuLow":55,"minFreeRamGB":24,"minFreeCommitGB":24,"everySec":15}` |
| `quickBurst` | `2` | `1` |

**VERIFIED** - the defaults that a genuinely-missing key WOULD fall back to are defined in `ps/bin/agentq-v2.ps1` lines 19-28 (`$c = @{ ... }` at the top of `Get-Config`), e.g.:

```text
L20: taskSlotsPerRepo = 3; taskSlotsMachine = 10; releaseSlots = @{}; pinned = @{}
L24: leaseDeadIdleMin = 120; leaseMaxIdleMin = 360; unleasedRemoveIdleHours = 168; minFreeCommitGB = 12
L26: machineCap = 2; quickBurst = 1; agingMin = 5; idleYieldMin = 5; idleCpuSec = 10
L27: bumpMax = 50; burstMax = 2; burstMaxMin = 60; overridesPerHour = 6; runBuildTimeoutMin = 240
L28: journalRotateMB = 64
```

Note that `landGate`, `sharedCloneMode`, `sharedCloneModeRepos`, `landPregate`, `greenTtlHours`, `admission`, `agentLimit` and `prune` are **not** in that default block - they are simply absent when not in a config file (`Get-Config` reads them via `ContainsKey`/`[]` guards). Both copies therefore supply them; nothing relies on the (non-existent) defaults. **EXPECTED** for the "absent = no value" behaviour; the block itself is **VERIFIED** by reading lines 19-28.

## 4. Top gaps (ranked)

1. **94/95 repos have no `landGate`** - a bare `agentq land` runs no agentq gate for any of them (only `brivio` is gated). VERIFIED (config + code).
2. **80 repos have neither a land gate nor a `pre-push` hook** - nothing gates a push at all; the largest actionable class. VERIFIED.
3. **80/95 repos have no `pre-push` hook** (only 15 do: husky repos + the 3 lefthook repos). VERIFIED.
4. **76/95 repos have no `pre-commit` hook** (only 19 do). VERIFIED.
5. **`codai` main clone is 21 commits behind `origin/main`** (last-fetched ref). VERIFIED.
6. **`facturai.v1` main clone is diverged 46/46** from `origin/main`. VERIFIED.
7. **`corporate` is 1 behind `origin/main`.** VERIFIED.
8. **`bancai` and `primaria-deschisa` have no upstream configured**; `primaria-deschisa` has no local `origin/main` either. VERIFIED.
9. **No config key drift** - both copies have the same 39 keys; only values differ (5 keys). VERIFIED.
10. **`vitals-win` is a config key with no local checkout** (cloud workspace); it is not a repo on disk. VERIFIED.

## 5. What I could not verify

- **True remote position** of each clone: I never fetched (task constraint), so `origin...HEAD` reflects local refs only; `codai [-21]`, `corporate [-1]`, `facturai.v1 [46/46]` may differ from the live remote. (No network used.)
- **Actual gate behaviour end-to-end**: the "no gate runs" conclusion for gate-less repos is derived by reading `agentq-v2.ps1` (VERIFIED quotes) but I did not run a land, so I did not observe it empirically (**EXPECTED**).
- **lefthook hook effectiveness**: for `marcai`, `scrin`, `titi` the git hook is a lefthook shim; whether it blocks a push depends on `lefthook.yml` and a lefthook install in the clone - I read the shim/config but did not run a push.
- **Reachability of `%USERPROFILE%`-relative paths** beyond the two config files explicitly named: not attempted.
- **`branch` field** is whatever `rev-parse --abbrev-ref HEAD` returned; a detached HEAD is reported as `HEAD` and its position as `(detached/HEAD)` (none were detached).
- **Hidden/extra repos** outside `E:\gh` and not named in config: out of scope.

- Not verified: nothing under `E:\gh\agentq\ps\**` was executed (only read); no build, test or hook was run anywhere.

