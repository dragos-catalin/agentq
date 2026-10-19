# ADR 0003 W2-3: flake ledger in `agentq land`. A test that fails and then passes on the same tree is
# quarantined; a later land whose ONLY pre-push failures are quarantined tests retries once and then
# lands with --no-verify (journal flake-quarantined). Anything else (a non-quarantined test, a type
# error) still fails with exit 7. Isolated in %TEMP%; bare repo = origin; client pre-push hook.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqflk-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'
$env:AGENTQ_SESSION = 'test-F'
Remove-Item Env:AGENTQ_NO_FLAKES -ErrorAction SilentlyContinue
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Remote([string]$f) { (git -C $repo show "origin/dev:$f" 2>$null) -join '' }
function Events([string]$e) { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq $e) }
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'
git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
# Client pre-push hook driven by a mode file: pass | once | A | AB | ATS. Pushes of topic branches pass.
$mode = Join-Path $tmp 'mode'; $flag = Join-Path $tmp 'once.flag'
$m = $mode -replace '\\', '/'; $fl = $flag -replace '\\', '/'
$A = ' FAIL  src/a.test.ts > suite > flaky one'; $B = ' FAIL  src/b.test.ts > suite > real one'
$hook = @"
#!/bin/sh
read l o r rs
[ "`$r" = refs/heads/dev ] || exit 0
md=`$(cat '$m')
case "`$md" in
  pass) exit 0 ;;
  once) if [ -f '$fl' ]; then exit 0; fi; touch '$fl'; echo '$A'; exit 1 ;;
  A) echo '$A'; echo ' Failed:    @r/x#test'; exit 1 ;;
  AB) echo '$A'; echo '$B'; exit 1 ;;
  ATS) echo '$A'; echo 'src/x.ts(1,1): error TS2304: Cannot find name'; exit 1 ;;
esac
exit 1
"@
[IO.File]::WriteAllText((Join-Path $repo '.git\hooks\pre-push'), ($hook -replace "`r`n", "`n"))
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
function Topic([string]$name, [string]$file) {
  git -C $tw fetch -q origin 2>$null
  git -C $tw checkout -q -B $name origin/dev
  Set-Content (Join-Path $tw $file) $name; git -C $tw add $file; git -C $tw commit -qm "topic $name"
  git -C $tw push -q --no-verify origin $name 2>$null
}
Push-Location $repo
try {
  # 1. fails once on a test, then passes on the SAME tree -> the test is quarantined (flake-flip)
  Set-Content $mode 'once'
  Topic 't1' 'b.txt'
  $o = AQ land -Branch t1 -Onto dev -Purpose 'flaky first'
  Check '1 first failure is not excused (exit 7)' ($code -eq 7) $o
  Check '1 no retry on an unknown test failure' (-not (Events 'flake').Count) $o
  $o = AQ land -Branch t1 -Onto dev -Purpose 'flaky second'
  git -C $repo fetch -q origin
  Check '1 second land passes' ($code -eq 0 -and (Remote 'b.txt') -eq 't1') $o
  $flip = Events 'flake-flip'
  Check '1 flake-flip journaled with the test' ($flip.Count -eq 1 -and "$($flip[0].paths)" -match 'flaky one') ($flip | ConvertTo-Json -Compress)
  $o = AQ flakes
  Check '1 agentq flakes lists the quarantined test' ($code -eq 0 -and $o -match 'src/a\.test\.ts > suite > flaky one' -and $o -match 'flips=1') $o

  # 2. only the quarantined test fails (every time) -> retried once, then landed without the hook
  Set-Content $mode 'A'
  Topic 't2' 'c.txt'
  $o = AQ land -Branch t2 -Onto dev -Purpose 'quarantined only'
  git -C $repo fetch -q origin
  Check '2 landed despite the quarantined failure' ($code -eq 0 -and (Remote 'c.txt') -eq 't2') $o
  Check '2 one retry journaled (flake)' ((Events 'flake').Count -eq 1) $o
  $q = Events 'flake-quarantined'
  Check '2 flake-quarantined journaled' ($q.Count -eq 1 -and "$($q[0].paths)" -match 'flaky one') $o

  # 3. quarantined + a real test failure -> exit 7, no retry, nothing pushed
  Set-Content $mode 'AB'
  Topic 't3' 'd.txt'
  $o = AQ land -Branch t3 -Onto dev -Purpose 'real failure'
  git -C $repo fetch -q origin
  Check '3 real test failure still blocks (exit 7)' ($code -eq 7 -and -not (Remote 'd.txt')) $o
  Check '3 no extra retry' ((Events 'flake').Count -eq 1) $o

  # 4. quarantined test + a type error -> exit 7 (non-test failures are never excused)
  Set-Content $mode 'ATS'
  Topic 't4' 'e.txt'
  $o = AQ land -Branch t4 -Onto dev -Purpose 'type error'
  git -C $repo fetch -q origin
  Check '4 type error blocks (exit 7)' ($code -eq 7 -and -not (Remote 'e.txt')) $o

  # 5. lifting the quarantine needs a reason; afterwards the same failure blocks again
  $o = AQ flakes -Id 'flaky one'
  Check '5 clear without -Reason refused' ($code -ne 0) $o
  $o = AQ flakes -Id 'flaky one' -Reason 'fixed the race in a.test.ts'
  Check '5 cleared' ($code -eq 0 -and $o -match 'lifted 1') $o
  Set-Content $mode 'A'
  Topic 't5' 'f.txt'
  $o = AQ land -Branch t5 -Onto dev -Purpose 'after clear'
  Check '5 after clear the failure blocks again (exit 7)' ($code -eq 7) $o
  Check '5 flake-clear journaled' ((Events 'flake-clear').Count -eq 1)

  # 6. AGENTQ_NO_FLAKES=1 disables the ledger (no quarantine excuse even for a known flip)
  $env:AGENTQ_NO_FLAKES = '1'
  Set-Content $mode 'pass'
  Topic 't6' 'g.txt'
  $o = AQ land -Branch t6 -Onto dev -Purpose 'ledger off'
  Check '6 ledger off: normal land still works' ($code -eq 0) $o
  Remove-Item Env:AGENTQ_NO_FLAKES
} finally {
  Pop-Location
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS land flakes'; exit 0 }
