<#
  prewarm-cloud.ps1 - a bounded prewarm has to be provably bounded.

  The three ways this script can cost money are the three that must be tested: resuming a machine
  nobody asked for (no activity), resuming one that is already up (fighting the self-suspend), and
  resuming more times a day than it says it will. Each check below drives the real script against a
  fake gcloud that records every call it receives, so "did it resume?" is answered by the call log
  rather than by the script's own narration.
#>
$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:Pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
    else { $script:Fail++; Write-Host "  FAIL  $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red }
}
function Contains([string]$haystack, [string]$needle) { return "$haystack".Contains($needle) }

$target = Join-Path $PSScriptRoot '..\bin\prewarm-cloud.ps1'
if (-not (Test-Path -LiteralPath $target)) { Write-Host "prewarm-cloud.ps1 not found at $target" -ForegroundColor Red; exit 2 }
$target = (Resolve-Path -LiteralPath $target).Path

$tmp = Join-Path ([IO.Path]::GetTempPath()) "prewarm-test-$(Get-Random)"
$coord = Join-Path $tmp 'coord'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $coord 'prewarm')
$cfgPath = Join-Path $tmp 'agentq-config.json'
@{
    cloudRegistry   = @{ 'vitals-win' = @{ project = 'p'; zone = 'z' }; 'codai' = @{ project = 'p'; zone = 'z' } }
    cloudWorkspaces = @{ 'vitals' = 'vitals-win'; 'codai' = 'codai' }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cfgPath -Encoding utf8

# The fake gcloud records every argument list it is handed and answers describe from an env var. A
# call it does not know is logged too, so an accidental `create`/`stop`/`suspend` shows up as a check
# failure instead of as a bill.
$fake = Join-Path $tmp 'fake-gcloud.ps1'
@'
$log = $env:FAKE_GCLOUD_LOG
Add-Content -LiteralPath $log -Value ($args -join ' ')
switch ("$($args[2])") {
    'describe' { $env:FAKE_VM_STATE; exit 0 }
    'resume' { exit 0 }
    default { exit 0 }
}
'@ | Set-Content -LiteralPath $fake -Encoding utf8

$callLog = Join-Path $tmp 'gcloud-calls.txt'
$env:FAKE_GCLOUD_LOG = $callLog
$journal = Join-Path $coord 'journal.jsonl'
$resumeLog = Join-Path $coord 'prewarm\resumes.jsonl'
$kill = Join-Path $coord 'prewarm\off'

function Reset-State {
    Remove-Item -LiteralPath $callLog -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $journal -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $resumeLog -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $kill -ErrorAction SilentlyContinue
    $script:Calls = ''
}
function Journal([string]$repo, [int]$minutesAgo = 2) {
    $line = @{ ts = [DateTime]::UtcNow.AddMinutes(-$minutesAgo).ToString('o'); event = 'start'; repo = $repo; resource = "build:$repo" } | ConvertTo-Json -Compress
    Add-Content -LiteralPath $journal -Value $line -Encoding utf8
}
function Invoke-Prewarm([string[]]$extra) {
    $argv = @('-NoProfile', '-File', $target, '-Root', $coord, '-ConfigPath', $cfgPath, '-Gcloud', $fake) + $extra
    $out = & pwsh @argv 2>&1 | Out-String
    $script:Calls = if (Test-Path -LiteralPath $callLog) { (Get-Content -LiteralPath $callLog -Raw) } else { '' }
    return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
}
function ResumesRecorded { if (Test-Path -LiteralPath $resumeLog) { return @(Get-Content -LiteralPath $resumeLog).Count } return 0 }
function LastRecord { $lines = @(Get-Content -LiteralPath $resumeLog); return "$($lines[-1])" }

Write-Host 'prewarm-cloud.ps1' -ForegroundColor Cyan

# 1. The kill switch, and the only file a user is expected to create.
Reset-State
$null = New-Item -ItemType File -Force -Path $kill
$env:FAKE_VM_STATE = 'SUSPENDED'
Journal 'vitals'
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED')
Check 'kill switch file stops it' (($r.Exit -eq 0) -and (Contains $r.Out 'disabled'))
Check 'kill switch resumes nothing' (-not (Contains $script:Calls 'resume'))
Check 'kill switch writes no resume record' ((ResumesRecorded) -eq 0)

# 2. A running machine is left to the idle self-suspend.
Reset-State
Journal 'vitals'
$r = Invoke-Prewarm @('-VmState', 'RUNNING')
Check 'a running workspace is a no-op' (($r.Exit -eq 0) -and (Contains $r.Out 'already running'))
Check 'a running workspace is not resumed' (-not (Contains $script:Calls 'resume'))

# 3. Any state that is not SUSPENDED is somebody else's decision.
Reset-State
Journal 'vitals'
$r = Invoke-Prewarm @('-VmState', 'TERMINATED')
Check 'a terminated workspace is not touched' (($r.Exit -eq 0) -and (Contains $r.Out 'not mine to change') -and (-not (Contains $script:Calls 'resume')))

# 4. The activity gate: no journal entries, no resume - and no noise in the log either.
Reset-State
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED')
Check 'no activity is a no-op' (($r.Exit -eq 0) -and (Contains $r.Out 'nothing to warm for'))
Check 'no activity resumes nothing' (-not (Contains $script:Calls 'resume'))
Check 'a no-op writes no resume record' ((ResumesRecorded) -eq 0)

# 4b. An unattended tick has no terminal, so -Log is the only place a no-op is visible.
Reset-State
$tickLog = Join-Path $tmp 'ticks.log'
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED', '-TickLog', $tickLog)
Check 'a no-op tick is logged where an operator will look' ((Test-Path -LiteralPath $tickLog) -and ((Get-Content -LiteralPath $tickLog -Raw) -match 'nothing to warm for'))
$bigLog = Join-Path $tmp 'big.log'
Set-Content -LiteralPath $bigLog -Value (('x' * 300) * 2000) -Encoding ascii
$before = (Get-Item -LiteralPath $bigLog).Length
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED', '-TickLog', $bigLog)
Check 'the tick log is trimmed rather than unbounded' (((Get-Item -LiteralPath $bigLog).Length -lt $before) -and ((Get-Item -LiteralPath $bigLog).Length -gt 0))

# 5. Activity on a repo this workspace serves, and only that.
Reset-State
Journal 'codai'
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED')
Check 'activity on another repo does not warm this one' (($r.Exit -eq 0) -and (-not (Contains $script:Calls 'resume')) -and (Contains $r.Out 'nothing to warm for'))

Reset-State
Journal 'vitals'
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED')
Check 'recent activity resumes the workspace' (($r.Exit -eq 0) -and (Contains $script:Calls 'resume ws-vitals-win'))
Check 'the resume is recorded' (((ResumesRecorded) -eq 1) -and (Contains (LastRecord) '"action":"resume"'))
Check 'nothing but describe and resume was ever called' (-not ($script:Calls -match 'instances (create|stop|suspend|reset)'))

# 6. An old entry is not activity.
Reset-State
Journal 'vitals' 120
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED')
Check 'stale activity does not warm' (($r.Exit -eq 0) -and (-not (Contains $script:Calls 'resume')))

# 7. The daily cap, and that it says so once rather than every tick.
Reset-State
Journal 'vitals'
$stamp = [DateTime]::UtcNow.ToString('o')
1..3 | ForEach-Object { Add-Content -LiteralPath $resumeLog -Value (@{ ts = $stamp; ws = 'vitals-win'; action = 'resume'; exit = 0 } | ConvertTo-Json -Compress) -Encoding utf8 }
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED', '-MaxResumesPerDay', '3')
Check 'the daily cap stops it' (($r.Exit -eq 0) -and (Contains $r.Out 'daily cap reached') -and (-not (Contains $script:Calls 'resume')))
Check 'the cap is recorded once' (((ResumesRecorded) -eq 4) -and (Contains (LastRecord) '"action":"cap"'))
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED', '-MaxResumesPerDay', '3')
Check 'a second capped tick records nothing more' ((ResumesRecorded) -eq 4)

# 8. A workspace with no project and zone is refused rather than guessed.
Reset-State
$r = Invoke-Prewarm @('-Ws', 'ghost-ws', '-VmState', 'SUSPENDED')
Check 'an unknown workspace is refused' (($r.Exit -eq 1) -and (Contains $r.Out 'not in cloudRegistry'))

# 9. The workspace is resolved from the repository when -Ws is not given.
Reset-State
Journal 'vitals'
$r = Invoke-Prewarm @('-Repo', 'vitals', '-VmState', 'SUSPENDED')
Check 'the workspace comes from the repo mapping' (-not (Contains $r.Out 'pass -Ws'))

# 10. The measurement path itself, which every check above skipped by passing -VmState. That override
# is why an unquoted `--format=value(status)` survived the suite: argument mode parses the parenthesis
# as a subexpression, the describe call never reaches gcloud, and the tick dies before it writes a
# line - so the first real scheduled run left an empty log while the task reported success (2026-11-25).
Reset-State
Journal 'vitals'
$env:FAKE_VM_STATE = 'RUNNING'
$r = Invoke-Prewarm @()
Check 'the state comes from gcloud when -VmState is not given' (Contains $r.Out 'is RUNNING')
Check 'the describe call carries the format argument intact' (Contains $script:Calls '--format value(status)')
Check 'a measured RUNNING workspace is not resumed' (-not (Contains $script:Calls 'resume'))
Reset-State
Journal 'vitals'
$env:FAKE_VM_STATE = 'SUSPENDED'
$r = Invoke-Prewarm @()
Check 'a measured SUSPENDED workspace resumes' (Contains $script:Calls 'resume ws-vitals-win')

# 11. Silence has to mean "the task did not fire". A tick that starts leaves a heartbeat even when it
# then fails to measure, because the alternative is a log that looks identical either way.
Reset-State
$tickLog2 = Join-Path $tmp 'ticks2.log'
$env:FAKE_VM_STATE = ''
$r = Invoke-Prewarm @('-TickLog', $tickLog2)
Check 'an unmeasurable workspace is left alone' (($r.Exit -eq 0) -and (Contains $r.Out 'could not measure') -and (-not (Contains $script:Calls 'resume')))
Check 'a tick that fails to measure still leaves a heartbeat' ((Test-Path -LiteralPath $tickLog2) -and ((Get-Content -LiteralPath $tickLog2 -Raw) -match 'tick ws='))
$env:FAKE_VM_STATE = 'SUSPENDED'

# 12. The scheduled task has to run the copy that is installed. A task's action records a path, and a
# path recorded by hand points wherever it was typed: the registered task on this machine named the
# SOURCE checkout E:\gh\agentq\ps\bin\prewarm-cloud.ps1 (measured 2026-11-26), so every unattended tick
# ran whatever was uncommitted in the tree under edit - and a tick that runs the wrong file still writes
# a healthy-looking log, so nothing else reports it. -TaskFile is the seam that proves the guard with no
# scheduled task involved, and a task that is not registered is not a failure: nothing points at any
# copy, so there is nothing to refuse.
$elsewhere = Join-Path $tmp 'someone-elses\prewarm-cloud.ps1'
$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent $elsewhere)
'# not the tool' | Set-Content -LiteralPath $elsewhere -Encoding utf8
$r = Invoke-Prewarm @('-VerifyTask', '-TaskFile', $target)
Check 'the task guard accepts the copy it was told about' (($r.Exit -eq 0) -and (Contains $r.Out 'runs this copy'))
$r = Invoke-Prewarm @('-VerifyTask', '-TaskFile', $elsewhere)
Check 'the task guard refuses a foreign copy' (($r.Exit -eq 1) -and (Contains $r.Out 'runs a DIFFERENT copy'))
Check 'the refusal names the copy that would run' (Contains $r.Out $elsewhere)
Check 'the refusal names the one-line fix' (Contains $r.Out '-RepairTask')
$r = Invoke-Prewarm @('-VerifyTask', '-TaskName', 'aq-no-such-task-xyz')
Check 'an unregistered task is not a failure' (($r.Exit -eq 0) -and (Contains $r.Out 'not registered'))
$r = Invoke-Prewarm @('-RepairTask', '-TaskFile', $elsewhere)
Check 'a repair refuses to run from the test seam' (($r.Exit -eq 2) -and (Contains $r.Out 'cannot run from -TaskFile'))

# 12b. The window against the cadence. A window shorter than the interval between ticks cannot see work
# that begins just after the previous tick, and the interval is not always the nominal one: measured
# 2026-11-27 over 105 intervals, 10 ran past the PT20M cadence and 3 past 25 min, worst 99.8 min, every
# one of them with the machine heavily loaded. A skipped trigger is invisible in a log that only records
# the ticks that did fire, so the guard reads the trigger itself. The seam supplies the cadence, so this
# is proven without reading or rewriting this machine's real task.
$r = Invoke-Prewarm @('-VerifyTask', '-TaskFile', $target, '-TaskCadenceMin', '20')
Check 'a window at the default clears a 20 min cadence' (($r.Exit -eq 0) -and (Contains $r.Out 'window 25 min against a cadence of 00:20'))
$r = Invoke-Prewarm @('-VerifyTask', '-TaskFile', $target, '-TaskCadenceMin', '20', '-ActivityMin', '10')
Check 'a window narrower than the cadence is refused' (($r.Exit -eq 1) -and (Contains $r.Out 'TOO NARROW'))
Check 'the refusal names the number that would pass' (Contains $r.Out '-ActivityMin 25')
$r = Invoke-Prewarm @('-VerifyTask', '-TaskFile', $target, '-TaskCadenceMin', '26')
Check 'a cadence wider than the default window is refused' (($r.Exit -eq 1) -and (Contains $r.Out 'TOO NARROW'))
$r = Invoke-Prewarm @('-VerifyTask', '-TaskFile', $target, '-ActivityMin', '31', '-TaskCadenceMin', '26')
Check 'the window the refusal names passes its own cadence' (($r.Exit -eq 0) -and (Contains $r.Out 'window 31 min'))

# 12c. The self-sizing window. What the gate must cover is the interval since the machine was last
# LOOKED AT, because a round that was delayed or skipped leaves a hole no fixed window can see into.
# All three directions are asserted: an event outside the floor is still warmed when the previous round
# was further back; the same event is ignored when that round was recent (so the floor still means
# something); and a long outage is capped rather than resurrecting work nobody is waiting for.
$stampFile = Join-Path $coord 'prewarm\last-tick-vitals-win'
Reset-State
Journal 'vitals' 35
[IO.File]::WriteAllText($stampFile, [DateTime]::UtcNow.AddMinutes(-40).ToString('o'))
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED')
Check 'an event outside the floor is warmed when the previous round was further back' ((Contains $script:Calls 'resume ws-vitals-win') -and (Contains $r.Out 'extended to 41 min')) "out=$($r.Out.Trim())"
Reset-State
Journal 'vitals' 35
[IO.File]::WriteAllText($stampFile, [DateTime]::UtcNow.ToString('o'))
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED')
Check 'the same event is ignored when the previous round was recent' ((-not (Contains $script:Calls 'resume')) -and (Contains $r.Out 'nothing to warm for'))
Reset-State
Journal 'vitals' 50
[IO.File]::WriteAllText($stampFile, [DateTime]::UtcNow.AddMinutes(-90).ToString('o'))
$r = Invoke-Prewarm @('-VmState', 'SUSPENDED')
Check 'the window is capped so a long outage does not resurrect old work' ((-not (Contains $script:Calls 'resume')) -and (Contains $r.Out 'extended to 45 min'))

# 13. The doctor's own prewarm check. Everything above proves the tick is bounded; this proves the
# report a person reads agrees with the exit code a scheduler reads, in all four states. It is driven
# with -Only prewarm so it stays fast and isolated, and with AGENTQ_PREWARM_TICKLOG pointed at a
# fixture under $tmp so it never reads the machine's real coord root (a check that reads green while
# the tick is stale would be worse than no check at all). -Json is one object on stdout; the report
# lives in its `rows` array, whose `check` field names the check.
$aq = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\bin\agentq.ps1')).Path
function Invoke-DoctorPrewarm {
    $out = & pwsh -NoProfile -File $aq doctor -Only prewarm -Json 2>&1 | Out-String
    $code = $LASTEXITCODE
    $rows = $null
    $match = @("$out" -split "`r?`n" | Where-Object { $_ -match '^\{.*"rows"' })
    if ($match.Count) { try { $rows = @((ConvertFrom-Json $match[-1]).rows) } catch { $rows = $null } }
    return [pscustomobject]@{ Out = $out; Exit = $code; Rows = $rows }
}
function PrewarmRows($rows) {
    if ($null -eq $rows) { return @() }
    return @($rows | Where-Object { $_.check -eq 'prewarm' })
}
$savedTick = $env:AGENTQ_PREWARM_TICKLOG
$savedNo = $env:AGENTQ_DOCTOR_NO_PREWARM
$savedMax = $env:AGENTQ_PREWARM_MAX_AGE_MIN
try {
    # 13a. No tick log at all: there is nothing to measure, so the check must be silent and green.
    $tickMissing = Join-Path $tmp 'doctor-ticks-missing.log'
    Remove-Item -LiteralPath $tickMissing -ErrorAction SilentlyContinue
    Remove-Item Env:AGENTQ_DOCTOR_NO_PREWARM -ErrorAction SilentlyContinue
    $env:AGENTQ_PREWARM_TICKLOG = $tickMissing
    $d = Invoke-DoctorPrewarm
    $real = @(PrewarmRows $d.Rows | Where-Object { $_.kind -ne 'summary' })
    Check 'doctor prewarm: no tick log -> no row, exit 0' (($d.Exit -eq 0) -and ($real.Count -eq 0)) "exit=$($d.Exit) prewarmRows=$($real.Count)"

    # 13b. A fresh tick log: one row saying so, and the process agrees.
    $tickFresh = Join-Path $tmp 'doctor-ticks-fresh.log'
    Set-Content -LiteralPath $tickFresh -Value 'tick ok' -Encoding utf8
    [IO.File]::SetLastWriteTimeUtc($tickFresh, [DateTime]::UtcNow)
    $env:AGENTQ_PREWARM_TICKLOG = $tickFresh
    $d = Invoke-DoctorPrewarm
    $pw = @(PrewarmRows $d.Rows)
    Check 'doctor prewarm: fresh tick log -> ok row, exit 0' (($d.Exit -eq 0) -and ($pw.Count -ge 1) -and (@($pw | Where-Object { $_.status -ne 'ok' }).Count -eq 0)) "exit=$($d.Exit) statuses=$(@($pw | ForEach-Object { $_.status }) -join ',')"

    # 13c. A stale tick log: the row and the exit code both have to say so.
    $tickStale = Join-Path $tmp 'doctor-ticks-stale.log'
    Set-Content -LiteralPath $tickStale -Value 'tick ok' -Encoding utf8
    [IO.File]::SetLastWriteTimeUtc($tickStale, [DateTime]::UtcNow.AddHours(-2))
    $env:AGENTQ_PREWARM_TICKLOG = $tickStale
    $d = Invoke-DoctorPrewarm
    $pw = @(PrewarmRows $d.Rows)
    Check 'doctor prewarm: stale tick log -> fail row, exit 1' (($d.Exit -eq 1) -and ($pw.Count -ge 1) -and (@($pw | Where-Object { $_.status -ne 'fail' }).Count -eq 0)) "exit=$($d.Exit) statuses=$(@($pw | ForEach-Object { $_.status }) -join ',')"

    # 13d. The opt-out, with a fresh file present so only the switch can explain the silence.
    $env:AGENTQ_PREWARM_TICKLOG = $tickFresh
    $env:AGENTQ_DOCTOR_NO_PREWARM = '1'
    $d = Invoke-DoctorPrewarm
    $real = @(PrewarmRows $d.Rows | Where-Object { $_.kind -ne 'summary' })
    Check 'doctor prewarm: AGENTQ_DOCTOR_NO_PREWARM -> no row, exit 0' (($d.Exit -eq 0) -and ($real.Count -eq 0)) "exit=$($d.Exit) prewarmRows=$($real.Count)"
}
finally {
    if ($null -ne $savedTick) { $env:AGENTQ_PREWARM_TICKLOG = $savedTick } else { Remove-Item Env:AGENTQ_PREWARM_TICKLOG -ErrorAction SilentlyContinue }
    if ($null -ne $savedNo) { $env:AGENTQ_DOCTOR_NO_PREWARM = $savedNo } else { Remove-Item Env:AGENTQ_DOCTOR_NO_PREWARM -ErrorAction SilentlyContinue }
    if ($null -ne $savedMax) { $env:AGENTQ_PREWARM_MAX_AGE_MIN = $savedMax } else { Remove-Item Env:AGENTQ_PREWARM_MAX_AGE_MIN -ErrorAction SilentlyContinue }
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "prewarm: $script:Pass passed, $script:Fail failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
