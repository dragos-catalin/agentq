<#
  agentq prewarm - the verb, the -All generalisation, and the hint at first contact.

  Three things are being asserted, and each of them is a way the feature could be useless while looking
  fine:

    * the verb reaches the tool AND carries its knobs (`-ActivityMin` that is parsed but not forwarded
      is a flag that silently does nothing);
    * `-All` really ticks every registered workspace, and one failing workspace still lets the others
      run while the process reports the failure (an aggregate that returns 0 after a failure is worse
      than no aggregate);
    * the hint speaks ONLY for a suspended workspace, and only once per TTL - a hint that fires when
      everything is healthy teaches agents to skip that part of the output;
    * the hint is where the agent actually is: `since`, but also `jobs list` and `wait-job`, which is
      where cloud work is looked at just before the next submission. It must stay silent in -Json
      (a hint inside a JSON document is a parse error for every consumer) and cost nothing there.

  Every cloud call is answered by a fake gcloud that records its own argv, so "did it resume?" is
  answered by the call log rather than by the narration.
#>
$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:Pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL  $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red }
}
function Contains([string]$haystack, [string]$needle) { return "$haystack".Contains($needle) }

$agentq = Join-Path $PSScriptRoot '..\bin\agentq.ps1'
if (-not (Test-Path -LiteralPath $agentq)) { Write-Host "agentq.ps1 not found at $agentq" -ForegroundColor Red; exit 2 }
$agentq = (Resolve-Path -LiteralPath $agentq).Path

$tmp = Join-Path ([IO.Path]::GetTempPath()) "prewarm-verb-test-$(Get-Random)"
$coord = Join-Path $tmp 'coord'
$null = New-Item -ItemType Directory -Force -Path (Join-Path $coord 'prewarm')
$cfgPath = Join-Path $tmp 'agentq-config.json'
@{
  # 'lonely' is registered but no repo maps to it: a tick for it has no activity signal, so -All must
  # skip it rather than warm it on whatever -Repo says (the defect found live on 2026-11-25).
  cloudRegistry   = @{ 'vitals-win' = @{ project = 'p'; zone = 'z' }; 'codai' = @{ project = 'p'; zone = 'z' }
                       'lonely' = @{ project = 'p'; zone = 'z' } }
  cloudWorkspaces = @{ 'vitals' = 'vitals-win'; 'codai' = 'codai' }
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cfgPath -Encoding utf8

# A repo the mapping knows ('vitals') and one it does not ('unmapped'), each with a real .git so
# Get-RepoInfo resolves them by path - the hint must be silent for the second one.
$repoKnown = Join-Path $tmp 'vitals'
$repoUnknown = Join-Path $tmp 'unmapped'
foreach ($r in @($repoKnown, $repoUnknown)) {
  $null = New-Item -ItemType Directory -Force -Path $r
  & git -C $r init -q -b main 2>&1 | Out-Null
}

# The fake answers describe from FAKE_STATE_<vm> and fails resume for FAKE_RESUME_FAIL, so a per
# workspace behaviour is expressible. Anything but describe/resume is logged and then fails loudly.
$fake = Join-Path $tmp 'fake-gcloud.ps1'
@'
$log = $env:FAKE_GCLOUD_LOG
Add-Content -LiteralPath $log -Value (($args -join ' '))
$verb = "$($args[2])"
$vm = "$($args[3])"
$state = [Environment]::GetEnvironmentVariable("FAKE_STATE_" + ($vm -replace '[^A-Za-z0-9]', '_'))
switch ($verb) {
    'describe' { if ($state) { $state } else { 'RUNNING' }; exit 0 }
    'resume' { if ($env:FAKE_RESUME_FAIL -eq $vm) { exit 1 }; exit 0 }
    default { exit 0 }
}
'@ | Set-Content -LiteralPath $fake -Encoding utf8

$callLog = Join-Path $tmp 'gcloud-calls.txt'
$journal = Join-Path $coord 'journal.jsonl'
$cacheFile = Join-Path $coord 'prewarm\vmstate-vitals-win.json'
$env:FAKE_GCLOUD_LOG = $callLog
$env:AGENTQ_CONFIG = $cfgPath
$env:AGENTQ_HOME = $coord
$env:AGENTQ_GCLOUD = $fake
$env:AGENTQ_NO_ADMISSION = '1'
$env:AGENTQ_NO_AGENT_LIMIT = '1'
$env:FAKE_STATE_ws_vitals_win = 'SUSPENDED'
$env:FAKE_STATE_ws_codai = 'SUSPENDED'
$env:FAKE_STATE_ws_lonely = 'SUSPENDED'
$env:FAKE_RESUME_FAIL = ''

function Reset-State {
  Remove-Item -LiteralPath $callLog -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $journal -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $cacheFile -ErrorAction SilentlyContinue
  $script:Calls = ''
}
# The hint reads the file the scheduled tick writes and makes NO cloud call of its own, because it runs
# inside `agentq since` - the first command of a task. So a test that wants a hint writes the record, and a
# test that wants silence ages it or removes it. An optional age is how the 30-minute window is exercised.
function Set-PrewarmCache([string]$status, [int]$ageSec = 0, [string]$ws = 'vitals-win') {
  $f = Join-Path $coord "prewarm\vmstate-$ws.json"
  $d = Split-Path -Parent $f
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  $at = [int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $ageSec
  [IO.File]::WriteAllText($f, (@{ atSec = $at; status = $status } | ConvertTo-Json -Compress))
}
function Journal([string]$repo, [int]$minutesAgo = 2) {
  $line = @{ ts = [DateTime]::UtcNow.AddMinutes(-$minutesAgo).ToString('o'); event = 'start'; repo = $repo; resource = "build:$repo" } | ConvertTo-Json -Compress
  Add-Content -LiteralPath $journal -Value $line -Encoding utf8
}
# A prewarm tick needs something to warm for: without journal activity every tick is a no-op, which is
# exactly what keeps the schedule free of cost - so the tests that expect a resume must write activity.
function Active([string]$repo = 'vitals') { Journal $repo }
function Invoke-Agentq([string[]]$extra) {
  # No flags before the verb: agentq.ps1:225 only reads a verb when argv[0] does not start with '-', so
  # `-Root X prewarm` parses as `status` plus an unknown argument. The fakes therefore travel in the
  # ENVIRONMENT (AGENTQ_HOME / AGENTQ_CONFIG / AGENTQ_GCLOUD, set above) and every check below is a real
  # call through the real verb. The first draft injected nothing, so it reached the real gcloud and really
  # resumed ws-vitals-win on codai-training at 22:02:48Z (its record is in that run's resumes.jsonl). A test
  # that is able to start a real VM is a test that costs money.
  $argv = @('-NoProfile', '-File', $agentq) + $extra
  $out = & pwsh @argv 2>&1 | Out-String
  $script:Calls = if (Test-Path -LiteralPath $callLog) { (Get-Content -LiteralPath $callLog -Raw) } else { '' }
  return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
}
function Resumes([string]$vm) { return @($script:Calls -split "`n" | Where-Object { $_ -match "resume $vm" }).Count }

Write-Host 'agentq prewarm (verb, -All, hint)' -ForegroundColor Cyan

# 1. Discoverability: a verb an agent cannot find is a verb that does not exist.
$r = Invoke-Agentq @('help', 'prewarm')
Check 'help prewarm exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)"
Check 'help prewarm documents -All' (Contains $r.Out '-All')
Check 'help prewarm shows the -- split' ($r.Exit -eq 0)

# 2. The verb reaches the tool and forwards a knob. -ActivityMin 42 must appear in the tool's own
#    narration; if it is parsed but not forwarded the child keeps its default of 10.
Reset-State
Active
$r = Invoke-Agentq @('prewarm', '-Ws', 'vitals-win', '-ActivityMin', '42')
Check 'the verb runs the tool' ($r.Exit -eq 0) "exit=$($r.Exit); out=$($r.Out)"
Check 'the verb forwards -ActivityMin' (Contains $r.Out 'in the last 42 min') "out=$($r.Out)"
Check 'the verb forwarded the workspace' (Contains $script:Calls 'describe ws-vitals-win')
Check 'the verb resumed it' ((Resumes 'ws-vitals-win') -eq 1)

# 3. -Off is the documented stop, and it must win over everything else.
Reset-State
Active
$r = Invoke-Agentq @('prewarm', '-Ws', 'vitals-win', '-Off')
Check 'the verb honours -Off' (($r.Exit -eq 0) -and (Contains $r.Out 'disabled'))
Check '-Off measures and resumes nothing' (-not (Contains $script:Calls 'describe'))

# 4. -Report is the read-only view an owner reads to price the feature: it must print the report and
#    touch no machine. A report that measured a VM to write its own summary would be a read that only
#    works when gcloud does, and it would leave a cloud call in the log of every report run.
Reset-State
$r = Invoke-Agentq @('prewarm', '-Report')
Check '-Report exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)"
Check '-Report prints the report' (Contains $r.Out 'prewarm report')
Check '-Report costs no cloud call' (-not (Contains $script:Calls 'describe')) "calls=$($script:Calls)"

# 4. -All covers every registered workspace, not only the repo this happens to be.
Reset-State
Active 'vitals'
Active 'codai'
$r = Invoke-Agentq @('prewarm', '-All')
Check '-All exits 0' ($r.Exit -eq 0) "exit=$($r.Exit)"
Check '-All describes both workspaces' ((Contains $script:Calls 'describe ws-vitals-win') -and (Contains $script:Calls 'describe ws-codai')) "calls=$($script:Calls)"
Check '-All resumed both' (((Resumes 'ws-vitals-win') -eq 1) -and ((Resumes 'ws-codai') -eq 1))
Check '-All reports the count' (Contains $r.Out '2 of 3 workspace(s) ticked') "out=$($r.Out)"
Check '-All names the tick as a fan-out, not as one repo' ((Contains $r.Out 'tick all') -and (-not (Contains $r.Out 'repo:vitals'))) "out=$($r.Out)"
Check '-All skips the workspace no repo maps to' (Contains $r.Out 'skip ws-lonely') "out=$($r.Out)"
Check 'the skip names its reason' (Contains $r.Out 'no repo maps to it in cloudWorkspaces')
# The money assertion: a skipped workspace is never even measured, so it can never be woken.
Check '-All never touches the unmapped workspace' (-not (Contains $script:Calls 'ws-lonely')) "calls=$($script:Calls)"
Check 'the summary lists the skip' (Contains $r.Out 'skipped lonely (no mapped repo)') "out=$($r.Out)"
Check '-All touches nothing but describe/resume' (@($script:Calls -split "`n" | Where-Object { $_.Trim() -and ($_ -notmatch ' (describe|resume) ') }).Count -eq 0) "calls=$($script:Calls)"

# 5. One failing workspace must not stop the others, and must not be hidden by the aggregate.
Reset-State
Active 'vitals'
Active 'codai'
$env:FAKE_RESUME_FAIL = 'ws-codai'
$r = Invoke-Agentq @('prewarm', '-All')
$env:FAKE_RESUME_FAIL = ''
Check '-All reports failure' ($r.Exit -eq 1) "exit=$($r.Exit)"
Check '-All still ticked the healthy workspace' ((Resumes 'ws-vitals-win') -eq 1)
Check '-All attempted the failing one too' ((Resumes 'ws-codai') -eq 1)
Check 'the failure is named in the output' (Contains $r.Out 'resume failed')

# 6. Without -Ws the verb names the repo it was pointed at, so a bare call acts for this workspace.
Reset-State
Active
$r = Invoke-Agentq @('prewarm', '-Repo', $repoKnown)
Check 'the repo mapping chooses the workspace' ((Contains $script:Calls 'describe ws-vitals-win') -and (-not (Contains $script:Calls 'ws-codai'))) "calls=$($script:Calls)"

# 7. The hint: only a suspended workspace, only for a mapped repo, and only from a FRESH cache record.
#    Measured 2026-11-25: with a live describe on this path one suite run took 6 minutes instead of 52
#    seconds, so the hot path is now the file read and nothing else.
Reset-State
Set-PrewarmCache 'SUSPENDED'
$atBefore = [int64](Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json).atSec
$r = Invoke-Agentq @('since', '-Repo', $repoKnown)
Check 'the hint fires for a suspended workspace' (Contains $r.Out 'is SUSPENDED') "out=$($r.Out)"
Check 'the hint names the workspace and the repo' ((Contains $r.Out 'ws-vitals-win') -and (Contains $r.Out 'vitals runs there'))
Check 'the hint says how to warm it' (Contains $r.Out 'agentq prewarm -Ws vitals-win')
Check 'the hint reads the cache without rewriting it' ([int64](Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json).atSec -eq $atBefore)

# 7b. The healthy path costs nothing: the hint spends no cloud call, and the CACHE - not a probe - decides
#     what it says. Flipping the fake to RUNNING while the record still says SUSPENDED is what makes this
#     non-vacuous: a hint that measured would go quiet here.
$env:FAKE_STATE_ws_vitals_win = 'RUNNING'
$callsBefore = $script:Calls
$r = Invoke-Agentq @('since', '-Repo', $repoKnown)
Check 'the hint spends no cloud call' ($script:Calls -eq $callsBefore) "before=$callsBefore after=$($script:Calls)"
Check 'the cache is what is reported' (Contains $r.Out 'is SUSPENDED')

# 7c. The cache decides the other way too: RUNNING is silent.
Set-PrewarmCache 'RUNNING'
$r = Invoke-Agentq @('since', '-Repo', $repoKnown)
Check 'nothing is said for a running workspace' (-not (Contains $r.Out 'SUSPENDED')) "out=$($r.Out)"

# 7d. No cache is unknown, and unknown is silent: the hint must never guess, and must not fill the gap with
#     a probe even when the VM really is suspended.
Reset-State
$env:FAKE_STATE_ws_vitals_win = 'SUSPENDED'
$r = Invoke-Agentq @('since', '-Repo', $repoKnown)
Check 'a missing cache says nothing' (-not (Contains $r.Out 'SUSPENDED')) "out=$($r.Out)"
Check 'a missing cache is not filled in by the hint' (-not (Test-Path -LiteralPath $cacheFile))

# 7e. A record older than the hint's 30-minute window is unknown too - the tick refreshes it every 20
#     minutes, so anything older than that is not evidence, it is a leftover.
Set-PrewarmCache 'SUSPENDED' -AgeSec 1900
$r = Invoke-Agentq @('since', '-Repo', $repoKnown)
Check 'a stale cache says nothing' (-not (Contains $r.Out 'SUSPENDED')) "out=$($r.Out)"

# 7f. An unmapped repo is silent, and costs no cloud call.
Reset-State
Set-PrewarmCache 'SUSPENDED'
$r = Invoke-Agentq @('since', '-Repo', $repoUnknown)
Check 'an unmapped repo gets no hint' (-not (Contains $r.Out 'SUSPENDED'))
Check 'an unmapped repo costs no cloud call' (-not $script:Calls)

# 7g. The two halves meet: the measurement writes the record the hint reads, so the hint's freshness comes
#     from the tick and never from a call of its own. This is the link that was MISSING when the hint first
#     went cache-only - every check above passed and the hint was silently dead, because nothing wrote the
#     file. A writer and no reader, or a reader and no writer, are the same defect.
Reset-State
Active
$env:FAKE_STATE_ws_vitals_win = 'SUSPENDED'
$null = Invoke-Agentq @('prewarm', '-Ws', 'vitals-win', '-Repo', 'vitals')
# The read is guarded on purpose: an unguarded Get-Content throws when the record is missing, which kills
# the suite and hides every check after it (measured 2026-11-25: under the tick-nowrite mutant the log
# ended at this line with no summary at all, so the gate could not tell a caught mutant from a crash).
$wrote = Test-Path -LiteralPath $cacheFile
Check 'the measurement writes the record the hint reads' $wrote
$rec = [pscustomobject]@{ status = ''; atSec = 0 }
if ($wrote) { $rec = Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json }
Check 'the record carries the measured state' ("$($rec.status)" -eq 'SUSPENDED') "status=$($rec.status)"
Check 'the record is stamped now' ([Math]::Abs([int64][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [int64]$rec.atSec) -lt 120) "atSec=$($rec.atSec)"
$r = Invoke-Agentq @('since', '-Repo', $repoKnown)
Check 'the hint reads what the measurement wrote' (Contains $r.Out 'is SUSPENDED') "out=$($r.Out)"

# 7h. A workspace the tick finds RUNNING must be recorded as well. The record is what keeps the hint quiet,
#     so a stale SUSPENDED one still inside the 30-minute window would send agents to warm a machine that is
#     already awake - which is why the writer sits above the RUNNING exit in prewarm-cloud.ps1.
Reset-State
Active
$env:FAKE_STATE_ws_vitals_win = 'RUNNING'
$null = Invoke-Agentq @('prewarm', '-Ws', 'vitals-win', '-Repo', 'vitals')
$runningRec = ''
if (Test-Path -LiteralPath $cacheFile) { $runningRec = "$((Get-Content -LiteralPath $cacheFile -Raw | ConvertFrom-Json).status)" }
Check 'the tick records a running workspace as well' ($runningRec -eq 'RUNNING') "status=$runningRec"
$r = Invoke-Agentq @('since', '-Repo', $repoKnown)
Check 'a fresh running record keeps the hint quiet' (-not (Contains $r.Out 'SUSPENDED')) "out=$($r.Out)"
$env:FAKE_STATE_ws_vitals_win = 'SUSPENDED'

# 8b. -Gcloud as a FLAG must win over the environment, because a caller that names the binary is asking
# for that one: drop the env var, pass the flag, and require the fake to receive the call.
Reset-State
$savedGcloud = $env:AGENTQ_GCLOUD
$env:AGENTQ_GCLOUD = ''
$r = Invoke-Agentq @('prewarm', '-Ws', 'vitals-win', '-Gcloud', $fake, '-Repo', 'vitals')
Check '-Gcloud on the command line reaches the fake' ($script:Calls -ne '') "exit=$($r.Exit) calls=$($script:Calls.Length)"
$env:AGENTQ_GCLOUD = $savedGcloud

# 8. A workspace no surface knows must be refused rather than guessed at.
Reset-State
Active
$r = Invoke-Agentq @('prewarm', '-Ws', 'no-such-ws')
Check 'an unknown workspace is refused' ($r.Exit -eq 1) "exit=$($r.Exit)"
Check 'the refusal explains itself' (Contains $r.Out 'cloudRegistry')
Check 'a refused workspace is never resumed' (-not (Contains $script:Calls 'resume'))

# 9. The hint at the two surfaces where an agent looks at cloud work immediately before submitting:
#    `jobs list` and `wait-job`. A hint only `since` prints is a hint nobody reads at the right moment.
$jobsScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\bin\jobs.ps1')).Path
$waitScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\bin\wait-job.ps1')).Path
$null = New-Item -ItemType Directory -Force -Path (Join-Path $coord 'jobs')
$jobLog = Join-Path $tmp 'fixture-job.log'
@('TURBO OK', 'EXIT=0', 'DONE') | Set-Content -LiteralPath $jobLog -Encoding utf8
function Write-CloudJob([string]$id, [int]$minutesAgo = 5) {
  @{
    id = $id; label = 'cloud gate (fixture)'; command = 'run the gate'; cwd = $repoKnown; repo = 'vitals'
    host = 'local'; placement = 'cloud:vitals-win'; pid = 0; pidStart = $null; state = 'done'; exitCode = 0
    expectedMin = 10
    startedAt = [DateTime]::UtcNow.AddMinutes(-$minutesAgo).ToString('o')
    endedAt = [DateTime]::UtcNow.AddMinutes(-$minutesAgo).ToString('o')
    lastOutputAt = $null; log = $jobLog
  } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $coord "jobs\$id.json") -Encoding utf8
}
function Invoke-JobsSurface([string]$script, [string[]]$extra) {
  $out = & pwsh -NoProfile -File $script @extra 2>&1 | Out-String
  $script:Calls = if (Test-Path -LiteralPath $callLog) { (Get-Content -LiteralPath $callLog -Raw) } else { '' }
  return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
}

Reset-State
Write-CloudJob 'fixture-1'
Set-PrewarmCache 'SUSPENDED'
$r = Invoke-JobsSurface $jobsScript @('list')
Check 'jobs list hints a suspended workspace' (Contains $r.Out 'is SUSPENDED') "out=$($r.Out)"
Check 'jobs list names the workspace and the repo' ((Contains $r.Out 'ws-vitals-win') -and (Contains $r.Out 'vitals runs in the cloud')) "out=$($r.Out)"
Check 'jobs list spends no cloud call on the hint' (-not (Contains $script:Calls 'describe ws-vitals-win')) "calls=$($script:Calls)"
Check 'jobs list warms nothing by itself' (-not (Contains $script:Calls 'resume')) "calls=$($script:Calls)"

# 9b. A RUNNING workspace is silent here too, and the silence must come from the record - otherwise the
#     hint would be quiet for the wrong reason (a missing mapping reads exactly like health).
Reset-State
Set-PrewarmCache 'RUNNING'
$r = Invoke-JobsSurface $jobsScript @('list')
Check 'jobs list is silent for a running workspace' (-not (Contains $r.Out 'SUSPENDED')) "out=$($r.Out)"
Check 'jobs list reports the record and does not probe for it' (-not (Contains $script:Calls 'describe ws-vitals-win')) "calls=$($script:Calls)"
Check 'the record was really there to be read' (Test-Path -LiteralPath $cacheFile)

# 9c. -Json is machine-readable output: a hint inside it is a parse error for every consumer, so the
#     suppressed branch must not even read the record.
Reset-State
Set-PrewarmCache 'SUSPENDED'
$r = Invoke-JobsSurface $jobsScript @('list', '-Json')
$parsed = $null
try { $parsed = @($r.Out | ConvertFrom-Json) } catch { $parsed = $null }
Check 'jobs list -Json stays parseable' ($null -ne $parsed) "out=$($r.Out)"
Check 'jobs list -Json carries no hint' (-not (Contains $r.Out 'SUSPENDED'))
Check 'jobs list -Json costs no cloud call' (-not $script:Calls) "calls=$($script:Calls)"

# 9d. A cloud job older than the 24 h window is hidden from the table but is still evidence that this
#     repo works in the cloud - and a cold workspace is exactly when the hint matters most.
Reset-State
Remove-Item -LiteralPath (Join-Path $coord 'jobs\fixture-1.json') -ErrorAction SilentlyContinue
Write-CloudJob 'fixture-old' 1500
Set-PrewarmCache 'SUSPENDED'
$r = Invoke-JobsSurface $jobsScript @('list')
Check 'the hidden-row case still says no jobs' (Contains $r.Out 'no jobs') "out=$($r.Out)"
Check 'a hidden cloud row still earns the hint' (Contains $r.Out 'is SUSPENDED') "out=$($r.Out)"

# 9e. wait-job: the hint is printed once, before the wait begins, and for ITS job's repository.
Reset-State
Set-PrewarmCache 'SUSPENDED'
$r = Invoke-JobsSurface $waitScript @('-JobId', 'fixture-old', '-MaxMin', '1')
Check 'wait-job still reports the finished job' ((Contains $r.Out 'DONE: job fixture-old') -and ($r.Exit -eq 0)) "exit=$($r.Exit); out=$($r.Out)"
Check 'wait-job hints the suspended workspace' (Contains $r.Out 'is SUSPENDED') "out=$($r.Out)"
Reset-State
Set-PrewarmCache 'RUNNING'
$r = Invoke-JobsSurface $waitScript @('-JobId', 'fixture-old', '-MaxMin', '1')
Check 'wait-job is silent for a running workspace' (-not (Contains $r.Out 'SUSPENDED')) "out=$($r.Out)"

# 9f. A job with no repository (a local pid wait) costs no call and says nothing.
Reset-State
Remove-Item -LiteralPath (Join-Path $coord 'jobs\fixture-old.json') -ErrorAction SilentlyContinue
Write-CloudJob 'fixture-local'
(Get-Content -LiteralPath (Join-Path $coord 'jobs\fixture-local.json') -Raw).Replace('cloud:vitals-win', 'local') |
  Set-Content -LiteralPath (Join-Path $coord 'jobs\fixture-local.json') -Encoding utf8
$r = Invoke-JobsSurface $jobsScript @('list')
Check 'a local-only registry costs no cloud call' (-not (Contains $script:Calls 'describe')) "calls=$($script:Calls)"
Check 'a local-only registry gets no hint' (-not (Contains $r.Out 'SUSPENDED')) "out=$($r.Out)"

# One temp root per run (config, fake gcloud, fake repos, call log) and this suite runs inside EVERY land
# gate and EVERY agentq install gate: measured 2026-11-26, that left 1 115 empty `prewarm-verb-test-*`
# directories in %TEMP% in 48 h. Whoever runs the suite owns cleaning it up - the stray-reaper should not
# have to know each suite's naming, and an unguarded Remove-Item would abort here under $ErrorActionPreference.
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
if ($script:Fail) { Write-Host "prewarm verb: $($script:Pass) passed, $($script:Fail) FAILED" -ForegroundColor Red; exit 1 }
Write-Host "prewarm verb: $($script:Pass) passed, 0 failed" -ForegroundColor Green
exit 0
