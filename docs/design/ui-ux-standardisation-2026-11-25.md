# Codwen UI/UX standardisation — research, target architecture, workstreams

Date: 2026-11-25 · Repo: `E:\gh\codai` (internal id **codai**, product brand **Codwen**)
Status: **plan only — nothing implemented.** Prepared so a fresh chat can execute without rediscovering.

Owner brief (2026-11-25, verbatim intent):
standardise and **reuse the tools, utilities and solutions from ONE place**; every app keeps **its own
style(s), structure, layout, primitives**; the architecture must let us **fix existing apps correctly**;
agents working on UI/UX must **know where to look and where to improve**; the standardisation itself must
be **optimisable and improvable by agents later** ("if something is missing or there is a bug"); must
include **interactions, animations, transitions, morphing, bouncing, liquid glass, swipe navigation,
reachability, usability, accessibility**; repo is codai, **branding is Codwen**.

---

## 1. What already exists (INVENTORY — measured 2026-11-25, do not re-discover)

### 1.1 Rules (agent-facing, `~/.claude/rules/`, always-on unless noted)

| file                                             | size | scope                                                                              |
| ------------------------------------------------ | ---- | ---------------------------------------------------------------------------------- |
| `accessibility.md`                               | —    | WCAG 2.2 AA, applies to `**/*.{tsx,jsx,html,svelte,vue,css}`                       |
| `styling-ui.md`                                  | —    | Tailwind v4 CSS-first tokens, `@codai/ui`, lucide/sonner/cmdk, Motion crash-safety |
| `core-engineering.md`                            | —    | path-scoped to code files; carries the formatter rule                              |
| `agent-behavior.md`, `ripple-completeness.md`, … | —    | **always-on set = 14 files, 58 188 bytes = 56.8 KB**                               |

### 1.2 Skills — **split across two roots** (this is itself a defect)

- Repo root `E:\gh\codai\.github\skills\`: `interaction-motion` (4 212 B), `ui-ux-behaviour` (6 447 B),
  `hub-ui-conventions` (17 440 B).
- User root `~/.claude/skills\`: `frontend-design` (3 190 B), `artist-designer` (6 683 B),
  `design-critic` (5 473 B), `brand-system` (8 996 B).
- A UI/UX task in codai therefore depends on **two roots**, and `hub-ui-conventions` overlays repo
  conventions on top of `ui-ux-behaviour` — there is no single entry point.

### 1.3 Agents

Brand Designer, Legal Review, Codwen Apps (cross-surface UI fixes), plus the non-agent skills above.
**No agent owns the shared design system / primitive layer itself.**

### 1.4 In-repo instruction files (`E:\gh\codai\.github\instructions\`)

`cards · docs · hub · pay · phone-android · platform-infra · studio · transcripts · web-marketing`.
**No UI/UX or design-system instruction file** — per-surface rules exist, no cross-surface one.

### 1.5 Design docs (`E:\gh\codai\docs\design\`)

`rules-layer.md` (33 KB, the trust-surface design), `design-scoring.md` (5.3 KB),
`visual-rubric.md` (3.1 KB), `glossary.md`, plus studio/personas contracts.
`design-scoring.md` + `visual-rubric.md` are the seed of a **verification gate** — they are not wired to
any agent or CI check today (VERIFY in the new chat).

### 1.6 A staged, never-applied bundle

`E:\gh\codai\docs\agent-config\2026-11-18-ui-ux\` — `APPLY.md`, `PROMPT-ui-ux-audit.md`,
`agents/ui-ux-expert.md` (6 499 B), `rules/interaction-motion.md` (3 590 B),
`skills/ui-ux-behaviour/SKILL.md` (6 731 B), `skills/marketing-surface/SKILL.md` (5 106 B).
Staged on 2026-11-18, blocked by the trust surface, **never applied**.
⚠️ Its skill copies are now **older than the installed ones** (staged 6 731 B vs installed 6 447 B) —
do not blind-copy; diff first. Its own `APPLY.md` documents the correct multi-glob ticket form.

### 1.7 What the inventory proves

The knowledge exists but is **scattered, duplicated across roots, unversioned outside git, and not
machine-checkable**. That — not missing documentation — is the actual problem.

---

## 2. Target architecture (proposed — to be confirmed in the new chat)

Five tiers. The rule that makes it reusable: **everything above a tier is derived from the tier below,
and nothing above the tier is hand-maintained.**

### T0 — Foundations: one token source

- One DTCG-format token file (`tokens/*.json`, OKLCH) → generated artefacts: CSS custom properties,
  Tailwind v4 `@theme`, Compose `MaterialTheme`/`ColorScheme`, SwiftUI `Color`/`Font`, Tauri web vars.
- Contents: semantic colour roles (surface/on-surface/state layers), typography scale **with a Romanian
  - diacritics glyph proof**, spacing/radius/elevation/z-index, motion durations + easings, blur/material
    params, breakpoints/safe-area insets.
- **Gate:** contrast computed on the generated tokens (WCAG 2.2 AA), not eyeballed; RO glyph coverage
  asserted for every font in the stack.
- There is already a brand pack (`E:\gh\codai\brand\` + `brand.json` + `docs/design` entries) — T0 must
  consume it, not re-invent it. **Decide: is the shared design system branded `@codwen/*` while the
  repo/package ids stay `@codai/*`?** (namespace decision, owner call).

### T1 — Primitives: one headless component layer

- `@codai/ui` (packages/ui today) = **behaviour + a11y only** on Base UI; styling comes from T0 tokens.
- A **parity matrix** per component × surface (web · Tauri desktop · Android · Wear · Google TV ·
  iOS · VS Code webview · browser extension), each row with a named native counterpart (Compose,
  SwiftUI) — so "there is no wheel for Wear" is written down instead of discovered.
- Utilities (class merge, focus trap, gesture recogniser, reachability helpers, D-pad/rotary focus
  router, reduced-motion hook, async-state renderer) live here once and are consumed by every app.

### T2 — Per-app design system (each app owns its identity)

- `apps/<x>/design/DESIGN.md` + a theme pack: token overrides, layout shell, app-level composition.
- It records: the app's style(s), structure/layout, primitives in use, **and every deviation from T1
  with a reason**. Deviations without a reason fail review.
- This is how "fiecare aplicație să aibă stilul ei propriu" and "one place for the solutions" coexist.

### T3 — Behaviour contracts (mandatory, cross-platform)

Input matrix: pointer · touch · keyboard · D-pad/remote · rotary · voice · gesture (incl. swipe
navigation from edge vs content). Plus focus management + focus-visible, safe areas + reachability,
the five async states (idle/loading/empty/error/partial) as a required component API, destructive-action
consent, offline/degraded, and reduced-motion parity on every platform.
**Deliverable shape:** one table per platform, each cell either satisfied-by-T1, app-owned, or
explicitly not-applicable with a reason.

### T4 — Motion & interaction vocabulary (named, measured)

Named intents instead of ad-hoc durations: enter/exit, transition between screens, **shared-element
morph**, spring vs curve, bounce/overshoot, **liquid-glass material** (blur/refraction/tint/depth rules),
gesture physics + interruptibility, choreography (stagger/order), and motion budgets per intent.
Each entry: tokens used, JS/runtime cost, and behaviour under reduced-motion (a real, tested path, not a
CSS afterthought). Motion must be **interruptible and crash-safe** (the existing rule already flags
Motion crash-safety — keep that invariant).

### T5 — Verification + self-improvement (this is what makes it survive)

- **Gates:** token contrast · a11y sweep + keyboard/focus matrix · visual regression per surface ·
  a reduced-motion run · platform smoke screenshots · motion cost budget.
- **Scoring:** fold `docs/design/design-scoring.md` + `visual-rubric.md` into one rubric a `design-critic`
  pass can apply deterministically.
- **Improvement path (the owner's "agents must be able to improve it"):** the standard lives in
  versioned packages + `docs/design/` + skills; an agent that finds a gap or bug files a proposal
  (`~/.copilot/rules/proposals/`, always writable) or opens a PR against T0/T1, and a documented
  **entry point** tells it which tier to touch. The entry point is the single most important artefact:
  one file that answers "where do I look, where do I fix, where do I add".

---

## 3. Workstreams (ranked; each with a verifiable done-means)

| #   | Workstream                                                                                | Done means                                                                                               |
| --- | ----------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| W1  | **Single entry point** `docs/design/README.md` (map: tier → path → owner → how to extend) | An agent with no prior context, given a UI bug, names the correct tier and file in one read              |
| W2  | **Inventory + reconcile the split skills** (two roots, staged vs installed drift)         | One canonical location per skill, no duplicates, `test-config-integrity.ps1` green                       |
| W3  | **T0 tokens**: one source, N generated outputs, contrast + RO glyph gates                 | Generated artefacts committed; contrast gate passes on every role; no hand-edited token in any app       |
| W4  | **T1 primitives + parity matrix**                                                         | Every shipped component has a matrix row; each cell satisfied-by-T1 / app-owned / n-a with reason        |
| W5  | **T3 input & async-state audit of existing apps**                                         | Per-app table filled with evidence (screenshots or test ids), gaps listed as issues                      |
| W6  | **T4 motion vocabulary**, incl. liquid glass + swipe + morph                              | Each intent has tokens, a cost number and a reduced-motion path; at least one app consumes it end to end |
| W7  | **T5 gates in CI**                                                                        | The a11y + contrast + visual-regression gates run and fail a deliberately broken PR                      |
| W8  | **Codwen branding pass**                                                                  | Brand pack applied through T0 only — no per-app brand strings hardcoded                                  |

**Do not start with W3.** W1 and W2 are cheap and everything else depends on the map being true.

**Agreed starting scope (owner, 2026-11-25): W1-W6.** W7 and W8 follow once the tokens and primitives
exist to gate.

---

## 4. Open decisions for the owner (raise at the start of the new chat)

1. Namespace: `@codai/ui` → `@codwen/ui` for the shared layer, or keep `@codai` internally?
2. Where does the shared system live: this monorepo (`packages/`) for now, or a separate repo other
   projects consume (brivio/titi/vitals/dashy all have UI surfaces)?
3. **ANSWERED (owner, 2026-11-25): raise the cap to 60 KB and add a WARN band at 56 KB**; trimming
   becomes a reviewed workstream, not an emergency edit. Patch filed as
  `~/.copilot/rules/proposals/01X04CONTEXTBUDGET20261125.proposal.json`; **APPLIED 2026-11-26**. Any
  UI/UX agent-facing text is then accounted for against 60 KB, not the old 52.
4. Do we retrofit the existing apps in one wave, or gate new work first and migrate per app?

## 5. Carried-over finding (unrelated to UI/UX, but it blocks "no problems left")

`test-config-integrity.ps1` X-04 enforces `$budgetKB = 52` over the 14 always-on rules in
`~/.claude/rules`; the measured total is **58 188 B = 56.8 KB → FAIL**. `multi-agent-coordination.md`
alone is 16 592 B. The 2026-11-25 dead-lease + ticket-scope documentation added ≈4.6 KB of it.
Gate remedy, quoted from the script: _"scope a rule to paths or trim it"_.

**Resolved as policy 2026-11-25:** the cap moves to 60 KB with a WARN band at 56 KB (owner decision, section 4 item 3). Scoping or trimming stays the right answer wherever a rule has a narrower trigger; the git, agentq, slot and ticket rules do not, which is why a cap raise - not a deletion - is the fix.

**Applied 2026-11-26:** `$budgetKB = 60` with `$warnKB = 56` is live in
`~/.copilot/hooks/test-config-integrity.ps1`, and the gate now reports
`ok  always-on rules: 14 files, 57.8 KB (budget 60 KB) - WARN: above the 56 KB watch band, trim before
the next raise`. The WARN band is deliberately non-blocking: creep stays visible without stopping a
commit. Trimming remains a tracked, reviewed workstream, and the honest shrinking target is the
overlap between `agent-behavior.md`, `capture-standing-preferences.md`, `request-intake.md` and
`ripple-completeness.md` (listed in the X-04 proposal), not the git/agentq/slot rules that have no
file glob to scope against.
