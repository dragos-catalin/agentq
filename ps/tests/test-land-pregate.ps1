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
# scratchSlotsMax:3 pins the scratch pool to exactly the floor for THIS fixture: cases 5/5c/5e exercise
# "the pool is full" (the pre-gate skips), holding scratch-1..3 and expecting no scratch-4. The elastic pool
# (an index beyond the floor when the machine has room) is covered by tests/test-slot-budget.ps1.
function Cfg([string]$extra = '') { "{`"taskSlotsPerRepo`":15,`"taskSlotsMachine`":17,`"scratchSlotsMax`":3,`"minFreeCommitGB`":0,`"landGate`":{`"$repoName`":`"pnpm land:gate`"}$extra}" | Set-Content $cfg }
Cfg
$env:AGENTQ_CONFIG = $cfg
# A leased task slot on a fresh topic branch; returns the lease.
# 2026-11-20: one SESSION holds one task slot per repo (the rule that stops a chat from hoarding slots),
# and this fixture is a single session that deliberately holds up to 11 -> it names each slot explicitly.
$script:slotN = 0
function Slot([string]$branch) {
  $script:slotN++
  Push-Location $repo
  try { $o = AQ lease -Purpose "work $branch" -Branch $branch -Ref origin/dev -Slot "task-$($script:slotN)" -Json } finally { Pop-Location }
  $l = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  if (-not $l -or -not $l.path) { throw "Slot '$branch' got no lease (exit $code): $o" }
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
# Runs a step as a DIFFERENT session id. This fixture is ONE session that holds task-1..task-11, and since
# 2026-11-23 `Invoke-LandPregate` prefers a clean slot THE CALLER'S SESSION holds (any role) before renting a
# scratch one - so a case that means to exercise the "land from the clone root, take a scratch slot" path has
# to stop looking like the session that holds task-1, or it legitimately pre-gates in task-1 instead.
function AsSession([string]$sid, [scriptblock]$body) {
  $prev = $env:AGENTQ_SESSION; $env:AGENTQ_SESSION = $sid
  try { & $body } finally { $env:AGENTQ_SESSION = $prev }
}
# ---- helpers for the quarantine / dirty-scratch / wrong-clone cases (2026-11-23) -----------------
$script:bgProcs = @()
function QFile { Join-Path (Join-Path $env:AGENTQ_HOME 'land') "$repoName.json" }
# branch -> { at, tree, reason }: the negative ledger the pre-gate failure feeds and the picker reads.
function QMap { if (Test-Path -LiteralPath (QFile)) { (Get-Content -LiteralPath (QFile) -Raw | ConvertFrom-Json -AsHashtable) } else { @{} } }
function QKeys { @((QMap).Keys) }
function QueueDir { Join-Path (Join-Path $env:AGENTQ_HOME 'queues') "land_$repoName" }
function QueuedCount { $d = QueueDir; if (Test-Path -LiteralPath $d) { @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'adaptive.json' }).Count } else { 0 } }
function WaitJournal([string]$evt, [string]$session, [int]$maxSec = 60) {
  for ($i = 0; $i -lt ($maxSec * 2); $i++) { if (@(Journal | Where-Object { $_.event -eq $evt -and "$($_.session)" -eq $session }).Count) { return $true }; Start-Sleep -Milliseconds 500 }
  $false
}
function WaitGates([string]$rx, [int]$maxSec = 60) {
  for ($i = 0; $i -lt ($maxSec * 2); $i++) { if (@(Gates $rx).Count) { return $true }; Start-Sleep -Milliseconds 500 }
  $false
}
# A land in its own session, in the background: the only way two lands can WAIT on each other (the land
# queue is cap 1), which is what the batch picker needs to have a quarantined waiter in front of it.
function Start-Land([string]$branch, [string]$session) {
  $sf = Join-Path $tmp "land-$branch.ps1"; $of = Join-Path $tmp "land-$branch.out"
  $body = @(
    "`$env:AGENTQ_SESSION = '$session'"
    "`$env:AGENTQ_LAND_NO_PREGATE = '1'"
    "Set-Location -LiteralPath '$repo'"
    "& pwsh -NoProfile -File '$Aq' land -Branch '$branch' -Onto dev -TimeoutMin 5 -Purpose 'land $branch' *>&1 | Out-File -Encoding utf8 '$of'"
    "exit `$LASTEXITCODE"
  ) -join "`n"
  [IO.File]::WriteAllText($sf, $body)
  $p = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $sf) -PassThru -WindowStyle Hidden
  $script:bgProcs += $p
  [pscustomobject]@{ p = $p; branch = $branch; out = $of }
}
function Stop-Land([int]$maxSec = 90) {
  $deadline = (Get-Date).AddSeconds($maxSec)
  foreach ($p in $script:bgProcs) { try { if (-not $p.HasExited) { [void]$p.WaitForExit([math]::Max(1000, [int](($deadline - (Get-Date)).TotalMilliseconds))) } } catch {} }
  foreach ($p in $script:bgProcs) { try { if (-not $p.HasExited) { $p.Kill() } } catch {} }
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

  # 5. a land from the SHARED CLONE takes a scratch slot for the pre-gate and gives it back, and a re-land
  #    of an unchanged green tree does not run the gate again (the point of OQ-003: under 1 min in land)
  #    Run as `pg5`, not `test-pg`: this case is about the session that has NO slot of its own.
  git -C $repo fetch -q origin; git -C $repo checkout -q -B p5 origin/dev
  Set-Content (Join-Path $repo 'p5.txt') 'p5'; git -C $repo add p5.txt; git -C $repo commit -qm 'topic p5'; git -C $repo push -q origin p5 2>$null
  git -C $repo checkout -q dev
  # the remote refuses the first push (as a failing pre-push or a protected branch would)
  [IO.File]::WriteAllText((Join-Path $bare 'hooks\pre-receive'), "#!/bin/sh`nif [ -f `"`$GIT_DIR/reject`" ] || [ -f ./reject ]; then echo refused-by-test >&2; exit 1; fi`nexit 0`n")
  [IO.File]::WriteAllText((Join-Path $bare 'reject'), '')
  $o = AsSession 'pg5' { LandFrom $repo @('-Branch', 'p5', '-Purpose', 'land p5') }
  $scr = @(Ev 'land-pregate-slot-released' 'p5')
  Check '5 first land from the clone: the pre-gate ran there, in a scratch slot (not the caller tree)' ($code -eq 7 -and @(Gates 'land pregate p5').Count -eq 1 -and (GateTrees 'land pregate p5')[0].root -match 'scratch-\d+$' -and $scr.Count -eq 1 -and "$($scr[0].slot)" -match '^scratch-\d+$') $o
  Check '5 ... and the queue did not gate again (the pre-gate recorded the tree green)' (@(Gates '^land gate p5').Count -eq 0 -and @(Ev 'land-pregate-skipped' 'p5').Count -eq 0) ((Gates 'p5') -join ' | ')
  $scratchDir = Join-Path $env:AGENTQ_HOME ("leases\$repoName")
  $heldAfter5 = if (Test-Path -LiteralPath $scratchDir) { @(Get-ChildItem -LiteralPath $scratchDir -Filter 'scratch-*.json' -File -ErrorAction SilentlyContinue) } else { @() }
  $leaseFile = if ($scr.Count -eq 1) { Join-Path $scratchDir ("$($scr[0].slot)" + '.json') } else { (($heldAfter5 | ForEach-Object { $_.FullName }) -join ', ') }
  Check '5 ... and the scratch slot was given back (lease record removed)' ($scr.Count -eq 1 -and $scr[0].exit -eq 0 -and -not (Test-Path -LiteralPath $leaseFile)) "$leaseFile"
  Remove-Item (Join-Path $bare 'reject')
  $n0 = (Journal).Count
  $o = AsSession 'pg5' { LandFrom $repo @('-Branch', 'p5', '-Purpose', 'land p5 again') }
  Check '5 re-land of the same tree lands' ($code -eq 0 -and (Remote 'p5.txt') -eq 'p5') $o
  $gates5 = @(Gates 'land pregate p5').Count + @(Gates '^land gate p5').Count
  $said5 = [bool]("$o" -match 'gate skipped')
  Check '5 ... without running the gate again' ($gates5 -eq 1 -and $said5) ("gates=$gates5 said=$said5 || " + ((@("$o" -split "`n") | Select-Object -Last 8) -join ' / '))
  $j2 = @(Journal | Select-Object -Skip $n0)
  $acq = $j2 | Where-Object { $_.event -eq 'acquired' -and "$($_.resource)" -eq "land:$repoName" } | Select-Object -First 1
  $done = $j2 | Where-Object { $_.event -eq 'land' } | Select-Object -First 1
  $held = if ($acq -and $done) { ([DateTime]$done.ts - [DateTime]$acq.ts).TotalSeconds } else { -1 }
  Check '5 ... and held the land ticket under 60 s' ($held -ge 0 -and $held -lt 60) "held=$held s"
  Write-Host ("     land ticket held {0:N1} s for the re-land" -f $held)
  # 5b. the shared-clone path is a config switch, and with it off the land says why (queue-side gate)
  Cfg ",`"landPregateFromMain`":false"
  git -C $repo fetch -q origin; git -C $repo checkout -q -B p5b origin/dev
  Set-Content (Join-Path $repo 'p5b.txt') 'p5b'; git -C $repo add p5b.txt; git -C $repo commit -qm 'topic p5b'; git -C $repo push -q origin p5b 2>$null
  git -C $repo checkout -q dev
  $o = LandFrom $repo @('-Branch', 'p5b', '-Purpose', 'land p5b')
  Check '5b landPregateFromMain=false -> the clone takes no slot, the reason is journaled, the queue gates' ($code -eq 0 -and @(Ev 'land-pregate-skipped' 'p5b')[0].reason -match 'not run from a leased task slot' -and @(Gates '^land gate p5b').Count -eq 1 -and @(Ev 'land-pregate-slot-released' 'p5b').Count -eq 0) $o
  # 5c. no free scratch slot: skip with the reason instead of running the gate anywhere (wait 0 = no wait)
  Cfg ",`"landPregateScratchWaitMin`":0"
  # The scratch slot case 5's land took MUST be gone before 5c holds all three. A land that leaks it (the
  # `finally { Release-PregateSlot }` in Invoke-Land removed) is exactly what makes the fixture below sit on
  # a slot that is still held. Fail HERE, naming the leaked lease file, before any lease has a chance to wait.
  $leaked = if (Test-Path -LiteralPath $scratchDir) { @(Get-ChildItem -LiteralPath $scratchDir -Filter 'scratch-*.json' -File -ErrorAction SilentlyContinue) } else { @() }
  Check '5c the scratch slot case 5 took was given back (no scratch lease is held)' ($leaked.Count -eq 0) ("leaked lease file(s): " + (($leaked | ForEach-Object { $_.FullName }) -join ', ') + ' - the land never released its pre-gate scratch slot')
  # A leaked slot would make the fixture below wait on a slot that is still held; give the leaked lease back
  # (the failure is already recorded), so the suite leaves no slot behind and 5c stays bounded.
  foreach ($lf in $leaked) {
    $lk = try { Get-Content -LiteralPath $lf.FullName -Raw | ConvertFrom-Json } catch { $null }
    if ($lk -and $lk.path -and $lk.leaseId) { $null = AQ unlease -Repo "$($lk.path)" -LeaseId "$($lk.leaseId)" -Reason 'cleanup: pre-gate scratch slot leaked by the land' }
  }
  # Bounded on purpose: -Wait -MaxMin 0 grabs a free slot on the first check but gives up at once on a held
  # one instead of blocking, so a leak makes the fixture FAIL (fewer than three held) rather than hang.
  $hold = @(1..3 | ForEach-Object {
    Push-Location $repo
    try { $o = AQ lease -Role scratch -Slot "scratch-$_" -Purpose 'hold for 5c' -Ref origin/dev -Json -Wait -MaxMin 0 } finally { Pop-Location }
    $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  })
  Check '5c the fixture holds all three scratch slots' (@($hold | Where-Object { $_.leaseId }).Count -eq 3) ($hold | ConvertTo-Json -Compress)
  git -C $repo fetch -q origin; git -C $repo checkout -q -B p5c origin/dev
  Set-Content (Join-Path $repo 'p5c.txt') 'p5c'; git -C $repo add p5c.txt; git -C $repo commit -qm 'topic p5c'; git -C $repo push -q origin p5c 2>$null
  git -C $repo checkout -q dev
  # As `pg5c`, so the three holders above (this session's) really are foreign to it: a session that holds a
  # clean slot of its own would pre-gate there instead, which is 5e's case, not this one.
  $o = AsSession 'pg5c' { LandFrom $repo @('-Branch', 'p5c', '-Purpose', 'land p5c') }
  Check '5c all scratch slots held -> pre-gate skipped with the reason, the queue gates, lands' ($code -eq 0 -and @(Ev 'land-pregate-skipped' 'p5c')[0].reason -match 'no scratch slot was free' -and @(Gates 'land pregate p5c').Count -eq 0 -and @(Gates '^land gate p5c').Count -eq 1) $o
  foreach ($l in $hold) { $null = AQ unlease -Repo $l.path -LeaseId $l.leaseId }
  Cfg

  # 5d. a land started from a SCRATCH slot uses THAT slot for the pre-gate. The role must not decide: the
  #     gate only needs a clean, installed tree, and `Prepare-Slot` installs for scratch too. Before
  #     2026-11-23 the filter was task/pinned, so this land looked like a land "from the shared clone",
  #     could not take a SECOND scratch slot, and skipped the pre-gate - the whole gate then ran inside the
  #     cap-1 land mutex (measured: 49 of a 99 min queue hold was gate runs, and 6 of the last ~10 lands
  #     skipped with "no scratch slot was free").
  Push-Location $repo
  try { $raw5d = AQ lease -Role scratch -Slot 'scratch-1' -Purpose 'land from a scratch slot' -Ref origin/dev -Json } finally { Pop-Location }
  $l5d = $raw5d -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check '5d the fixture holds a scratch slot' ([bool]$l5d.leaseId) $raw5d
  git -C $l5d.path config core.autocrlf false
  Set-Content (Join-Path $l5d.path 'p5d.txt') 'p5d'; git -C $l5d.path add p5d.txt; git -C $l5d.path commit -qm 'topic p5d'
  git -C $l5d.path push -q origin "HEAD:refs/heads/p5d" 2>$null
  git -C $repo fetch -q origin '+refs/heads/*:refs/remotes/origin/*'; git -C $repo branch -f p5d origin/p5d 2>$null
  $head5d = git -C $l5d.path rev-parse HEAD
  $o = LandFrom $l5d.path @('-Branch', 'p5d', '-Purpose', 'land p5d')
  $trees5d = @(GateTrees 'land pregate p5d')
  Check '5d pre-gate ran in the caller scratch slot, not in a second one' ($code -eq 0 -and (Remote 'p5d.txt') -eq 'p5d' -and $trees5d.Count -eq 1 -and "$($trees5d[0].root)" -eq "$($l5d.path)" -and @(Ev 'land-pregate-slot-released' 'p5d').Count -eq 0) (($trees5d | ConvertTo-Json -Compress) + ' || ' + $o)
  Check '5d ... and the queue did not gate again (the tree went into the green ledger)' (@(Gates '^land gate p5d').Count -eq 0 -and @(Ev 'land-gate-skipped-green').Count -ge 1) ((Gates 'p5d') -join ' | ')
  Check '5d ... and the scratch slot is back on its own commit, clean' ((git -C $l5d.path rev-parse HEAD) -eq $head5d -and -not (git -C $l5d.path status --porcelain))
  $null = AQ unlease -Repo $l5d.path -LeaseId $l5d.leaseId -Reason 'test 5d done'

  # 5e. a land launched from the SHARED CLONE ROOT while this session already holds a clean slot uses THAT
  #     slot for the pre-gate. In real life agents run `agentq land` from the clone root, never from inside
  #     their slot, so cwd containment finds nothing and the old code fell through to renting a fourth slot
  #     (three scratches permanently leased) -> skip -> the whole gate ran inside the cap-1 land mutex.
  Push-Location $repo
  try { $raw5e = AQ lease -Role scratch -Slot 'scratch-1' -Purpose 'this session holds a slot' -Ref origin/dev -Json } finally { Pop-Location }
  $l5e = $raw5e -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check '5e the fixture holds a scratch slot for this session' ([bool]$l5e.leaseId) ($raw5e -join ' ')
  git -C $l5e.path config core.autocrlf false
  Set-Content (Join-Path $l5e.path 'p5e.txt') 'p5e'; git -C $l5e.path add p5e.txt; git -C $l5e.path commit -qm 'topic p5e'
  git -C $l5e.path push -q origin "HEAD:refs/heads/p5e" 2>$null
  git -C $repo fetch -q origin '+refs/heads/*:refs/remotes/origin/*'; git -C $repo branch -f p5e origin/p5e 2>$null
  $head5e = git -C $l5e.path rev-parse HEAD
  $o = LandFrom $repo @('-Branch', 'p5e', '-Purpose', 'land p5e from the clone root')
  $trees5e = @(GateTrees 'land pregate p5e')
  Check '5e pre-gate ran in the slot this session holds, though the land came from the clone root' ($code -eq 0 -and (Remote 'p5e.txt') -eq 'p5e' -and $trees5e.Count -eq 1 -and "$($trees5e[0].root)" -eq "$($l5e.path)" -and @(Ev 'land-pregate-slot-released' 'p5e').Count -eq 0) (($trees5e | ConvertTo-Json -Compress) + ' || ' + $o)
  Check '5e ... the queue did not gate again (the tree went into the green ledger)' (@(Gates '^land gate p5e').Count -eq 0 -and @(Ev 'land-gate-skipped-green').Count -ge 1) ((Gates 'p5e') -join ' | ')
  Check '5e ... and the session''s own slot is back on its commit, clean' ((git -C $l5e.path rev-parse HEAD) -eq $head5e -and -not (git -C $l5e.path status --porcelain))
  $null = AQ unlease -Repo $l5e.path -LeaseId $l5e.leaseId -Reason 'test 5e done'

  # 6. a dirty CALLER slot is no longer a reason to skip the pre-gate: it rents the resettable scratch slot
  #    and gates the rebased result there (6b). It skips ONLY when no scratch can be had either - that is
  #    6, with the pool held full by the fixture. Measured 2026-11-23: 171 of the `land-pregate-skipped`
  #    lines in 48 h said "the slot has uncommitted or untracked files", each pushing a 5-40 min gate into
  #    the cap-1 land mutex.
  Cfg ",`"landPregateScratchWaitMin`":0"
  $hold6 = @(1..3 | ForEach-Object {
    Push-Location $repo
    try { $o = AQ lease -Role scratch -Slot "scratch-$_" -Purpose 'hold for 6' -Ref origin/dev -Json -Wait -MaxMin 0 } finally { Pop-Location }
    $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  })
  Check '6 the fixture holds all three scratch slots' (@($hold6 | Where-Object { $_.leaseId }).Count -eq 3) ($hold6 | ConvertTo-Json -Compress)
  $l6 = Slot 'p6'; Commit $l6 'p6.txt' 'p6' 'p6'
  Set-Content (Join-Path $l6.path 'scratch.txt') 'uncommitted'
  $o = LandFrom $l6.path @('-Branch', 'p6', '-Purpose', 'land p6')
  Check '6 dirty slot + no free scratch -> pre-gate skipped with the reason, gate in the queue, lands' ($code -eq 0 -and @(Ev 'land-pregate-skipped' 'p6')[0].reason -match 'uncommitted' -and @(Gates '^land gate p6').Count -eq 1 -and @(Gates 'land pregate p6').Count -eq 0) $o
  Check '6 the uncommitted file was not touched' ((Get-Content (Join-Path $l6.path 'scratch.txt')) -eq 'uncommitted')
  foreach ($l in $hold6) { $null = AQ unlease -Repo $l.path -LeaseId $l.leaseId -Reason 'test 6 done' }
  # 6b. a dirty CALLER slot with a FREE scratch: the pre-gate rents the scratch, gates the rebased result
  #     there, leaves the caller's tree untouched, releases the scratch, and the queue does not gate again.
  $l6b = Slot 'p6b'; Commit $l6b 'p6b.txt' 'p6b' 'p6b'
  Set-Content (Join-Path $l6b.path 'scratch.txt') 'uncommitted'
  $o = LandFrom $l6b.path @('-Branch', 'p6b', '-Purpose', 'land p6b')
  $t6b = @(GateTrees 'land pregate p6b')
  Check '6b dirty caller slot -> pre-gate runs in a rented scratch slot, not in the queue' ($code -eq 0 -and (Remote 'p6b.txt') -eq 'p6b' -and $t6b.Count -eq 1 -and "$($t6b[0].root)" -match 'scratch-\d+$' -and @(Ev 'land-pregate-skipped' 'p6b').Count -eq 0 -and @(Ev 'land-pregate-slot-released' 'p6b').Count -eq 1) ("$o || " + ($t6b | ConvertTo-Json -Compress))
  Check '6b the queue did not gate again (the tree went into the green ledger)' (@(Gates '^land gate p6b').Count -eq 0 -and @(Ev 'land-gate-skipped-green').Count -ge 1) ($o -join ' | ')
  Check '6b the caller''s uncommitted file was not touched and its slot is still on p6b' ((Get-Content (Join-Path $l6b.path 'scratch.txt')) -eq 'uncommitted' -and (git -C $l6b.path symbolic-ref --short HEAD) -eq 'p6b')
  Cfg
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

  # B1. a topic whose PRE-GATE failed is QUARANTINED (a per-repo negative ledger) and comes back as soon as
  #     a fresh explicit land passes its pre-gate. Without it, the topic was re-absorbed into the next
  #     holder's cap-1 batch on every turn (measured 2026-11-23: one red topic held land:<repo> 60+ min).
  $lq = Slot 'qb'; Commit $lq 'qb.txt' 'qb' 'qb'
  Set-Content (Join-Path $lq.path 'bad.txt') 'x'; git -C $lq.path add bad.txt; git -C $lq.path commit -qm 'topic qb bad'
  git -C $lq.path push -q origin qb 2>$null
  $o = LandFrom $lq.path @('-Branch', 'qb', '-Purpose', 'land qb')
  Check 'B1 a failed pre-gate quarantines the topic (negative ledger + journal)' ($code -eq 6 -and (QKeys) -contains 'qb' -and @(Ev 'land-pregate-quarantined' 'qb').Count -eq 1) ("$o || keys=" + ((QKeys) -join ','))
  # NB: `$(QMap['qb'].reason)` in a double-quoted string is parsed as a COMMAND (and `Stop` aborts the run),
  # so bind the entry to a variable first.
  $qE = (QMap)['qb']
  Check 'B1 ... the entry carries the tree and the failing gate command' ("$($qE.reason)" -match 'land:gate' -and "$($qE.tree)" -match '^[0-9a-f]{40}$' -and "$($qE.at)") ((QMap) | ConvertTo-Json -Compress)
  git -C $lq.path rm -q bad.txt; git -C $lq.path commit -qm 'fix qb'; git -C $lq.path push -q origin qb 2>$null; git -C $repo fetch -q origin
  $o = LandFrom $lq.path @('-Branch', 'qb', '-Purpose', 'land qb fixed')
  Check 'B1 a fresh passing pre-gate lands it and CLEARS the quarantine' ($code -eq 0 -and (Remote 'qb.txt') -eq 'qb' -and @(Ev 'land-quarantine-cleared' 'qb').Count -eq 1 -and -not ((QKeys) -contains 'qb')) ("$o || keys=" + ((QKeys) -join ','))
  # B1c. an entry older than landQuarantineHours is pruned on the next write (the TTL is read, not assumed)
  $qm = QMap; $qm['zzz'] = [ordered]@{ at = (Get-Date).ToUniversalTime().AddHours(-8).ToString('o'); tree = ('0' * 40); reason = 'stale entry' }
  ConvertTo-Json $qm -Depth 5 | Set-Content -LiteralPath (QFile)
  $lqc = Slot 'qc'; Commit $lqc 'qc.txt' 'qc' 'qc'
  Set-Content (Join-Path $lqc.path 'bad.txt') 'x'; git -C $lqc.path add bad.txt; git -C $lqc.path commit -qm 'topic qc bad'; git -C $lqc.path push -q origin qc 2>$null
  $o = LandFrom $lqc.path @('-Branch', 'qc', '-Purpose', 'land qc')
  Check 'B1c an entry older than landQuarantineHours (default 6) is pruned on the next write' ($code -eq 6 -and -not ((QKeys) -contains 'zzz') -and ((QKeys) -contains 'qc')) ("$o || keys=" + ((QKeys) -join ','))

  # B2. a quarantined topic is NOT absorbed into another holder's batch, and `agentq status` shows why.
  #     The land queue is cap 1, so the only way to have a quarantined WAITER in front of a new holder is a
  #     blocker parked inside its gate (the fake gate holds while FAKE_GATE_HOLD exists).
  git -C $repo fetch -q origin; git -C $repo checkout -q -B qq origin/dev
  Set-Content (Join-Path $repo 'bad.txt') 'x'; git -C $repo add bad.txt; git -C $repo commit -qm 'topic qq bad'; git -C $repo push -q origin qq 2>$null
  git -C $repo checkout -q dev
  $o = AsSession 'pgq' { LandFrom $repo @('-Branch', 'qq', '-Purpose', 'land qq') }
  Check 'B2 the topic the batch must skip is quarantined first' ($code -eq 6 -and ((QKeys) -contains 'qq')) ("$o || keys=" + ((QKeys) -join ','))
  foreach ($b in 'blocker2', 'wq') {
    git -C $repo checkout -q -B $b origin/dev
    Set-Content (Join-Path $repo "$b.txt") $b; git -C $repo add "$b.txt"; git -C $repo commit -qm "topic $b"; git -C $repo push -q origin $b 2>$null
    git -C $repo checkout -q dev
  }
  Cfg (",`"landBatch`":{`"$repoName`":true}")
  Remove-Item Env:AGENTQ_LAND_BATCH -ErrorAction SilentlyContinue
  $env:FAKE_GATE_HOLD = Join-Path $tmp 'hold'; [IO.File]::WriteAllText($env:FAKE_GATE_HOLD, '')
  $blk = Start-Land 'blocker2' 'sblk'
  Check 'B2 the blocker parks inside its gate and holds the cap-1 land queue' (WaitGates 'land gate blocker2') ((Gates '.') -join ' | ')
  $wq = Start-Land 'wq' 'swq'; $null = WaitJournal 'queued' 'swq'
  $qq = Start-Land 'qq' 'sqq'; $null = WaitJournal 'queued' 'sqq'
  Check 'B2 two lands wait behind it (one of them quarantined)' ((QueuedCount) -ge 2) "queued=$(QueuedCount)"
  $st = AQ status -All
  Check 'B2 agentq status shows the quarantined topic with the reason' ("$st" -match 'QUARANTINED' -and "$st" -match 'qq' -and "$st" -match 'pre-gate failed' -and "$st" -match 'LAND QUARANTINE') ((@("$st" -split "`n") | Where-Object { $_ -match 'QUARANTINED|LAND QUARANTINE|qq ' }) -join ' / ')
  Remove-Item -LiteralPath $env:FAKE_GATE_HOLD -ErrorAction SilentlyContinue
  Stop-Land 150
  Check 'B2 the green waiter landed while the quarantined topic was skipped' ((Remote 'wq.txt') -eq 'wq' -and (Remote 'blocker2.txt') -eq 'blocker2' -and "$(Remote 'bad.txt')" -eq '') ("blk=" + ((Get-Content -LiteralPath $blk.out -Raw -EA SilentlyContinue) -join '') + " || wq=" + ((Get-Content -LiteralPath $wq.out -Raw -EA SilentlyContinue) -join '') + " || qq=" + ((Get-Content -LiteralPath $qq.out -Raw -EA SilentlyContinue) -join ''))
  # NB: `"$(Ev 'x' 'y')[0].ticket"` interpolates the COMMAND result and appends the literal "[0].ticket", so it
  # was always truthy (a vacuous assertion) - bind the array first and index inside the subexpression.
  $qev = @(Ev 'land-topic-quarantined' 'qq')
  Check 'B2 the picker journaled land-topic-quarantined (and named the waiting ticket)' ($qev.Count -eq 1 -and "$($qev[0].ticket)") (Ev 'land-topic-quarantined' | ConvertTo-Json -Compress)
  Check 'B2 ... and the batch gated only its own topic (the quarantined one was not absorbed)' ((@(GateTrees 'land gate wq')[0].purpose) -notmatch 'qq') ((Gates 'land gate wq') -join ' | ')
  Check 'B2 ... and the quarantined topic gated on its own turn and failed' (@(Gates 'land gate qq').Count -ge 1) ((Gates '.') -join ' | ')
  Remove-Item Env:AGENTQ_LAND_NO_PREGATE -ErrorAction SilentlyContinue
  Cfg; $env:AGENTQ_LAND_BATCH = '0'

  # A. a scratch slot handed back DIRTY by its previous tenant is RESET before the gate judges it. The
  #    fixture reproduces the real mechanism: the repo's own lease-time prep step (codai has
  #    scripts/slot-prep.ps1, and Prepare-Slot runs it on every lease) leaves a file in the slot, so the
  #    lease that hands the slot to the pre-gate returns it dirty. 2026-11-23: 21 of one day's
  #    `land-pregate-skipped` lines said "the slot has uncommitted or untracked files", and every one of
  #    them pushed the whole ~21 min gate back INSIDE the cap-1 land mutex.
  $prepSrc = @'
param([Parameter(Mandatory)][string]$Worktree, [string]$Main)
# fixture stand-in for codai's scripts/slot-prep.ps1: a lease-time step that leaves the slot dirty.
if ((Split-Path $Worktree -Leaf) -notmatch '^scratch-') { exit 0 }
if ($env:FAKE_PREP_DIRT -eq 'nested') {
  # a nested repository: `git clean -fdq` refuses to delete it, so the slot stays dirty after a reset
  git init -q (Join-Path $Worktree 'sub-dirt')
  Set-Content (Join-Path $Worktree 'sub-dirt\b.txt') 'x'
} else { Set-Content (Join-Path $Worktree 'prep-artifact.txt') 'prep' }
exit 0
'@
  git -C $repo fetch -q origin; git -C $repo checkout -q -B dev origin/dev
  New-Item -ItemType Directory -Force (Join-Path $repo 'scripts') | Out-Null
  [IO.File]::WriteAllText((Join-Path $repo 'scripts\slot-prep.ps1'), $prepSrc)
  git -C $repo add scripts/slot-prep.ps1; git -C $repo commit -qm 'fixture slot-prep'; git -C $repo push -q origin dev 2>$null; git -C $repo fetch -q origin
  Remove-Item Env:AGENTQ_NO_PREP -ErrorAction SilentlyContinue
  git -C $repo checkout -q -B pA1 origin/dev
  Set-Content (Join-Path $repo 'pA1.txt') 'pA1'; git -C $repo add pA1.txt; git -C $repo commit -qm 'topic pA1'; git -C $repo push -q origin pA1 2>$null
  git -C $repo checkout -q dev
  $env:FAKE_PREP_DIRT = 'file'
  $o = AsSession 'pgA1' { LandFrom $repo @('-Branch', 'pA1', '-Purpose', 'land pA1') }
  $reset1 = @(Ev 'land-pregate-slot-reset' 'pA1'); $trees1 = @(GateTrees 'land pregate pA1')
  Check 'A a dirty scratch slot is reset to the target ref before the gate judges it' ($reset1.Count -eq 1 -and "$($reset1[0].reason)" -match 'dirty when leased; reset' -and $trees1.Count -eq 1 -and "$($trees1[0].root)" -match 'scratch-\d+$') ("$o || reset=" + (($reset1 | ConvertTo-Json -Compress)))
  Check 'A ... no generic skip, the gate runs, the topic lands' ($code -eq 0 -and (Remote 'pA1.txt') -eq 'pA1' -and @(Ev 'land-pregate-skipped' 'pA1').Count -eq 0 -and @(Gates '^land gate pA1').Count -eq 0) $o
  Check 'A ... and the slot it reset is clean when the gate sees it' ($trees1.Count -eq 1 -and -not @(git -C "$($trees1[0].root)" status --porcelain 2>$null | Where-Object { $_ })) ((git -C "$($trees1[0].root)" status --porcelain 2>$null) -join ' / ')
  git -C $repo checkout -q -B pA2 origin/dev
  Set-Content (Join-Path $repo 'pA2.txt') 'pA2'; git -C $repo add pA2.txt; git -C $repo commit -qm 'topic pA2'; git -C $repo push -q origin pA2 2>$null
  git -C $repo checkout -q dev
  $env:FAKE_PREP_DIRT = 'nested'
  $o = AsSession 'pgA2' { LandFrom $repo @('-Branch', 'pA2', '-Purpose', 'land pA2') }
  $reset2 = @(Ev 'land-pregate-slot-reset' 'pA2'); $skip2 = @(Ev 'land-pregate-skipped' 'pA2'); $rel2 = @(Ev 'land-pregate-slot-released' 'pA2')
  Check 'A a slot still dirty after the reset is given back with a PRECISE reason (not the generic one)' ($reset2.Count -eq 1 -and "$($reset2[0].reason)" -match 'left 1 dirty path' -and $skip2.Count -eq 1 -and "$($skip2[0].reason)" -match 'still dirty after a reset' -and $rel2.Count -eq 1 -and "$($rel2[0].reason)" -match 'still dirty') ("$o || reset=" + (($reset2 | ConvertTo-Json -Compress)) + ' || skip=' + (($skip2 | ConvertTo-Json -Compress)))
  Check 'A ... and that land still goes through, with the gate in the queue' ($code -eq 0 -and (Remote 'pA2.txt') -eq 'pA2' -and @(Gates 'land pregate pA2').Count -eq 0 -and @(Gates '^land gate pA2').Count -eq 1) $o
  foreach ($lf in @(Get-ChildItem -LiteralPath (Join-Path $env:AGENTQ_HOME "leases\$repoName") -Filter 'scratch-*.json' -File -ErrorAction SilentlyContinue)) {
    $lk = try { Get-Content -LiteralPath $lf.FullName -Raw | ConvertFrom-Json } catch { $null }
    if ($lk -and $lk.path -and $lk.leaseId) { $null = AQ unlease -Repo "$($lk.path)" -LeaseId "$($lk.leaseId)" -Force -Reason 'test A cleanup' }
  }
  Remove-Item Env:FAKE_PREP_DIRT -ErrorAction SilentlyContinue; $env:AGENTQ_NO_PREP = '1'

  # C. a land started from a DIFFERENT clone of the same repo (the `land` slot is one per repo NAME, owned
  #    by whichever clone created it) is refused EARLY, naming both clones, instead of dying inside
  #    Initialize-Slot after a ticket and a gate slot were set up.
  $other = Join-Path (Join-Path $tmp 'clone2') $repoName
  New-Item -ItemType Directory -Force (Split-Path -Parent $other) | Out-Null
  git clone -q $bare $other 2>$null; git -C $other config core.autocrlf false
  git -C $other checkout -q -B c1 origin/dev
  Set-Content (Join-Path $other 'c1.txt') 'c1'; git -C $other add c1.txt; git -C $other commit -qm 'topic c1'; git -C $other push -q origin c1 2>$null
  $nQ = @(Journal | Where-Object { $_.event -eq 'queued' -and "$($_.resource)" -eq "land:$repoName" }).Count
  $nG = @(Gates '.').Count
  $o = AsSession 'pgC' { LandFrom $other @('-Branch', 'c1', '-Purpose', 'land c1') }
  Check 'C a land from another clone of the same repo is REFUSED (exit 3, naming both clones)' ($code -eq 3 -and "$o" -match 'REFUSED' -and "$o" -match [regex]::Escape($repo) -and "$o" -match [regex]::Escape($other)) $o
  $wcev = @(Ev 'land-wrong-clone' 'dev')
  Check 'C ... journal land-wrong-clone names the resolved clone, the owner clone and the slot' ($wcev.Count -eq 1 -and "$($wcev[0].clone)" -match [regex]::Escape($other) -and "$($wcev[0].owner)" -match [regex]::Escape($repo)) (Ev 'land-wrong-clone' | ConvertTo-Json -Compress)
  Check 'C ... nothing was queued and no gate ran' (@(Journal | Where-Object { $_.event -eq 'queued' -and "$($_.resource)" -eq "land:$repoName" }).Count -eq $nQ -and @(Gates '.').Count -eq $nG) ("queued now=$(@(Journal | Where-Object { $_.event -eq 'queued' -and "$($_.resource)" -eq "land:$repoName" }).Count) was=$nQ ; gates now=$(@(Gates '.').Count) was=$nG")
} finally {
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_RUN_BUILD', 'FAKE_GATE_LOG', 'FAKE_GATE_TREE_LOG', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_FLAKES', 'AGENTQ_NO_POSTLAND', 'AGENTQ_LAND_BATCH', 'AGENTQ_LAND_NO_PREGATE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
