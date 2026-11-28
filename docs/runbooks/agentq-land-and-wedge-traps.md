# agentq — capcane la `land` și la un runner „înghețat"

Runbook pentru cine debughează un `agentq land` care „nu aterizează" și pentru unul care pare
blocat. Fiecare capcană e scrisă ca **Simptom → Cauză → Fix**, cu citare `cale:linie`.

**Legendă dovezi**

- `VERIFIED` — am rulat sau citit sursa în acest task (2026-11-28) și am văzut linia.
- `EXPECTED` — dedus dintr-un mecanism documentat, nereprodus punctual aici.

> Ordinea de lucru: `agentq since` întâi, commit doar via `agentq commit -Paths a,b`, deploy doar din
> arbore curat. Capcanele de mai jos se aplică peste regulile din `~/.claude/rules/multi-agent-coordination.md`.

---

## 1. Un land RESCRIE sha-ul publicat — verifică pe CONȚINUT, niciodată pe sha

**Simptom.** Crezi că un `land` a aterizat cmpărând `git rev-parse <ref>` cu un sha notat înainte de
land; cifrele diferă, sau `git merge-base --is-ancestor <topic> <ref>` întoarce „nu" și tragi concluzia
că slice-ul nu a ajuns.

**Cauză.** `land` face **merge-tree + commit-tree + push** (`ps/bin/agentq-v2.ps1:2811-2822`): commit-ul
publicat are părinți și arbore recompuse de rezolvator, deci **sha-ul e altul** chiar când conținutul
slice-ului e identic. Iar `merge-base --is-ancestor` judecă ref-ul **local**; dacă remote-tracking-ul
local e vechi, poate minți — exact bugul documentat al pre-poartei: un topic rezolvat dintr-un ref
remote-tracking „1737 commits behind origin/main", deci poarta a judecat un arbore pe care land-ul nu-l
va merge-ui niciodată (`ps/bin/agentq-v2.ps1:2733-2736`).

**Fix.**

- Verifică **conținutul**, nu sha-ul:
  - `git rev-parse "<ref>:<cale>"` (blob-ul din ref) versus `git hash-object --no-filters <fișier>`
    (octeții din working tree, fără filtre clean) — trebuie **egale**.
  - Pentru un fișier supus `.gitattributes`/EOL, folosește `git hash-object --path <cale> <fișier>`
    (aplică filtrul clean exact cum ar face-o un commit normal). agentq scrie blob-urile publicate
    exact așa: „Blobs are written from the file bytes via the repo's own clean filters (`git
hash-object --path`)" (`ps/bin/agentq-v2.ps1:3683`) și `hash-object -w --stdin-paths`
    (`ps/bin/agentq-v2.ps1:3802`).
- **Fetch întâi**, apoi judecă: land-ul însuși face `Invoke-GitNet @('-C', $main, 'fetch', '-q',
'origin')` înainte de a rezolva topicul (`ps/bin/agentq-v2.ps1:2735`, `:3590`). Dacă tu verifici de
  mână, rulează `git fetch -q origin` înainte de orice `merge-base --is-ancestor`.
- `merge-base --is-ancestor` apare și în `ps/hooks/deploy-clean.ps1:110`, `ps/bin/git-publish.ps1:162,177`,
  `ps/bin/agentq-doctor.ps1:435` — toate judecă ref-uri locale, deci moștenesc aceeași capcană.

_(VERIFIED: liniile citate.)_

---

## 2. `lease` ia repo-ul din CWD; linia tipărită poate fi a ALTUI chat

**Simptom.** `agentq lease` tipărește „leased …" pentru un repo/slot pe care nu l-ai cerut, sau
considerezi că slotul tipărit e al tău și scrii în el.

**Cauză.** Rezolvarea repo-ului cade pe **directorul curent** când nu dai `-Repo`:
`$p = if ($path) { "$path" } else { (Get-Location).Path }` (`ps/bin/agentq.ps1:524`, funcția
`Get-RepoInfo`). Deci **închiriază din directorul repo-ului dorit**. `land`, în schimb, **refuză** dacă
rulează din altă clonă decât cea care deține slotul: „land: REFUSED — this land runs against the clone
$main, but the land slot … belongs to the clone …" (`ps/bin/agentq-v2.ps1:3357`, verificarea
`Test-LandCloneOwnsSlot` la `:313`).

În plus, terminalul e **partajat între chat-uri**: linia `leased <repo>/<slot> (<leaseId>) -> <path> …`
(`ps/bin/agentq-v2.ps1:1580`) poate fi scrisă de `lease`-ul altui chat — sau chiar de pre-poarta unui
land, care închiriază cu `-Json -Wait -Purpose "land pre-gate for $Branch …"` (`ps/bin/agentq-v2.ps1:2611`).

**Fix.**

- Rulează `agentq lease` **din repo-ul țintă** (sau dă `-Repo`).
- Nu te încrede în scrollback. Sursa de adevăr care poartă **`purpose`-ul TĂU** e JSON-ul:
  `agentq status --json` → `leases[]` are câmpurile `{ leaseId, repo, slot, role, path, purpose, pid,
created, beat, alive, stale, … }` (`ps/bin/agentq.ps1:60-72`; builder-ul pune `purpose` în rând,
  `ps/bin/agentq.ps1:283`). Potrivește pe `leaseId` + `purpose`.
- Notă: `agentq lease -Json` pentru un lease NOU întoarce `{ leaseId, repo, slot, role, path, branch,
head }` (`ps/bin/agentq-v2.ps1:1577`) — **fără** `purpose`; verificarea „e al meu?" o faci cu
  `status --json`.

_(VERIFIED: liniile citate.)_

---

## 3. Pre-poarta închiriază un slot `scratch` și judecă ARBORELE ACELUI slot

**Simptom.** Un `land` eșuează cu „the pre-gate failed … in: <membru>" și nu înțelegi de unde vine
membrul roșu: în arborele tău testul e verde.

**Cauză.** Când nu găsește un slot curat al tău, pre-poarta **închiriază un slot `scratch`** și rulează
gate-ul în **acel** arbore: `Get-PregateScratchSlot` (`ps/bin/agentq-v2.ps1:2605`) cheamă `lease -Role
scratch …` (`:2611`), apoi `merge-tree`/`commit-tree`/`checkout --detach` și `Invoke-GateRun $sp …`
(`:2811-2822`). Slotul e re-setat la `origin/<onto>` înainte (`:2650-2668`), dar **rulările cloud** ale
gate-ului aduc arborele ca patch construit cu `git add -A` într-un index temporar
(`ps/bin/agentq-cloud.ps1:580`) și aplicat de runner cu `git apply --binary --whitespace=nowarn`
(`cloud/runner-agent.mjs:443`). WIP-ul necomis al unui alt agent poate intra astfel în gate și **otrăvi
verdictul**.

**Fix.**

- Membrul roșu apare **doar în logul slotului**, nu în terminalul tău. Journalul poartă `log:` per
  eveniment: `land-pregate-failed` scrie `log = $script:GateLog` (`ps/bin/agentq-v2.ps1:2834`);
  însoțitoare: `land-pregate-foreign-untracked` (`:2769`), `land-pregate-untrusted-fail` (`:2841`).
  Citește logul acela, apoi `~/.codai/coord/journal.jsonl` pentru linia `land-pregate-*` a branch-ului.
- Când gate-ul cade în slotul **tău** care cară căi `untracked` străine, verdictul e marcat **UNTRUSTED**:
  nu se carantinează topicul și nu eșuează land-ul — slotul curat de land decide în coadă
  (`ps/bin/agentq-v2.ps1:2841-2847`).
- Fix de fond: landează **din propriul slot** (nu din clona partajată), ca poarta să nu mai închirieze.

_(VERIFIED: liniile citate.)_

---

## 4. Fazele pre-push rulează în CLOUD; CPU local ~0 NU e hang

**Simptom.** Un pas pre-push al unui `land` pare blocat: log local plat, procesul local cu ~0 % CPU,
`wait-job` raportează `STALLED`.

**Cauză.** Fazele pre-push sunt trimise pe workspace-ul cloud: `scripts/hooks/turbo-run.sh` rulează
`pwsh -NoProfile -File "$AGENTQ" run -Resource build -Where cloud -TimeoutMin 90 -Purpose "hook:
$label" -- bash -c "$remote"` (`E:\gh\codai\scripts\hooks\turbo-run.sh:46`; varianta imprimată cu
`CODAI_HOOKS_DRYRUN=1` la `:42`). Munca reală e pe VM, deci **logul local e mut prin construcție**.

**Fix.**

- Ia verdictul din starea cloud, nu din CPU: runner-ul scrie heartbeat-ul cu `state: "busy"` cât
  lucrează și `"idle"` altfel (`cloud/runner-agent.mjs:648`, `:670`). Citește-l cu
  `agentq-cloud.ps1 -Status` (sau `-Status -Json`, care dă `state`, `heartbeatAgeSec`, `idleSec`,
  `queueDepth` per workspace — `ps/bin/agentq-cloud.ps1:423-477`).
- `wait-job` are acum **ramură cloud** prin `-Placement`: `cloud:<ws>` înseamnă „silence is not a
  stall", deci NU mai tipărește `STALLED` fals (header `ps/bin/wait-job.ps1:11-14`; comentariul
  „measured 2026-11-28 … printed a FALSE STALLED" la `:59`; funcția `Get-CloudHeartbeatState` la `:92`).
  Pasează `-Placement 'cloud:<ws>'` (sau `-JobId`, care ia `placement`-ul din înregistrarea jobului).

_(VERIFIED: liniile citate.)_

---

## 5. Un singur job cloud per workspace

**Simptom.** Al doilea `-Where cloud` pe același workspace pare că nu pornește, sau moare cu
`exit 64` în ~0.1 s.

**Cauză.** Workspace-ul preia **un job odată**, FIFO: runner-ul ia `queue/[0]` și îl revendică printr-un
`delete` cu `ifGenerationMatch` („only one agent wins a queued job", `cloud/runner-agent.mjs:75`) —
restul **așteaptă în coadă**. Iar un wrapper de tip greșit (PowerShell trimis unui pool Linux) nu
execută nimic și răspunde **`exit 64`** (documentat: `ps/bin/agentq-v2.ps1:2548-2551`, tratat ca
`land-pregate-infra-64` la `:2821-2826`).

**Fix.**

- Verifică adâncimea cozii: `agentq-cloud.ps1 -Status -Json` → `queueDepth` per workspace (`:439`,
  `:477`). O valoare nemăsurată e `null`, **niciodată `0`**, ca să nu confunzi „nemăsurat" cu „liber".
- Al doilea job **așteaptă**, nu se pierde. Nu-l „repara" relansându-l (risc de dublare).
- `exit 64` = runner/platformă, nu conținutul: **nu** carantina topicul pe el (vezi `land-pregate-infra-64`).

_(VERIFIED: liniile citate.)_

---

## 6. `core.fsmonitor=true` face `git status --porcelain` să dureze ~25 min cu git la 0 CPU

**Simptom.** `git status --porcelain` (pe care agentq îl cheamă des, ex. `Test-GitClean`
`ps/bin/agentq-v2.ps1:782`) pare blocat ~25 min; procesul `git` stă la ~0 % CPU și totuși nu iese.

**Cauză.** `core.fsmonitor` e o setare de **repo** moștenită de fiecare worktree (worktree-urile
partajează config-ul repo-ului principal, mai puțin când `extensions.worktreeConfig` e activ). Un
`fsmonitor` care nu răspunde face `git status` să aștepte fără să consume CPU.

**Fix.**

- Dacă un `git status` „pare blocat": **nu ucide copiii** lui preemptiv. Așteaptă / investighează
  (CPU ~0 = așteaptă un hook, nu calculează).
- Dezactivează fsmonitor-ul per repo/worktree: `git config --local core.fsmonitor false` (și verifică
  sursa cu `git config --show-origin --get core.fsmonitor`).
- `EXPECTED` — pe această mașină, la 2026-11-28, setarea **nu** era prezentă: `git config --get
core.fsmonitor` întoarce gol în `agentq` local/global/system (VERIFIED: exit 1). Nu am putut
  reproduce valoarea exactă; mecanismul (moștenire per-worktree + așteptare fără CPU) e cel documentat.

_(Mecanism EXPECTED; absența config-ului e VERIFIED.)_

---

## 7. Runner/agent înghețat: marcajul „busy" are TTL 300 s + `clearStaleBusyOnStart()`

**Simptom.** Un workspace pare „ocupat" de un job care nu mai rulează, sau un agent nou nu preia nimic
și pare mort; te întrebi dacă `timeout`-ul jobului garantează durata maximă de rulare.

**Cauză.** Marcajul `ws/<ws>/busy` are un **TTL scurt și e reîmprospătat** cât jobul rulează:
`const BUSY_TTL_SEC = 300;` și `const ttlSec = Math.min(timeoutSec, BUSY_TTL_SEC);`
(`cloud/runner-agent.mjs:261`, `:264`), reîmprospătat la fiecare 60 s (`:650-652`). La pornire, un
marcaj rămas de la un agent ucis e șters: `clearStaleBusyOnStart()` (`:297`, apelat la `:572`). Un
„long wake" (>300 s fără tick, în afara jobului) **iese intenționat**, ca supervisorul să pornească un
agent nou (`cloud/runner-agent.mjs:629-631`).

**Fix.**

- Nu promite că `jobSpec.scheduling.timeout` e un plafon **dur** de rulare: marcajul de busy era cândva
  `at + timeoutSec` (până la 90 min) și lăsa markeri care blocau heal-ul pentru vecini — de aici TTL-ul
  de 300 s (`cloud/runner-agent.mjs:256-260`). Timeout-ul jobului și TTL-ul markerului sunt lucruri
  diferite.
- Un „long wake" care iese cu `process.exit(0)` **nu** e o eroare: supervisorul (systemd
  `Restart=always` pe Linux, `agent-loop.ps1` pe Windows) pornește un agent curat.
- Diagnostic: `agentq-cloud.ps1 -Status -Json` (`state`, `heartbeatAgeSec`).

_(VERIFIED: liniile citate.)_

---

## 8. Loguri: un fișier per rulare; citește FIȘIERELE, nu scrollback-ul

**Simptom.** `wait-job` zice `STALLED` pe un log care, de fapt, avansează; sau citești output-ul din
panoul terminalului și vezi linii de la alt chat.

**Cauză.** Fiecare rulare `job-start` scrie **propriul** fișier: `<cwd>\.copilot-tmp\jobs\<id>.log`
(„combined output, then `EXIT=<code>` and `DONE`", `ps/bin/job-start.ps1:12`; calea `:45-47`), cu `id`
unic — deci **niciodată** un log partajat între rulări. Terminalul **sync** este partajat între
chat-uri, deci scrollback-ul nu e o sursă sigură. Iar `wait-job` declară `STALLED` când **dimensiunea**
logului nu s-a schimbat: „log size unchanged for `-StallMin` while the pid is alive" (header
`ps/bin/wait-job.ps1:22`) — un log buffered poate părea nemișcat.

**Fix.**

- Citește **fișierul** de output al rulării tale (calea tipărită de `job-start`: `log <path>`), nu
  scrollback-ul. La `-JobId`, `wait-job` folosește logul din înregistrarea jobului (`ps/bin/wait-job.ps1:44-47`).
- La `STALLED`, privește diagnosticile pe care `wait-job` le tipărește (ultimele 30 de linii, arborele
  de procese cu CPU/working-set, `Terminate batch job (Y/N)?`, holderii agentq) — `ps/bin/wait-job.ps1`
  `Show-Diagnostics`.
- Nu refolosi un log între rulări; fiecare rulare are id-ul ei.

_(VERIFIED: liniile citate.)_

---

## 9. Instalarea: `ps/install.ps1` copiază din ARBORELE SURSĂ

**Simptom.** Cod „live" în `~/.copilot` care nu e cel de pe `main`; sau un diff de instalare ilizibil.

**Cauză.** `install.ps1` copiază **din checkout-ul curent**: `$src = $PSScriptRoot`
(`ps/install.ps1:38`). Rulat dintr-un checkout vechi sau cu WIP-ul altor agenți, instalezi cod
neaterizat în locația live pe care o folosesc toate hook-urile. Face și backup: „backup of each file it
replaces in `~/.copilot/.backup/<ts>/`" (`ps/install.ps1:4`; calea `$bk = Join-Path $dst
".backup\<ts>"`, `:492`). `-Check` doar raportează drift: tipărește `DRIFT: <cheile SURSA>` (cheile din
map-ul sursă) și iese 1, respectiv `'in sync'` cu 0 (`ps/install.ps1:408-410`).

**Fix.**

- **Instalează doar dintr-un checkout LA `main`** (fără WIP străin). Verifică întâi cu
  `ps/install.ps1 -Check` (citește cheile sursă în drift) și abia apoi instalează.
- La nevoie, restaurează din `~/.copilot/.backup/<ts>/`.
- Instalarea rulează suitele și **refuză pe roșu**; `agentq-config.json` e **merge-uit**, niciodată
  înlocuit (`ps/install.ps1` header + blocul de merge). Nu ocoli poarta cu `-SkipTests` fără motiv scris.

_(VERIFIED: liniile citate.)_

---

## Cum verifici că un land chiar a aterizat (rețeta de 6 comenzi)

Rulează din repo-ul țintă (`<repo>`), cu `<onto>` de obicei `main` și `<cale>` căile tale:

```powershell
# 1. Reîmprospătează ref-urile (altfel merge-base/rev-parse pot minți pe un ref vechi).
git -C <repo> fetch -q origin

# 2. Tipul publicat + commit-ul de land (mesajul lui purtă topicul tău).
git -C <repo> rev-parse "origin/<onto>"; git -C <repo> log --oneline -1 "origin/<onto>"

# 3. Confirmă pe CONȚINUT, nu pe sha: blob-ul din ref == octeții din fișier.
git -C <repo> rev-parse "origin/<onto>:<cale>"      # blob stocat
git -C <repo> hash-object --no-filters <cale>       # octeții din working tree (fără filtre)

# 4. Dacă e supus .gitattributes/EOL, compară prin filtrul clean (același idiom ca land-ul).
git -C <repo> hash-object --path <cale> <cale>

# 5. Dovada de push în jurnalul agentq (evenimentul `land` pentru branch-ul tău).
Select-String -Path "$env:USERPROFILE\.codai\coord\journal.jsonl" -Pattern '<branch>.*(land|pushed|pregate-ok)'

# 6. Verdictul porții pentru arborul land-uit (nu al slotului; acesta e al altui chat).
Select-String -Path "$env:USERPROFILE\.codai\coord\journal.jsonl" -Pattern 'land-gate-ok|land-pregate-ok'
```

Interpretare: la pasul 3, **egal** = conținutul a aterizat (sha-ul putând diferi — capcana 1). La 5/6,
lipsește un `land`/`gate-ok` pentru branch/arbore **înseamnă** că nu a aterizat, oricât de „verde"
arăta un probe. `status --json` (`agentq status -Json`) rămâne sursa pentru lease/release-uri.

_(VERIFIED: comenzile folosesc exact idiomul din `ps/bin/agentq-v2.ps1:3683,3802` și
`ps/tests/test-agentq-publish.ps1:83`.)_
