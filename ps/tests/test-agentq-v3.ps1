# Behavioural tests for the agentq v3 scheduler (devcloud F1): lanes/priority, atomic multi-ticket
# grant (no repo hold while waiting for build:machine), soft slots, idle-yield accounting, overrides
# with reasons, metrics, journal reasons. Isolated AGENTQ_HOME + AGENTQ_CONFIG + temp git repo.
$ErrorActionPreference = 'Stop'
$aq = Join-Path $PSScriptRoot 'agentq.ps1'
if (-not (Test-Path $aq)) { $aq = Join-Path (Split-Path $PSScriptRoot) 'bin\agentq.ps1' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agentq-v3-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_SESSION = 'v3test'
$cfgFile = Join-Path $tmp 'agentq-config.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
@{ machineCap = 1; quickBurst = 1; agingMin = 0; idleYieldMin = 0; idleCpuSec = 10; bumpMax = 50; burstMax = 2; burstMaxMin = 60; overridesPerHour = 3; minFreeCommitGB = 0; journalRotateMB = 64 } | ConvertTo-Json | Set-Content $cfgFile
$env:AGENTQ_CONFIG = $cfgFile
$repo = Join-Path $tmp 'repo'; $repo2 = Join-Path $tmp 'other'
foreach ($r in $repo, $repo2) {
  New-Item -ItemType Directory -Force $r | Out-Null
  git -C $r init -q -b main; git -C $r config user.email t@t; git -C $r config user.name t
  Set-Content (Join-Path $r 'a.txt') 'a'; git -C $r add a.txt; git -C $r commit -qm init
}
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }
$J = Join-Path $env:AGENTQ_HOME 'journal.jsonl'
function Journal { @(Get-Content $J -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
$mq = Join-Path $env:AGENTQ_HOME 'queues\build_machine'
function Start-Run([string]$dir, [string]$purpose, [string]$lane, [string]$body, [int]$prio = 0) {
  $a = @('-NoProfile', '-File', $aq, 'run', '-Resource', 'build', '-Purpose', $purpose, '-Lane', $lane, '-Priority', "$prio", '-MinFreeGB', '0', '-TimeoutMin', '3', '--', 'pwsh', '-NoProfile', '-Command', $body)
  Start-Process pwsh -ArgumentList $a -WorkingDirectory $dir -PassThru -WindowStyle Hidden
}
function Wait-For([scriptblock]$cond, [int]$sec = 30) { $t = 0; while ($t -lt ($sec * 4) -and -not (& $cond)) { Start-Sleep -Milliseconds 250; $t++ }; & $cond }
$order = Join-Path $tmp 'order.log'

# 1. priority beats FIFO: with machineCap 1 held, a later quick/high waiter starts before an earlier batch waiter.
$h = Start-Run $repo 'holder' 'gate' 'Start-Sleep -Seconds 6'
Wait-For { Get-ChildItem $mq -Filter '*.json' -ErrorAction SilentlyContinue } | Out-Null; Start-Sleep 1
$b = Start-Run $repo2 'batchy' 'batch' "Add-Content '$order' batch"
Start-Sleep 2
$g = Start-Run $repo2 'urgent' 'heavy' "Add-Content '$order' heavy" 40
$h, $b, $g | ForEach-Object { $_.WaitForExit(90000) | Out-Null }
$o = @(Get-Content $order -ErrorAction SilentlyContinue)
Check 'higher priority waiter goes first' ($o.Count -eq 2 -and $o[0] -eq 'heavy') ($o -join ',')

# 2. no repo hold while waiting for the machine: a run in repo A waiting for build:machine must not hold build:repo.
Remove-Item $order -ErrorAction SilentlyContinue
$h = Start-Run $repo2 'machine-holder' 'gate' 'Start-Sleep -Seconds 15'
Wait-For { @(Get-ChildItem $mq -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.purpose -eq 'machine-holder' -and $_.held }).Count -ge 1 } | Out-Null
$w = Start-Run $repo 'repo-waiter' 'gate' 'exit 0'
Wait-For { Get-ChildItem (Join-Path $env:AGENTQ_HOME 'queues\build_repo') -Filter '*.json' -ErrorAction SilentlyContinue } | Out-Null; Start-Sleep 2
$rq = Join-Path $env:AGENTQ_HOME 'queues\build_repo'
$wt = @(Get-ChildItem $rq -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
Check 'waiter holds nothing while machine busy' (($wt.Count -ge 1) -and -not ($wt | Where-Object held)) (($wt | ForEach-Object { "$($_.purpose) held=$($_.held)" }) -join ',')
# status shows wait with ~ (not ready) on the repo ticket
$st = (& pwsh -NoProfile -File $aq status -Repo $repo) -join "`n"
Check 'status shows lane column' ($st -match 'lane') ''
$h.WaitForExit(60000) | Out-Null; $w.WaitForExit(60000) | Out-Null

# 3. quick burst: with machineCap 1 held by a gate, a quick lane run starts immediately.
# Judged on the scheduler's own `waitSec` (ticket created -> granted) from the journal, not wall
# clock: wall clock includes pwsh startup, which reached 17-19 s on a loaded machine (2026-10-18,
# install.ps1 refused to install on this test alone). Holder sleeps 25 s, so a run that had to wait
# shows waitSec >= ~20; one admitted beside it shows ~0-2.
function WaitSecOf([string]$purpose) { $e = @(Journal | Where-Object { $_.event -eq 'acquired' -and $_.purpose -eq $purpose }) | Select-Object -Last 1; if ($e) { [double]$e.waitSec } else { -1 } }
$h = Start-Run $repo2 'gate-holder' 'gate' 'Start-Sleep -Seconds 25'
Wait-For { Get-ChildItem $mq -Filter '*.json' -ErrorAction SilentlyContinue } | Out-Null; Start-Sleep 1
& pwsh -NoProfile -File $aq run -Resource build -Purpose 'lint' -Lane quick -MinFreeGB 0 -TimeoutMin 1 -Repo $repo -- pwsh -NoProfile -Command 'exit 0' 2>$null
$rc = $LASTEXITCODE; $ws = WaitSecOf 'lint'; $holderAlive = -not $h.HasExited
Check 'quick lane uses burst slot (no wait)' ($rc -eq 0 -and $ws -ge 0 -and $ws -lt 10 -and $holderAlive) "exit $rc waitSec=$ws holderAlive=$holderAlive"
$h.WaitForExit(60000) | Out-Null

# 4. non-batch beside batch: batch holder does not block a gate run.
$h = Start-Run $repo2 'batch-holder' 'batch' 'Start-Sleep -Seconds 25'
Wait-For { Get-ChildItem $mq -Filter '*.json' -ErrorAction SilentlyContinue } | Out-Null; Start-Sleep 1
& pwsh -NoProfile -File $aq run -Resource build -Purpose 'gate-beside-batch' -Lane gate -MinFreeGB 0 -TimeoutMin 1 -Repo $repo -- pwsh -NoProfile -Command 'exit 0' 2>$null
$rc = $LASTEXITCODE; $ws = WaitSecOf 'gate-beside-batch'; $holderAlive = -not $h.HasExited
Check 'gate runs beside batch holder' ($rc -eq 0 -and $ws -ge 0 -and $ws -lt 10 -and $holderAlive) "exit $rc waitSec=$ws holderAlive=$holderAlive"
$h.WaitForExit(60000) | Out-Null

# 5. yielded holder does not count: a fake live machine holder marked yielded leaves the slot free.
New-Item -ItemType Directory -Force $mq | Out-Null
$f = Join-Path $mq '99999999-yield001.json'
@{ v = 3; id = 'yield001'; seq = 99999999; resource = 'build:machine'; pid = $PID; procStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); session = 'idle'; purpose = 'idle holder'; created = [DateTime]::UtcNow.ToString('o'); lane = 'gate'; prio = 0; bump = 0; held = $true; ready = $true; yielded = $true } | ConvertTo-Json | Set-Content $f
Set-Content "$f.hb" ''
& pwsh -NoProfile -File $aq run -Resource build -Purpose 'after-idle' -Lane gate -MinFreeGB 0 -TimeoutMin 1 -Repo $repo -- pwsh -NoProfile -Command 'exit 0' 2>$null
Check 'idle-yielded holder frees the machine slot' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
Remove-Item $f, "$f.hb" -Force

# 6. overrides need a reason; bump changes priority; budget is enforced.
& pwsh -NoProfile -File $aq burst -Reason 'x' 2>$null
Check 'burst without real reason refused' ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE"
& pwsh -NoProfile -File $aq burst -Resource build:machine -By 1 -Minutes 5 -MinFreeGB 0 -Reason 'unit test burst window' | Out-Null
Check 'burst accepted with reason' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
$cap = [int](Get-Content (Join-Path $mq 'capacity') -Raw)
$st = (& pwsh -NoProfile -File $aq status -All) -join "`n"
Check 'burst raises effective capacity and shows in status' ($st -match 'BURST build:machine \+1') $st
$h = Start-Run $repo2 'hold-for-bump' 'gate' 'Start-Sleep -Seconds 10'
Start-Sleep 2
$env:AGENTQ_SESSION = 'bumper'
$w = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $aq, 'run', '-Resource', 'install', '-Purpose', 'wait-install', '--', 'pwsh', '-NoProfile', '-Command', 'exit 0') -WorkingDirectory $repo -PassThru -WindowStyle Hidden
$env:AGENTQ_SESSION = 'v3test'
& pwsh -NoProfile -File $aq burst -Resource build:machine -MinFreeGB 0 -Reason 'second burst in budget' | Out-Null
& pwsh -NoProfile -File $aq burst -Resource build:machine -MinFreeGB 0 -Reason 'third burst in budget' 2>$null | Out-Null
& pwsh -NoProfile -File $aq burst -Resource build:machine -MinFreeGB 0 -Reason 'fourth burst over budget' 2>$null | Out-Null
Check 'override budget enforced (exit 3)' ($LASTEXITCODE -eq 3) "exit $LASTEXITCODE"
$h.WaitForExit(60000) | Out-Null; $w.WaitForExit(60000) | Out-Null
$ev = Journal
Check 'burst journaled with reason' (@($ev | Where-Object { $_.event -eq 'burst' -and $_.reason -eq 'unit test burst window' }).Count -eq 1)

# 7. metrics: v3 runs carry waitSec/holdSec/lane/kind; metrics renders rows.
$done = @($ev | Where-Object { $_.event -in 'done', 'fail' -and $_.PSObject.Properties['holdSec'] })
Check 'done events carry holdSec+waitSec+lane+kind' ($done.Count -ge 3 -and -not ($done | Where-Object { -not $_.PSObject.Properties['waitSec'] -or -not $_.lane -or -not $_.kind })) "$($done.Count)"
Check 'acquired event journaled with waitSec' (@($ev | Where-Object { $_.event -eq 'acquired' -and $null -ne $_.waitSec }).Count -ge 3)
$m = (& pwsh -NoProfile -File $aq metrics -Hours 1 -Json) | ConvertFrom-Json
Check 'metrics json has rows' (@($m.rows).Count -ge 1) ''

# 8. commit failure is journaled with a reason (was silent for ~30 % of commit tickets).
Push-Location $repo
& pwsh -NoProfile -File $aq commit -Purpose 'unit' -Message 'test: nothing' -Paths 'does-not-exist.txt' -NoPush 2>$null | Out-Null
Pop-Location
$ev = Journal
Check 'commit failure journaled (commit-failed + reason)' (@($ev | Where-Object { $_.event -eq 'commit-failed' -and $_.reason }).Count -ge 1)

# 9. rotate archives and keeps a fresh journal with a rotate event.
& pwsh -NoProfile -File $aq rotate | Out-Null
$arch = @(Get-ChildItem (Join-Path $env:AGENTQ_HOME 'journal-archive') -Filter '*.jsonl' -ErrorAction SilentlyContinue)
$ev = Journal
Check 'rotate archived + fresh journal' ($arch.Count -eq 1 -and @($ev).Count -le 2 -and ($ev | Where-Object event -eq 'rotate')) "$($arch.Count) $(@($ev).Count)"

# 10. propose breaks a holder whose heartbeat is stale for > 2x StaleMin (pid alive) and journals it.
New-Item -ItemType Directory -Force $mq | Out-Null
$f = Join-Path $mq '99999998-stale001.json'
@{ v = 3; id = 'stale001'; seq = 99999998; resource = 'build:machine'; pid = $PID; procStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); session = 'hung'; purpose = 'hung holder'; created = [DateTime]::UtcNow.AddMinutes(-30).ToString('o'); lane = 'gate'; prio = 0; bump = 0; held = $true; ready = $true } | ConvertTo-Json | Set-Content $f
Set-Content "$f.hb" ''; [IO.File]::SetLastWriteTimeUtc("$f.hb", [DateTime]::UtcNow.AddMinutes(-5))
$env:AGENTQ_SESSION = 'proposer'
$out = (& pwsh -NoProfile -File $aq propose -StaleMin 1 -MinFreeGB 0 -Repo $repo -Reason 'unit propose check') -join ' '
$env:AGENTQ_SESSION = 'v3test'
Check 'propose breaks STALE holder' (-not (Test-Path $f) -and $out -match 'broke STALE') $out
Check 'propose-applied journaled' (@(Journal | Where-Object event -eq 'propose-applied').Count -ge 1)

# 11. idle-yield watchdog: a holder sleeping (no CPU) for > idleYieldMin flips yielded=true, and a
#     gate waiter then runs beside it. (~70 s: the watchdog samples every 60 s.)
@{ machineCap = 1; quickBurst = 0; agingMin = 0; idleYieldMin = 1; idleCpuSec = 10; overridesPerHour = 3; minFreeCommitGB = 0 } | ConvertTo-Json | Set-Content $cfgFile
$h = Start-Run $repo2 'sleepy' 'gate' 'Start-Sleep -Seconds 100'
$yielded = Wait-For { @(Get-ChildItem $mq -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.purpose -eq 'sleepy' -and $_.PSObject.Properties['yielded'] -and $_.yielded }).Count -ge 1 } 95
Check 'idle watchdog marks sleeping holder yielded' ([bool]$yielded) ''
$t0 = Get-Date
& pwsh -NoProfile -File $aq run -Resource build -Purpose 'beside-idle' -Lane gate -MinFreeGB 0 -TimeoutMin 1 -Repo $repo -- pwsh -NoProfile -Command 'exit 0' 2>$null
$secs = ((Get-Date) - $t0).TotalSeconds
Check 'gate runs beside an idle-yielded holder' ($LASTEXITCODE -eq 0 -and $secs -lt 20) "exit $LASTEXITCODE ${secs}s"
Check 'idle-yield journaled' (@(Journal | Where-Object event -eq 'idle-yield').Count -ge 1)
Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-Item Env:AGENTQ_CONFIG, Env:AGENTQ_SESSION -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
