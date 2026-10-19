# ADR 0004: the shared clone becomes read-only for agents (ADR 0003 W4-1)

Status: accepted 2026-10-19 (owner decision via askQuestions: warn for 7 days, then refuse; one config flag).

## Context

- The shared clone `E:\gh\<repo>` is where every agent starts, and several agents edit there at once. Drafts left in it after the same work landed from a slot block `git-autosync` (2026-10-17: codai, brivio, dragoscatalin, dashy and vmui were 1-26 days behind on exactly that).
- Since 2026-10-17 the guard prints a non-blocking advisory (`SHARED clone`) for source edits there. Nothing measures how often it fires, and nothing ever refuses.
- Leased slots (ADR 0001), `agentq publish` (ADR 0003 W1-2) and ready slots (W1-4) now give every edit a place outside the shared clone.

## Decision

1. Config key `sharedCloneMode` in `agentq-config.json`: `warn` (default) or `refuse`. Per repo: `sharedCloneModeRepos: { "<repo>": "warn"|"refuse"|"off" }` wins over the global value.
2. Every source edit in a shared clone (same detection and exemptions as the advisory: `.copilot-tmp`, `.git`, `plan`, `docs`, `memories`, `*.md|mdx|txt|csv`, non-repo paths) is journaled as `shared-write` (repo, rel path, tool, mode) by the guard. The journal write is best effort and never blocks the tool.
3. `warn`: today's advisory, plus the journal line.
4. `refuse`: the guard denies the edit with the lease recipe and the `agentq publish` alternative. Opt-out per call: env `CODAI_SHARED_CLONE_WRITE_OK=1` (already honoured), journaled as `shared-write` with `override=true`.
5. Switch date: `refuse` is set after 7 days of `warn` (on or after 2026-10-26) once `agentq slo` shows the `shared-write` count per repo. `agentq slo` gets a `sharedWrites` line per repo so the switch is decided on data.
6. Autosync keeps the shared clone current for reading. Reading, searching and running read-only commands there stay allowed.

## Consequences

- Agents must lease a slot (or use `agentq publish` from a scratch copy) for source edits. Docs, plans and scratch stay writable in the shared clone.
- The guard reads `agentq-config.json` on edit calls only (one small JSON read).
- Rollback = set `sharedCloneMode` to `warn` or `off`.

## Verification

`test-guard-shared.ps1` gains cases: journal line written in warn mode; deny in refuse mode; per-repo override; opt-out env journaled with `override`; exempt paths stay silent in refuse mode. `test-slo.mjs` covers `sharedWrites`.
