# ADR 0012 (2026-11-19): LIVENESS IS WORK IN THE SLOT. Read-Leases takes $beat = the newest of
#   <lease>.json.hb   - an agentq call for the lease's repo/session, or `agentq renew`;
#   <lease>.json.work - touched ONLY by a tool call that NAMES the slot (hooks/guard-tooluse.ps1);
#   the slot's git activity (index/HEAD/logs/HEAD), ignoring the first 2 min after creation.
# With $idle = now - $beat (minutes): role land -> 3; scratch -> leaseScratchIdleMin (15); owner pid alive
# -> leaseOwnerIdleMin (90); else leaseIdleMin (45). A bound <lease>.json.chat younger than
# leaseChatGraceMin (20) counts as a grace (0 for scratch). holdUntil suppresses staleness. This suite
# drives each of those levers over real files, with an isolated AGENTQ_HOME / CODAI_WT_ROOT / config.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqlv-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
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
# stdout only: `who -Json` writes its JSON to stdout, notices go to stderr.
function AQJson { $o = @(& pwsh -NoProfile -File $Aq @args 2>$null | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; ($o -join "`n") }
function Set-Cfg([string]$json) { [IO.File]::WriteAllText($cfg, $json) }
function LFile([string]$slot) { Join-Path $env:AGENTQ_HOME "leases\repo\$slot.json" }
function Clear-Leases { Get-ChildItem (Join-Path $env:AGENTQ_HOME 'leases\repo') -Filter '*.json*' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
function Leases { $env:AGENTQ_SESSION = 'observer'; @((AQJson who -Json | ConvertFrom-Json).leases) }
function L([string]$slot) { @(Leases | Where-Object { $_.slot -eq $slot }) | Select-Object -First 1 }
# Set the three liveness clocks (minutes ago): heartbeat, slot git activity, the .work clock. $workMin
# $null deletes .work (nobody every touched the slot).
function Set-Times([string]$slot, [int]$hbMin, [int]$gitMin, $workMin) {
  $lf = LFile $slot
  [IO.File]::SetLastWriteTimeUtc("$lf.hb", [DateTime]::UtcNow.AddMinutes(-$hbMin))
  if ($null -ne $workMin) { if (-not (Test-Path "$lf.work")) { [IO.File]::WriteAllText("$lf.work", 't') }; [IO.File]::SetLastWriteTimeUtc("$lf.work", [DateTime]::UtcNow.AddMinutes(-$workMin)) }
  elseif (Test-Path "$lf.work") { Remove-Item "$lf.work" -Force }
  $l = Get-Content $lf -Raw | ConvertFrom-Json
  $maxMin = [int](@($hbMin, [int]$(if ($null -ne $workMin) { $workMin } else { 0 }), $gitMin) | Measure-Object -Maximum).Maximum
  $l.created = [DateTime]::UtcNow.AddMinutes(-($maxMin + 10)).ToString('o')
  [IO.File]::WriteAllText($lf, ($l | ConvertTo-Json -Compress))
  # the slot's git activity (Get-SlotGitActivity reads index / HEAD / logs\HEAD), only counted when it is
  # newer than created + 2 min, which the back-dated created above guarantees.
  $gd = ((Get-Content (Join-Path $l.path '.git') -Raw) -replace '^gitdir:\s*', '').Trim()
  foreach ($n in 'index', 'HEAD', 'logs\HEAD') { $p = Join-Path $gd $n; if (Test-Path $p) { [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddMinutes(-$gitMin)) } }
}
# Owner pid alive with a matching start time (ladder top tier) resp. alive pid but a wrong start time
# (Test-Alive compares both, so this is a dead owner without depending on any pid being free).
function Set-Owner([string]$slot, [bool]$live) {
  $lf = LFile $slot; $l = Get-Content $lf -Raw | ConvertFrom-Json
  $l.pid = $PID
  $l.procStart = if ($live) { (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o') } else { [DateTime]::UtcNow.AddYears(5).ToString('o') }
  [IO.File]::WriteAllText($lf, ($l | ConvertTo-Json -Compress))
}
function Set-Chat([string]$slot, $min) {
  $lf = LFile $slot
  if ($null -eq $min) { Remove-Item "$lf.chat" -Force -ErrorAction SilentlyContinue; return }
  [IO.File]::WriteAllText("$lf.chat", '{"leaseId":"x","chats":["c"]}')
  [IO.File]::SetLastWriteTimeUtc("$lf.chat", [DateTime]::UtcNow.AddMinutes(-$min))
}
function Clear-Hold([string]$slot) {
  $lf = LFile $slot; $l = Get-Content $lf -Raw | ConvertFrom-Json
  $l.PSObject.Properties.Remove('holdUntil')
  [IO.File]::WriteAllText($lf, ($l | ConvertTo-Json -Compress))
}

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  # =============================== work clock: .work, not .hb/git, is the primary beat
  # leaseDirtyIdleMin 100: unchanged-work protection (2026-11-22) keeps a slot holding unsaved work up to
  # that idle window. This block is about the .work clock on a DIRTY slot (the file is written below on
  # purpose, to prove the backup-on-expiry), so the window must be SHORTER than the 3 h set below.
  Set-Cfg '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseDirtyIdleMin":100,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'wc'
  $o = AQ lease -Purpose 'work clock'
  Check 'work: lease granted' ($script:code -eq 0 -and (Test-Path (LFile 'task-1'))) $o
  Set-Owner 'task-1' $false
  $slotPath = (Get-Content (LFile 'task-1') -Raw | ConvertFrom-Json).path
  'dirty' | Set-Content (Join-Path $slotPath 'dirty.txt')
  Set-Times 'task-1' 180 180 0   # .hb + git 3 h old, .work NOW -> the slot is being worked in
  $l = L 'task-1'
  Check 'work: .work now, .hb/git 3 h old -> NOT stale' ($l -and -not $l.stale) ($l | ConvertTo-Json -Compress)
  Check 'work: idleMin reports the .work clock (0)' ($l.idleMin -lt 2) "idle=$($l.idleMin)"
  Set-Times 'task-1' 180 180 $null   # delete .work -> nothing has touched the slot for 3 h
  $l = L 'task-1'
  Check 'work: .work gone too -> stale' ($l -and $l.stale) ($l | ConvertTo-Json -Compress)
  $o = AQ sweep
  Check 'work: sweep expired it' ($o -match 'expired repo/task-1' -and -not (Test-Path (LFile 'task-1'))) $o
  $refs = @(& git -C $repo ls-remote origin 'refs/backup/wt/repo/task-1/*' 2>$null | Where-Object { $_ })
  Check 'work: the dirty slot was backed up to a ref before expiry' ($refs.Count -ge 1) ($refs -join '; ')

  # =============================== owner-alive ladder: 90 min tier for a live owner, 45 for a dead one
  Clear-Leases
  Set-Cfg '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'ladder'
  $null = AQ lease -Purpose 'ladder'
  Set-Owner 'task-1' $true
  Set-Times 'task-1' 60 60 60
  $l = L 'task-1'
  Check 'ladder: live owner, slot idle 60 (< 90) -> NOT stale' ($l -and $l.alive -and -not $l.stale) ($l | ConvertTo-Json -Compress)
  Set-Times 'task-1' 120 120 120
  $l = L 'task-1'
  Check 'ladder: live owner, slot idle 120 (> 90) -> stale' ($l -and $l.alive -and $l.stale) ($l | ConvertTo-Json -Compress)
  Set-Owner 'task-1' $false
  Set-Times 'task-1' 60 60 60
  $l = L 'task-1'
  Check 'ladder: DEAD owner, slot idle 60 (> 45) -> stale' ($l -and -not $l.alive -and $l.stale) ($l | ConvertTo-Json -Compress)

  # =============================== chat grace: a fresh chat protects, an old one does not
  Clear-Leases
  Set-Cfg '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":20,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'grace'
  $null = AQ lease -Purpose 'chat grace'
  Set-Owner 'task-1' $false
  Set-Times 'task-1' 30 30 30
  Set-Chat 'task-1' 10            # chat younger than the 20 min grace
  $l = L 'task-1'
  Check 'grace: idle 30 with a 10-min chat (< 20) -> NOT stale' ($l -and -not $l.stale -and $l.chatIdleMin -lt 11) ($l | ConvertTo-Json -Compress)
  Set-Chat 'task-1' 30            # chat older than the grace
  $l = L 'task-1'
  Check 'grace: idle 30 with a 30-min chat (> 20) -> stale' ($l -and $l.stale) ($l | ConvertTo-Json -Compress)
  Set-Chat 'task-1' 10
  Set-Cfg '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":20,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":0,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $l = L 'task-1'
  Check 'grace: grace 0 (scratch-style) -> a fresh chat does not protect' ($l -and $l.stale) ($l | ConvertTo-Json -Compress)

  # =============================== scratch: own pool, not counted against the task caps
  Clear-Leases
  Set-Cfg '{"taskSlotsPerRepo":1,"taskSlotsMachine":1,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'scratch'
  $null = AQ lease -Purpose 'the one task slot'
  $o = AQ lease -Role scratch -Purpose 'scratch while the task cap is full'
  Check 'scratch: granted while taskSlotsPerRepo/taskSlotsMachine are full' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-1'))) $o
  $ls = Leases
  Check 'scratch: role scratch, NOT a task (task caps count only task)' ((@($ls | Where-Object { $_.slot -eq 'scratch-1' })[0].role) -eq 'scratch' -and @($ls | Where-Object { $_.role -eq 'task' }).Count -eq 1) ($ls | ConvertTo-Json -Compress)
  Set-Owner 'task-1' $false; Set-Owner 'scratch-1' $false
  Set-Times 'task-1' 20 20 20; Set-Times 'scratch-1' 20 20 20
  Check 'scratch: idle 20 (> 15) -> stale' ((L 'scratch-1').stale)
  Check 'scratch: a task idle 20 (< 45) is NOT stale' (-not (L 'task-1').stale)

  # =============================== second task lease: refused unless -Slot is named
  Clear-Leases
  Set-Cfg '{"taskSlotsPerRepo":2,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'one-session'
  $null = AQ lease -Purpose 'first'
  Set-Owner 'task-1' $true; Set-Times 'task-1' 0 0 0   # keep it live so the guard sees a live task lease
  $o = AQ lease -Purpose 'second, same session'
  Check 'second: refused (exit 3) with a live task lease in this session' ($script:code -eq 3) "exit=$code :: $o"
  Check 'second: the message points at scratch' ($o -match 'scratch') $o
  $o = AQ lease -Slot task-2 -Purpose 'second, named on purpose'
  Check 'second: -Slot task-2 grants it (the deliberate override)' ($script:code -eq 0 -and (Test-Path (LFile 'task-2'))) $o

  # =============================== -Hold: suppresses staleness until its bound passes
  Clear-Leases
  Set-Cfg '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'hold'
  $o = AQ lease -Purpose 'long job outside the slot' -Hold -HoldMin 60
  Check 'hold: lease granted with -Hold' ($script:code -eq 0 -and (Test-Path (LFile 'task-1'))) $o
  Set-Owner 'task-1' $false
  Set-Times 'task-1' 180 180 180   # every clock 3 h old, well past the 45-min threshold
  $l = L 'task-1'
  Check 'hold: holdUntil in the future -> NOT stale at idle 180' ($l -and -not $l.stale) ($l | ConvertTo-Json -Compress)
  Clear-Hold 'task-1'
  Set-Times 'task-1' 180 180 180
  $l = L 'task-1'
  Check 'hold: holdUntil removed -> stale at idle 180' ($l -and $l.stale) ($l | ConvertTo-Json -Compress)

  # =============================== who: one line per lease, and -Json has the documented fields
  Clear-Leases
  Set-Cfg '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'who-A'; $null = AQ lease -Slot task-1 -Purpose 'who one'
  $env:AGENTQ_SESSION = 'who-B'; $null = AQ lease -Slot task-2 -Purpose 'who two'
  $env:AGENTQ_SESSION = 'observer'
  $who = AQ who
  $lines = @($who -split "`r?`n" | Where-Object { $_ -match '^repo\s' })
  Check 'who: one line per lease (2)' ($lines.Count -eq 2) $who
  # the plain table keeps repo and slot as separate columns (repo/slot is the -Json/status form, not this)
  Check 'who: reports the total and both slots' ($who -match 'total 2 lease' -and $who -match 'task-1' -and $who -match 'task-2' -and $who -match 'who-A' -and $who -match 'who-B') $who
  $wj = AQJson who -Json | ConvertFrom-Json
  $row = @($wj.leases | Where-Object { $_.slot -eq 'task-1' })[0]
  $need = 'repo', 'slot', 'role', 'session', 'idleMin', 'chatIdleMin', 'alive', 'stale', 'why', 'purpose', 'path'
  $missing = @($need | Where-Object { -not $row.PSObject.Properties.Name.Contains($_) })
  Check 'who -Json: every documented field present, values sane' ($missing.Count -eq 0 -and $row.repo -eq 'repo' -and $row.role -eq 'task' -and $row.session -eq 'who-A' -and $row.purpose.Contains('who one') -and $row.path) "missing=$($missing -join ',')"

  # =============================== ADR 0012 refinements (ideas 1/3/4/5/8)
  $env:AGENTQ_SESSION = 'observer'
  Check 'why (idea 4): who -Json row carries why' ($row.PSObject.Properties.Name -contains 'why' -and "$($row.why)") ($row | ConvertTo-Json -Compress)
  # filters (idea 5)
  Set-Owner 'task-1' $false; Set-Times 'task-1' 600 600 600
  $so = @((AQJson who -Json -StaleOnly | ConvertFrom-Json).leases)
  Check 'who -StaleOnly: only the stale lease' ($so.Count -eq 1 -and $so[0].slot -eq 'task-1') ($so | ConvertTo-Json -Compress)
  $dh = @((AQJson who -Json -IdleHours 1 | ConvertFrom-Json).leases)
  Check 'who -IdleHours 1: only leases idle >= 60 min' ($dh.Count -eq 1 -and $dh[0].slot -eq 'task-1') ($dh | ConvertTo-Json -Compress)
  $dh0 = @((AQJson who -Json -IdleHours 100 | ConvertFrom-Json).leases)
  Check 'who -IdleHours 100: none match' ($dh0.Count -eq 0) ($dh0 | ConvertTo-Json -Compress)

  # sweep journals an auditable lease-kept line for a slot a chat grace keeps (idea 3)
  Clear-Leases
  Set-Cfg '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'kept'
  $null = AQ lease -Purpose 'kept by a chat grace'
  Set-Owner 'task-1' $false; Set-Times 'task-1' 60 60 60; Set-Chat 'task-1' 5
  $null = AQ sweep
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'lease-kept' } | Select-Object -Last 1)
  Check 'sweep journals lease-kept (idle/threshold/chat/why) for a grace-held slot' ($j.Count -eq 1 -and $j.idleMin -ge 59 -and $j.thresholdMin -eq 45 -and $j.why -eq 'chat grace') ($j | ConvertTo-Json -Compress)

  # leaseMaxIdleMin default is 6 h (idea 2): without the key, idle 310 is not stale but idle 400 is
  Clear-Leases
  Set-Cfg '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'cap'
  $null = AQ lease -Purpose 'cap'
  Set-Owner 'task-1' $false; Set-Times 'task-1' 310 310 310; Set-Chat 'task-1' 1
  Check 'cap: idle 310 with a fresh chat is NOT stale (< default 360)' (-not (L 'task-1').stale) ((L 'task-1') | ConvertTo-Json -Compress)
  Set-Times 'task-1' 400 400 400; Set-Chat 'task-1' 1
  Check 'cap: idle 400 with a fresh chat IS stale (>= default 360)' ((L 'task-1').stale) ((L 'task-1') | ConvertTo-Json -Compress)

  # lease -Reclaim (idea 8): take a grace-held slot from another session, with a reason
  Clear-Leases
  Set-Cfg '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}'
  $env:AGENTQ_SESSION = 'holder'
  $null = AQ lease -Purpose 'diagonal holder'
  $holdId = (Get-Content (LFile 'task-1') -Raw | ConvertFrom-Json).leaseId
  # the refusal check FIRST and as the CLAIMANT: a `lease` call renews the caller's own lease, so ageing the
  # holder's slot and then calling as the holder would reset its idle to 0 and make it non-reclaimable.
  # -NoWait on both calls: a reclaim grants within the call; if it ever does NOT the call must fail fast
  # (exit 3) instead of waiting on the legacy 60-min bound (that wait hung this suite once).
  $env:AGENTQ_SESSION = 'claimant'
  $o = AQ lease -Slot task-1 -Purpose 'reclaim' -Reclaim -NoWait
  Check 'reclaim: -Reclaim without -Reason is refused' ($script:code -ne 0) $o
  # now age the holder's slot past its threshold, with a fresh chat grace -> reclaimable
  Set-Owner 'task-1' $false; Set-Times 'task-1' 60 60 60; Set-Chat 'task-1' 5
  $o = AQ lease -Slot task-1 -Purpose 'reclaim now' -Reclaim -Reason 'blocked on a slot a chat grace is holding' -NoWait
  $newId = (Get-Content (LFile 'task-1') -Raw | ConvertFrom-Json).leaseId
  Check 'reclaim: takes a grace-held slot (new leaseId)' ($script:code -eq 0 -and $newId -ne $holdId) $o
  $rj = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'lease-reclaim' } | Select-Object -Last 1)
  Check 'reclaim: journaled lease-reclaim' ($rj.Count -eq 1 -and $rj.ticket -eq $holdId) ($rj | ConvertTo-Json -Compress)
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_AGENT_LIMIT', 'AGENTQ_NO_PRUNE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL PASS'; exit 0 }
