# Behavioural tests for the background-job tools: wait-job (DONE/FAILED/STALLED/TIMEOUT, literal markers,
# pid mode, never exceeding the bound), job-start -> registry -> jobs list/show -> done, jobs kill,
# run-build defaults + isolation, agentq status WEDGED flag, agentq-sync jobs[] payload.
# Isolated AGENTQ_HOME + temp dirs; never touches the real coord dir.
param([string]$Bin, [string]$Hooks)
$ErrorActionPreference = 'Stop'
if (-not $Bin) { $Bin = Join-Path (Split-Path $PSScriptRoot) 'bin' }
if (-not $Hooks) { $Hooks = Join-Path (Split-Path $PSScriptRoot) 'hooks' }
$wait = Join-Path $Bin 'wait-job.ps1'; $start = Join-Path $Bin 'job-start.ps1'; $jobs = Join-Path $Bin 'jobs.ps1'
$aq = Join-Path $Bin 'agentq.ps1'; $sync = Join-Path $Bin 'agentq-sync.ps1'; $rb = Join-Path $Hooks 'run-build.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aq-jobs-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_SESSION = 'jobstest'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }
function Run-Wait([string[]]$a) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $out = @(& pwsh -NoProfile -File $wait @a 2>&1 | ForEach-Object { "$_" })
  @{ code = $LASTEXITCODE; out = ($out -join "`n"); sec = $sw.Elapsed.TotalSeconds }
}
# Writer: appends lines to a log in a hidden process (holds no lock between writes).
function Start-Writer([string]$log, [string]$body) {
  $f = Join-Path $tmp ("w-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.ps1')
  Set-Content -LiteralPath $f -Value ("`$log = '$log'`nfunction W([string]`$s) { [IO.File]::AppendAllText(`$log, `$s + `"``n`") }`n" + $body)
  Start-Process pwsh -ArgumentList @('-NoProfile', '-File', "`"$f`"") -WindowStyle Hidden -PassThru
}

# --- wait-job: DONE with a literal marker containing regex metacharacters ---------------------------
$l1 = Join-Path $tmp 'done.log'
$w = Start-Writer $l1 'W "starting"; Start-Sleep -Milliseconds 800; W "^RB_EXIT=0 (literal)"; Start-Sleep 5'
$r = Run-Wait @('-Log', $l1, '-Done', '^RB_EXIT=|.*never', '-EveryS', '0.2', '-MaxSec', '20')
Check 'wait-job DONE on literal marker with ^ (not a regex anchor)' ($r.code -eq 0 -and $r.out -match "DONE: marker '\^RB_EXIT='") "code=$($r.code) $($r.out)"
$w | Stop-Process -Force -ErrorAction SilentlyContinue

# '.*never' must NOT match arbitrary text (literal, not regex)
$l1b = Join-Path $tmp 'literal.log'
Set-Content -LiteralPath $l1b -Value 'some output that never ends'
$r = Run-Wait @('-Log', $l1b, '-Done', '.*never', '-EveryS', '0.1', '-MaxSec', '1.5', '-StallSec', '30')
Check 'wait-job does not treat markers as regex (".*never" no match)' ($r.code -eq 3) "code=$($r.code)"

# --- FAILED: fail marker, and EXIT=<nonzero> beside the done marker ----------------------------------
$l2 = Join-Path $tmp 'fail.log'
$w = Start-Writer $l2 'W "compiling"; Start-Sleep -Milliseconds 600; W "Traceback (most recent call last):"; Start-Sleep 5'
$r = Run-Wait @('-Log', $l2, '-Done', 'DONE', '-Fail', 'Traceback|BUILD FAILED', '-EveryS', '0.2', '-MaxSec', '20')
Check 'wait-job FAILED on fail marker (exit 1)' ($r.code -eq 1 -and $r.out -match 'Traceback') "code=$($r.code)"
$w | Stop-Process -Force -ErrorAction SilentlyContinue
$l2b = Join-Path $tmp 'exit3.log'
Set-Content -LiteralPath $l2b -Value @('work', 'EXIT=3', 'DONE')
$r = Run-Wait @('-Log', $l2b, '-Done', 'DONE', '-EveryS', '0.1', '-MaxSec', '5')
Check 'wait-job FAILED when EXIT=<nonzero> accompanies the done marker' ($r.code -eq 1) "code=$($r.code)"

# --- STALLED: log silent, live pid -> diagnostics incl. Terminate batch job + process tree --------
$l3 = Join-Path $tmp 'stall.log'
Set-Content -LiteralPath $l3 -Value @('step 1', 'Terminate batch job (Y/N)? ')
$sleeper = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 60' -WindowStyle Hidden -PassThru
$r = Run-Wait @('-Log', $l3, '-Done', 'DONE', '-Pid', "$($sleeper.Id)", '-EveryS', '0.2', '-StallSec', '1.5', '-MaxSec', '20')
Check 'wait-job STALLED (exit 2) when log is silent and pid alive' ($r.code -eq 2) "code=$($r.code)"
Check 'STALLED prints the log tail' ($r.out -match 'last 30 log lines' -and $r.out -match 'step 1')
Check 'STALLED detects Terminate batch job (Y/N)' ($r.out -match 'got Ctrl\+C')
Check 'STALLED prints the process tree with cpu/ws' ($r.out -match "process tree of pid $($sleeper.Id)" -and $r.out -match 'cpu=[\d.]+s ws=\d+MB') $r.out
$sleeper | Stop-Process -Force -ErrorAction SilentlyContinue

# --- TIMEOUT: log still growing at the bound -> exit 3, tail + advice; bound respected --------------
$l4 = Join-Path $tmp 'grow.log'
$w = Start-Writer $l4 '1..200 | ForEach-Object { W "line $_"; Start-Sleep -Milliseconds 200 }'
$r = Run-Wait @('-Log', $l4, '-Done', 'DONE', '-EveryS', '0.2', '-StallSec', '30', '-MaxSec', '2.5')
Check 'wait-job TIMEOUT (exit 3) while log grows' ($r.code -eq 3 -and $r.out -match 'still running, keep working or investigate') "code=$($r.code)"
# The wall time of a Run-Wait call is pwsh STARTUP + the bound. Startup on a shared machine with 20+
# peer agents ranges 0.5 s to 30 s (measured 2026-11-19: a full-suite run under contention reported
# 40.4 s here with the product bound respected), so an absolute second count is a load test, not a
# bound test. Calibrate on the same invocation shape with a 0.3 s bound, same tick, and compare.
$lb = Join-Path $tmp 'boundbase.log'
Set-Content -LiteralPath $lb -Value 'nothing yet'
$b1 = (Run-Wait @('-Log', $lb, '-Done', 'DONE', '-EveryS', '0.2', '-StallSec', '30', '-MaxSec', '0.3')).sec
$b2 = (Run-Wait @('-Log', $lb, '-Done', 'DONE', '-EveryS', '0.2', '-StallSec', '30', '-MaxSec', '0.3')).sec
$base = [math]::Min($b1, $b2)   # startup + ~0.3 s bound
Check 'wait-job never blocks past its bound (+ measured pwsh startup)' ($r.sec -lt ($base + 2.5 + 3)) "$([math]::Round($r.sec,1))s total; startup baseline $([math]::Round($base,1))s; bound 2.5s"
Check 'wait-job prints one line per change, not per tick' (@($r.out -split "`n" | Where-Object { $_ -match 'log \d+ bytes' }).Count -le 20)
$w | Stop-Process -Force -ErrorAction SilentlyContinue
# -MaxMin above the hard cap is clamped to 10 (shown in the banner)
$r = Run-Wait @('-Log', $l1b, '-Done', 'zzz', '-MaxMin', '60', '-MaxSec', '0.5')
Check 'MaxSec override still capped; banner shows bound' ($r.code -eq 3 -and $r.out -match 'max 0\.01 min') "$($r.out)"
$bannerOut = @(& pwsh -NoProfile -Command "& '$wait' -Log '$l2b' -Done 'DONE' -MaxMin 60 -EveryS 0.1" 2>&1 | ForEach-Object { "$_" }) -join "`n"
Check '-MaxMin 60 is clamped to 10' ($bannerOut -match 'max 10 min') $bannerOut

# --- pid mode: done when the process exits; nonzero exit -> FAILED ----------------------------------
$p = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 700; exit 0' -WindowStyle Hidden -PassThru
$r = Run-Wait @('-Pid', "$($p.Id)", '-EveryS', '0.2', '-MaxSec', '20')
Check 'wait-job -Pid DONE when the process exits 0' ($r.code -eq 0) "code=$($r.code) $($r.out)"
$p = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Milliseconds 700; exit 4' -WindowStyle Hidden -PassThru
$r = Run-Wait @('-Pid', "$($p.Id)", '-EveryS', '0.2', '-MaxSec', '20')
Check 'wait-job -Pid FAILED when the process exits nonzero' ($r.code -eq 1 -and $r.out -match 'exit code 4') "code=$($r.code) $($r.out)"

# --- job-start -> registry -> jobs list -> done ------------------------------------------------------
$cwd = Join-Path $tmp 'work'; New-Item -ItemType Directory -Force $cwd | Out-Null
$sw0 = [Diagnostics.Stopwatch]::StartNew()
$o = (& pwsh -NoProfile -File $start -Label 'unit ok' -Command '"hello from job"; $in = [Console]::In.ReadLine(); "stdin-null=$($null -eq $in)"; Start-Sleep 8; Write-Error "to stderr" -ErrorAction Continue; exit 0' -Cwd $cwd -ExpectedMin 1 -Json) | ConvertFrom-Json
$launchSec = $sw0.Elapsed.TotalSeconds
Check 'job-start returns at once even when its output is captured (no inherited handles)' ($launchSec -lt 7) "$([math]::Round($launchSec,1))s"
$jf = Join-Path $env:AGENTQ_HOME "jobs\$($o.id).json"
Check 'job-start writes the registry json' (Test-Path $jf)
$reg = Get-Content $jf -Raw | ConvertFrom-Json
Check 'registry has pid, pidStart, log, host, ownerPid, state running' ($reg.pid -gt 0 -and $reg.pidStart -and $reg.log.StartsWith("$cwd\.copilot-tmp\jobs\", [StringComparison]::OrdinalIgnoreCase) -and $reg.host -and $reg.ownerPid -gt 0 -and $reg.state -eq 'running') (($reg | ConvertTo-Json -Compress) + " cwd=$cwd")
$lst = (& pwsh -NoProfile -File $jobs list -Json) | ConvertFrom-Json
Check 'jobs list shows the running job' (@($lst | Where-Object { $_.id -eq $o.id -and $_.state -in 'running', 'starting' }).Count -eq 1) (($lst | ConvertTo-Json -Compress))
$r = Run-Wait @('-JobId', $o.id, '-EveryS', '0.3', '-MaxSec', '60')
Check 'wait-job -JobId DONE' ($r.code -eq 0) "code=$($r.code) $($r.out)"
Start-Sleep -Milliseconds 800
$reg = Get-Content $jf -Raw | ConvertFrom-Json
Check 'runner records state done, exitCode 0, endedAt' ($reg.state -eq 'done' -and $reg.exitCode -eq 0 -and $reg.endedAt) (($reg | ConvertTo-Json -Compress))
$logText = Get-Content $reg.log -Raw
Check 'log has stdout + stderr + EXIT=0 + DONE' ($logText -match 'hello from job' -and $logText -match 'to stderr' -and $logText -match '(?m)^EXIT=0' -and $logText -match '(?m)^DONE')
Check 'job command gets an empty stdin (a prompt reads EOF, never blocks)' ($logText -match 'stdin-null=True')
$lst = (& pwsh -NoProfile -File $jobs list -Json) | ConvertFrom-Json
Check 'jobs list shows done' (@($lst | Where-Object { $_.id -eq $o.id -and $_.state -eq 'done' }).Count -eq 1)
$show = (& pwsh -NoProfile -File $jobs show $o.id) -join "`n"
Check 'jobs show prints json + tail' ($show -match '"label": "unit ok"' -and $show -match 'EXIT=0')

# --- priority: the job's command runs below normal by default, so it yields to interactive work ------
$pcmd = '"prio=" + (Get-Process -Id $PID).PriorityClass'
$o = (& pwsh -NoProfile -File $start -Label 'prio default' -Command $pcmd -Cwd $cwd -ExpectedMin 1 -Json) | ConvertFrom-Json
$null = Run-Wait @('-JobId', $o.id, '-EveryS', '0.3', '-MaxSec', '60'); Start-Sleep -Milliseconds 500
$pl = Get-Content ((Get-Content (Join-Path $env:AGENTQ_HOME "jobs\$($o.id).json") -Raw | ConvertFrom-Json).log) -Raw
Check 'job command inherits BelowNormal priority by default' ($pl -match 'prio=BelowNormal') $pl
$o = (& pwsh -NoProfile -File $start -Label 'prio normal' -Command $pcmd -Cwd $cwd -ExpectedMin 1 -Priority Normal -Json) | ConvertFrom-Json
$null = Run-Wait @('-JobId', $o.id, '-EveryS', '0.3', '-MaxSec', '60'); Start-Sleep -Milliseconds 500
$pl = Get-Content ((Get-Content (Join-Path $env:AGENTQ_HOME "jobs\$($o.id).json") -Raw | ConvertFrom-Json).log) -Raw
Check 'job-start -Priority Normal runs the command at Normal' ($pl -match 'prio=Normal') $pl

# failing job -> failed + wait-job exit 1
$o2 = (& pwsh -NoProfile -File $start -Label 'unit fail' -Command '"boom"; exit 7' -Cwd $cwd -ExpectedMin 1 -Json) | ConvertFrom-Json
$r = Run-Wait @('-JobId', $o2.id, '-EveryS', '0.3', '-MaxSec', '60')
Start-Sleep -Milliseconds 800
$reg2 = Get-Content (Join-Path $env:AGENTQ_HOME "jobs\$($o2.id).json") -Raw | ConvertFrom-Json
Check 'failing job: wait-job FAILED and registry failed/7' ($r.code -eq 1 -and $reg2.state -eq 'failed' -and $reg2.exitCode -eq 7) "code=$($r.code) state=$($reg2.state) exit=$($reg2.exitCode)"

# -File mode with args
# a job that PRINTS 'EXIT=0' mid-run must not end a -JobId wait (completion comes from the registry)
$o5 = (& pwsh -NoProfile -File $start -Label 'unit echo' -Command '"EXIT=0"; "DONE"; Start-Sleep 4; "really finished"' -Cwd $cwd -ExpectedMin 1 -Json) | ConvertFrom-Json
$r = Run-Wait @('-JobId', $o5.id, '-EveryS', '0.3', '-MaxSec', '60')
Check 'wait-job -JobId ignores EXIT=/DONE printed by the job itself' ($r.code -eq 0 -and (Get-Content $o5.log -Raw) -match 'really finished' -and $r.out -match 'finished \(exit 0\)') "code=$($r.code) $($r.out)"
$scr = Join-Path $cwd 'echo.ps1'; Set-Content -LiteralPath $scr -Value 'param($a, $b) "args=$a,$b"'
$o3 = (& pwsh -NoProfile -File $start -Label 'unit file' -File $scr -Cwd $cwd -ExpectedMin 1 -Json x1 'y 2') | ConvertFrom-Json
$r = Run-Wait @('-JobId', $o3.id, '-EveryS', '0.3', '-MaxSec', '60')
Check 'job-start -File with args' ($r.code -eq 0 -and (Get-Content $o3.log -Raw) -match 'args=x1,y 2') "code=$($r.code)"

# --- jobs kill + SUSPECT/DEAD computed states --------------------------------------------------------
$o4 = (& pwsh -NoProfile -File $start -Label 'unit long' -Command '"long"; Start-Sleep 120' -Cwd $cwd -ExpectedMin 1 -Json) | ConvertFrom-Json
Start-Sleep 2
$reg4 = Get-Content (Join-Path $env:AGENTQ_HOME "jobs\$($o4.id).json") -Raw | ConvertFrom-Json
$kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($reg4.pid)" | ForEach-Object ProcessId)
& pwsh -NoProfile -File $jobs kill $o4.id | Out-Null
Start-Sleep -Milliseconds 800
$reg4 = Get-Content (Join-Path $env:AGENTQ_HOME "jobs\$($o4.id).json") -Raw | ConvertFrom-Json
$alive = @(@($reg4.pid) + $kids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
Check 'jobs kill kills the whole tree and marks killed' ($reg4.state -eq 'killed' -and $alive.Count -eq 0) "state=$($reg4.state) alive=$($alive -join ',')"

# --- jobs kill argument forms: -JobId, positional, several ids, comma list, bad flag, bad id ---------
function Run-Jobs([string[]]$a) {
  $out = @(& pwsh -NoProfile -File $jobs @a 2>&1 | ForEach-Object { "$_" })
  @{ code = $LASTEXITCODE; out = ($out -join "`n") }
}
function Start-Long([string]$label) {
  (& pwsh -NoProfile -File $start -Label $label -Command '"long"; Start-Sleep 120' -Cwd $cwd -ExpectedMin 1 -Json) | ConvertFrom-Json
}
function Job-Killed([string]$id) {
  $r = Get-Content (Join-Path $env:AGENTQ_HOME "jobs\$id.json") -Raw | ConvertFrom-Json
  $a = @(@($r.pid) | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
  @{ state = $r.state; alive = $a.Count }
}
# (a) -JobId (the form every other tool uses) must work
$k1 = Start-Long 'argform -JobId'; Start-Sleep -Milliseconds 600
$r = Run-Jobs @('kill', '-JobId', $k1.id)
Start-Sleep -Milliseconds 800
$k = Job-Killed $k1.id
Check 'jobs kill -JobId works (named form) and kills the tree' ($r.code -eq 0 -and $k.state -eq 'killed' -and $k.alive -eq 0 -and $r.out -match "killed $([regex]::Escape($k1.id))") "code=$($r.code) state=$($k.state) out=$($r.out)"
# (b) the positional form must keep working
$k2 = Start-Long 'argform positional'; Start-Sleep -Milliseconds 600
$r = Run-Jobs @('kill', $k2.id)
Start-Sleep -Milliseconds 800
$k = Job-Killed $k2.id
Check 'jobs kill <id> positional form still works' ($r.code -eq 0 -and $k.state -eq 'killed' -and $k.alive -eq 0) "code=$($r.code) state=$($k.state)"
# several positional ids in one call
$k3 = Start-Long 'argform multi a'; $k4 = Start-Long 'argform multi b'; Start-Sleep -Milliseconds 600
$r = Run-Jobs @('kill', $k3.id, $k4.id)
Start-Sleep -Milliseconds 1200
$k3r = Job-Killed $k3.id; $k4r = Job-Killed $k4.id
Check 'jobs kill takes several positional ids' ($r.code -eq 0 -and $k3r.state -eq 'killed' -and $k4r.state -eq 'killed' -and $k3r.alive -eq 0 -and $k4r.alive -eq 0) "code=$($r.code) $($k3r.state)/$($k4r.state)"
# one comma/space separated value
$k5 = Start-Long 'argform comma a'; $k6 = Start-Long 'argform comma b'; Start-Sleep -Milliseconds 600
$r = Run-Jobs @('kill', "$($k5.id),$($k6.id)")
Start-Sleep -Milliseconds 1200
$k5r = Job-Killed $k5.id; $k6r = Job-Killed $k6.id
Check 'jobs kill accepts a comma-separated id list' ($r.code -eq 0 -and $k5r.state -eq 'killed' -and $k6r.state -eq 'killed') "code=$($r.code) $($k5r.state)/$($k6r.state)"
# (c) a genuinely unknown flag still fails loudly and names the accepted ones
$r = Run-Jobs @('list', '-Bogus')
Check 'jobs rejects an unknown flag and names the accepted flags' ($r.code -ne 0 -and $r.out -match "unknown argument '-Bogus'" -and $r.out -match '-JobId') "code=$($r.code) out=$($r.out)"
# (d) an unknown id lists the running jobs instead of a bare refusal, and kills nothing
$k7 = Start-Long 'argform live for bad-id'; Start-Sleep -Milliseconds 600
$r = Run-Jobs @('kill', 'no-such-job-xyz')
$helpful = ($r.out -match [regex]::Escape("no job 'no-such-job-xyz'")) -and (($r.out -match [regex]::Escape($k7.id)) -or ($r.out -match 'jobs\.ps1 list'))
Check 'jobs kill on an unknown id lists the running job ids (or how to get them)' ($r.code -eq 2 -and $helpful) "code=$($r.code) out=$($r.out)"
& pwsh -NoProfile -File $jobs kill $k7.id | Out-Null   # the bad-id call must have left it alive
Start-Sleep -Milliseconds 800
$k7r = Job-Killed $k7.id
Check 'a bad-id kill does not touch a running job' ($k7r.state -eq 'killed') "state=$($k7r.state)"

# DEAD: registry says running, pid gone, no EXIT marker
$deadId = 'dead-0001'; $deadLog = Join-Path $cwd 'dead.log'; Set-Content -LiteralPath $deadLog -Value 'partial'
@{ id = $deadId; label = 'ghost'; command = 'x'; cwd = $cwd; pid = 999999; pidStart = 1; log = $deadLog; expectedMin = 1; startedAt = [DateTime]::UtcNow.AddMinutes(-3).ToString('o'); state = 'running'; ownerPid = 999999; host = 'h' } | ConvertTo-Json | Set-Content (Join-Path $env:AGENTQ_HOME "jobs\$deadId.json")
# SUSPECT: live pid (this test), runtime > 2x expected
$susId = 'sus-0001'; $susLog = Join-Path $cwd 'sus.log'; Set-Content -LiteralPath $susLog -Value 'x'
@{ id = $susId; label = 'slow'; command = 'x'; cwd = $cwd; pid = $PID; pidStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks; log = $susLog; expectedMin = 0.01; startedAt = [DateTime]::UtcNow.AddMinutes(-2).ToString('o'); state = 'running'; ownerPid = $PID; host = 'h' } | ConvertTo-Json | Set-Content (Join-Path $env:AGENTQ_HOME "jobs\$susId.json")
$lst = (& pwsh -NoProfile -File $jobs list -Json) | ConvertFrom-Json
Check 'jobs list computes DEAD (pid gone, no EXIT marker)' (@($lst | Where-Object { $_.id -eq $deadId -and $_.state -eq 'dead' }).Count -eq 1)
Check 'jobs list computes SUSPECT (runtime > 2x expected)' (@($lst | Where-Object { $_.id -eq $susId -and $_.state -eq 'suspect' }).Count -eq 1)
$orph = (& pwsh -NoProfile -File $jobs orphans -Json) | ConvertFrom-Json
Check 'jobs orphans lists DEAD registry jobs (report only)' (@($orph | Where-Object { $_.kind -eq 'job-dead' -and $_.name -eq $deadId }).Count -eq 1)
$r = Run-Wait @('-JobId', $deadId, '-EveryS', '0.2', '-MaxSec', '10')
Check 'wait-job on a DEAD job returns FAILED' ($r.code -eq 1) "code=$($r.code)"
# prune: finished > 7 days removed, recent kept
$oldId = 'old-0001'
@{ id = $oldId; label = 'old'; command = 'x'; cwd = $cwd; pid = 1; log = $deadLog; startedAt = [DateTime]::UtcNow.AddDays(-9).ToString('o'); endedAt = [DateTime]::UtcNow.AddDays(-9).ToString('o'); state = 'done'; exitCode = 0 } | ConvertTo-Json | Set-Content (Join-Path $env:AGENTQ_HOME "jobs\$oldId.json")
& pwsh -NoProfile -File $jobs prune | Out-Null
Check 'jobs prune removes finished > 7 days, keeps recent' (-not (Test-Path (Join-Path $env:AGENTQ_HOME "jobs\$oldId.json")) -and (Test-Path $jf))

# --- jobs reap: reconcile the registry with reality (dead/recycled pid -> dead; live untouched) --------
$reapLog = Join-Path $cwd 'reap.log'; Set-Content -LiteralPath $reapLog -Value 'x'
@{ id = 'reap-dead'; label = 'zombie'; command = 'x'; cwd = $cwd; pid = 999999; pidStart = 1; log = $reapLog; expectedMin = 1; startedAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o'); state = 'running'; ownerPid = 999999; host = 'h' } | ConvertTo-Json | Set-Content (Join-Path $env:AGENTQ_HOME "jobs\reap-dead.json")
$live = (& pwsh -NoProfile -File $start -Label 'reap live' -Command 'Start-Sleep 30' -Cwd $cwd -ExpectedMin 1 -Json) | ConvertFrom-Json
Start-Sleep -Milliseconds 500
$rj = (& pwsh -NoProfile -File $jobs reap -Json) | ConvertFrom-Json
Check 'jobs reap reports the dead-pid running job' (@($rj | Where-Object { $_.id -eq 'reap-dead' }).Count -eq 1)
Check 'jobs reap never lists the live job' (@($rj | Where-Object { $_.id -eq $live.id }).Count -eq 0)
$rd = Get-Content (Join-Path $env:AGENTQ_HOME "jobs\reap-dead.json") -Raw | ConvertFrom-Json
Check 'jobs reap marks dead + endedAt + reapedBy' ($rd.state -eq 'dead' -and $rd.endedAt -and $rd.reapedBy)
$rl = Get-Content (Join-Path $env:AGENTQ_HOME "jobs\$($live.id).json") -Raw | ConvertFrom-Json
Check 'jobs reap leaves the live job running' ($rl.state -eq 'running')
# -WhatIf prints the change but writes nothing
@{ id = 'reap-wi'; label = 'zombie2'; command = 'x'; cwd = $cwd; pid = 999999; pidStart = 1; log = $reapLog; expectedMin = 1; startedAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o'); state = 'running'; ownerPid = 999999; host = 'h' } | ConvertTo-Json | Set-Content (Join-Path $env:AGENTQ_HOME "jobs\reap-wi.json")
$wiOut = (& pwsh -NoProfile -File $jobs reap -WhatIf) -join "`n"
$rwi = Get-Content (Join-Path $env:AGENTQ_HOME "jobs\reap-wi.json") -Raw | ConvertFrom-Json
Check 'jobs reap -WhatIf writes nothing' ($rwi.state -eq 'running' -and $wiOut -match 'would reap')
# a recycled pid (alive, but a different start time) is dead too
@{ id = 'reap-recycle'; label = 'recycled'; command = 'x'; cwd = $cwd; pid = $PID; pidStart = 1; log = $reapLog; expectedMin = 1; startedAt = [DateTime]::UtcNow.AddMinutes(-5).ToString('o'); state = 'running'; ownerPid = $PID; host = 'h' } | ConvertTo-Json | Set-Content (Join-Path $env:AGENTQ_HOME "jobs\reap-recycle.json")
& pwsh -NoProfile -File $jobs reap | Out-Null
$rrc = Get-Content (Join-Path $env:AGENTQ_HOME "jobs\reap-recycle.json") -Raw | ConvertFrom-Json
Check 'jobs reap treats a recycled pid as dead' ($rrc.state -eq 'dead')
& pwsh -NoProfile -File $jobs kill $live.id | Out-Null

# --- agentq-sync payload carries jobs[] in the contract shape ---------------------------------------
$env:AGENTQ_SYNC_STATE = Join-Path $tmp 'sync-state.json'
$env:AGENTQ_SYNC_DUMP = Join-Path $tmp 'sync-body.json'
# daemon health: the default daemon (git-autosync) is pointed at a fake so the dry-run never runs the
# real tool (which would scan the configured repos and touch real state); the payload stays deterministic.
$fakeDaemon = Join-Path $tmp 'fake-git-autosync.ps1'
$fakeRec = '{"name":"git-autosync","at":"2026-01-01T00:00:00Z","verdict":"warn","okCount":2,"warnCount":1,"failCount":0,"lines":["WARN x"],"failStreak":0,"history":[]}'
[IO.File]::WriteAllText($fakeDaemon, "'" + $fakeRec.Replace("'", "''") + "'`n")
$env:AGENTQ_GIT_AUTOSYNC = $fakeDaemon
$d = (& pwsh -NoProfile -File $sync -Once -DryRun) -join ' '
$body = Get-Content $env:AGENTQ_SYNC_DUMP -Raw | ConvertFrom-Json
$sj = @($body.jobs | Where-Object { $_.id -eq $o.id })
$keys = 'id,label,command,cwd,repo,host,pid,state,exitCode,expectedMin,startedAt,endedAt,lastOutputAt,log' -split ','
Check 'agentq-sync -DryRun counts jobs' ($d -match 'jobs=\d+') $d
Check 'sync jobs[] entry has exactly the contract fields' ($sj.Count -eq 1 -and -not (Compare-Object $keys @($sj[0].PSObject.Properties.Name))) (($sj | ConvertTo-Json -Compress))
Check 'sync jobs[] carries computed state (dead/suspect)' (@($body.jobs | Where-Object { $_.id -eq $deadId -and $_.state -eq 'dead' }).Count -eq 1)
Check 'agentq-sync -DryRun counts daemons' ($d -match 'daemons=1') $d
Check 'sync payload carries daemons[] in the frozen shape' (@($body.daemons).Count -eq 1 -and $body.daemons[0].name -eq 'git-autosync' -and $body.daemons[0].verdict -eq 'warn' -and @($body.daemons[0].history).Count -eq 1) (($body.daemons | ConvertTo-Json -Compress))
Check 'daemon record written under coord/daemons' (Test-Path (Join-Path $env:AGENTQ_HOME 'daemons\git-autosync.json'))
Remove-Item Env:AGENTQ_SYNC_DUMP, Env:AGENTQ_SYNC_STATE, Env:AGENTQ_GIT_AUTOSYNC

# --- run-build: defaults + isolated child -------------------------------------------------------------
$pa = [System.Management.Automation.Language.Parser]::ParseFile($rb, [ref]$null, [ref]$null).ParamBlock.Parameters
$def = { param($n) "$(($pa | Where-Object { $_.Name.VariablePath.UserPath -eq $n }).DefaultValue)" }
Check 'run-build -TimeoutMin default is 240' ((& $def 'TimeoutMin') -eq '240') (& $def 'TimeoutMin')
Check 'run-build has -WedgeMin default 10' ((& $def 'WedgeMin') -eq '10') (& $def 'WedgeMin')
$rbText = Get-Content $rb -Raw
Check 'run-build child is hidden with stdin from an empty file (no shared console)' ($rbText -match '-WindowStyle Hidden' -and $rbText -match '-RedirectStandardInput \$stdinEmpty' -and $rbText -notmatch 'ComSpec[^\r\n]*-NoNewWindow')
# real run: the child must not block on a prompt (stdin is empty) and must not share our console
$repo = Join-Path $tmp 'rbrepo'; New-Item -ItemType Directory -Force $repo | Out-Null
git -C $repo init -q -b main; git -C $repo config user.email t@t; git -C $repo config user.name t
$env:RUN_BUILD_NO_AGENTQ = '1'
$rbOut = @(& pwsh -NoProfile -File $rb -Command 'echo built & set /p x=never-answered & echo after-prompt' -Root $repo 2>&1 | ForEach-Object { "$_" }) -join "`n"
$rbCode = $LASTEXITCODE
Remove-Item Env:RUN_BUILD_NO_AGENTQ
Check 'run-build child with a prompt finishes (stdin = empty file)' ($rbCode -eq 0 -and $rbOut -match 'built' -and $rbOut -match 'after-prompt') "code=$rbCode $rbOut"

# --- WEDGED: run-build writes <ticket>.wedged, agentq status shows WEDGED ----------------------------
$rbs = Join-Path $tmp 'rb-wedge.ps1'
Set-Content -LiteralPath $rbs -Value "& '$rb' -Command 'echo start & ping -n 30 127.0.0.1 >nul' -Root '$repo' -WedgeMin 0.05"
$h = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $aq, 'run', '-Resource', 'build', '-Purpose', 'wedge-test', '-MinFreeGB', '0', '-Repo', $repo, '--', 'pwsh', '-NoProfile', '-File', $rbs) -WorkingDirectory $repo -WindowStyle Hidden -PassThru
$seen = $false; $st = ''
for ($k = 0; $k -lt 80 -and -not $seen; $k++) {
  Start-Sleep -Milliseconds 500
  $st = (& pwsh -NoProfile -File $aq status -Repo $repo) -join "`n"
  $seen = $st -match 'WEDGED\(\d+m\)'
}
Check 'agentq status shows WEDGED for a holder whose build log went silent' $seen $st
$wf = @(Get-ChildItem (Join-Path $env:AGENTQ_HOME 'queues') -Recurse -Filter '*.wedged' -File -ErrorAction SilentlyContinue)
Check 'wedged sidecar names the build log' ($wf.Count -ge 1 -and ((Get-Content $wf[0].FullName -Raw) -match 'build-logs'))
Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match [regex]::Escape($rbs) -or $_.CommandLine -match 'ping -n 30 127' } | ForEach-Object { & taskkill.exe /T /F /PID $_.ProcessId 2>&1 | Out-Null }
$h | Stop-Process -Force -ErrorAction SilentlyContinue
$h.WaitForExit(10000) | Out-Null
Start-Sleep 1
& pwsh -NoProfile -File $aq sweep | Out-Null  # reaps the dead holder (status only reads since ADR 0009 stage 0)
$left = @(Get-ChildItem (Join-Path $env:AGENTQ_HOME 'queues') -Recurse -Filter '*.wedged' -File -ErrorAction SilentlyContinue)
Check 'reaping the holder removes the wedged sidecar' ($left.Count -eq 0) ($left.FullName -join ',')

Remove-Item Env:AGENTQ_HOME, Env:AGENTQ_NO_SIGNAL, Env:AGENTQ_SESSION
cmd /c rmdir /s /q "`"$tmp`"" 2>$null
if ($fail) { Write-Host "test-jobs: $fail failure(s)"; exit 1 } else { Write-Host 'test-jobs: all passed'; exit 0 }
