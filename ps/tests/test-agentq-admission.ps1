# ADR 0009 stage 0 (OQ-004): admission by load. The load probe is the start latency of a trivial process;
# when its recent median is above the limit, agentq grants no new task slot and no second
# gate/heavy/batch build. The probe is faked through AGENTQ_PROBE_FAKE (a file holding milliseconds), so
# the suite does not depend on how busy the machine is. Isolated in %TEMP%.
# OQ-005 (cases 8+): the machine-wide limit on task leases follows owner presence (seconds since the last
# input, faked through AGENTQ_IDLE_FAKE) and a night schedule (local time faked through AGENTQ_FAKE_LOCALTIME).
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqad-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_JOBOBJ = '1'
$env:AGENTQ_SESSION = 'test-adm'
Remove-Item Env:AGENTQ_NO_ADMISSION -ErrorAction SilentlyContinue
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fake = Join-Path $tmp 'probe-ms.txt'
$env:AGENTQ_PROBE_FAKE = $fake
$idleFake = Join-Path $tmp 'idle-sec.txt'
foreach ($v in 'AGENTQ_IDLE_FAKE', 'AGENTQ_FAKE_LOCALTIME', 'AGENTQ_NO_AGENT_LIMIT') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$cfg = Join-Path $tmp 'cfg.json'; $env:AGENTQ_CONFIG = $cfg
function Cfg([double]$maxHoldMin, [bool]$enabled = $true, $agentLimit = $null) {
  $h = @{ taskSlotsPerRepo = 3; taskSlotsMachine = 5; minFreeCommitGB = 0; machineCap = 2; quickBurst = 0; agingMin = 0; idleYieldMin = 0
    admission = @{ enabled = $enabled; probeMs = 400; window = 3; everySec = 0; staleSec = 300; maxHoldMin = $maxHoldMin }
  }
  if ($agentLimit) { $h.agentLimit = $agentLimit }
  $h | ConvertTo-Json -Depth 5 | Set-Content $cfg
}
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Journal([string]$ev) { $f = Join-Path $env:AGENTQ_HOME 'journal.jsonl'; if (Test-Path $f) { @(Get-Content $f | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq $ev) } else { @() } }
# Make the shared record say "$ms" for the whole window (3 forced samples).
function Load([int]$ms) { [IO.File]::WriteAllText($fake, "$ms"); foreach ($i in 1..3) { $null = AQ probe -Force } }
# The literal build:machine resource: the machine slot alone, without the per-repo build ticket (a second
# build of the SAME repo waits for that ticket whatever the load is).
function Run([string[]]$more) { $a = @('run', '-Resource', 'build:machine', '-MinFreeGB', '0', '-Repo', $repo) + $more + @('--', 'pwsh', '-NoProfile', '-Command', 'exit 0'); AQ @a }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
$holder = $null
Push-Location $repo
try {
  Cfg 60
  # 1. the probe: recorded, judged, shown by status
  $o = AQ status
  Check '1 no sample yet: status says so, admission open' ($o -match '== LOAD no start probe yet') $o
  Load 50
  $o = AQ probe -Json; $p = $o | ConvertFrom-Json
  Check '1 probe verb reports the sample and the verdict' ($p.probeMs -eq 50 -and $p.medianMs -eq 50 -and $p.samples -eq 3 -and $p.saturated -eq $false) $o
  $o = AQ status
  Check '1 status prints the probe and OPEN' ($o -match '== LOAD start probe 50 ms .*limit 400 ms -> admission OPEN') $o
  $day = @(Get-ChildItem (Join-Path $env:AGENTQ_HOME 'load') -Filter 'probe-*.jsonl')
  $lines = @(Get-Content $day[0].FullName | ForEach-Object { $_ | ConvertFrom-Json })
  Check '1 every sample is appended to the day file (ts, ms, src)' ($day.Count -eq 1 -and $lines.Count -ge 4 -and $lines[-1].ms -eq 50 -and $lines[-1].src -eq 'agentq' -and $lines[-1].ts) "$($lines.Count)"
  # status only reads: no sample, no write
  $pf = Join-Path $env:AGENTQ_HOME 'load\probe.json'
  $h0 = (Get-FileHash $pf).Hash; $n0 = @(Get-Content $day[0].FullName).Count
  $null = AQ status -All; $null = AQ status -Json
  Check '1 status does not take a sample' ((Get-FileHash $pf).Hash -eq $h0 -and @(Get-Content $day[0].FullName).Count -eq $n0)

  # 2. saturated: shown, and a new task slot is not granted
  Load 2000
  $o = AQ status
  Check '2 status prints SATURATED' ($o -match 'median of last 3: 2000 ms; limit 400 ms -> admission SATURATED') $o
  $st = AQ status -Json | ConvertFrom-Json
  Check '2 status -Json carries the load object' ($st.load.saturated -eq $true -and $st.load.medianMs -eq 2000 -and $st.load.thresholdMs -eq 400) ($st.load | ConvertTo-Json -Compress)
  $o = AQ lease -Purpose 'new agent' -NoWait
  Check '2 saturated: lease -NoWait is refused (exit 3) and says why' ($code -eq 3 -and $o -match 'saturated' -and -not (Test-Path (Join-Path $env:AGENTQ_HOME 'leases\repo\task-1.json'))) $o
  Check '2 journal: admission-hold with the probe' (@(Journal 'admission-hold').Count -ge 1 -and (Journal 'admission-hold')[-1].probeMs -eq 2000)
  # a release slot is never gated (it finishes work already admitted)
  $o = AQ lease -Role release -Purpose 'release run' -NoWait -Json
  $lr = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check '2 saturated: a release slot is still granted' ($code -eq 0 -and $lr.role -eq 'release') $o

  # 3. recovered: the same lease is granted
  Load 50
  $o = AQ lease -Purpose 'new agent' -NoWait -Json
  $l1 = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check '3 recovered: lease granted' ($code -eq 0 -and $l1.slot -eq 'task-1') $o

  # 4. progress guarantee: held only by load for maxHoldMin -> admitted anyway, journaled
  Cfg 0.05   # 3 s
  Load 2000
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $o = AQ lease -Purpose 'held then admitted' -TimeoutMin 2 -Json
  $l2 = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check '4 saturated + waiting: granted after maxHoldMin' ($code -eq 0 -and $l2.slot -eq 'task-2' -and $sw.Elapsed.TotalSeconds -ge 3) "$([int]$sw.Elapsed.TotalSeconds) s | $o"
  Check '4 journal: admission-override' (@(Journal 'admission-override').Count -eq 1)
  $le = Journal 'lease' | Where-Object { $_.ticket -eq $l2.leaseId }
  Check '4 the lease event carries loadWaitSec' ($le -and $le.loadWaitSec -ge 3) ($le | ConvertTo-Json -Compress)

  # 5. builds. A holder occupies one of the two machine slots.
  Cfg 60
  Load 50
  # The holder keeps its slot until $stop exists: a fixed sleep ended too early on a busy machine (every
  # agentq call below starts a process), and the checks then ran with no holder at all.
  $hold = Join-Path $tmp 'hold.ps1'; $stop = Join-Path $tmp 'holder.stop'
  [IO.File]::WriteAllText($hold, "param([string]`$Stop)`n`$end = (Get-Date).AddMinutes(20)`nwhile (-not (Test-Path -LiteralPath `$Stop) -and (Get-Date) -lt `$end) { Start-Sleep -Milliseconds 300 }`n")
  $hs = Join-Path $tmp 'holder.ps1'
  [IO.File]::WriteAllText($hs, "`$env:AGENTQ_SESSION = 'holder'`n& pwsh -NoProfile -File '$Aq' run -Resource build:machine -Purpose holder -MinFreeGB 0 -Repo '$repo' -- pwsh -NoProfile -File '$hold' -Stop '$stop'`n")
  $holder = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $hs -WindowStyle Hidden -PassThru
  $held = $false
  $until = (Get-Date).AddSeconds(180)
  while (-not $held -and (Get-Date) -lt $until) { $st = AQ status -Json | ConvertFrom-Json; if (@($st.tickets | Where-Object { $_.resource -eq 'build:machine' -and $_.role -eq 'HOLD' }).Count) { $held = $true } else { Start-Sleep -Milliseconds 500 } }
  Check '5 setup: one build holds build:machine' $held
  $o = Run @('-Purpose', 'second gate, machine fine', '-NoWait')
  Check '5 control: machine fine -> a second gate build runs beside the holder' ($code -eq 0) $o
  Load 2000
  $o = Run @('-Purpose', 'second gate, saturated', '-NoWait')
  Check '5 saturated -> no second gate build (exit 3)' ($code -eq 3) $o
  $o = Run @('-Purpose', 'quick, saturated', '-NoWait', '-Lane', 'quick')
  Check '5 saturated -> a quick-lane job is never gated' ($code -eq 0) $o
  $env:AGENTQ_NO_ADMISSION = '1'
  $o = Run @('-Purpose', 'opt out', '-NoWait')
  Remove-Item Env:AGENTQ_NO_ADMISSION
  Check '5 AGENTQ_NO_ADMISSION=1 opts one call out' ($code -eq 0) $o
  Cfg 60 $false
  $o = Run @('-Purpose', 'config off', '-NoWait')
  Check '5 config admission.enabled=false turns it off' ($code -eq 0) $o
  $o = AQ status
  Check '5 ... and status says admission is off' ($o -match '== LOAD admission by load is off') $o
  # waiting (not -NoWait): the wait message names the reason; recovery admits it
  Cfg 60
  Load 2000
  $ws = Join-Path $tmp 'waiter.ps1'; $wout = Join-Path $tmp 'waiter.out'
  [IO.File]::WriteAllText($ws, "`$env:AGENTQ_SESSION = 'waiter'`n& pwsh -NoProfile -File '$Aq' run -Resource build:machine -Purpose waiter -MinFreeGB 0 -TimeoutMin 10 -Repo '$repo' -- pwsh -NoProfile -Command 'exit 0' *> '$wout'`n`"WAITER_EXIT=`$LASTEXITCODE`" | Add-Content '$wout'`n")
  $waiter = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $ws -WindowStyle Hidden -PassThru
  $said = $false
  $until = (Get-Date).AddSeconds(180)
  while (-not $said -and (Get-Date) -lt $until -and -not $waiter.HasExited) { if ((Test-Path $wout) -and (Get-Content $wout -Raw) -match 'machine saturated \(start probe median') { $said = $true } else { Start-Sleep -Milliseconds 500 } }
  Check '5 a waiting build says it is held by load' $said ($(if (Test-Path $wout) { Get-Content $wout -Raw } else { '(no output)' }))
  Check '5 ... and is still waiting' (-not $waiter.HasExited)
  [IO.File]::WriteAllText($fake, '50')
  $null = $waiter.WaitForExit(240000)
  $wtxt = if (Test-Path $wout) { Get-Content $wout -Raw } else { '' }
  Check '5 the machine recovers -> the waiting build is granted and runs' ($wtxt -match 'WAITER_EXIT=0') $wtxt
  $acq = Journal 'acquired' | Where-Object { $_.purpose -eq 'waiter' } | Select-Object -Last 1
  Check '5 its acquired event carries loadWaitSec > 0' ($acq -and $acq.loadWaitSec -gt 0) ($acq | ConvertTo-Json -Compress)

  # 6. progress guarantee for builds: saturated and NO holder -> one build always starts
  [IO.File]::WriteAllText($stop, '')
  if (-not $holder.WaitForExit(120000)) { & taskkill.exe /T /F /PID $holder.Id 2>&1 | Out-Null }
  $holder = $null
  Load 2000
  $o = Run @('-Purpose', 'only build on a saturated machine', '-TimeoutMin', '1')
  Check '6 saturated, nothing running -> a gate build still starts' ($code -eq 0) $o

  # 6b. the ONE build a saturated machine starts is the first in rank. A higher-priority build is queued
  # and cannot start yet (its own RAM gate asks for more than any machine has); nothing holds a slot. A
  # lower-priority build must not take the slot ahead of it. Without the rank test it did: whichever
  # waiter polled first after a holder ended started, and the other was then held by load behind it.
  $whs = Join-Path $tmp 'w-high.ps1'
  [IO.File]::WriteAllText($whs, "`$env:AGENTQ_SESSION = 'high'`n& pwsh -NoProfile -File '$Aq' run -Resource build:machine -Lane heavy -Purpose high -MinFreeGB 99999999 -TimeoutMin 10 -Repo '$repo' -- pwsh -NoProfile -Command 'exit 0'`n")
  $wHigh = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $whs -WindowStyle Hidden -PassThru
  $queued = $false
  $until = (Get-Date).AddSeconds(180)
  while (-not $queued -and (Get-Date) -lt $until) { $st = AQ status -Json | ConvertFrom-Json; if (@($st.tickets | Where-Object { $_.resource -eq 'build:machine' -and $_.purpose -eq 'high' -and $_.role -like 'wait#1*' }).Count) { $queued = $true } else { Start-Sleep -Milliseconds 500 } }
  Check '6b setup: a higher-priority build waits first in rank, nothing holds a slot' ($queued -and -not @($st.tickets | Where-Object { $_.resource -eq 'build:machine' -and $_.role -like 'HOLD*' }).Count) ($st.tickets | ConvertTo-Json -Compress)
  $o = Run @('-Purpose', 'low, saturated', '-NoWait', '-Lane', 'batch')
  Check '6b saturated: a lower-priority build does not start ahead of the first in rank (exit 3)' ($code -eq 3) $o
  Load 50
  $o = Run @('-Purpose', 'low, machine fine', '-NoWait', '-Lane', 'batch')
  Check '6b control: machine fine -> the same build takes the free second slot' ($code -eq 0) $o
  & taskkill.exe /T /F /PID $wHigh.Id 2>&1 | Out-Null; $wHigh = $null
  Load 2000

  # 7. a stale record (older than staleSec) is "unknown", not "saturated"
  $pj = Get-Content $pf -Raw | ConvertFrom-Json
  $old = [DateTime]::UtcNow.AddMinutes(-30).ToString('o')
  $pj.at = $old; foreach ($s in $pj.samples) { $s.t = $old }
  [IO.File]::WriteAllText($pf, ($pj | ConvertTo-Json -Compress -Depth 4))
  $st = AQ status -Json | ConvertFrom-Json
  Check '7 samples older than staleSec do not saturate' ($st.load.saturated -eq $false -and $st.load.samples -eq 0) ($st.load | ConvertTo-Json -Compress)

  # 8. OQ-005: the agent limit follows owner presence and the night schedule; both are shown by status.
  # Two task leases exist at this point (cases 3 and 4); taskSlotsMachine is 5.
  function Agents { (AQ status -Json | ConvertFrom-Json).agents }
  function Idle($sec) { [IO.File]::WriteAllText($idleFake, "$sec"); $env:AGENTQ_IDLE_FAKE = $idleFake; Load 50 }
  $o = AQ status
  Check '8 no agentLimit in the config: status says it is off, limit = taskSlotsMachine' ($o -match '== AGENTS limit 5 of 5 task slots \(agentLimit is off\); 2 leased') $o
  $al = @{ enabled = $true; awayAfterMin = 10; present = 1; away = 3; night = @{ from = '23:00'; to = '07:00'; limit = 4 } }
  Cfg 60 $true $al
  $env:AGENTQ_FAKE_LOCALTIME = '12:00'
  Idle 5
  $a = Agents
  Check '8 owner present (input 5 s ago) -> the present limit' ($a.state -eq 'present' -and $a.limit -eq 1 -and $a.base -eq 5 -and $a.inputIdleSec -eq 5 -and $a.leased -eq 2) ($a | ConvertTo-Json -Compress)
  $o = AQ status
  Check '8 status prints the limit, the reason and the schedule' ($o -match '== AGENTS limit 1 of 5 task slots \(owner present \(last input 5 s ago\); night 23:00-07:00: not now\); 2 leased') $o
  $o = AQ lease -Purpose 'third agent while the owner works' -NoWait
  Check '8 present: a new task lease over the limit is refused (exit 3) and says why' ($code -eq 3 -and $o -match 'task slot cap \(1\) reached - agent limit: owner present' -and -not (Test-Path (Join-Path $env:AGENTQ_HOME 'leases\repo\task-3.json'))) $o
  $hold = Journal 'agent-limit-hold' | Select-Object -Last 1
  Check '8 journal: agent-limit-hold with the limit and the reason' ($hold -and $hold.limit -eq 1 -and $hold.base -eq 5 -and $hold.reason -match 'owner present') ($hold | ConvertTo-Json -Compress)
  $env:AGENTQ_NO_AGENT_LIMIT = '1'
  $a = Agents
  Remove-Item Env:AGENTQ_NO_AGENT_LIMIT
  Check '8 AGENTQ_NO_AGENT_LIMIT=1 opts one call out' ($a.limit -eq 5 -and $a.state -eq 'off') ($a | ConvertTo-Json -Compress)
  Idle 3600
  $a = Agents
  Check '8 owner away at noon (no input for 60 min) -> the away limit' ($a.state -eq 'away' -and $a.limit -eq 3 -and $a.night -eq $false) ($a | ConvertTo-Json -Compress)
  $o = AQ lease -Purpose 'third agent, owner away' -NoWait -Json
  $l3 = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check '8 away: the same lease is now granted' ($code -eq 0 -and $l3.slot -eq 'task-3') $o
  $env:AGENTQ_FAKE_LOCALTIME = '02:00'
  $a = Agents
  Check '8 owner away at 02:00, window 23:00-07:00 -> the night limit' ($a.state -eq 'night' -and $a.limit -eq 4 -and $a.night -eq $true -and $a.leased -eq 3) ($a | ConvertTo-Json -Compress)
  $o = AQ status
  Check '8 status names the night schedule' ($o -match '== AGENTS limit 4 of 5 task slots \(owner away, night schedule 23:00-07:00; night 23:00-07:00: now\)') $o
  $env:AGENTQ_FAKE_LOCALTIME = '23:30'
  Check '8 the window wraps midnight: 23:30 is night' ((Agents).state -eq 'night')
  $env:AGENTQ_FAKE_LOCALTIME = '07:00'
  Check '8 ... and 07:00 is not (the end is exclusive)' ((Agents).state -eq 'away')
  $env:AGENTQ_FAKE_LOCALTIME = '02:00'
  Idle 5
  $a = Agents
  Check '8 owner at the keyboard at 02:00 -> present wins over the schedule' ($a.state -eq 'present' -and $a.limit -eq 1) ($a | ConvertTo-Json -Compress)
  # nothing that already runs is touched: three leases stay although the limit is 1
  Check '8 a lower limit stops no running lease' (@(Get-ChildItem (Join-Path $env:AGENTQ_HOME 'leases\repo') -Filter 'task-*.json').Count -eq 3)
  # values that are not set fall back to taskSlotsMachine
  Cfg 60 $true @{ enabled = $true; awayAfterMin = 10; present = $null; away = $null; night = @{ from = '23:00'; to = '07:00'; limit = $null } }
  $a = Agents
  Check '8 a limit that is not set = taskSlotsMachine (state still reported)' ($a.state -eq 'present' -and $a.limit -eq 5) ($a | ConvertTo-Json -Compress)
  Cfg 60 $true $al
  # presence unknown: the sample has no idle value, or the record is stale
  [IO.File]::WriteAllText($idleFake, 'not-a-number'); Load 50
  $a = Agents
  Check '8 a sample without an idle value -> unknown -> taskSlotsMachine' ($a.state -eq 'unknown' -and $a.limit -eq 5 -and $null -eq $a.inputIdleSec) ($a | ConvertTo-Json -Compress)
  Idle 5
  $pj = Get-Content $pf -Raw | ConvertFrom-Json
  $pj.at = [DateTime]::UtcNow.AddMinutes(-30).ToString('o')
  [IO.File]::WriteAllText($pf, ($pj | ConvertTo-Json -Compress -Depth 4))
  $a = Agents
  Check '8 a record older than staleSec -> unknown -> taskSlotsMachine' ($a.state -eq 'unknown' -and $a.limit -eq 5) ($a | ConvertTo-Json -Compress)
  # the real reading (no fake): a number of seconds, or unknown where there is no interactive session
  Remove-Item Env:AGENTQ_IDLE_FAKE
  $p = AQ probe -Force -Json | ConvertFrom-Json
  Check '8 the real idle reading does not fail (seconds >= 0, or unknown)' ($code -eq 0 -and ($null -eq $p.inputIdleSec -or $p.inputIdleSec -ge 0)) ($p | ConvertTo-Json -Compress)
  Write-Host ("     real input idle on this machine: {0}" -f $(if ($null -ne $p.inputIdleSec) { "$($p.inputIdleSec) s" } else { 'unknown' }))
} finally {
  Pop-Location
  foreach ($pr in $holder, $wHigh) { if ($pr) { & taskkill.exe /T /F /PID $pr.Id 2>&1 | Out-Null } }
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_PROBE_FAKE', 'AGENTQ_IDLE_FAKE', 'AGENTQ_FAKE_LOCALTIME', 'AGENTQ_NO_AGENT_LIMIT', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_JOBOBJ', 'AGENTQ_NO_ADMISSION') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
