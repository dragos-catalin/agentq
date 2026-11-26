# Cloud-aware run-build (devcloud DC-037 follow-up, 2026-11-26).
#
# Two defects this suite pins:
#
#   1. run-build.ps1 re-enters the queue with `agentq run -Resource <class>` and forwarded NO placement
#      flag, so a build that really delegates to the cloud still took a LOCAL `build` (cap 1) +
#      `build:machine` (cap 2) ticket, and the decision always came from the `local` default. The fix
#      forwards the caller's intent as `-Where <value>` (explicit -Where wins, else the inherited
#      AGENTQ_WHERE), and keeps the old behaviour when neither is set.
#
#   2. run-build.ps1's wedge watch marked a run WEDGED after -WedgeMin of no output. A cloud-bound run
#      does its real work on a VM and legitimately emits NO local output, so 0 output is not a wedge.
#      Measured 2026-11-26: a land pre-gate sat 10 min with 0 local output, WEDGED was written, and the
#      wrapper held its tickets for 2-4.6 h; eight such tickets jammed the machine's build lanes.
#
# Contract stated here (all four are asserted):
#   * the effective placement reaches the `agentq run` argv as `-Where`;
#   * a cloud-bound run (param `-Where cloud`, env `AGENTQ_WHERE=cloud`, or resolved-placement env
#     `AGENTQ_PLACEMENT=cloud`) does NOT get `<ticket>.wedged` written;
#   * a LOCAL run DOES, and it is CLEARED when output resumes;
#   * the default (no -Where, no env) is unchanged (still local, still wedges).
#
# It drives the REAL script and takes NO queue ticket: the `agentq run` argv is observed with a FAKE
# agentq at `$env:USERPROFILE\.copilot\bin\agentq.ps1` (recording argv, running nothing), and the wedge
# cases set RUN_BUILD_NO_AGENTQ=1 so the script goes straight to lock+run with a real child command.
# Exit 1 on any failure.
param([string]$RunBuild = (Join-Path $PSScriptRoot '..\hooks\run-build.ps1'))
$ErrorActionPreference = 'Stop'
$RunBuild = (Resolve-Path -LiteralPath $RunBuild).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aqrb-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
if ($tmp -match '\s') { Write-Host "FAIL temp path has whitespace: $tmp" -ForegroundColor Red; exit 1 }
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }

# A throwaway repo (the resource leaf IS the repo name) with a unique leaf.
$leaf = 'aqrb-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$repo = Join-Path $tmp $leaf
git init -q -b main $repo 2>$null
[IO.File]::WriteAllText("$repo\a.txt", "a`n")

# ---- helpers: the child command written once, invoked by path (no quotes in the -Command string) ----
# Prewarm: the FIRST pwsh started by this suite pays the cold-start cost (several seconds on a
# loaded box). Its CPU is the child's own startup, which the wedge watch correctly reads as work, so
# a cold first case moves its verdict several seconds later than a warm one and can fall outside the
# poll window -- the measured w1 failure (build log with no WEDGED line AND no exit line = killed
# while still waiting). Pay that cost once, here, outside every measurement.
$null = & pwsh -NoProfile -Command 'exit' 2>&1
$quiet = Join-Path $tmp 'quiet.ps1'
# A warm-up line, then 40 s of silence. Two independent reasons, both measured:
#  * the warm-up ANCHORS the silence clock. run-build starts its watch only after its init process-tree
#    sweep (0.2 s warm, 5-12.8 s under load, and on a 200-process box long enough to swallow a whole
#    25 s child: that is exactly how w1 failed on 2026-11-26 with Seen=False and NO marker at all).
#    Everything the child printed before the loop began is read on the loop's first iteration and
#    resets the clock there, so the silence is measured from a moment the watch actually observed.
#  * 40 s, not 25 s, so a slow sweep still leaves far more than -WedgeMin (3 s) of watched silence.
[IO.File]::WriteAllText($quiet, "Write-Output 'warming'`nStart-Sleep -Seconds 40`n")
$resume = Join-Path $tmp 'resume.ps1'
[IO.File]::WriteAllText($resume, @'
# TWO 25 s silence phases, not one 12 s phase. The verdict needs -WedgeMin (3 s) of silence measured
# from the moment run-build's watch starts, and that watch starts only after its init process-tree
# sweep -- measured 0.2 s warm, 5-12.8 s under load (2026-11-26). With 12 s of silence the case was a
# race against that sweep: when the sweep ran long, the child's 'resumed' line was already waiting when
# the loop began, the first iteration read it as output ('outGrew'), no marker was ever written and the
# case failed with Seen=False (measured w6, 3 runs out of 3, while the same wrapper passed standalone
# with seen=9.3 s). A second silence phase after the first 'resumed' line removes the race: whichever
# way it goes, the watch sees a full silence phase with the output still to come, and a later clearance.
Start-Sleep -Seconds 25
Write-Output 'resumed'
Start-Sleep -Seconds 25
Write-Output 'resumed2'
for ($i = 0; $i -lt 10; $i++) { Write-Output ('tick ' + $i); Start-Sleep -Milliseconds 500 }
'@)

# ---- -Plan (print and exit: no ticket, no lock, no build) ------------------------------------------
function Plan([string[]]$more) {
  $o = @(& pwsh -NoProfile -File $RunBuild -Plan -Root $repo @more 2>&1 | ForEach-Object { "$_" })
  $script:code = $LASTEXITCODE
  $o -join "`n"
}

# ---- fake agentq records the argv run-build asked `agentq run` for, and runs nothing -----------------
$up = Join-Path $tmp 'up'
New-Item -ItemType Directory -Force (Join-Path $up '.copilot\bin') | Out-Null
$fakeOut = Join-Path $tmp 'aq-args.txt'
[IO.File]::WriteAllText((Join-Path $up '.copilot\bin\agentq.ps1'), @'
if ($env:FAKE_AQ_OUT) { [IO.File]::WriteAllText($env:FAKE_AQ_OUT, ($args -join ' ')) }
exit 0
'@)
$oldUp = $env:USERPROFILE; $oldHeld = $env:AGENTQ_HELD; $oldNoAq = $env:RUN_BUILD_NO_AGENTQ
$oldWhere = $env:AGENTQ_WHERE; $oldPlace = $env:AGENTQ_PLACEMENT
$env:FAKE_AQ_OUT = $fakeOut
function Queued([string[]]$more, [string]$where = '') {
  Remove-Item -LiteralPath $fakeOut -Force -ErrorAction SilentlyContinue
  $env:USERPROFILE = $up
  Remove-Item Env:AGENTQ_HELD -ErrorAction SilentlyContinue
  Remove-Item Env:RUN_BUILD_NO_AGENTQ -ErrorAction SilentlyContinue
  Remove-Item Env:AGENTQ_PLACEMENT -ErrorAction SilentlyContinue
  if ($where) { $env:AGENTQ_WHERE = $where } else { Remove-Item Env:AGENTQ_WHERE -ErrorAction SilentlyContinue }
  $o = @(& pwsh -NoProfile -File $RunBuild -Root $repo @more 2>&1 | ForEach-Object { "$_" })
  $script:code = $LASTEXITCODE
  $env:USERPROFILE = $oldUp
  Remove-Item Env:AGENTQ_WHERE -ErrorAction SilentlyContinue
  $o -join "`n"
}
function FakeArgs { if (Test-Path -LiteralPath $fakeOut) { (Get-Content -LiteralPath $fakeOut -Raw).Trim() } else { '' } }

# ---- wedge watcher: launch run-build in a child, poll the <ticket>.wedged marker over the run --------
function Test-Wedge([string]$tag, [string]$command, [hashtable]$cfg) {
  # OWN repo per case. run-build's mutex is `Global\brivio-build-<repo path, scrubbed>`: with one
  # shared repo every case serialised on the SAME system-wide mutex as the case just killed, which
  # showed up as an empty-tail `Locked=False` run that never reached the lock (flaky w1/w3/w6/w7,
  # 9-13 PASS across runs of the same code). A per-case path gives a per-case mutex.
  $repo = Join-Path $tmp ("rb-$tag")
  if (-not (Test-Path $repo)) { git init -q -b main $repo 2>$null }
  $ticket = Join-Path $tmp "$tag.ticket"
  [IO.File]::WriteAllText($ticket, '')
  $log = Join-Path $tmp "$tag.log"
  $wrapper = Join-Path $tmp "$tag.wrap.ps1"
  $lines = @()
  $lines += '$env:RUN_BUILD_NO_AGENTQ = ''1'''
  $lines += '$env:AGENTQ_SESSION = ''caw'''
  $lines += ('$env:AGENTQ_TICKET_FILES = ''' + $ticket + '''')
  if ($cfg.EnvPlacement) { $lines += ('$env:AGENTQ_PLACEMENT = ''' + $cfg.EnvPlacement + '''') } else { $lines += 'Remove-Item Env:AGENTQ_PLACEMENT -ErrorAction SilentlyContinue' }
  if ($cfg.EnvWhere) { $lines += ('$env:AGENTQ_WHERE = ''' + $cfg.EnvWhere + '''') } else { $lines += 'Remove-Item Env:AGENTQ_WHERE -ErrorAction SilentlyContinue' }
  $par = "-Root '" + $repo + "' -Command '" + $command + "' -WedgeMin " + $cfg.WedgeMin + ' -TimeoutMin 1'
  if ($cfg.Where) { $par += (' -Where ' + $cfg.Where) }
  $lines += ('& pwsh -NoProfile -File ''' + $RunBuild + ''' ' + $par + ' *> ''' + $log + '''')
  $lines += 'exit $LASTEXITCODE'
  [IO.File]::WriteAllText($wrapper, ($lines -join "`n"))
  $marker = "$ticket.wedged"
  Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
  # Kill-on-close of the previous case can orphan a run-build child that still holds the repo lock;
  # the repo is test-owned, so clear it to keep every case independent.
  Remove-Item -LiteralPath (Join-Path $repo '.copilot-tmp\build.lock') -Force -ErrorAction SilentlyContinue
  $p = Start-Process pwsh -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrapper -PassThru -WindowStyle Hidden
  $seen = $false; $clearedAfter = $false
  $deadline = (Get-Date).AddSeconds([double]$cfg.PollSec)
  while ((Get-Date) -lt $deadline -and -not $p.HasExited) {
    if (Test-Path -LiteralPath $marker) { $seen = $true } elseif ($seen) { $clearedAfter = $true }
    Start-Sleep -Milliseconds 150
    $p.Refresh()
  }
  if (-not $p.HasExited) {
    if (-not $p.WaitForExit([int]$cfg.WaitMs)) { & taskkill /PID $p.Id /T /F 2>&1 | Out-Null }
  }
  $raw = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
  # "ran" = the wrapper reached the run section (acquired the lock), so a cloud "no WEDGED" is a real
  # suppression and not a run that exited 3 before starting.
  $locked = ($raw -match 'build lock acquired')
  $tail = if ($raw) { (($raw -split "`n" | Where-Object { $_ -match 'WEDGED|Not starting a second build|build lock acquired' } | Select-Object -Last 3) -join ' | ') } else { '(no log)' }
    # Evidence from BOTH sinks, and independently: the marker FILE is the product `agentq status` reads,
    # the console line is the DECISION run-build made, written the moment it makes it. Polling the file
    # every 150 ms made the case a measurement of the box rather than of the code -- a poll can miss a
    # marker that existed for seconds, and (see the resume fixture note) a slow init sweep can leave
    # nothing to poll at all. A decision line cannot be missed by a poll. Cloud cases get STRICTER this
    # way: a 'WEDGED: build output silent' line fails them even if the marker was never polled.
    $wedgeLine = ($raw -match 'WEDGED: build output silent')
    $clearLine = ($raw -match 'WEDGED cleared')
    [pscustomobject]@{
      Seen = ($seen -or $wedgeLine)
      ClearedAfterSeen = ($clearedAfter -or ($wedgeLine -and $clearLine))
      Locked = $locked; Tail = $tail
    }
}

try {
  # =============================== 1. -Plan shows the effective placement ==========================
  $o = Plan @('-Command', 'pnpm build')
  Check '1 Plan default: where=default and NOT cloud-bound' (($script:code -eq 0) -and ($o -match 'where=default(\s|$)') -and (-not ($o -match 'cloud-bound'))) $o
  $o = Plan @('-Command', 'pnpm build', '-Where', 'cloud')
  Check '1 Plan -Where cloud: where=cloud and cloud-bound' (($o -match 'where=cloud(\s|$)') -and ($o -match 'cloud-bound: wedge watch disabled')) $o
  $o = Plan @('-Command', 'pnpm build', '-Where', 'local')
  Check '1 Plan -Where local: where=local, NOT cloud-bound' (($o -match 'where=local(\s|$)') -and (-not ($o -match 'cloud-bound'))) $o
  $env:AGENTQ_WHERE = 'auto'
  $o = Plan @('-Command', 'pnpm build')
  Remove-Item Env:AGENTQ_WHERE -ErrorAction SilentlyContinue
  Check '1 Plan: AGENTQ_WHERE=auto is echoed as where=auto' ($o -match 'where=auto(\s|$)') $o

  # =============================== 2. the effective placement reaches `agentq run -Where` ===========
  $o = Queued @('-Command', 'pnpm build')
  $aq = FakeArgs
  Check '2 default: no -Where is forwarded (agentq keeps its own default)' (($script:code -eq 0) -and (-not ($aq -match '(^|\s)-Where(\s|$)'))) "exit=$($script:code) aq='$aq' $o"
  $o = Queued @('-Command', 'pnpm build', '-Where', 'cloud')
  $aq = FakeArgs
  Check '2 -Where cloud is forwarded verbatim' ($aq -match '(^|\s)-Where cloud(\s|$)') "aq='$aq' $o"
  $o = Queued @('-Command', 'pnpm build', '-Where', 'auto')
  $aq = FakeArgs
  Check '2 -Where auto is forwarded verbatim' ($aq -match '(^|\s)-Where auto(\s|$)') "aq='$aq' $o"
  $o = Queued @('-Command', 'pnpm build') 'auto'
  $aq = FakeArgs
  Check '2 AGENTQ_WHERE=auto is forwarded when -Where is absent' ($aq -match '(^|\s)-Where auto(\s|$)') "aq='$aq' $o"
  # Explicit -Where must win over the env (the caller's flag is the more specific intent).
  $o = Queued @('-Command', 'pnpm build', '-Where', 'local') 'cloud'
  $aq = FakeArgs
  Check '2 explicit -Where local wins over AGENTQ_WHERE=cloud' ($aq -match '(^|\s)-Where local(\s|$)') "aq='$aq' $o"

  # =============================== 3. wedge: LOCAL fires, cloud-bound is suppressed =================
  # 0.05 min = 3 s. The quiet child warms up (one line, which anchors the silence clock at the loop's
  # first iteration) and is then silent for 40 s, so a local run crosses the threshold with room to
  # spare no matter how long run-build's init process-tree sweep takes. 13 s, then 25 s, both measured
  # TOO TIGHT on a loaded box: the verdict moves with how long the sweep takes, and w1 went red as an
  # empty-tail kill (no WEDGED line and no exit line in the build log), and once with Seen=False and no
  # marker at all because the sweep had swallowed the child's entire silence window (2026-11-26).
  # PollSec 60 is free: the poll breaks the moment run-build exits (the quiet child lives ~40 s), it
  # only bounds the worst case so a slow init sweep cannot push the run past the window.
  $w = @{ WedgeMin = 0.05; PollSec = 60; WaitMs = 8000 }
  $cmd = "pwsh -NoProfile -File $quiet"

  $r = Test-Wedge 'w1' $cmd $w
  Check '3 local default: WEDGED is written (unchanged behaviour)' ($r.Locked -and $r.Seen) $($r | Out-String)

  $r = Test-Wedge 'w2' $cmd ($w + @{ EnvWhere = 'cloud' })
  Check '3 AGENTQ_WHERE=cloud: ran, no WEDGED (cloud-bound)' ($r.Locked -and (-not $r.Seen)) $($r | Out-String)

  $r = Test-Wedge 'w3' $cmd ($w + @{ Where = 'cloud' })
  Check '3 -Where cloud: ran, no WEDGED (cloud-bound)' ($r.Locked -and (-not $r.Seen)) $($r | Out-String)

  $r = Test-Wedge 'w4' $cmd ($w + @{ EnvPlacement = 'cloud' })
  Check '3 AGENTQ_PLACEMENT=cloud: ran, no WEDGED (resolved cloud)' ($r.Locked -and (-not $r.Seen)) $($r | Out-String)

  $r = Test-Wedge 'w5' $cmd ($w + @{ Where = 'local' })
  Check '3 -Where local: WEDGED still written (no over-suppression)' ($r.Locked -and $r.Seen) $($r | Out-String)

  # Output resumes after the quiet period -> the marker must be cleared while the run is still going.
  # 60 s poll: the fixture is silent for 25 s (a verdict), resumes, and is silent 25 s again, so the
  # case legitimately outlives a 40 s window on a loaded box.
  $r = Test-Wedge 'w6' ("pwsh -NoProfile -File $resume") @{ WedgeMin = 0.05; PollSec = 60; WaitMs = 8000 }
  Check '3 local run: WEDGED written then CLEARED when output resumes' ($r.Locked -and $r.Seen -and $r.ClearedAfterSeen) $($r | Out-String)

  # A cloud-bound run whose output resumes is equally irrelevant (never marked), so no clear needed.
  $r = Test-Wedge 'w7' ("pwsh -NoProfile -File $resume") @{ WedgeMin = 0.05; PollSec = 60; WaitMs = 8000; EnvWhere = 'cloud' }
  Check '3 AGENTQ_WHERE=cloud + resume: ran, never WEDGED' ($r.Locked -and (-not $r.Seen)) $($r | Out-String)
} finally {
  $env:USERPROFILE = $oldUp
  [Environment]::SetEnvironmentVariable('AGENTQ_HELD', $oldHeld)
  [Environment]::SetEnvironmentVariable('RUN_BUILD_NO_AGENTQ', $oldNoAq)
  [Environment]::SetEnvironmentVariable('AGENTQ_WHERE', $oldWhere)
  [Environment]::SetEnvironmentVariable('AGENTQ_PLACEMENT', $oldPlace)
  Remove-Item Env:FAKE_AQ_OUT -ErrorAction SilentlyContinue
  # CAW_KEEP_TMP=1 keeps the scratch tree so the per-case build logs can be read after a red run
  # (a red case with Locked=True and an empty tail is otherwise un-diagnosable: the tree is gone).
  if ($env:CAW_KEEP_TMP) { Write-Host "kept: $tmp" } else { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
}
if ($fail) { Write-Host "FAILED $fail" -ForegroundColor Red; exit 1 }
Write-Host 'PASS runbuild-cloud-aware'
