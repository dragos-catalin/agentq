# ADR 0005: advisory path claims on leases (ADR 0003 W4-2)

Status: accepted 2026-10-19 (owner decision via askQuestions: show overlaps at lease time AND order lands).

## Context

- 24 land conflicts in codai and 42 in brivio in 7 days (ADR 0003 research). Most are two live slots editing the same package at the same time, which neither agent knew about until land.
- W2-6 (land precheck) finds a conflict only after the work is done.

## Decision

1. `agentq lease -Claims 'apps/hub/**,packages/ui/**'` stores `claims` (array of globs, `/` separators, `**` and `*` wildcards) in the lease record. `agentq claim -LeaseId <id> -Claims '...'` replaces them later (journal `claim`).
2. At lease time (and on `claim`), every other LIVE lease of the same repo whose claims overlap is printed (`slot`, `session`, `purpose`, the overlapping globs) and journaled as `claim-overlap`. A lease is never refused because of a claim.
3. Overlap test: two globs overlap when one's literal prefix (up to the first wildcard) is a path-prefix of the other's, segment-aligned (`apps/hub/**` overlaps `apps/hub/src/x.ts` and `apps/**`; not `apps/hubx/**`).
4. Land order: when a land ticket is created from a slot with claims, it records `claims` and `leaseCreated`. In `Test-Admissible` for `land:<repo>`, a waiting ticket whose claims overlap an OLDER waiting ticket's claims (older = earlier `leaseCreated`) ranks after it, whatever the priority. Tickets without claims keep today's order.
5. `agentq status` shows each lease's claims next to the slot.

## Consequences

- Claims are advisory and self-declared. A wrong claim costs nothing but a misleading warning.
- The land ordering only changes the order among WAITING tickets. It never pre-empts a holder and never blocks a lone ticket.

## Verification

`test-agentq-claims.ps1`: claims stored on lease; overlap printed and journaled (and no false positive on a sibling prefix); `claim` replaces; land ordering: a younger-overlapping ticket with a higher priority still ranks after the older one, and a non-overlapping one is not affected.
