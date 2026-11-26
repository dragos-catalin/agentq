# D5 (owner 2026-11-23): a per-session cap on SLOT LEASES + reuse before renting - the slot-side twin of
# the queue's fair share (D4, ADR 0014). Symptom that motivated it: ONE VS Code window is ONE agentq
# session, so every terminal AND every subagent shares one session id; that session held 4 slots at once
# (scratch-1, task-1, task-2, scratch-2) while other windows starved on the pool. Two behaviours:
#   (1) REUSE BEFORE RENTING - a session that already holds a CLEAN slot of the requested role in this repo
#       gets that slot back (journal `slot-reuse`) instead of renting a second one. "Subagents work in the
#       lead's slot" (ADR 0012) is now automatic. A DIRTY slot (unsaved work, the same `git status
#       --porcelain` test the pre-gate uses) is NOT handed back.
#   (2) PER-SESSION SHARE - a session may hold at most `fairShare.slotsPerSession` slots when > 0, else a
#       DERIVED share of the machine task-slot cap (ceil(cap / competing sessions), floor 1). It applies
#       ONLY while another live session holds a slot, so a lone session keeps every slot (no regression).
#       Over the share: a bounded wait, then a refusal naming the session, the held slots, the share and
#       the two recipes (journal `slot-fair-share`).
# Part A pins the pure helpers (`Get-FairShare` + `Get-SlotShare`); part B drives the REAL lease path in an
# isolated %TEMP% fixture (AGENTQ_HOME / CODAI_WT_ROOT / AGENTQ_CONFIG), the same pattern as
# test-slot-budget.ps1 / test-agentq-fairshare.ps1.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqss-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'
$env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_AGENT_LIMIT = '1'; $env:AGENTQ_NO_PRUNE = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
Remove-Item Env:\AGENTQ_NO_FAIRSHARE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
# 2026-11-26: the config literals below set scratchMinFreeGB/minFreeCommitGB to 0 on purpose. This
# suite is isolated in %TEMP% but the pool still consults the REAL volume: with the shipped values
# (25 / 12) a machine under pressure caps the scratch pool at its floor of 3, so B7's last lease can
# never be granted and the suite waits forever for a slot nobody releases. Measured 2026-11-26 with
# C: at 8 GB free: `scratch-alloc-denied`, three runs stuck at ~0 CPU. A fixture pins the resource
# knobs it depends on - it never inherits them from whatever else the machine is doing.
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Set-Cfg([string]$json) { [IO.File]::WriteAllText($cfg, $json) }
function LFile([string]$slot) { Join-Path $env:AGENTQ_HOME "leases\repo\$slot.json" }
function Clear-Leases { Get-ChildItem (Join-Path $env:AGENTQ_HOME 'leases\repo') -Filter '*.json*' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
function Journal { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ }) }
function Ev([string]$name) { @(Journal | Where-Object { $_.event -eq $name }) }
function Reset-Journal { Remove-Item -LiteralPath (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- part A: the helpers in isolation
$src = Get-Content -LiteralPath $Aq -Raw
$blk = [regex]::Match($src, '(?s)function Get-FairShare \{.*?\r?\n\}').Value + "`n" +
       [regex]::Match($src, '(?s)function Get-SlotShare\(.*?\r?\n\}').Value
Check '0 the helpers are in agentq.ps1' ($blk -match 'function Get-FairShare' -and $blk -match 'function Get-SlotShare')
$cfgJson = '{}'
function Get-Config { $s = $cfgJson | ConvertFrom-Json -AsHashtable; if (-not $s) { $s = @{} }; $s }
function P($o, $k, $d = $null) {
  if ($null -eq $o) { return $d }
  if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($k) -and $null -ne $o[$k]) { return $o[$k] } ; return $d }
  if ($o.PSObject.Properties.Name -contains $k -and $null -ne $o.$k) { $o.$k } else { $d }
}
if ($blk) { Invoke-Expression $blk }
try {
  $fs = Get-FairShare
  Check 'A1 default: enabled, maxPerSession 0, slotsPerSession 0 (back-compat)' ($fs.enabled -eq $true -and $fs.maxPerSession -eq 0 -and $fs.slotsPerSession -eq 0) ($fs | ConvertTo-Json -Compress)
  $cfgJson = '{"fairShare":false}'
  Check 'A1a the shorthand false still turns it off (slotsPerSession is not a second switch)' ((Get-FairShare).enabled -eq $false -and (Get-FairShare).slotsPerSession -eq 0)
  $cfgJson = '{"fairShare":{"enabled":true,"maxPerSession":2}}'
  $fs = Get-FairShare
  Check 'A1b the existing shape (enabled+maxPerSession) is unchanged, slotsPerSession defaults to 0' ($fs.enabled -eq $true -and $fs.maxPerSession -eq 2 -and $fs.slotsPerSession -eq 0)
  $cfgJson = '{"fairShare":{"enabled":true,"slotsPerSession":3}}'
  $fs = Get-FairShare
  Check 'A2 slotsPerSession is read through the SAME Get-FairShare helper' ($fs.enabled -eq $true -and $fs.slotsPerSession -eq 3) ($fs | ConvertTo-Json -Compress)
  $cfgJson = '{}'
  $s = Get-SlotShare @(@{ session = 'A'; stale = $false }) 'A' 6
  Check 'A3 a lone session is never competing (never capped)' ($s.competing -eq $false -and $s.held -eq 1) ($s | ConvertTo-Json -Compress)
  $two = @(@{ session = 'A'; stale = $false }, @{ session = 'B'; stale = $false })
  $s = Get-SlotShare $two 'A' 6
  Check 'A4 two sessions: the share is ceil(cap / sessions)' ($s.competing -eq $true -and $s.share -eq 3 -and $s.held -eq 1) ($s | ConvertTo-Json -Compress)
  $s = Get-SlotShare @(@{ session = 'A'; stale = $false }, @{ session = 'A'; stale = $false }, @{ session = 'B'; stale = $false }) 'A' 6
  Check 'A5 the share follows the competing SESSION count, not the lease count' ($s.share -eq 3 -and $s.held -eq 2) ($s | ConvertTo-Json -Compress)
  $cfgJson = '{"fairShare":{"enabled":true,"slotsPerSession":1}}'
  $s = Get-SlotShare $two 'A' 12
  Check 'A6 slotsPerSession overrides the derived share' ($s.share -eq 1 -and $s.slotsPerSession -eq 1) ($s | ConvertTo-Json -Compress)
  $cfgJson = '{}'
  $s = Get-SlotShare @(@{ session = 'A'; stale = $false }, @{ session = 'B'; stale = $true }) 'A' 6
  Check 'A7 a stale lease is not a competitor (a dead chat does not cap me)' ($s.competing -eq $false) ($s | ConvertTo-Json -Compress)
  $s = Get-SlotShare $two 'A' 0
  Check 'A8 a zero/unknown task cap still floors the derived share at 1' ($s.share -eq 1) ($s | ConvertTo-Json -Compress)
  Check 'A9 the lease path and status both use the helper (one config shape, one store)' `
    ($src -match 'Get-SlotShare \(Read-Leases \$null\) \$Session' -and $src -match 'event = ''slot-reuse''' -and $src -match 'event = ''slot-fair-share''' -and $src -match 'SLOT SHARE')
} catch { Check 'A the helpers run' $false "$_" }

# ---------------------------------------------------------------- part B: end to end on the real lease path
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  $base = '{"taskSlotsPerRepo":12,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":true}}'

  # =============================== B1: a lone session is never capped
  Clear-Leases; Reset-Journal
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":2,"taskSlotsMachineFloor":0,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":true}}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'   # derived cap 1 - ONLY safe because a lone session is never capped
  $env:AGENTQ_SESSION = 'lone'
  foreach ($n in 1..3) { $null = AQ lease -Role scratch -Purpose "l$n" -Slot "scratch-$n" -Json }
  Check 'B1 a lone session is never capped: three slots granted' ((Test-Path (LFile 'scratch-1')) -and (Test-Path (LFile 'scratch-2')) -and (Test-Path (LFile 'scratch-3'))) "code=$($script:code)"
  Check 'B1 no slot-fair-share event for a lone session' (@(Ev 'slot-fair-share').Count -eq 0)

  # =============================== B2: reuse of a clean same-role slot
  Clear-Leases; Reset-Journal
  Set-Cfg $base
  Remove-Item Env:\AGENTQ_TEST_SLOT_BUDGET -ErrorAction SilentlyContinue
  $env:AGENTQ_SESSION = 'me'
  $o = AQ lease -Role scratch -Purpose 'lead work' -Json
  Check 'B2 the first scratch lease is granted' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-1'))) $o
  $slot1 = (Get-Content (LFile 'scratch-1') -Raw | ConvertFrom-Json).path
  git -C $slot1 checkout -q -- . 2>$null; git -C $slot1 clean -qfd 2>$null
  $o = AQ lease -Role scratch -Purpose 'a subagent asks too' -Json
  $reused = @(Ev 'slot-reuse')
  Check 'B2 a second lease of the same role REUSES the clean slot, it does not rent one' ($script:code -eq 0 -and $reused.Count -eq 1 -and -not (Test-Path (LFile 'scratch-2'))) $o
  Check 'B2 the reused answer names the slot this session already holds' ($o -match 'scratch-1') $o
  Check 'B2 the reuse is journaled with the session and the role' ($reused.Count -eq 1 -and $reused[0].session -eq 'me' -and $reused[0].role -eq 'scratch') ($reused[0] | ConvertTo-Json -Compress)

  # =============================== B3: a DIRTY slot is NOT reused
  Clear-Leases; Reset-Journal
  $env:AGENTQ_SESSION = 'me'
  $o = AQ lease -Role scratch -Purpose 'lead dirty' -Json
  Check 'B3 the first scratch lease is granted' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-1'))) $o
  $slot1 = (Get-Content (LFile 'scratch-1') -Raw | ConvertFrom-Json).path
  [IO.File]::WriteAllText((Join-Path $slot1 'unsaved.txt'), "wip`n")
  $o = AQ lease -Role scratch -Purpose 'needs a slot while the lead has unsaved work' -Json
  Check 'B3 a DIRTY same-role slot is NOT reused (a new slot is rented)' ($script:code -eq 0 -and @(Ev 'slot-reuse').Count -eq 0 -and (Test-Path (LFile 'scratch-2'))) $o

  # =============================== B4: derived share - a session at its share is REFUSED
  Clear-Leases; Reset-Journal
  # taskSlotsMachineFloor 0 -> floor+1 = 1; AGENTQ_TEST_SLOT_BUDGET '8,8' -> derived 0 -> cap 1 -> with
  # 2 competing sessions the derived share is ceil(1/2) = 1.
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":2,"taskSlotsMachineFloor":0,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":true}}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'mine-1' -Slot scratch-1 -Json
  Check 'B4 my session holds 1 scratch slot' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-1')))
  $env:AGENTQ_SESSION = 'other'
  $null = AQ lease -Role scratch -Purpose 'other-1' -Slot scratch-2 -Json
  Check 'B4 another session holds a slot (so we compete)' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-2')))
  $env:AGENTQ_SESSION = 'me'
  $o = AQ lease -Role scratch -Purpose 'mine-2' -Slot scratch-3 -Wait -MaxMin 0 -Json
  Check 'B4 a session at its share is REFUSED (exit 3), no slot taken' ($script:code -eq 3 -and -not (Test-Path (LFile 'scratch-3'))) $o
  $ev = @(Ev 'slot-fair-share')
  Check 'B4 the refusal is journaled ONCE with session/held/cap' ($ev.Count -eq 1 -and $ev[0].session -eq 'me' -and [int]$ev[0].held -ge 1 -and [int]$ev[0].cap -eq 1) ($ev[0] | ConvertTo-Json -Compress)
  Check 'B4 the message names my session, the held count, the share, the held purpose and BOTH recipes' ($o -match 'me' -and $o -match 'holds 1' -and $o -match 'share of 1' -and $o -match 'mine-1' -and $o -match 'agentq unlease' -and $o -match 'reuse') $o
  Check 'B4 no event is journaled for the OTHER session' (@($ev | Where-Object { $_.session -ne 'me' }).Count -eq 0)

  # =============================== B5: slotsPerSession > 0 is honoured (overrides the derived share)
  Clear-Leases; Reset-Journal
  # With plenty of room the derived share would be ceil(20/2) = 10; the PIN of 1 must refuse a 2nd slot.
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":20,"taskSlotsMachineFloor":2,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":true,"slotsPerSession":1}}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '1000,1000'
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'p1' -Slot scratch-1 -Json
  $env:AGENTQ_SESSION = 'other'
  $null = AQ lease -Role scratch -Purpose 'o1' -Slot scratch-2 -Json
  $env:AGENTQ_SESSION = 'me'
  $o = AQ lease -Role scratch -Purpose 'p2' -Slot scratch-3 -Wait -MaxMin 0 -Json
  Check 'B5 slotsPerSession=1 refuses a 2nd slot the derived share would have allowed' ($script:code -eq 3 -and -not (Test-Path (LFile 'scratch-3'))) $o
  $ev = @(Ev 'slot-fair-share')[-1]
  Check 'B5 the journal records the PINNED slotsPerSession, not the derived share' ([int]$ev.slotsPerSession -eq 1 -and [int]$ev.cap -eq 1) ($ev | ConvertTo-Json -Compress)

  # =============================== B6: the status SLOT SHARE line
  $env:AGENTQ_SESSION = 'me'
  $o = AQ status -All
  Check 'B6 status -All prints a SLOT SHARE line' ($script:code -eq 0 -and $o -match 'SLOT SHARE') "code=$($script:code) :: $o"

  # =============================== B7: fairShare disabled -> no reuse, no cap (old behaviour)
  Clear-Leases; Reset-Journal
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":2,"taskSlotsMachineFloor":0,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":false}}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'd1' -Slot scratch-1 -Json
  $env:AGENTQ_SESSION = 'other'
  $null = AQ lease -Role scratch -Purpose 'd2' -Slot scratch-2 -Json
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'd3' -Slot scratch-3 -Json
  Check 'B7 fairShare disabled: a 2nd slot of the same session is granted (no cap)' ((Test-Path (LFile 'scratch-3')) -and @(Ev 'slot-fair-share').Count -eq 0) "code=$($script:code)"
  $o = AQ lease -Role scratch -Purpose 'd4' -Wait -MaxMin 0 -Json
  Check 'B7 fairShare disabled: no reuse either (a new slot is rented)' (-not ($o -match 'reusing')) $o
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''
if ($fail) { Write-Host "FAILED $fail" -ForegroundColor Red; exit 1 }
Write-Host 'ALL PASS slot share (D5)'
exit 0
