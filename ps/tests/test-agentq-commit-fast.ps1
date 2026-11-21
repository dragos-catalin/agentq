# ADR 0014 D1: a commit must not queue behind the pre-push gates.
# Measured before: `commit:codai` was HELD 9.2 h over 7 days, because one ticket covered add+commit AND
# fetch+merge+push, and a repo's pre-push hook (husky lint/typecheck) runs inside the push - minutes per
# commit. Every other agent's `git add` waited for the length of someone else's gates.
# Contract now: the index phase holds commit:<repo> (capacity 1, the index is shared state) and releases it
# the moment HEAD moves; the push phase holds push:<repo> (capacity 2) and the pre-push gates run there.
# This suite proves it with a slow pre-push hook: while commit #1 is inside the hook, the commit queue is
# EMPTY, the push queue is OCCUPIED, and commit #2 (another agent) finishes while #1 is still pushing.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqcf-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"minFreeCommitGB":0,"sharedCloneMode":"off"}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); [IO.File]::WriteAllText("$repo\b.txt", "b`n"); [IO.File]::WriteAllText("$repo\c.txt", "c`n")
git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
# a pre-push gate that takes 8 s (LF only: a CRLF shebang/sh script fails under Git for Windows)
[IO.File]::WriteAllText("$repo\.git\hooks\pre-push", "#!/bin/sh`nsleep 8`nexit 0`n")
[IO.File]::WriteAllText("$repo\a.txt", "a2`n"); [IO.File]::WriteAllText("$repo\b.txt", "b2`n"); [IO.File]::WriteAllText("$repo\c.txt", "c2`n")
$qc = Join-Path $env:AGENTQ_HOME 'queues\commit_repo'
$qp = Join-Path $env:AGENTQ_HOME 'queues\push_repo'
function Tickets([string]$d) { @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue).Count }
# who holds a ticket in a resource queue (a peer may legitimately hold the same resource)
function TicketsOf([string]$d, [string]$session) {
  @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.session -eq $session }).Count
}
Push-Location $repo
try {
  $env:AGENTQ_SESSION = 'agent-1'
  $p1 = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $Aq, 'commit', '-Purpose', 'slow-push-1', '-Message', 'test:one', '-Paths', 'a.txt' -PassThru -WindowStyle Hidden
  $env:AGENTQ_SESSION = 'agent-3'
  $p3 = Start-Process pwsh -ArgumentList '-NoProfile', '-File', $Aq, 'commit', '-Purpose', 'slow-push-3', '-Message', 'test:three', '-Paths', 'c.txt' -PassThru -WindowStyle Hidden
  # wait until agent-1 is inside its push (the push ticket appears)
  $inPush = $false
  for ($i = 0; $i -lt 60 -and -not $inPush; $i++) { Start-Sleep -Milliseconds 250; if ((TicketsOf $qp 'agent-1') -ge 1) { $inPush = $true } }
  Check '1 agent-1 reached the push phase' $inPush "commit=$(Tickets $qc) push=$(Tickets $qp)"
  # agent-1 must have RELEASED commit:repo (a peer in its own index phase may legitimately hold it)
  Check '2 agent-1 released the commit ticket' ((TicketsOf $qc 'agent-1') -eq 0) "agent-1 commit tickets: $(TicketsOf $qc 'agent-1')"
  Check '2 agent-1 holds the push ticket' ((TicketsOf $qp 'agent-1') -ge 1) "agent-1 push tickets: $(TicketsOf $qp 'agent-1')"
  # agent-2 COMMITS (no push) a different path while two peers are inside their 8 s pre-push gates.
  # This is the whole point: the index phase must not queue behind anyone's gates. With the old single
  # `commit:repo` ticket this call waited for a full gate (>= 8 s here).
  $env:AGENTQ_SESSION = 'agent-2'
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $o2 = @(& pwsh -NoProfile -File $Aq commit -Purpose 'second' -Message 'test:two' -Paths 'b.txt' -NoPush 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $c2 = $LASTEXITCODE; $sw.Stop()
  Check '3 agent-2 committed' ($c2 -eq 0 -and $o2 -match 'committed') "exit=$c2 after $([int]$sw.Elapsed.TotalSeconds)s`n$o2"
  # Causal, load-independent proof that the index phase did not queue behind the 8 s gates: the gap
  # between this call writing its commit ticket and its commit is the QUEUE WAIT only — pwsh startup and
  # the gate both sit outside it. The old single `commit:repo` ticket produced >= 8 s here; a wall-clock
  # bound on the whole process measures pwsh startup on a shared machine (measured 9.5 s under load
  # 2026-11-21 with the contract respected), which is a load test, not a contract test.
  $jr2 = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.purpose -eq 'second' })
  $tQueued = @($jr2 | Where-Object { $_.event -eq 'queued' -and $_.resource -like 'commit*' } | Select-Object -First 1).ts
  $tCommit = @($jr2 | Where-Object { $_.event -eq 'commit' } | Select-Object -First 1).ts
  $waitSec2 = if ($tQueued -and $tCommit) { ([DateTime]$tCommit - [DateTime]$tQueued).TotalSeconds } else { $null }
  Check '3 the index phase did NOT wait for the gates' ($null -ne $waitSec2 -and $waitSec2 -lt 3.5) "queue->commit $(if ($null -ne $waitSec2) { [math]::Round($waitSec2,1) } else { '?' })s (whole process $([math]::Round($sw.Elapsed.TotalSeconds,1))s; one gate alone is 8 s)"
  # let the two pushers finish: they race for the same branch, the loser must auto-retry (fetch+merge+push)
  foreach ($p in @($p1, $p3)) { if (-not $p.WaitForExit(90000)) { $p.Kill() } }
  Check '4 agent-1 pushed' ($p1.ExitCode -eq 0) "exit=$($p1.ExitCode)"
  Check '4 agent-3 pushed too (lost the ref race and retried)' ($p3.ExitCode -eq 0) "exit=$($p3.ExitCode)"
  $log = @(& git -C $repo log --oneline -3 2>$null | ForEach-Object { "$_" }) -join ' | '
  Check '4 all three commits are in history' ($log -match 'test:one' -and $log -match 'test:two' -and $log -match 'test:three') $log
  $remote = @(& git -C $bare log --oneline -5 2>$null | ForEach-Object { "$_" }) -join ' | '
  Check '4 origin has both pushed commits' ($remote -match 'test:one' -and $remote -match 'test:three') $remote
  $jr = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
  $qpj = @($jr | Where-Object { $_.event -eq 'queued' -and $_.resource -eq 'push:repo' })
  Check '5 the push phase is a first-class resource' ($qpj.Count -ge 2) ($jr | Where-Object { $_.event -eq 'queued' } | ConvertTo-Json -Depth 3)
  $pushEv = @($jr | Where-Object { $_.event -eq 'push' })
  Check '5 pushes are journalled' ($pushEv.Count -ge 2) ($pushEv | ConvertTo-Json -Depth 3)
  $capf = Join-Path $qp 'capacity'
  Check '5 push capacity is 2' ((Test-Path $capf) -and ([int](Get-Content $capf -Raw) -eq 2)) "capacity file: $(if (Test-Path $capf) { Get-Content $capf -Raw } else { 'missing' })"
} finally {
  Pop-Location
  foreach ($p in @($p1, $p3)) { if ($p -and -not $p.HasExited) { $p.Kill() } }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'ALL OK'
