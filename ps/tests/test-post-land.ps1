# `agentq land` starts the pushed tree's scripts/post-land.ps1 after a successful push (ADR 0008; brivio
# ADR-0339 D14): detached, hidden, once per push, with AGENTQ_POSTLAND_REPO/BRANCH/SHA, the blob of the
# PUSHED commit (not a working-tree copy), never waited for and never able to fail the land. A tree
# without the script, or AGENTQ_NO_POSTLAND=1, starts nothing. Isolated in %TEMP%; bare repo = origin.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqpl-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_FLAKES = '1'
$env:AGENTQ_SESSION = 'test-PL'
Remove-Item Env:AGENTQ_NO_POSTLAND, Env:AGENTQ_LAND_BATCH, Env:AGENTQ_NO_JOBOBJ -ErrorAction SilentlyContinue
$env:AGENTQ_RUN_BUILD = Join-Path $PSScriptRoot 'fake-gate.ps1'
$env:FAKE_GATE_LOG = Join-Path $tmp 'gates.log'
$env:FAKE_GATE_HOLD = Join-Path $tmp 'hold.flag'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
$env:AGENTQ_CONFIG = $cfg
$fail = 0; $script:procs = @()
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Tip { "$((git -C $repo ls-remote origin refs/heads/dev) -split "`t" | Select-Object -First 1)".Trim() }
function Remote([string]$f) { (git -C $repo show "origin/dev:$f" 2>$null) -join '' }
function Events([string]$e) { $j = Join-Path $env:AGENTQ_HOME 'journal.jsonl'; if (-not (Test-Path $j)) { return @() }; @(Get-Content $j | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq $e) }
# The hook script records every run as <main clone>\hook-runs\run-*.txt (the only path it knows).
$runsDir = Join-Path $tmp 'repo\hook-runs'
function Runs { if (Test-Path $runsDir) { @(Get-ChildItem $runsDir -Filter 'run-*.txt' | Sort-Object LastWriteTimeUtc, Name) } else { @() } }
function Wait-Runs([int]$n, [int]$sec = 45) { for ($i = 0; $i -lt $sec * 2; $i++) { if (@(Runs).Count -ge $n) { return $true }; Start-Sleep -Milliseconds 500 }; $false }
function Read-Run($f) { $h = @{}; foreach ($l in Get-Content $f.FullName) { if ($l -match '^([A-Z]+)=(.*)$') { $h[$Matches[1]] = $Matches[2] } }; $h }
function Wait-Output([string]$needle, [int]$sec = 30) {
  for ($i = 0; $i -lt $sec * 2; $i++) {
    $logs = @(Get-ChildItem (Join-Path $env:AGENTQ_HOME 'post-land') -Recurse -Filter 'output.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($l in $logs) { if ((Get-Content $l.FullName -Raw -ErrorAction SilentlyContinue) -match $needle) { return $l.FullName } }
    Start-Sleep -Milliseconds 500
  }
  $null
}

# A pid alone can be recycled on a busy machine: a process is OUR hook only when its command line names
# the launcher under this test's AGENTQ_HOME. Nothing here kills or trusts a bare pid.
$plHome = Join-Path $env:AGENTQ_HOME 'post-land'
function Test-Hook([int]$id) { $p = Get-Process -Id $id -ErrorAction SilentlyContinue; [bool]($p -and "$($p.CommandLine)".IndexOf($plHome, [StringComparison]::OrdinalIgnoreCase) -ge 0) }
function Stop-Hook([int]$id) { if (Test-Hook $id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }

# The hook script. Mode file <main clone>\hook-mode: exit1 | throw | sleep (600 s). VERSION tells copies apart;
# SHOW is the show-window value the process was created with (0 = hidden).
function HookScript([int]$version) {
  @"
`$o = Join-Path `$env:AGENTQ_POSTLAND_REPO 'hook-runs'
New-Item -ItemType Directory -Force `$o | Out-Null
`$f = Join-Path `$o ('run-{0}-{1}.txt' -f (Get-Date).ToUniversalTime().ToString('HHmmssfff'), `$PID)
`$show = 'error'
try {
  Add-Type -Namespace PL -Name K -MemberDefinition '[StructLayout(LayoutKind.Sequential)] public struct SI { public int cb; public IntPtr r, d, t; public int x, y, xs, ys, xc, yc, fa, flags; public short show, r2; public IntPtr r3, i, o, e; } [DllImport("kernel32.dll")] public static extern void GetStartupInfoW(out SI si);'
  `$si = New-Object PL.K+SI; [PL.K]::GetStartupInfoW([ref]`$si)
  `$show = if (`$si.flags -band 1) { "`$(`$si.show)" } else { 'default' }
} catch { `$show = "error: `$(`$_.Exception.Message)" }
@("VERSION=$version", "REPO=`$env:AGENTQ_POSTLAND_REPO", "BRANCH=`$env:AGENTQ_POSTLAND_BRANCH", "SHA=`$env:AGENTQ_POSTLAND_SHA", "CWD=`$((Get-Location).Path)", "PID=`$PID", "SCRIPT=`$PSCommandPath", "HELD=`$env:AGENTQ_HELD", "SHOW=`$show") | Set-Content `$f
`$m = Join-Path `$env:AGENTQ_POSTLAND_REPO 'hook-mode'
`$mode = if (Test-Path `$m) { (Get-Content `$m -Raw).Trim() } else { '' }
switch (`$mode) { 'exit1' { exit 1 } 'throw' { throw 'hook boom' } 'sleep' { Start-Sleep -Seconds 600 } }
'hook ok'
"@
}

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'
git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$repoName = Split-Path -Leaf $repo
"{`"taskSlotsPerRepo`":2,`"taskSlotsMachine`":3,`"leaseDeadIdleMin`":1,`"leaseMaxIdleMin`":5,`"minFreeCommitGB`":0,`"machineCap`":2}" | Set-Content $cfg
# Client pre-push hook (shared by every worktree of $repo): refuses pushes to dev while reject.flag exists.
$rejectFlag = Join-Path $tmp 'reject.flag'
$hook = "#!/bin/sh`nread l o r rs`n[ `"`$r`" = refs/heads/dev ] || exit 0`nif [ -f '$($rejectFlag -replace '\\', '/')' ]; then echo 'pre-push: refused by test'; exit 1; fi`nexit 0`n"
[IO.File]::WriteAllText((Join-Path $repo '.git\hooks\pre-push'), $hook)
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
function Topic([string]$name, [string]$file, [string]$content = $name) {
  git -C $tw fetch -q origin 2>$null
  git -C $tw checkout -q -B $name origin/dev 2>$null
  $p = Join-Path $tw $file
  New-Item -ItemType Directory -Force (Split-Path $p) | Out-Null
  [IO.File]::WriteAllText($p, $content)
  git -C $tw add $file; git -C $tw commit -qm "topic $name"
  git -C $tw push -q --no-verify origin $name 2>$null
  git -C $repo fetch -q origin 2>$null
}
function Start-Land([string]$branch, [string]$session) {
  $outF = Join-Path $tmp "$branch.out"
  $cmd = "`$env:AGENTQ_SESSION='$session'; Set-Location '$repo'; & pwsh -NoProfile -File '$Aq' land -Branch $branch -Onto dev -Gate 'gate' -Purpose 'land $branch' *> '$outF'; exit `$LASTEXITCODE"
  $p = Start-Process pwsh -ArgumentList @('-NoProfile', '-Command', $cmd) -PassThru -WindowStyle Hidden
  $script:procs += $p
  @{ p = $p; out = $outF; branch = $branch }
}
function Wait-Queued([int]$n) { for ($i = 0; $i -lt 120; $i++) { if (@(Events 'queued').Count -ge $n) { return $true }; Start-Sleep -Milliseconds 500 }; $false }
function Finish($l) { if (-not $l.p.WaitForExit(600000)) { try { $l.p.Kill($true) } catch {} ; return -1 }; $l.p.ExitCode }
Push-Location $repo
try {
  # --- 5. no script in the tree: no process, no journal event, nothing on disk --------------------
  Topic 'plain' 'p.txt'
  $o = AQ land -Branch plain -Onto dev -Purpose 'plain'
  Check '5 no script: land exit 0' ($code -eq 0) $o
  Start-Sleep -Seconds 3
  Check '5 no script: no hook run' (@(Runs).Count -eq 0)
  Check '5 no script: no post-land event' (@(Events 'post-land').Count -eq 0 -and @(Events 'post-land-failed').Count -eq 0)
  Check '5 no script: no post-land directory' (-not (Test-Path (Join-Path $env:AGENTQ_HOME 'post-land')))

  # --- install the hook (v1) on dev from the MAIN clone: its working tree keeps v1 from here on -----
  git -C $repo pull -q --no-rebase origin dev 2>$null
  New-Item -ItemType Directory -Force (Join-Path $repo 'scripts') | Out-Null
  [IO.File]::WriteAllText((Join-Path $repo 'scripts\post-land.ps1'), (HookScript 1))
  git -C $repo add scripts/post-land.ps1; git -C $repo commit -qm 'add post-land hook v1'; git -C $repo push -q --no-verify origin dev 2>$null

  # --- 11. the hook cannot be started: journaled, and the land is exactly as successful ------------
  $plRoot = Join-Path $env:AGENTQ_HOME 'post-land'
  Set-Content $plRoot 'a file where the directory should be'
  Topic 'zero' 'z.txt'
  $o = AQ land -Branch zero -Onto dev -Purpose 'zero'
  Remove-Item $plRoot -Force
  Check '11 start failure: land exit 0 and pushed' ($code -eq 0 -and (Remote 'z.txt') -eq 'zero') $o
  $pf = @(Events 'post-land-failed')
  Check '11 start failure: post-land-failed journaled with sha, branch and reason' ($pf.Count -eq 1 -and $pf[0].sha -eq (Tip) -and $pf[0].branch -eq 'dev' -and "$($pf[0].reason)".Length -gt 5) ($pf | ConvertTo-Json -Compress)
  Check '11 start failure: no post-land event, no run' (@(Events 'post-land').Count -eq 0 -and @(Runs).Count -eq 0)

  # --- 10. set-up: a run directory from two days ago and one from two hours ago -------------------
  $oldDir = Join-Path $plRoot 'other\old-run'; $freshDir = Join-Path $plRoot 'other\fresh-run'
  foreach ($d in $oldDir, $freshDir) { New-Item -ItemType Directory -Force $d | Out-Null; Set-Content (Join-Path $d 'post-land.ps1') 'x' }
  [IO.Directory]::SetLastWriteTimeUtc($oldDir, [DateTime]::UtcNow.AddDays(-2)); [IO.Directory]::SetLastWriteTimeUtc($freshDir, [DateTime]::UtcNow.AddHours(-2))

  # --- 1. a land starts the hook once, with the three variables ----------------------------------
  Topic 'one' 'b.txt'
  $o = AQ land -Branch one -Onto dev -Purpose 'one'
  Check '1 land exit 0' ($code -eq 0) $o
  $tip = Tip
  Check '1 hook ran' (Wait-Runs 1) $o
  Start-Sleep -Seconds 2
  $runs = @(Runs)
  Check '1 hook ran exactly once' ($runs.Count -eq 1) "runs=$($runs.Count)"
  $r1 = if ($runs.Count) { Read-Run $runs[0] } else { @{} }
  Check '1 AGENTQ_POSTLAND_REPO = main clone' ("$($r1['REPO'])".TrimEnd('\') -ieq $repo) "$($r1['REPO'])"
  Check '1 AGENTQ_POSTLAND_BRANCH = -Onto' ($r1['BRANCH'] -eq 'dev') "$($r1['BRANCH'])"
  Check '1 AGENTQ_POSTLAND_SHA = pushed tip (full sha)' ($r1['SHA'] -eq $tip -and "$tip".Length -eq 40) "$($r1['SHA']) vs $tip"
  Check '1 working directory = main clone' ("$($r1['CWD'])".TrimEnd('\') -ieq $repo) "$($r1['CWD'])"
  Check '1 ran from the copy under AGENTQ_HOME, not a working tree' ("$($r1['SCRIPT'])".StartsWith((Join-Path $env:AGENTQ_HOME 'post-land'), [StringComparison]::OrdinalIgnoreCase)) "$($r1['SCRIPT'])"
  # STARTF_USESHOWWINDOW + wShowWindow 0 (SW_HIDE): what the creator asked for, whatever terminal application is the default.
  Check '1 hook process was created hidden (show-window = SW_HIDE)' ($r1['SHOW'] -eq '0') "SHOW=$($r1['SHOW'])"
  Check '1 land tickets not passed on (AGENTQ_HELD empty)' (-not $r1['HELD']) "$($r1['HELD'])"
  Check '1 land output does not wait on or mention the hook' (-not ($o -match 'hook ok')) $o
  # --- 8. journal: post-land with the sha ------------------------------------------------------
  $ev = @(Events 'post-land')
  Check '8 post-land journaled once with sha, branch, repo and pid' ($ev.Count -eq 1 -and $ev[0].sha -eq $tip -and $ev[0].branch -eq 'dev' -and $ev[0].repo -eq $repoName -and [int]$ev[0].pid -gt 0) ($ev | ConvertTo-Json -Compress)
  # --- 10. the NEXT run removed the directory older than a day and kept the newer one -----------
  Check '10 run directory older than a day removed' (-not (Test-Path $oldDir))
  Check '10 run directory from two hours ago kept' (Test-Path $freshDir)
  Check '8 journaled pid = the hook process' ($ev.Count -eq 1 -and "$($ev[0].pid)" -eq "$($r1['PID'])") "$($ev[0].pid) vs $($r1['PID'])"

  # --- 2. the copy that runs is the PUSHED commit's (main clone working tree still has v1) ---------
  Topic 'two' 'scripts/post-land.ps1' (HookScript 2)
  Check '2 precondition: main clone working tree still has v1' ((Get-Content (Join-Path $repo 'scripts\post-land.ps1') -Raw) -match 'VERSION=1')
  $o = AQ land -Branch two -Onto dev -Purpose 'two'
  Check '2 land exit 0' ($code -eq 0) $o
  Check '2 hook ran' (Wait-Runs 2) $o
  $r2 = Read-Run (@(Runs) | Select-Object -Last 1)
  Check '2 the pushed commit''s script ran (VERSION=2)' ($r2['VERSION'] -eq '2') "VERSION=$($r2['VERSION'])"
  Check '2 its sha is the new tip' ($r2['SHA'] -eq (Tip)) "$($r2['SHA'])"
  Check '2 main clone working tree untouched (v1)' ((Get-Content (Join-Path $repo 'scripts\post-land.ps1') -Raw) -match 'VERSION=1')

  # --- 3. exit 1, throw, sleep: the land is unaffected -----------------------------------------------
  $modeFile = Join-Path $repo 'hook-mode'
  Set-Content $modeFile 'exit1'
  Topic 'three' 'c.txt'
  $o = AQ land -Branch three -Onto dev -Purpose 'three'
  Check '3 exit 1: land exit 0' ($code -eq 0) $o
  Check '3 exit 1: hook ran' (Wait-Runs 3) $o
  Check '3 exit 1: launcher recorded EXIT=1' ([bool](Wait-Output 'EXIT=1'))
  Set-Content $modeFile 'throw'
  Topic 'four' 'd.txt'
  $o = AQ land -Branch four -Onto dev -Purpose 'four'
  Check '3 throw: land exit 0' ($code -eq 0) $o
  Check '3 throw: hook ran' (Wait-Runs 4) $o
  Check '3 throw: launcher recorded the exception' ([bool](Wait-Output 'hook boom'))
  Check '3 throw: no further post-land-failed event (a failing script is not a start failure)' (@(Events 'post-land-failed').Count -eq 1)
  Set-Content $modeFile 'sleep'
  Topic 'five' 'e.txt'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  # Under `agentq run`: the land sits in a kill-on-close job object, like every queued land gate.
  $o = @(& pwsh -NoProfile -File $Aq run -Resource install -Purpose 'land under a job object' '--' pwsh -NoProfile -File $Aq land -Branch five -Onto dev -Purpose 'five' 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $code = $LASTEXITCODE
  $landSec = [math]::Round($sw.Elapsed.TotalSeconds)
  Check '3 sleep: land exit 0' ($code -eq 0) $o
  # Load-independent: the hook sleeps 600 s; a land that waited for it could not be back before that.
  # (A limit near the land's own duration fails under load: a land took 149 s with 4 suites in parallel.)
  Check '3 sleep: land returned in under half the hook''s sleep (600 s)' ($landSec -lt 300) "land took $landSec s"
  Check '3 sleep: hook ran' (Wait-Runs 5) $o
  $sleepLog = Join-Path (Split-Path (Read-Run (@(Runs) | Select-Object -Last 1))['SCRIPT']) 'output.log'
  Check '3 sleep: hook had not finished when the land returned (no EXIT line yet)' (-not ((Get-Content $sleepLog -Raw -ErrorAction SilentlyContinue) -match 'EXIT='))
  Check '3 sleep: the land ran inside a job object' (@(Events 'jobobj-failed').Count -eq 0 -and @(Events 'done' | Where-Object { $_.cpuWeight -ge 1 }).Count -ge 1)
  # --- 4. the sleeping hook outlived the land and its job object --------------------------------
  $r5 = Read-Run (@(Runs) | Select-Object -Last 1)
  $hookPid = [int]$r5['PID']
  Start-Sleep -Seconds 3
  $alive = Test-Hook $hookPid
  Check '4 hook still alive after the land (and its job object) ended' $alive "pid=$hookPid"
  Stop-Hook $hookPid
  Remove-Item $modeFile -Force

  # --- 6. AGENTQ_NO_POSTLAND=1: no process, no event -------------------------------------------------
  $n6 = @(Runs).Count; $e6 = @(Events 'post-land').Count
  Topic 'six' 'f.txt'
  $env:AGENTQ_NO_POSTLAND = '1'
  $o = AQ land -Branch six -Onto dev -Purpose 'six'
  Remove-Item Env:AGENTQ_NO_POSTLAND
  Check '6 opt-out: land exit 0' ($code -eq 0 -and (Remote 'f.txt') -eq 'six') $o
  Start-Sleep -Seconds 4
  Check '6 opt-out: no hook run, no event' (@(Runs).Count -eq $n6 -and @(Events 'post-land').Count -eq $e6) "runs $(@(Runs).Count)/$n6 events $(@(Events 'post-land').Count)/$e6"

  # --- 9. push refused: the hook does not run (it is a POST-push hook) -----------------------------
  $n9 = @(Runs).Count; $e9 = @(Events 'post-land').Count; $t9 = Tip
  Set-Content $rejectFlag 'x'
  Topic 'nine' 'g.txt'
  $o = AQ land -Branch nine -Onto dev -Purpose 'nine'
  Remove-Item $rejectFlag -Force
  Check '9 refused push: land exit 7, nothing pushed' ($code -eq 7 -and (Tip) -eq $t9) $o
  Start-Sleep -Seconds 4
  Check '9 refused push: no hook run, no event' (@(Runs).Count -eq $n9 -and @(Events 'post-land').Count -eq $e9) "runs $(@(Runs).Count)/$n9 events $(@(Events 'post-land').Count)/$e9"

  # --- 7. a batch of two lands absorbed into one push = one hook run ----------------------------------
  "{`"taskSlotsPerRepo`":2,`"taskSlotsMachine`":3,`"leaseDeadIdleMin`":1,`"leaseMaxIdleMin`":5,`"minFreeCommitGB`":0,`"machineCap`":2,`"landBatch`":{`"$repoName`":true}}" | Set-Content $cfg
  $n7 = @(Runs).Count; $e7 = @(Events 'post-land').Count; $l7 = @(Events 'land').Count
  Set-Content $env:FAKE_GATE_HOLD 'x'
  Topic 'blocker' 'blk.txt'
  $q0 = @(Events 'queued').Count
  $b = Start-Land 'blocker' 's-blk'
  [void](Wait-Queued ($q0 + 1))
  for ($i = 0; $i -lt 120 -and -not (Select-String -LiteralPath $env:FAKE_GATE_LOG -Pattern 'blocker' -Quiet -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
  Topic 'w1' 'w1.txt'; $l1 = Start-Land 'w1' 's-w1'; [void](Wait-Queued ($q0 + 2))
  Topic 'w2' 'w2.txt'; $l2 = Start-Land 'w2' 's-w2'; [void](Wait-Queued ($q0 + 3))
  Start-Sleep -Seconds 2
  Remove-Item $env:FAKE_GATE_HOLD -Force
  $rb = Finish $b; $r1c = Finish $l1; $r2c = Finish $l2
  $outs = (@($b, $l1, $l2) | ForEach-Object { Get-Content $_.out -Raw -ErrorAction SilentlyContinue }) -join "`n---`n"
  git -C $repo fetch -q origin
  Check '7 blocker and both waiters landed' ($rb -eq 0 -and $r1c -eq 0 -and $r2c -eq 0 -and (Remote 'w1.txt') -eq 'w1' -and (Remote 'w2.txt') -eq 'w2') $outs
  $bat = @(Events 'land-batch')
  Check '7 the two waiters were one batch' ($bat.Count -eq 1 -and $bat[0].size -eq 2) ($bat | ConvertTo-Json -Compress)
  Check '7 three land events' (@(Events 'land').Count -eq $l7 + 3)
  Start-Sleep -Seconds 4
  $ev7 = @(Events 'post-land' | Select-Object -Skip $e7)
  Check '7 two pushes = two post-land events (not three)' ($ev7.Count -eq 2) ($ev7 | ConvertTo-Json -Compress)
  Check '7 two hook runs' ((Wait-Runs ($n7 + 2)) -and @(Runs).Count -eq $n7 + 2) "runs=$(@(Runs).Count) expected $($n7 + 2)"
  $last = Read-Run (@(Runs) | Select-Object -Last 1)
  Check '7 the batch run carries the batch tip' ($last['SHA'] -eq (Tip) -and ($ev7 | Where-Object { $_.sha -eq (Tip) }).Count -eq 1) "$($last['SHA']) vs $(Tip)"
} finally {
  Pop-Location
  foreach ($p in $script:procs) { try { if (-not $p.HasExited) { $p.Kill($true) } } catch {} }
  # A hook of this run that is still alive (sleep mode) holds nothing; stop it, identified by its command line.
  foreach ($f in @(Runs)) { $h = Read-Run $f; if ($h['PID']) { Stop-Hook ([int]$h['PID']) } }
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_RUN_BUILD', 'FAKE_GATE_LOG', 'FAKE_GATE_HOLD', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_FLAKES', 'AGENTQ_NO_POSTLAND') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS post-land'; exit 0 }
