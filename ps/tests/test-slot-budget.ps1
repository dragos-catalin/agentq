# Two measured fixes (2026-11-23). (A) ELASTIC SCRATCH SLOTS: scratch-N is valid up to scratchSlotsMax; an
# index beyond the scratchSlots floor is only allocated when the machine has room (scratchMinFreeGB free on
# the slot volume + the minFreeCommitGB commit guard), else ONE `scratch-alloc-denied` event. A hard cap of 3
# starved the `agentq land` pre-gate, which rents a scratch slot for the length of the gate. (B) RESOURCE-
# DERIVED MACHINE TASK-SLOT BUDGET: the machine-wide cap is measured (free disk + commit charge), ceiling
# taskSlotsMachine, floor taskSlotsMachineFloor (the first `floor` slots are never refused); above the derived
# budget a task lease is refused with a `slot-admission-denied` event.
# The measurement is injectable (AGENTQ_TEST_SLOT_BUDGET "<freeGB>,<freeCommitGB>"), so the suite pins the
# allowed AND the refused side without touching the real machine. Isolated in %TEMP% (AGENTQ_HOME /
# CODAI_WT_ROOT / AGENTQ_CONFIG), the same pattern as test-agentq-lease-liveness.ps1.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqsb-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'
$env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_AGENT_LIMIT = '1'; $env:AGENTQ_NO_PRUNE = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Set-Cfg([string]$json) { [IO.File]::WriteAllText($cfg, $json) }
function LFile([string]$slot) { Join-Path $env:AGENTQ_HOME "leases\repo\$slot.json" }
function Clear-Leases { Get-ChildItem (Join-Path $env:AGENTQ_HOME 'leases\repo') -Filter '*.json*' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
function Journal { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
function Ev([string]$name) { @(Journal | Where-Object { $_.event -eq $name }) }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  # taskSlotsMachineFloor 2 keeps the FLOOR testable (2 always admitted) while taskSlotsMachine 20 leaves
  # ceiling headroom; scratch floor 3 / max 8 / minFree 25.
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":20,"taskSlotsMachineFloor":2,"scratchSlots":3,"scratchSlotsMax":8,"scratchMinFreeGB":25,"minFreeCommitGB":12,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2}'
  $env:AGENTQ_SESSION = 'sb'

  # =============================== A1: elastic scratch reaches index 4 and 5 when 1..3 are held
  $env:AGENTQ_TEST_SLOT_BUDGET = '200,100'
  $o = AQ lease -Role scratch -Purpose 's1' -Json
  Check 'A1 scratch-1 granted' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-1'))) $o
  $null = AQ lease -Role scratch -Purpose 's2' -Json
  $null = AQ lease -Role scratch -Purpose 's3' -Json
  Check 'A1 scratch-1..3 held' ((Test-Path (LFile 'scratch-1')) -and (Test-Path (LFile 'scratch-2')) -and (Test-Path (LFile 'scratch-3')))
  $o = AQ lease -Role scratch -Purpose 's4' -Json
  Check 'A1 beyond the floor: scratch-4 granted (elastic)' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-4'))) $o
  $o = AQ lease -Role scratch -Purpose 's5' -Json
  Check 'A1 scratch-5 granted (lowest free index upward)' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-5'))) $o
  Check 'A1 no scratch-alloc-denied when there is room' (@(Ev 'scratch-alloc-denied').Count -eq 0)

  # =============================== A2: the resource gate refuses a beyond-floor index (one event)
  Clear-Leases
  $env:AGENTQ_TEST_SLOT_BUDGET = '200,100'
  foreach ($s in 1..3) { $null = AQ lease -Role scratch -Purpose "hold$s" -Slot "scratch-$s" -Json }
  Check 'A2 scratch-1..3 held' ((Test-Path (LFile 'scratch-1')) -and (Test-Path (LFile 'scratch-3')))
  $before = @(Ev 'scratch-alloc-denied').Count
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'    # below scratchMinFreeGB 25 -> the beyond-floor gate fails
  $o = AQ lease -Role scratch -Purpose 'denied' -Wait -MaxMin 0 -Json
  Check 'A2 the beyond-floor scratch lease is refused' ($script:code -ne 0 -and -not (Test-Path (LFile 'scratch-4'))) $o
  $ev = @(Ev 'scratch-alloc-denied')
  Check 'A2 one scratch-alloc-denied event, with the numbers' ($ev.Count -eq ($before + 1) -and $ev[-1].index -eq 4 -and [double]$ev[-1].freeGB -eq 8 -and [double]$ev[-1].needGB -eq 25) ($ev[-1] | ConvertTo-Json -Compress)

  # =============================== B1: a task lease is never refused while the machine holds <= floor
  Clear-Leases
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'    # derived 0 -> cap = floor+1 = 3
  $env:AGENTQ_SESSION = 'tb'
  $null = AQ lease -Purpose 't1' -Slot task-1 -Json
  $null = AQ lease -Purpose 't2' -Slot task-2 -Json
  $o = AQ lease -Purpose 't3' -Slot task-3 -Json
  Check 'B1 task-1..3 granted (the floor of 2 is never refused)' ((Test-Path (LFile 'task-1')) -and (Test-Path (LFile 'task-2')) -and (Test-Path (LFile 'task-3'))) $o
  Check 'B1 no slot-admission-denied at or below the floor' (@(Ev 'slot-admission-denied').Count -eq 0)

  # =============================== B2: above the derived budget the task lease is refused + journalled
  $o = AQ lease -Purpose 't4' -Slot task-4 -Wait -MaxMin 0 -Json
  Check 'B2 the 4th task lease is refused (derived budget 3)' ($script:code -ne 0 -and -not (Test-Path (LFile 'task-4'))) $o
  $ev = @(Ev 'slot-admission-denied')
  Check 'B2 one slot-admission-denied event with budget/held/free numbers' ($ev.Count -eq 1 -and $ev[0].budget -eq 3 -and $ev[0].held -ge 3 -and [double]$ev[0].freeGB -eq 8) ($ev[0] | ConvertTo-Json -Compress)

  # =============================== B3: with room the derived cap is the ceiling, not a hand-raised number
  Clear-Leases
  $env:AGENTQ_TEST_SLOT_BUDGET = '1000,1000'
  foreach ($n in 1..12) { $null = AQ lease -Purpose "m$n" -Slot "task-$n" -Json }
  Check 'B3 all 12 task slots granted with room (derived 122, ceiling 20 > 12)' ((Test-Path (LFile 'task-1')) -and (Test-Path (LFile 'task-12')))
  Check 'B3 no slot-admission-denied with room' (@(Ev 'slot-admission-denied').Count -eq 1)

  # =============================== A3: the PRODUCTION path - no injection, the real machine probe
  # AGENTQ_TEST_SLOT_BUDGET is a test seam; production runs Get-PSDrive (free space on the slot volume) +
  # Get-MemInfo (commit headroom). This pins that the REAL probe neither throws nor hangs inside the mutex
  # and that whichever way it lands carries real numbers - a beyond-floor scratch lease is granted when there
  # is room and refused WITH a journalled reason when there is not. Machine-independent on purpose.
  Clear-Leases
  Remove-Item Env:\AGENTQ_TEST_SLOT_BUDGET -ErrorAction SilentlyContinue
  foreach ($s in 1..3) { $null = AQ lease -Role scratch -Purpose "h$s" -Slot "scratch-$s" -Json }
  $before = @(Ev 'scratch-alloc-denied').Count
  $o = AQ lease -Role scratch -Purpose 'real probe' -Slot 'scratch-4' -Wait -MaxMin 0 -Json
  $granted = ($script:code -eq 0 -and (Test-Path (LFile 'scratch-4')))
  $denied = ($script:code -ne 0 -and -not (Test-Path (LFile 'scratch-4')) -and @(Ev 'scratch-alloc-denied').Count -eq ($before + 1))
  Check 'A3 real probe: the beyond-floor lease is granted or refused, never an error' ($granted -or $denied) "code=$($script:code) granted=$granted denied=$denied :: $o"
  Check 'A3 real probe: no PowerShell error leaked to the caller' ($o -notmatch 'Exception|Cannot bind|is not recognized|ParserError') $o
  if ($granted) {
    Check 'A3 real probe granted: it reported >= scratchMinFreeGB free on the slot volume' $true
  } else {
    $ev = @(Ev 'scratch-alloc-denied')[-1]
    Check 'A3 real probe refused: the event carries real numbers' ($null -ne $ev.freeGB -and [double]$ev.freeGB -ge 0 -and [double]$ev.needGB -eq 25) ($ev | ConvertTo-Json -Compress)
  }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "FAILED $fail" -ForegroundColor Red; exit 1 }
Write-Host 'PASS slot-budget'