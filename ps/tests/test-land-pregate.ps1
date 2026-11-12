# ADR 0009 stage 0 (OQ-002 / OQ-003): the land gate runs in the caller's slot on the REBASED result
# before the land ticket is taken; a tree that already passed the gate is not gated again in the queue.
# Isolated in %TEMP%; the gate is the fake-gate test double (fails when the tree contains bad.txt).
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqpg-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'
$env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_FLAKES = '1'; $env:AGENTQ_NO_POSTLAND = '1'; $env:AGENTQ_LAND_BATCH = '0'
$env:AGENTQ_SESSION = 'test-pg'
$env:AGENTQ_RUN_BUILD = Join-Path $PSScriptRoot 'fake-gate.ps1'
$env:FAKE_GATE_LOG = Join-Path $tmp 'gates.log'
$env:FAKE_GATE_TREE_LOG = Join-Path $tmp 'gate-trees.log'
foreach ($v in 'FAKE_GATE_HOLD', 'AGENTQ_LAND_NO_PREGATE', 'AGENTQ_NO_GREEN') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Gates([string]$rx) { if (Test-Path $env:FAKE_GATE_LOG) { @(Get-Content $env:FAKE_GATE_LOG | Where-Object { $_ -match $rx }) } else { @() } }
function GateTrees([string]$rx) { if (Test-Path $env:FAKE_GATE_TREE_LOG) { @(Get-Content $env:FAKE_GATE_TREE_LOG | Where-Object { $_ -match $rx } | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ purpose = $p[0]; tree = $p[1]; root = $p[2] } }) } else { @() } }
function Journal { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }) }
function Ev([string]$name, [string]$branch) { @(Journal | Where-Object { $_.event -eq $name -and (-not $branch -or "$($_.PSObject.Properties['branch'].Value)" -eq $branch) }) }
function Tip { (git -C $repo ls-remote origin refs/heads/dev).Split("`t")[0] }
function Remote([string]$f) { git -C $repo fetch -q origin 2>$null; (git -C $repo show "origin/dev:$f" 2>$null) -join '' }
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$repoName = Split-Path -Leaf $repo
$cfg = Join-Path $tmp 'cfg.json'
# 12 slots: the cases below lease up to 11 task slots and release only some of them on the way (with 3,
# the 4th lease waited for a free slot until the suite timed out).
function Cfg([string]$extra = '') { "{`"taskSlotsPerRepo`":12,`"taskSlotsMachine`":14,`"minFreeCommitGB`":0,`"landGate`":{`"$repoName`":`"pnpm land:gate`"}$extra}" | Set-Content $cfg }
Cfg
$env:AGENTQ_CONFIG = $cfg
# A leased task slot on a fresh topic branch; returns the lease.
function Slot([string]$branch) {
  Push-Location $repo
  try { $o = AQ lease -Purpose "work $branch" -Branch $branch -Ref origin/dev -Json } finally { Pop-Location }
  $l = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  git -C $l.path config core.autocrlf false
  $l
}
function Commit($l, [string]$file, [string]$text, [string]$branch) {
  Set-Content (Join-Path $l.path $file) $text; git -C $l.path add $file; git -C $l.path commit -qm "topic $branch"
  git -C $l.path push -q origin $branch 2>$null
}
# Move origin/dev forward behind the slot's back (another agent landed).
function AdvanceDev([string]$file, [string]$text) {
  git -C $repo fetch -q origin; git -C $repo checkout -q -B dev origin/dev
  Set-Content (Join-Path $repo $file) $text; git -C $repo add $file; git -C $repo commit -qm "other $file"; git -C $repo push -q origin dev 2>$null
}
function LandFrom([string]$dir, [string[]]$more) {
  Push-Location $dir
  try { $a = @('land', '-Onto', 'dev', '-TimeoutMin', '5') + $more; AQ @a } finally { Pop-Location }
}
try {
  # 1. green path: the gate runs ONCE, in the slot, before the land ticket; the queue does not gate again
  $l1 = Slot 'p1'; Commit $l1 'p1.txt' 'p1' 'p1'
  $head1 = git -C $l1.path rev-parse HEAD
  $o = LandFrom $l1.path @('-Branch', 'p1', '-Purpose', 'land p1')
  Check '1 land exits 0 and lands' ($code -eq 0 -and (Remote 'p1.txt') -eq 'p1') $o
  Check '1 the gate ran once, as a pre-gate in the slot' (@(Gates 'land pregate p1').Count -eq 1 -and (GateTrees 'land pregate p1')[0].root -eq $l1.path) ((Gates '.') -join ' | ')
  Check '1 no second gate while holding the land ticket' (@(Gates '^land gate p1').Count -eq 0) ((Gates '.') -join ' | ')
  $j = Journal
  $iPre = [array]::IndexOf(@($j | ForEach-Object event), 'land-pregate-ok')
  $iQ = @(0..($j.Count - 1) | Where-Object { $j[$_].event -eq 'queued' -and "$($j[$_].resource)" -eq "land:$repoName" })[0]
  Check '1 the pre-gate finished BEFORE the land ticket was queued' ($iPre -ge 0 -and $iQ -gt $iPre) "pre=$iPre queued=$iQ"
  Check '1 journal: land-gate-skipped-green names the tree the gate saw' (@(Ev 'land-gate-skipped-green').Count -eq 1 -and (Ev 'land-gate-skipped-green')[0].tree -eq (GateTrees 'land pregate p1')[0].tree)
  Check '1 the tree that landed is the tree that was gated' ((git -C $repo rev-parse 'origin/dev^{tree}') -eq (GateTrees 'land pregate p1')[0].tree)
  Check '1 the slot is back on its branch and commit' ((git -C $l1.path symbolic-ref --short HEAD) -eq 'p1' -and (git -C $l1.path rev-parse HEAD) -eq $head1 -and -not (git -C $l1.path status --porcelain))

  # 2. a failing gate ends the land BEFORE the queue: exit 6, no land ticket, nothing pushed
  $l2 = Slot 'p2'; Commit $l2 'bad.txt' 'x' 'p2'
  $before = Tip; $queuedBefore = @(Journal | Where-Object { $_.event -eq 'queued' -and "$($_.resource)" -eq "land:$repoName" }).Count
  $o = LandFrom $l2.path @('-Branch', 'p2', '-Purpose', 'land p2')
  Check '2 failing pre-gate -> exit 6' ($code -eq 6 -and $o -match 'BEFORE the queue') $o
  Check '2 nothing pushed' ((Tip) -eq $before)
  Check '2 no land ticket was taken' (@(Journal | Where-Object { $_.event -eq 'queued' -and "$($_.resource)" -eq "land:$repoName" }).Count -eq $queuedBefore)
  Check '2 journal: land-pregate-failed, and no in-queue land-gate-failed' (@(Ev 'land-pregate-failed' 'p2').Count -eq 1 -and @(Ev 'land-gate-failed').Count -eq 0)
  Check '2 the slot is back on its branch' ((git -C $l2.path symbolic-ref --short HEAD) -eq 'p2')

  # 3. the pre-gate judges the REBASED result, not the slot's own (older) tree
  $l3 = Slot 'p3'; Commit $l3 'p3.txt' 'p3' 'p3'
  AdvanceDev 'other3.txt' 'o3'
  $own = git -C $l3.path rev-parse 'HEAD^{tree}'; $head3 = git -C $l3.path rev-parse HEAD
  $o = LandFrom $l3.path @('-Branch', 'p3', '-Purpose', 'land p3')
  $seen = (GateTrees 'land pregate p3')[0].tree
  Check '3 lands' ($code -eq 0 -and (Remote 'p3.txt') -eq 'p3' -and (Remote 'other3.txt') -eq 'o3') $o
  Check '3 the gated tree is not the slot tree (it contains what landed meanwhile)' ($seen -and $seen -ne $own)
  Check '3 the gated tree is exactly what landed' ($seen -eq (git -C $repo rev-parse 'origin/dev^{tree}'))
  Check '3 gate ran once (pre-gate), queue skipped it' (@(Gates 'land pregate p3').Count -eq 1 -and @(Gates '^land gate p3').Count -eq 0)
  Check '3 the slot is back on its own commit' ((git -C $l3.path symbolic-ref --short HEAD) -eq 'p3' -and (git -C $l3.path rev-parse HEAD) -eq $head3)

  # 4. a rebased result that FAILS although the slot tree passes: caught before the queue
  $l4 = Slot 'p4'; Commit $l4 'p4.txt' 'p4' 'p4'
  AdvanceDev 'bad.txt' 'landed by someone else'
  $before = Tip
  $o = LandFrom $l4.path @('-Branch', 'p4', '-Purpose', 'land p4')
  Check '4 slot tree alone would pass, the rebased one fails -> exit 6 before the queue' ($code -eq 6 -and (Tip) -eq $before -and -not (Test-Path (Join-Path $l4.path 'bad.txt'))) $o
  git -C $repo fetch -q origin; git -C $repo checkout -q -B dev origin/dev; git -C $repo rm -q bad.txt; git -C $repo commit -qm 'remove bad'; git -C $repo push -q origin dev 2>$null

  # 5. OQ-003: a re-land of an unchanged green tree does not run the gate again (under 1 min in land)
  git -C $repo fetch -q origin; git -C $repo checkout -q -B p5 origin/dev
  Set-Content (Join-Path $repo 'p5.txt') 'p5'; git -C $repo add p5.txt; git -C $repo commit -qm 'topic p5'; git -C $repo push -q origin p5 2>$null
  git -C $repo checkout -q dev
  # the remote refuses the first push (as a failing pre-push or a protected branch would)
  [IO.File]::WriteAllText((Join-Path $bare 'hooks\pre-receive'), "#!/bin/sh`nif [ -f `"`$GIT_DIR/reject`" ] || [ -f ./reject ]; then echo refused-by-test >&2; exit 1; fi`nexit 0`n")
  [IO.File]::WriteAllText((Join-Path $bare 'reject'), '')
  $o = LandFrom $repo @('-Branch', 'p5', '-Purpose', 'land p5')
  Check '5 first land: not from a slot -> pre-gate skipped, gate ran in the queue, push refused (exit 7)' ($code -eq 7 -and @(Gates '^land gate p5').Count -eq 1 -and @(Ev 'land-pregate-skipped' 'p5').Count -eq 1) $o
  Remove-Item (Join-Path $bare 'reject')
  $n0 = (Journal).Count
  $o = LandFrom $repo @('-Branch', 'p5', '-Purpose', 'land p5 again')
  Check '5 re-land of the same tree lands' ($code -eq 0 -and (Remote 'p5.txt') -eq 'p5') $o
  Check '5 ... without running the gate again' (@(Gates '^land gate p5').Count -eq 1 -and $o -match 'gate skipped') ((Gates 'p5') -join ' | ')
  $j2 = @(Journal | Select-Object -Skip $n0)
  $acq = $j2 | Where-Object { $_.event -eq 'acquired' -and "$($_.resource)" -eq "land:$repoName" } | Select-Object -First 1
  $done = $j2 | Where-Object { $_.event -eq 'land' } | Select-Object -First 1
  $held = if ($acq -and $done) { ([DateTime]$done.ts - [DateTime]$acq.ts).TotalSeconds } else { -1 }
  Check '5 ... and held the land ticket under 60 s' ($held -ge 0 -and $held -lt 60) "held=$held s"
  Write-Host ("     land ticket held {0:N1} s for the re-land" -f $held)

  # 6. when the pre-gate cannot run, the land still works and says why (gate in the queue as before)
  $l6 = Slot 'p6'; Commit $l6 'p6.txt' 'p6' 'p6'
  Set-Content (Join-Path $l6.path 'scratch.txt') 'uncommitted'
  $o = LandFrom $l6.path @('-Branch', 'p6', '-Purpose', 'land p6')
  Check '6 dirty slot -> pre-gate skipped with the reason, gate in the queue, lands' ($code -eq 0 -and @(Ev 'land-pregate-skipped' 'p6')[0].reason -match 'uncommitted' -and @(Gates '^land gate p6').Count -eq 1 -and @(Gates 'land pregate p6').Count -eq 0) $o
  Check '6 the uncommitted file was not touched' ((Get-Content (Join-Path $l6.path 'scratch.txt')) -eq 'uncommitted')
  $l7 = Slot 'p7'; Commit $l7 'p7.txt' 'p7' 'p7'
  AdvanceDev 'pnpm-lock.yaml' 'lockfileVersion: 9'
  $o = LandFrom $l7.path @('-Branch', 'p7', '-Purpose', 'land p7')
  Check '6 lockfile moved on the tip -> skipped (slot modules would be stale), gate in the queue, lands' ($code -eq 0 -and @(Ev 'land-pregate-skipped' 'p7')[0].reason -match 'lockfile' -and @(Gates '^land gate p7').Count -eq 1) $o
  Check '6 ... and the slot was never moved off its branch' ((git -C $l7.path symbolic-ref --short HEAD) -eq 'p7')

  # 7. switches: env off, config off, -Gate none
  $l8 = Slot 'p8'; Commit $l8 'p8.txt' 'p8' 'p8'
  $env:AGENTQ_LAND_NO_PREGATE = '1'
  $o = LandFrom $l8.path @('-Branch', 'p8', '-Purpose', 'land p8')
  Remove-Item Env:AGENTQ_LAND_NO_PREGATE
  Check '7 AGENTQ_LAND_NO_PREGATE=1 -> gate in the queue only' ($code -eq 0 -and @(Gates 'land pregate p8').Count -eq 0 -and @(Gates '^land gate p8').Count -eq 1 -and @(Ev 'land-pregate-skipped' 'p8').Count -eq 0) $o
  $null = AQ unlease -Repo $l1.path -LeaseId $l1.leaseId; $null = AQ unlease -Repo $l2.path -LeaseId $l2.leaseId -Reason 'test'
  Cfg ",`"landPregate`":{`"$repoName`":false}"
  $l9 = Slot 'p9'; Commit $l9 'p9.txt' 'p9' 'p9'
  $o = LandFrom $l9.path @('-Branch', 'p9', '-Purpose', 'land p9')
  Check '7 config landPregate.<repo>=false -> gate in the queue only' ($code -eq 0 -and @(Gates 'land pregate p9').Count -eq 0 -and @(Gates '^land gate p9').Count -eq 1) $o
  Cfg
  $null = AQ unlease -Repo $l3.path -LeaseId $l3.leaseId; $null = AQ unlease -Repo $l4.path -LeaseId $l4.leaseId -Reason 'test'
  $l10 = Slot 'p10'; Commit $l10 'p10.txt' 'p10' 'p10'
  $o = LandFrom $l10.path @('-Branch', 'p10', '-Gate', 'none', '-Purpose', 'land p10')
  Check '7 -Gate none -> no gate anywhere' ($code -eq 0 -and @(Gates 'p10').Count -eq 0) $o

  # 8. the green ledger is keyed by the gate command too
  $g = Get-Content (Join-Path $env:AGENTQ_HOME "green\$repoName.json") -Raw | ConvertFrom-Json
  Check '8 green ledger written (tree|gate keys, where = pre-gate or land)' (@($g.PSObject.Properties).Count -ge 3 -and @($g.PSObject.Properties | Where-Object { $_.Value.where -eq 'pre-gate' }).Count -ge 2 -and @($g.PSObject.Properties | Where-Object { $_.Value.where -eq 'land' }).Count -ge 1)
  $l11 = Slot 'p11'; Commit $l11 'p11.txt' 'p11' 'p11'
  $o = LandFrom $l11.path @('-Branch', 'p11', '-Purpose', 'land p11')
  $l12 = $l11; git -C $l12.path checkout -q -B p12 origin/dev 2>$null; git -C $l12.path fetch -q origin; git -C $l12.path reset -q --hard origin/dev
  Commit $l12 'p12.txt' 'p12' 'p12'
  $o = LandFrom $l12.path @('-Branch', 'p12', '-Gate', 'pnpm other:gate', '-Purpose', 'land p12')
  Check '8 another gate command on a new tree runs its own pre-gate' ($code -eq 0 -and @(Gates 'land pregate p12').Count -eq 1) $o
} finally {
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_RUN_BUILD', 'FAKE_GATE_LOG', 'FAKE_GATE_TREE_LOG', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_FLAKES', 'AGENTQ_NO_POSTLAND', 'AGENTQ_LAND_BATCH', 'AGENTQ_LAND_NO_PREGATE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
