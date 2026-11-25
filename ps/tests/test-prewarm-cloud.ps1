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

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host "prewarm: $script:Pass passed, $script:Fail failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
