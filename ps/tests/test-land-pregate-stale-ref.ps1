# A `land` pre-gate must judge the SAME commit the land will merge - never a stale topic ref.
#
# 2026-11-25 (round 7): `Invoke-LandPregate` fetched ONLY `origin/<onto>`, while `Invoke-Land` refreshes
# EVERY ref immediately before it resolves the topic (`& git -C $main fetch -q origin`). On any path that
# does not lease a slot, `Resolve-LandRef` could therefore answer with a remote-tracking TOPIC ref this clone
# had not refreshed since the branch was pushed, and the gate judged a tree 1737 commits behind origin/main.
# `gate:knip` is a ratchet against the baselines IN the tree, so it failed for reasons that had nothing to do
# with the slice - while the very same slice passed in the land slot, which had fetched everything and merged
# the real tip. The land was right, the verdict was noise, and the diagnosis cost real time.
#
# The leased-scratch path HID the defect: `Invoke-Lease` runs its own full `git fetch origin` (~L1085), so a
# slot rented FOR the gate was always current. The defect survived exactly on the paths that take a slot the
# session ALREADY holds - which is why this suite holds a slot itself instead of letting the land rent one.
#
# S1 (discriminating): a stale remote-tracking topic ref. The pre-gate must refresh it, gate the FRESH tree
#     and let the slice land. Before the change the gate judged the stale tree, the fake gate failed on
#     `bad.txt`, the topic was QUARANTINED and the land ended non-zero.
# S2 (invariant; passes before AND after): when the clone's own `remote.origin.fetch` cannot see the branch,
#     no full fetch can make the ref current - and the LAND then merges that same stale ref. The pre-gate must
#     agree with the land (judge the stale tip, fail) instead of inventing a verdict about a tree nobody
#     will merge.
# Isolated in %TEMP%; the gate is the fake-gate double (fails when the tree contains bad.txt).
param(
  [string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'),
  [string]$FakeGate = (Join-Path $PSScriptRoot 'fake-gate.ps1')
)
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
if (-not (Test-Path $FakeGate)) { throw "the fake gate is not there: $FakeGate" }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqpgs-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'
$env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_FLAKES = '1'; $env:AGENTQ_NO_POSTLAND = '1'; $env:AGENTQ_LAND_BATCH = '0'
$env:AGENTQ_SESSION = 'test-pgs'
$env:AGENTQ_RUN_BUILD = $FakeGate
$env:FAKE_GATE_LOG = Join-Path $tmp 'gates.log'
$env:FAKE_GATE_TREE_LOG = Join-Path $tmp 'gate-trees.log'
foreach ($v in 'FAKE_GATE_HOLD', 'AGENTQ_LAND_NO_PREGATE', 'AGENTQ_NO_GREEN') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Short([string]$s, [int]$n = 12) { if (-not $s) { return '' }; $s.Substring(0, [math]::Min($n, $s.Length)) }
function Norm([string]$p) { if (-not $p) { return '' }; $p.TrimEnd('\').ToLower() }
function Gates([string]$rx) { if (Test-Path $env:FAKE_GATE_LOG) { @(Get-Content $env:FAKE_GATE_LOG | Where-Object { $_ -match $rx }) } else { @() } }
function GateTrees([string]$rx) { if (Test-Path $env:FAKE_GATE_TREE_LOG) { @(Get-Content $env:FAKE_GATE_TREE_LOG | Where-Object { $_ -match $rx } | ForEach-Object { $p = $_ -split '\|'; [pscustomobject]@{ purpose = $p[0]; tree = $p[1]; root = $p[2] } }) } else { @() } }
function Journal { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }) }
function Ev([string]$name, [string]$branch) { @(Journal | Where-Object { $_.event -eq $name -and (-not $branch -or "$($_.PSObject.Properties['branch'].Value)" -eq $branch) }) }
function Remote([string]$f) { git -C $repo fetch -q origin 2>$null; (git -C $repo show "origin/dev:$f" 2>$null) -join '' }
function TreeOf([string]$rev) { "$(& git -C $repo rev-parse "$rev^{tree}" 2>$null)".Trim() }
function MergeTree([string]$a, [string]$b) { "$(& git -C $repo merge-tree --write-tree --no-messages $a $b 2>$null | Select-Object -First 1)".Trim() }
function LandFrom([string]$dir, [string]$branch) { Push-Location $dir; try { AQ @('land', '-Onto', 'dev', '-TimeoutMin', '5', '-Branch', $branch, '-Purpose', "land $branch") } finally { Pop-Location } }
# A slot this session holds from BEFORE the land. `Invoke-Lease` does a full `git fetch origin` (~L1085), so
# the slot has to be taken FIRST and the topic ref made stale AFTERWARDS - a topic ref that is stale while the
# land rents its own slot would be refreshed by that rental and the case would prove nothing.
function HoldSlot([string]$name) {
  Push-Location $repo
  try { $raw = AQ @('lease', '-Role', 'scratch', '-Slot', $name, '-Purpose', "hold $name for the stale-ref case", '-Ref', 'origin/dev', '-Json') } finally { Pop-Location }
  $l = ($raw -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1) | ConvertFrom-Json
  if (-not $l -or -not $l.path) { throw "$name got no lease (exit $code): $raw" }
  $l
}
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$repoName = Split-Path -Leaf $repo
$cfg = Join-Path $tmp 'cfg.json'
"{`"taskSlotsPerRepo`":15,`"taskSlotsMachine`":17,`"scratchSlotsMax`":3,`"minFreeCommitGB`":0,`"landPregateScratchWaitMin`":0,`"landGate`":{`"$repoName`":`"pnpm land:gate`"}}" | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
# A SEPARATE clone as the commit source: it owns its own refs, so a branch pushed from it never appears as
# `refs/heads/<branch>` in $repo (a worktree of $repo would share refs/heads and Resolve-LandRef would then
# answer with the local, fresh branch).
$src = Join-Path (Join-Path $tmp 'clone-src') $repoName
New-Item -ItemType Directory -Force (Split-Path -Parent $src) | Out-Null
git clone -q $bare $src 2>$null; git -C $src config core.autocrlf false
try {
  $slot = HoldSlot 'scratch-1'
  # ---- S1 ---------------------------------------------------------------------------------------------
  # A topic whose STALE tip carries bad.txt (the fake gate fails on a tree that contains it) and whose fresh
  # tip drops it. The land runs from the CLONE ROOT: the session already holds scratch-1, so the pre-gate
  # uses THAT slot and no lease (no full fetch) happens on the way.
  git -C $src checkout -q -B pS1 origin/dev
  Set-Content (Join-Path $src 'pS1.txt') 'pS1'
  Set-Content (Join-Path $src 'bad.txt') 'x'
  git -C $src add -A; git -C $src commit -qm 'topic pS1 (stale tip: bad.txt present)'; git -C $src push -q origin pS1 2>$null
  git -C $repo fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
  $stale = "$(git -C $repo rev-parse origin/pS1)".Trim()
  git -C $src rm -q bad.txt; Set-Content (Join-Path $src 'pS1-fixed.txt') 'yes'
  git -C $src add -A; git -C $src commit -qm 'fix pS1: drop bad.txt'; git -C $src push -q origin pS1 2>$null
  $fresh = "$(git -C $src rev-parse HEAD)".Trim()
  Check 'S1 the fixture made origin/pS1 stale in the main clone (and offers no local pS1)' ($stale -and $fresh -and $stale -ne $fresh -and -not (git -C $repo rev-parse --verify -q refs/heads/pS1 2>$null)) "stale=$(Short $stale) fresh=$(Short $fresh)"
  $o = LandFrom $repo 'pS1'
  $t1 = @(GateTrees 'land pregate pS1')
  Check 'S1 the pre-gate gates the FRESH tree, so the slice lands' ($code -eq 0 -and (Remote 'pS1-fixed.txt') -eq 'yes' -and (Remote 'bad.txt') -eq '') ("exit=$code || $o || stale=" + (Short $stale) + " fresh=" + (Short $fresh))
  Check 'S1 ... a pre-gate DID run, in the slot this session holds (no rental, so nothing refreshed the ref for it)' ($t1.Count -eq 1 -and (Norm "$($t1[0].root)") -eq (Norm "$($slot.path)")) (((($t1 | ConvertTo-Json -Compress) + ' || want ' + $slot.path)))
  Check 'S1 ... the gated tree is exactly the tree that landed' ($t1.Count -eq 1 -and "$($t1[0].tree)" -eq (TreeOf 'origin/dev')) ("gated=$($t1[0].tree) landed=" + (TreeOf 'origin/dev'))
  Check 'S1 ... and the queue did not have to gate again (the tree went into the green ledger)' (@(Gates '^land gate pS1').Count -eq 0 -and @(Ev 'land-gate-skipped-green').Count -ge 1) (((Gates 'pS1') -join ' | '))
  Check 'S1 ... no misleading failure: nothing quarantined, no pre-gate failure journaled' (@(Ev 'land-pregate-failed' 'pS1').Count -eq 0 -and @(Ev 'land-pregate-quarantined' 'pS1').Count -eq 0) ((Ev 'land-pregate-failed' 'pS1' | ConvertTo-Json -Compress))
  # ---- S2 ---------------------------------------------------------------------------------------------
  # The clone's own refspec covers only dev, so NO fetch can make origin/pS2 current - and the land resolves
  # the same stale ref. Pre-gate and land must agree: both judge the stale tip.
  git -C $src checkout -q -B pS2 origin/dev
  Set-Content (Join-Path $src 'pS2.txt') 'pS2'; Set-Content (Join-Path $src 'bad.txt') 'x'
  git -C $src add -A; git -C $src commit -qm 'topic pS2 (stale tip)'; git -C $src push -q origin pS2 2>$null
  # the ref AND its object first (an explicit refspec ignores the configured one), so the local ref exists
  # and then CANNOT be moved again: from here on every fetch obeys the narrowed refspec below.
  git -C $repo fetch -q origin 'refs/heads/pS2:refs/remotes/origin/pS2'
  $stale2 = "$(git -C $repo rev-parse origin/pS2)".Trim()
  git -C $repo config remote.origin.fetch '+refs/heads/dev:refs/remotes/origin/dev'
  Set-Content (Join-Path $src 'pS2-fixed.txt') 'yes'; git -C $src rm -q bad.txt
  git -C $src add -A; git -C $src commit -qm 'fix pS2: drop bad.txt'; git -C $src push -q origin pS2 2>$null
  $staleTree = MergeTree 'origin/dev' $stale2
  $o = LandFrom $repo 'pS2'
  $t2 = @(GateTrees 'land pregate pS2')
  Check 'S2 a ref this clone cannot refresh: the pre-gate judges the SAME stale tip the land merges' ($code -ne 0 -and $t2.Count -eq 1 -and "$($t2[0].tree)" -eq $staleTree -and @(Ev 'land-pregate-failed' 'pS2').Count -eq 1) ("exit=$code gated=$($t2[0].tree) staleTree=$staleTree || " + (($t2 | ConvertTo-Json -Compress)))
  Check 'S2 ... and it says so with the topic quarantined, not landed' (@(Ev 'land-pregate-quarantined' 'pS2').Count -eq 1 -and "$o".Length -gt 0 -and (Remote 'pS2-fixed.txt') -eq '') ("exit=$code || $o")
} finally {
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_RUN_BUILD', 'FAKE_GATE_LOG', 'FAKE_GATE_TREE_LOG', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_FLAKES', 'AGENTQ_NO_POSTLAND', 'AGENTQ_LAND_BATCH', 'AGENTQ_LAND_NO_PREGATE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
