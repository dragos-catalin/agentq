# Behavioural tests for agentq.ps1 against an isolated AGENTQ_HOME and a temp git repo
# (main clone + linked worktree). No network, no real repos touched.
$ErrorActionPreference = 'Stop'
$aq = Join-Path $PSScriptRoot 'agentq.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agentq-test-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:AGENTQ_NO_SIGNAL = '1'
$repo = Join-Path $tmp 'repo'; $wt = Join-Path $tmp 'wt'
New-Item -ItemType Directory -Force $repo | Out-Null
git -C $repo init -q -b main; git -C $repo config user.email t@t; git -C $repo config user.name t
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo worktree add -q $wt -b side 2>$null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ }
}

# 1. run: exit code passes through, journal records start/done.
Push-Location $repo
& pwsh -NoProfile -File $aq run -Resource build -Purpose 'unit' -MinFreeGB 0 -- pwsh -NoProfile -Command 'exit 7' 2>$null
Check 'run passes exit code' ($LASTEXITCODE -eq 7) "got $LASTEXITCODE"
$j = Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
Check 'journal has start+fail' ((@($j | Where-Object event -eq 'start').Count -ge 1) -and (@($j | Where-Object event -eq 'fail').Count -ge 1))
Pop-Location

# 2. serialization across worktrees: two runs on build:<repo> from main + worktree never overlap.
$marker = Join-Path $tmp 'overlap.log'
$body = "Add-Content '$marker' ('S ' + [DateTime]::UtcNow.ToString('o')); Start-Sleep -Seconds 3; Add-Content '$marker' ('E ' + [DateTime]::UtcNow.ToString('o'))"
$p1 = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $aq, 'run', '-Resource', 'build', '-Purpose', 'p1', '-MinFreeGB', '0', '--', 'pwsh', '-NoProfile', '-Command', $body) -WorkingDirectory $repo -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 800
$p2 = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $aq, 'run', '-Resource', 'build', '-Purpose', 'p2', '-MinFreeGB', '0', '--', 'pwsh', '-NoProfile', '-Command', $body) -WorkingDirectory $wt -PassThru -WindowStyle Hidden
$p1.WaitForExit(60000) | Out-Null; $p2.WaitForExit(60000) | Out-Null
$ev = @(Get-Content $marker)
$seqOk = ($ev.Count -eq 4) -and ($ev[0] -like 'S *') -and ($ev[1] -like 'E *') -and ($ev[2] -like 'S *') -and ($ev[3] -like 'E *')
Check 'worktrees share build:<repo> (no overlap)' $seqOk ($ev -join ' | ')

# 3. mark frozen refuses; clear allows.
Push-Location $repo
& pwsh -NoProfile -File $aq mark -Resource 'deploy:web' -State frozen -Reason 'incident' | Out-Null
& pwsh -NoProfile -File $aq run -Resource 'deploy:web' -Purpose 'x' -- pwsh -NoProfile -Command 'exit 0' 2>$null
Check 'frozen resource refuses run (exit 3)' ($LASTEXITCODE -eq 3) "got $LASTEXITCODE"
& pwsh -NoProfile -File $aq mark -Resource 'deploy:web' -State clear -Reason 'resolved' | Out-Null
& pwsh -NoProfile -File $aq run -Resource 'deploy:web' -Purpose 'x' -- pwsh -NoProfile -Command 'exit 0' 2>$null
Check 'cleared resource runs' ($LASTEXITCODE -eq 0) "got $LASTEXITCODE"

# 4. dead holder is reaped: a ticket whose pid is gone does not block.
$qd = Join-Path $env:AGENTQ_HOME 'queues\build_repo'  # repo name = common-git-dir parent = 'repo'
New-Item -ItemType Directory -Force $qd | Out-Null
$ghost = @{ id = 'ghost001'; seq = 0; resource = 'build:repo'; pid = 999999; procStart = [DateTime]::UtcNow.ToString('o'); session = 'dead'; purpose = 'ghost'; created = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json
Set-Content (Join-Path $qd '00000000-ghost001.json') $ghost
& pwsh -NoProfile -File $aq run -Resource build -Purpose 'after-ghost' -MinFreeGB 0 -TimeoutMin 1 -- pwsh -NoProfile -Command 'exit 0' 2>$null
Check 'dead-pid ticket reaped' ($LASTEXITCODE -eq 0) "got $LASTEXITCODE"

# 5. -NoWait on a busy resource exits 3 without waiting.
$holder = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $aq, 'run', '-Resource', 'install', '-Purpose', 'hold', '--', 'pwsh', '-NoProfile', '-Command', 'Start-Sleep -Seconds 20') -WorkingDirectory $repo -PassThru -WindowStyle Hidden
$w = 0; while ($w -lt 40 -and -not (Get-ChildItem (Join-Path $env:AGENTQ_HOME 'queues') -Recurse -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.DirectoryName -like '*install_*' })) { Start-Sleep -Milliseconds 250; $w++ }; Start-Sleep -Seconds 1
& pwsh -NoProfile -File $aq run -Resource install -Purpose 'nowait' -NoWait -- pwsh -NoProfile -Command 'exit 0' 2>$null
Check '-NoWait busy exits 3' ($LASTEXITCODE -eq 3) "got $LASTEXITCODE"
$st = (& pwsh -NoProfile -File $aq status) -join "`n"
Check 'status shows holder purpose' ($st -match 'hold') $st
Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue

# 6. commit: only -Paths are committed even when something else is staged.
Set-Content (Join-Path $repo 'mine.txt') 'm'; Set-Content (Join-Path $repo 'theirs.txt') 't'
git -C $repo add theirs.txt
& pwsh -NoProfile -File $aq commit -Purpose 'unit' -Message 'test: mine' -Paths mine.txt -NoPush | Out-Null
$files = @(git -C $repo show --name-only --format= HEAD)
Check 'commit takes only -Paths' (($files -contains 'mine.txt') -and -not ($files -contains 'theirs.txt')) ($files -join ',')
$staged = @(git -C $repo diff --cached --name-only)
Check 'foreign staged file left staged' ($staged -contains 'theirs.txt') ($staged -join ',')
$body = (git -C $repo log -1 --format=%B) -join "`n"
Check 'commit has Agent-Purpose trailer' ($body -match 'Agent-Purpose: unit')

# 12. X-02: -ExpectRepo / AGENTQ_EXPECT_REPO refuse a commit or run in the wrong repo (a dropped
#     Set-Location made commits land in the shared clone twice). Matching repo still works.
Set-Content (Join-Path $wt 'x02.txt') 'w'
Push-Location $repo
& pwsh -NoProfile -File $aq commit -Purpose 'x02' -Message 'test: wrong repo' -Paths x02.txt -NoPush -ExpectRepo $wt 2>$null | Out-Null
Check 'X-02 commit in wrong repo refused (exit 3)' ($LASTEXITCODE -eq 3) "got $LASTEXITCODE"
$env:AGENTQ_EXPECT_REPO = $wt
& pwsh -NoProfile -File $aq run -Resource build -Purpose 'x02' -MinFreeGB 0 -- pwsh -NoProfile -Command 'exit 0' 2>$null
Check 'X-02 run refused via AGENTQ_EXPECT_REPO' ($LASTEXITCODE -eq 3) "got $LASTEXITCODE"
Remove-Item Env:AGENTQ_EXPECT_REPO
& pwsh -NoProfile -File $aq commit -Purpose 'x02' -Message 'test: abs outside' -Paths (Join-Path $wt 'x02.txt') -NoPush 2>$null | Out-Null
Check 'X-02 absolute path outside repo refused' ($LASTEXITCODE -eq 3) "got $LASTEXITCODE"
Pop-Location
Push-Location $wt
& pwsh -NoProfile -File $aq commit -Purpose 'x02' -Message 'test: right repo' -Paths x02.txt -NoPush -ExpectRepo $wt 2>$null | Out-Null
$wf = @(git -C $wt show --name-only --format= HEAD)
Check 'X-02 commit in expected repo works' (($LASTEXITCODE -eq 0) -and ($wf -contains 'x02.txt')) "exit $LASTEXITCODE files $($wf -join ',')"
Pop-Location

# 13. X-03: a commit rejected by pre-commit must NOT leave its -Paths staged (a later amend
#     swallowed them, 2026-10-02). A path that was already staged before agentq stays staged.
$x3 = Join-Path $tmp 'x3'
New-Item -ItemType Directory -Force $x3 | Out-Null
git -C $x3 init -q -b main; git -C $x3 config user.email t@t; git -C $x3 config user.name t
Set-Content (Join-Path $x3 'base.txt') 'b'; git -C $x3 add base.txt; git -C $x3 commit -qm init
New-Item -ItemType Directory -Force (Join-Path $x3 '.githooks') | Out-Null
Set-Content (Join-Path $x3 '.githooks\pre-commit') "#!/bin/sh`nexit 1`n" -NoNewline
git -C $x3 config core.hooksPath .githooks
Set-Content (Join-Path $x3 'new.txt') 'n'; Set-Content (Join-Path $x3 'pre.txt') 'p'
git -C $x3 add pre.txt
Push-Location $x3
& pwsh -NoProfile -File $aq commit -Purpose 'x03' -Message 'test: rejected' -Paths 'new.txt,pre.txt' -NoPush 2>$null | Out-Null
$x3exit = $LASTEXITCODE
$x3staged = @(git -C $x3 diff --cached --name-only)
Pop-Location
Check 'X-03 rejected commit exits non-zero' ($x3exit -ne 0) "got $x3exit"
Check 'X-03 own path unstaged after rejection' (-not ($x3staged -contains 'new.txt')) ($x3staged -join ',')
Check 'X-03 previously staged path stays staged' ($x3staged -contains 'pre.txt') ($x3staged -join ',')

# 7. break removes a live ticket with a reason and journals it.
$holder = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $aq, 'run', '-Resource', 'deploy:api', '-Purpose', 'stuck', '--', 'pwsh', '-NoProfile', '-Command', 'Start-Sleep -Seconds 8') -WorkingDirectory $repo -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
& pwsh -NoProfile -File $aq break -Resource 'deploy:api' -Reason 'unit break' | Out-Null
$j = Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }
Check 'break journaled with reason' (@($j | Where-Object { $_.event -eq 'break' -and $_.reason -like 'unit break*' }).Count -eq 1)
$holder.WaitForExit(30000) | Out-Null

# 8. a run waiting for build:<repo> must not already occupy build:machine (phantom hold).
$repoHold = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $aq, 'run', '-Resource', 'build', '-Purpose', 'repo-holder', '-MinFreeGB', '0', '--', 'pwsh', '-NoProfile', '-Command', 'Start-Sleep -Seconds 12') -WorkingDirectory $repo -PassThru -WindowStyle Hidden
$mq = Join-Path $env:AGENTQ_HOME 'queues\build_machine'
$w = 0; while ($w -lt 60 -and -not (Get-ChildItem $mq -Filter '*.json' -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 250; $w++ }
$waiter = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $aq, 'run', '-Resource', 'build', '-Purpose', 'repo-waiter', '-MinFreeGB', '0', '--', 'pwsh', '-NoProfile', '-Command', 'exit 0') -WorkingDirectory $wt -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 4
$machine = @(Get-ChildItem $mq -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).purpose })
Check 'waiter for build:<repo> holds no build:machine ticket' (-not ($machine -contains 'repo-waiter')) ($machine -join ',')

# 9. while waiting for build:machine, the already-held build:<repo> ticket keeps beating.
#    Fill build:machine with two live foreign tickets owned by this test process.
$fill = foreach ($n in 1, 2) {
  $f = Join-Path $mq ("0000000$n-fill000$n.json")
  @{ id = "fill000$n"; seq = $n; resource = 'build:machine'; pid = $PID; procStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o'); session = 'fill'; purpose = 'fill'; created = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json | Set-Content $f
  Set-Content "$f.hb" ''
  $f
}
$repoHold.WaitForExit(30000) | Out-Null; $waiter.WaitForExit(30000) | Out-Null
$beater = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $aq, 'run', '-Resource', 'build', '-Purpose', 'beater', '-MinFreeGB', '0', '-TimeoutMin', '1', '--', 'pwsh', '-NoProfile', '-Command', 'exit 0') -WorkingDirectory $repo -PassThru -WindowStyle Hidden
$rq = Join-Path $env:AGENTQ_HOME 'queues\build_repo'
$w = 0; while ($w -lt 60 -and -not (Get-ChildItem $rq -Filter '*.json.hb' -ErrorAction SilentlyContinue)) { Start-Sleep -Milliseconds 250; $w++ }
$hbFile = @(Get-ChildItem $rq -Filter '*.json.hb')[0].FullName
[IO.File]::SetLastWriteTimeUtc($hbFile, [DateTime]::UtcNow.AddHours(-2))
Start-Sleep -Seconds 5
$age = ([DateTime]::UtcNow - (Get-Item $hbFile).LastWriteTimeUtc).TotalSeconds
Check 'held build:<repo> heartbeat refreshed while waiting for build:machine' ($age -lt 10) "age ${age}s"

# 10. break without -Id refuses when several tickets exist, and names them.
$out = (& pwsh -NoProfile -File $aq break -Resource 'build:machine' -Reason 'ambiguous' 2>&1) -join ' '
Check 'ambiguous break refused (exit 2)' ($LASTEXITCODE -eq 2) "got $LASTEXITCODE $out"
Check 'both fill tickets still present' (@($fill | Where-Object { Test-Path $_ }).Count -eq 2)
& pwsh -NoProfile -File $aq break -Resource 'build:machine' -Id 'fill0002' -Reason 'targeted' | Out-Null
Check 'break -Id removes only that ticket' ((Test-Path $fill[0]) -and -not (Test-Path $fill[1]))
Remove-Item $fill[0], "$($fill[0]).hb" -Force -ErrorAction SilentlyContinue
$beater.WaitForExit(90000) | Out-Null
Pop-Location

# 11. push: a pre-push hook rejection fails fast (hook runs ONCE, commit stays local);
#     a lost race (remote moved) is still fetched, merged and pushed.
# Own repos: the shared test repo still has a foreign staged file from case 6.
$bare = Join-Path $tmp 'origin.git'; $peer = Join-Path $tmp 'peer'; $prepo = Join-Path $tmp 'pushrepo'
git init -q --bare -b main $bare
git init -q -b main $prepo; git -C $prepo config user.email t@t; git -C $prepo config user.name t
Set-Content (Join-Path $prepo 'a.txt') 'a'; git -C $prepo add a.txt; git -C $prepo commit -qm init
git -C $prepo remote add origin $bare; git -C $prepo push -q -u origin main 2>$null
$repo = $prepo
$hookLog = Join-Path $tmp 'hook-runs.log'
$hook = Join-Path $repo '.git\hooks\pre-push'
Set-Content $hook -NoNewline -Value ("#!/bin/sh`necho run >> '" + ($hookLog -replace '\\', '/') + "'`necho 'gates: rust FAIL' >&2`nexit 1`n")
Push-Location $repo
Set-Content (Join-Path $repo 'p1.txt') 'p1'
$t0 = Get-Date
$out = (& pwsh -NoProfile -File $aq commit -Purpose 'unit' -Message 'test: hook' -Paths p1.txt 2>&1) -join ' '
$secs = ((Get-Date) - $t0).TotalSeconds
Check 'hook rejection fails the commit command' ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE"
Check 'hook ran once (no silent 4x retry)' (@(Get-Content $hookLog).Count -eq 1) "runs=$(@(Get-Content $hookLog).Count)"
Check 'hook output surfaced' ($out -match 'gates: rust FAIL') $out
Check 'commit stays local' ((git -C $repo rev-list --count origin/main..HEAD) -eq '1')
Remove-Item $hook -Force
git clone -q $bare $peer 2>$null; git -C $peer config user.email p@p; git -C $peer config user.name p
Set-Content (Join-Path $peer 'peer.txt') 'x'; git -C $peer add peer.txt; git -C $peer commit -qm 'peer'; git -C $peer push -q origin main 2>$null
Set-Content (Join-Path $repo 'p2.txt') 'p2'
$out = (& pwsh -NoProfile -File $aq commit -Purpose 'unit' -Message 'test: race' -Paths p2.txt 2>&1) -join ' '
Check 'lost race is merged and pushed' ($LASTEXITCODE -eq 0 -and $out -match 'pushed') "exit $LASTEXITCODE $out"
Check 'remote has both commits' ((@(git -C $repo ls-tree --name-only origin/main) -contains 'peer.txt') -and (@(git -C $repo ls-tree --name-only origin/main) -contains 'p2.txt'))
Pop-Location

git -C $repo worktree remove $wt 2>$null
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
