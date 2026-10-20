# ADR 0003 W2-5: land batching. While a blocker land holds the queue, 3 more lands wait; the next holder
# absorbs the other waiters (same -Onto, same -Gate), runs ONE gate and ONE push. A batch containing a
# bad topic is bisected: the good topics land, only the culprit fails (exit 6). Absorbed waiters exit
# with their own topic's code. Batching off (no config) = one gate per land. Isolated in %TEMP%.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqbat-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'
Remove-Item Env:AGENTQ_LAND_BATCH -ErrorAction SilentlyContinue
$env:AGENTQ_RUN_BUILD = Join-Path $PSScriptRoot 'fake-gate.ps1'
$env:FAKE_GATE_LOG = Join-Path $tmp 'gates.log'
$env:FAKE_GATE_HOLD = Join-Path $tmp 'hold.flag'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
$fail = 0; $script:procs = @()
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function Events([string]$e) { if (-not (Test-Path (Join-Path $env:AGENTQ_HOME 'journal.jsonl'))) { return @() }; @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq $e) }
function Remote([string]$f) { (git -C $repo show "origin/dev:$f" 2>$null) -join '' }
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'
git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$repoName = Split-Path -Leaf $repo
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
function Topic([string]$name, [string]$file) {
  git -C $tw fetch -q origin 2>$null
  git -C $tw checkout -q -B $name origin/dev
  Set-Content (Join-Path $tw $file) $name; git -C $tw add $file; git -C $tw commit -qm "topic $name"
  git -C $tw push -q origin $name 2>$null
  git -C $repo fetch -q origin 2>$null
}
# Starts a land in the background; returns the process + its output file.
function Start-Land([string]$branch, [string]$session) {
  $outF = Join-Path $tmp "$branch.out"
  $cmd = "`$env:AGENTQ_SESSION='$session'; Set-Location '$repo'; & pwsh -NoProfile -File '$Aq' land -Branch $branch -Onto dev -Gate 'gate' -Purpose 'land $branch' *> '$outF'; exit `$LASTEXITCODE"
  $p = Start-Process pwsh -ArgumentList @('-NoProfile', '-Command', $cmd) -PassThru -WindowStyle Hidden
  $script:procs += $p
  @{ p = $p; out = $outF; branch = $branch }
}
function Wait-Queued([int]$n) { for ($i = 0; $i -lt 120; $i++) { if (@(Events 'queued').Count -ge $n) { return $true }; Start-Sleep -Milliseconds 500 }; $false }
# 600 s: the bisection case runs several gates; 240 s timed out under machine load (run-all 2026-10-19 22:00, all -1).
function Finish($l) { if (-not $l.p.WaitForExit(600000)) { try { $l.p.Kill($true) } catch {} ; return -1 }; $l.p.ExitCode }
function Run-Scenario([string]$tag, [string[]]$files) {
  Set-Content $env:FAKE_GATE_HOLD 'x'
  Topic "blocker$tag" "blk$tag.txt"
  $b = Start-Land "blocker$tag" "s-blk$tag"
  $q0 = @(Events 'queued').Count
  [void](Wait-Queued ($q0 + 1))
  for ($i = 0; $i -lt 120 -and -not (Select-String -LiteralPath $env:FAKE_GATE_LOG -Pattern "blocker$tag" -Quiet -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
  $ls = @()
  $k = 0
  foreach ($f in $files) { $k++; Topic "t$tag$k" $f; $ls += Start-Land "t$tag$k" "s-$tag$k"; [void](Wait-Queued ($q0 + 1 + $k)) }
  Start-Sleep -Seconds 2
  Remove-Item $env:FAKE_GATE_HOLD -Force
  $rb = Finish $b
  $codes = @{}; foreach ($l in $ls) { $codes[$l.branch] = Finish $l }
  @{ blocker = $rb; codes = $codes; lands = $ls }
}
Push-Location $repo
try {
  # 1. batching ON: 3 waiters -> one batch, one gate for all three
  "{`"taskSlotsPerRepo`":2,`"taskSlotsMachine`":3,`"leaseDeadIdleMin`":1,`"leaseMaxIdleMin`":5,`"minFreeCommitGB`":0,`"landBatch`":{`"$repoName`":true}}" | Set-Content $cfg
  $env:AGENTQ_CONFIG = $cfg
  $r = Run-Scenario 'A' @('x1.txt', 'x2.txt', 'x3.txt')
  git -C $repo fetch -q origin
  $outs = ($r.lands | ForEach-Object { Get-Content $_.out -Raw -ErrorAction SilentlyContinue }) -join "`n---`n"
  Check '1 blocker landed' ($r.blocker -eq 0) $outs
  Check '1 all three waiters exit 0' (@($r.codes.Values | Where-Object { $_ -ne 0 }).Count -eq 0) (($r.codes | ConvertTo-Json -Compress) + "`n" + $outs)
  Check '1 all three on origin' ((Remote 'x1.txt') -eq 'tA1' -and (Remote 'x2.txt') -eq 'tA2' -and (Remote 'x3.txt') -eq 'tA3') $outs
  $gates = @(Get-Content $env:FAKE_GATE_LOG | Where-Object { $_ -match 'tA' })
  Check '1 one gate for the batch' ($gates.Count -eq 1 -and $gates[0] -match 'tA1\+tA2\+tA3') ($gates -join ' | ')
  $bat = @(Events 'land-batch')
  Check '1 land-batch journaled (size 3, not bisected)' ($bat.Count -eq 1 -and $bat[0].size -eq 3 -and -not $bat[0].bisected) ($bat | ConvertTo-Json -Compress)
  Check '1 one land event per topic, attributed to its session' (@(Events 'land' | Where-Object { "$($_.reason)" -match '^tA\d' -and "$($_.session)" -like 's-A*' }).Count -eq 3)

  # 2. a bad topic in the batch -> bisect: the good ones land, the bad one exits 6
  Clear-Content $env:FAKE_GATE_LOG
  $r = Run-Scenario 'B' @('y1.txt', 'bad.txt', 'y3.txt')
  git -C $repo fetch -q origin
  $outs = ($r.lands | ForEach-Object { Get-Content $_.out -Raw -ErrorAction SilentlyContinue }) -join "`n---`n"
  Check '2 good topics landed' ($r.codes['tB1'] -eq 0 -and $r.codes['tB3'] -eq 0 -and (Remote 'y1.txt') -eq 'tB1' -and (Remote 'y3.txt') -eq 'tB3') (($r.codes | ConvertTo-Json -Compress) + "`n" + $outs)
  Check '2 culprit exits 6 and is not on origin' ($r.codes['tB2'] -eq 6 -and -not (Remote 'bad.txt')) (($r.codes | ConvertTo-Json -Compress) + "`n" + $outs)
  $bat = @(Events 'land-batch' | Select-Object -Last 1)
  Check '2 land-batch bisected' ($bat.Count -eq 1 -and $bat[0].bisected) ($bat | ConvertTo-Json -Compress)

  # 3. batching OFF (no landBatch): one gate per land
  '{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
  Clear-Content $env:FAKE_GATE_LOG
  $nb = @(Events 'land-batch').Count
  $r = Run-Scenario 'C' @('z1.txt', 'z2.txt')
  git -C $repo fetch -q origin
  Check '3 off: both land' ($r.codes['tC1'] -eq 0 -and $r.codes['tC2'] -eq 0 -and (Remote 'z2.txt') -eq 'tC2')
  $gates = @(Get-Content $env:FAKE_GATE_LOG | Where-Object { $_ -match 'tC' })
  Check '3 off: one gate per topic, no batch' ($gates.Count -eq 2 -and @(Events 'land-batch').Count -eq $nb) ($gates -join ' | ')
} finally {
  Pop-Location
  foreach ($p in $script:procs) { try { if (-not $p.HasExited) { $p.Kill($true) } } catch {} }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS land batch'; exit 0 }
