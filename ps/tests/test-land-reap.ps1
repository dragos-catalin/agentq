# Land queue resilience (2026-11-23): two wedges that both stalled the cap-1 land lock.
#   A) land-autoreap - a HOLDER whose gate is GREEN but which never landed, with a STALE heartbeat while its
#      pid is still ALIVE, used to hold land:<repo> forever (measured 85.9 min on one topic, released only by
#      a MANUAL `agentq break -Id`). A land WAITER must reap it from the waiting side and take the lock.
#   B) land-requeue - a waiter that hit its landWaitMin window used to LEAVE the queue (exit 3), so with a
#      deep queue the attempts "evaporated" (10 x "timed out after 60 min" in 90 min). It must go back to the
#      HEAD of the queue (seq 0, original prio/bump kept), bounded by landRequeueMax, and only then give up.
#   C) negative - a STALE holder whose gate is NOT green must never be touched (that may be a long gate).
# The holders here are SYNTHETIC tickets written straight into the queue (pid = this test process, so they
# look alive); no child land is needed for the holder. Isolated in %TEMP%; ~3.5 min.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqlr-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'
$env:AGENTQ_LAND_NO_PREGATE = '1'
$env:AGENTQ_RUN_BUILD = Join-Path $PSScriptRoot 'fake-gate.ps1'
$env:FAKE_GATE_LOG = Join-Path $tmp 'gates.log'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function JEvents([string]$ev) {
  $f = Join-Path $env:AGENTQ_HOME 'journal.jsonl'
  if (-not (Test-Path $f)) { return @() }
  @(Get-Content -LiteralPath $f | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.event -eq $ev })
}
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$cfg = Join-Path $tmp 'cfg.json'
$env:AGENTQ_CONFIG = $cfg
function Set-Cfg([int]$requeueMax) { '{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"minFreeCommitGB":0,"landBatchMax":1,"landWaitMin":1,"landRequeueMax":' + $requeueMax + '}' | Set-Content $cfg }
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
function Topic([string]$name, [string]$file) {
  git -C $tw checkout -q -B $name origin/dev
  Set-Content (Join-Path $tw $file) $name; git -C $tw add $file; git -C $tw commit -qm "topic $name"
  git -C $tw push -q origin $name 2>$null
  git -C $repo fetch -q origin 2>$null
}
$qdir = Join-Path $env:AGENTQ_HOME 'queues\land_repo'
function Clean-Queue { if (Test-Path $qdir) { Get-ChildItem $qdir -File -Filter '*.json*' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue } } }
# A holder ticket that looks ALIVE (pid = this test process) but is not managed by any agentq run.
function PlantHolder([string]$id, [string]$session, [switch]$Stale, [switch]$Green) {
  New-Item -ItemType Directory -Force $qdir | Out-Null
  [IO.File]::WriteAllText((Join-Path $qdir 'capacity'), '1')
  [IO.File]::WriteAllText((Join-Path $qdir 'seq'), '5')   # -> the waiter's own ticket gets seq 6, ranked AFTER the holder
  $me = Get-Process -Id $PID
  $t = [ordered]@{
    id = $id; seq = 1; resource = 'land:repo'; pid = $PID; procStart = $me.StartTime.ToUniversalTime().ToString('o')
    session = $session; purpose = "holder $id"; cmd = 'land'; repo = 'repo'; host = [Environment]::MachineName
    created = (Get-Date).ToUniversalTime().ToString('o'); v = 3; lane = 'gate'; prio = 0; bump = 0
    held = $true; ready = $true; claims = @(); leaseCreated = ''
  }
  $file = Join-Path $qdir ("{0:D8}-{1}.json" -f 1, $id)
  [IO.File]::WriteAllText($file, ($t | ConvertTo-Json -Compress))
  $hb = "$file.hb"; [IO.File]::WriteAllText($hb, '')
  if ($Stale) { [IO.File]::SetLastWriteTimeUtc($hb, [DateTime]::UtcNow.AddMinutes(-20)) }
  if ($Green) {
    $gdir = Join-Path $env:AGENTQ_HOME 'green'; New-Item -ItemType Directory -Force $gdir | Out-Null
    $g = @{}
    $g[('beef' * 10) + '|' + ('0' * 12)] = [ordered]@{ at = (Get-Date).ToUniversalTime().ToString('o'); sec = 7; where = 'land'; by = $session; gate = 'gate' }
    [IO.File]::WriteAllText((Join-Path $gdir 'repo.json'), ($g | ConvertTo-Json -Depth 4))
  }
  $file
}
function RunLand([string]$session, [string]$branch) {
  $env:AGENTQ_SESSION = $session
  Push-Location $repo
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $o = @(& pwsh -NoProfile -File $Aq land -Branch $branch -Onto dev -Gate 'gate' -Purpose "land $branch" 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $code = $LASTEXITCODE; $sw.Stop()
  Pop-Location
  @{ code = $code; out = $o; sec = $sw.Elapsed.TotalSeconds }
}
# `@(...) -match 'x'` returns the MATCHING ELEMENTS (an array), and Check's [bool] parameter refuses an
# array: the assertion has to be a real boolean.
function DevHas([string]$pattern) { [bool]@(git -C $bare log --format=%s dev | Where-Object { "$_" -match $pattern }).Count }
try {
  Topic 'w1' 'w1.txt'; Topic 'w2' 'w2.txt'; Topic 'w3' 'w3.txt'

  # ---- C) negative: STALE but NOT green -> must never be touched (run first: nothing pre-litters the queue)
  Clean-Queue; Set-Cfg 0
  $null = PlantHolder -id 'stale2' -session 'holder-stale2' -Stale
  $r = RunLand 's-w-c' 'w3'
  Check 'C: stale non-green holder is NOT reaped (waiter gives up, exit 3)' ($r.code -eq 3) "code=$($r.code) $($r.out)"
  Check 'C: no land-autoreap journaled for it' (@(JEvents 'land-autoreap' | Where-Object { $_.ticket -eq 'stale2' }).Count -eq 0)
  Check 'C: the stale non-green holder is still in the queue' (Test-Path (Join-Path $qdir '00000001-stale2.json'))

  # ---- A) the wedge: STALE + ALIVE + gate GREEN + no land event -> the waiter reaps it and lands
  Clean-Queue; Set-Cfg 2
  $wf = PlantHolder -id 'wedge01' -session 'holder-wedge' -Stale -Green
  $r = RunLand 's-w-a' 'w1'
  $jr = @(JEvents 'land-autoreap')
  Check 'A: land proceeds after the reap (exit 0)' ($r.code -eq 0) "code=$($r.code) $($r.out)"
  Check 'A: journaled land-autoreap with the ticket id' ($jr.Count -eq 1 -and $jr[0].ticket -eq 'wedge01') ($jr | ConvertTo-Json -Compress)
  Check 'A: land-autoreap names the held + stale minutes' ($jr.Count -eq 1 -and [double]$jr[0].staleMin -ge 10 -and [double]$jr[0].heldSec -ge 0) ($jr | ConvertTo-Json -Compress)
  Check 'A: land-autoreap records the holder session' ($jr.Count -eq 1 -and $jr[0].holderSession -eq 'holder-wedge') ($jr | ConvertTo-Json -Compress)
  Check 'A: the wedged holder ticket is gone' (-not (Test-Path $wf))
  Check 'A: the topic actually landed on dev' (DevHas 'topic w1')

  # ---- B) requeue: a FRESH live holder the waiter cannot reap -> requeue once (cap 1) then give up
  Clean-Queue; Set-Cfg 1
  $hf = PlantHolder -id 'fresh01' -session 'holder-fresh'
  $r = RunLand 's-w-b' 'w2'
  $jq = @(JEvents 'land-requeue')
  Check 'B: waiter gives up only after the requeue cap (exit 3)' ($r.code -eq 3) "code=$($r.code) $($r.out)"
  Check 'B: journaled land-requeue exactly once (cap 1)' ($jq.Count -eq 1) ($jq | ConvertTo-Json -Compress)
  Check 'B: land-requeue carries attempts + waitedSec' ($jq.Count -eq 1 -and [int]$jq[0].attempts -eq 1 -and [int]$jq[0].waitedSec -ge 55) ($jq | ConvertTo-Json -Compress)
  Check 'B: requeue put the ticket at the HEAD (seq 0)' ($jq.Count -eq 1 -and [long]$jq[0].seq -eq 0) ($jq | ConvertTo-Json -Compress)
  Check 'B: the requeue message says the attempt is not lost' ($r.out -match 'put back at the HEAD') $r.out
  Check 'B: a FRESH holder is never reaped' (@(JEvents 'land-autoreap' | Where-Object { $_.ticket -eq 'fresh01' }).Count -eq 0)
  Check 'B: the fresh holder is still in the queue' (Test-Path $hf)
  Check 'B: nothing of w2 was pushed' (-not (DevHas 'topic w2'))
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'ALL PASS'
