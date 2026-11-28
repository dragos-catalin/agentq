# ADR 0003 W2-6: `agentq land` refuses BEFORE queueing (exit 5, no ticket, no land slot) when the topic
# conflicts with origin/<onto> on a real file; a conflict only in CHANGELOG.md still proceeds (the land
# resolver handles it). Isolated in %TEMP%; bare repo = origin.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqpre-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_SESSION = 'test-P'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Tip { "$((git -C $repo ls-remote origin refs/heads/dev) -split "`t" | Select-Object -First 1)".Trim() }
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'; Set-Content (Join-Path $repo 'CHANGELOG.md') "# Changelog`n`n- base"
git -C $repo add a.txt CHANGELOG.md; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
Push-Location $repo
try {
  # 1. real conflict on a.txt -> exit 5 before queueing
  git -C $tw checkout -q -B clash origin/dev
  Set-Content (Join-Path $tw 'a.txt') 'topic edit'; git -C $tw commit -qam 'topic a'; git -C $tw push -q origin clash 2>$null
  Set-Content (Join-Path $repo 'a.txt') 'dev edit'; git -C $repo commit -qam 'dev a'; git -C $repo push -q origin dev 2>$null
  $t0 = Tip
  $o = AQ land -Branch clash -Onto dev -Purpose 'clash'
  Check 'precheck conflict -> exit 5' ($code -eq 5) $o
  Check 'precheck names the file' ($o -match 'a\.txt' -and $o -match 'Nothing queued') $o
  Check 'nothing pushed' ((Tip) -eq $t0)
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  Check 'journaled land-precheck-conflict' (@($j | Where-Object event -eq 'land-precheck-conflict').Count -eq 1)
  Check 'never queued (no land ticket, no land lease)' (-not @($j | Where-Object { $_.event -eq 'queued' -and "$($_.resource)" -like 'land:*' }).Count -and -not (Test-Path (Join-Path $env:AGENTQ_HOME 'leases\repo\land.json')))
  # 2. AGENTQ_LAND_NO_PRECHECK=1 skips it -> the classic in-slot conflict path (still exit 5)
  $env:AGENTQ_LAND_NO_PRECHECK = '1'
  $o = AQ land -Branch clash -Onto dev -Purpose 'clash no precheck'
  Remove-Item Env:AGENTQ_LAND_NO_PRECHECK
  Check 'opt-out: in-slot conflict path, exit 5' ($code -eq 5 -and $o -match 'CONFLICT picking') $o
  # 3. conflict ONLY in CHANGELOG.md -> not refused, lands via the union resolver
  git -C $repo pull -q --no-rebase origin dev 2>$null
  git -C $tw fetch -q origin; git -C $tw checkout -q -B cl origin/dev
  [IO.File]::WriteAllText((Join-Path $tw 'CHANGELOG.md'), "# Changelog`n`n- topic entry`n- base`n")
  Set-Content (Join-Path $tw 'b.txt') 'b'; git -C $tw add CHANGELOG.md b.txt; git -C $tw commit -qm 'topic b'; git -C $tw push -q origin cl 2>$null
  [IO.File]::WriteAllText((Join-Path $repo 'CHANGELOG.md'), "# Changelog`n`n- dev entry`n- base`n")
  git -C $repo commit -qam 'dev cl'; git -C $repo push -q origin dev 2>$null
  $o = AQ land -Branch cl -Onto dev -Purpose 'changelog only'
  Check 'CHANGELOG-only conflict is not refused, lands' ($code -eq 0 -and $o -match 'landed cl') $o
  # 4. The PUSHED tip conflicts with origin/dev, but the LOCAL (rebased) tip is a CLEAN descendant of it -
  #    what a rebase in the slot produces. The precheck MUST judge the ref land merges (the local tip) and
  #    land, not read origin/<branch> and refuse. Old behaviour: exit 5 "does not merge onto" on a branch
  #    the user had already rebased (brivio 2026-11-21). The pre-gate and the merge already use
  #    Resolve-LandRef (local-first); the precheck must agree with them.
  git -C $repo pull -q --no-rebase origin dev 2>$null
  git -C $tw fetch -q origin
  git -C $tw checkout -q -B reb origin/dev
  Set-Content (Join-Path $tw 'a.txt') 'reb clash'; git -C $tw commit -qam 'reb clash'; git -C $tw push -q origin reb 2>$null
  Set-Content (Join-Path $repo 'a.txt') 'dev after reb'; git -C $repo commit -qam 'dev reb'; git -C $repo push -q origin dev 2>$null
  git -C $repo fetch -q origin reb
  git -C $tw fetch -q origin dev
  git -C $tw checkout -q -B reb origin/dev
  Set-Content (Join-Path $tw 'c.txt') 'c'; git -C $tw add c.txt; git -C $tw commit -qm 'reb rebased (local only)'
  $devTop = (git -C $repo rev-parse origin/dev).Trim()
  git -C $repo merge-tree --write-tree --name-only --no-messages origin/dev refs/remotes/origin/reb > $null 2>&1
  Check 'rebased: pushed tip conflicts' ($LASTEXITCODE -eq 1)
  $mb = (git -C $repo merge-base (git -C $repo rev-parse refs/heads/reb).Trim() origin/dev).Trim()
  Check 'rebased: local tip is a clean descendant' ($mb -eq $devTop)
  $o = AQ land -Branch reb -Onto dev -Purpose 'rebased local tip'
  Check 'rebased local tip: not refused, lands' ($code -eq 0 -and $o -match 'landed reb') $o
  git -C $repo fetch -q origin dev
  git -C $repo cat-file -e origin/dev:c.txt 2>$null
  Check 'reb content is on origin/dev' ($LASTEXITCODE -eq 0)
  # 5. The in-slot conflict message must be self-sufficient (2026-11-23): the paths AND the exact
  #    commands, naming the slot. The merge is computed when the ticket reaches the head of the queue,
  #    not when it was queued, so "rebase and land again" cannot be followed while a long queue wait is
  #    still ahead - the message has to say that too, or it is not actionable.
  $env:AGENTQ_LAND_NO_PRECHECK = '1'
  $t0 = Tip
  $o = AQ land -Branch clash -Onto dev -Purpose 'conflict message'
  Check 'in-slot conflict -> exit 5' ($code -eq 5) $o
  Check 'message names the conflicted path' ($o -match 'CONFLICT picking\b' -and $o -match 'a\.txt') $o
  Check 'message says nothing was pushed' ($o -match 'Nothing pushed') $o
  Check 'message explains the merge is computed at ACQUIRE time' ($o -match 'ACQUIRE time') $o
  Check 'message says origin moved underneath the queued branch' ($o -match 'moved underneath') $o
  Check 'message says rebasing before queuing is not enough' ($o -match 'before you queued is not enough') $o
  Check 'message prints the three commands, same slot, onto the CURRENT origin' ($o -match '(?s)git -C "([^"]+)" fetch origin dev.*git -C "\1" rebase origin/dev.*agentq land -Branch clash -Onto dev -Purpose') $o
  Check 'message points at -RebaseOnConflict' ($o -match '\-RebaseOnConflict') $o
  Check 'message conflict: nothing pushed' ((Tip) -eq $t0)
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  Check 'no rebase attempted without the switch' (-not @($j | Where-Object { "$($_.event)" -like 'land-rebase-*' }).Count)
  # 6. -RebaseOnConflict: clash really does conflict with origin/dev, so the rebase conflicts too. It must
  #    abort the rebase, say so, leave no rebase or throwaway branch behind, and push nothing.
  $o = AQ land -Branch clash -Onto dev -Purpose 'rebase conflicts too' -RebaseOnConflict
  Remove-Item Env:AGENTQ_LAND_NO_PRECHECK
  Check '-RebaseOnConflict: still exit 5' ($code -eq 5) $o
  Check '-RebaseOnConflict: says the rebase was aborted and the slot left clean' ($o -match 'rebasing .* onto origin/dev conflicts too' -and $o -match 'aborted') $o
  Check '-RebaseOnConflict: still names the conflicted path' ($o -match 'a\.txt') $o
  Check '-RebaseOnConflict: nothing pushed' ((Tip) -eq $t0)
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  Check '-RebaseOnConflict: journaled land-rebase-conflict' (@($j | Where-Object event -eq 'land-rebase-conflict').Count -ge 1)
  $left = @(Get-ChildItem -LiteralPath (Join-Path $repo '.git') -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -in 'rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD', 'MERGE_HEAD', 'REBASE_HEAD' })
  Check '-RebaseOnConflict: no rebase/cherry-pick left behind' (-not $left.Count) (($left | ForEach-Object FullName) -join ' | ')
  Check '-RebaseOnConflict: no throwaway branch left' (-not "$(& git -C $repo branch --list 'agentq-rebase-*')".Trim())
  # 7. -RebaseOnConflict on a branch that does NOT conflict is a no-op: it still lands, and it journals
  #    no rebase at all (the flag only acts on a failed pick). Scenario 4 covers the same land with the
  #    switch absent, so together they pin flag-absent == flag-present on a clean topic.
  git -C $repo pull -q --no-rebase origin dev 2>$null
  git -C $tw fetch -q origin; git -C $tw checkout -q -B ok2 origin/dev
  Set-Content (Join-Path $tw 'd.txt') 'd'; git -C $tw add d.txt; git -C $tw commit -qm 'ok2'; git -C $tw push -q origin ok2 2>$null
  $j0 = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  $o = AQ land -Branch ok2 -Onto dev -Purpose 'clean with the switch' -RebaseOnConflict
  Check '-RebaseOnConflict on a clean branch: lands' ($code -eq 0 -and $o -match 'landed ok2') $o
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  Check '-RebaseOnConflict on a clean branch: no rebase journaled' (@($j | Where-Object { "$($_.event)" -like 'land-rebase-*' }).Count -eq @($j0 | Where-Object { "$($_.event)" -like 'land-rebase-*' }).Count)
  # 6. (c) owner 2026-11-28: `land -WaitShare [-WaitShareMin n]` waits for the fair share to ADMIT a land
  #    slot instead of refusing at once, and stays BOUNDED - on the bound the pre-existing refusal is
  #    returned unchanged (exit 3, nothing queued, no ticket, nothing pushed). Two halves: the bound
  #    expiring, and a wait that is admitted because the competing unit goes away while it polls.
  #    The share needs CONTENTION: two live leases in THIS repo from two sessions, against a derived cap of
  #    1 (taskSlotsMachine 2 + floor 0, pinned with the AGENTQ_TEST_SLOT_BUDGET seam) -> share 1, and this
  #    session already holds 1, so a land is refused. A lone session is never capped, so deleting the other
  #    lease mid-wait is what "the share frees" looks like from a real caller.
  Set-Content $cfg '{"taskSlotsPerRepo":2,"taskSlotsMachine":2,"taskSlotsMachineFloor":0,"scratchSlots":2,"scratchSlotsMax":4,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseMaxIdleMin":1440,"machineCap":2}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'
  $env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_REGISTRY = '1'
  $env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_AGENT_LIMIT = '1'; $env:AGENTQ_NO_PRUNE = '1'
  $env:AGENTQ_SESSION = 'other'
  $null = AQ lease -Role scratch -Purpose 'competing unit' -Slot scratch-1 -Json
  $env:AGENTQ_SESSION = 'test-P'
  $null = AQ lease -Role scratch -Purpose 'mine' -Slot scratch-2 -Json
  $compLease = Join-Path $env:AGENTQ_HOME 'leases\repo\scratch-1.json'
  Check '(c) fixture: two live leases in this repo from two sessions are in place' ((Test-Path $compLease) -and (Test-Path (Join-Path $env:AGENTQ_HOME 'leases\repo\scratch-2.json')))
  git -C $repo pull -q --no-rebase origin dev 2>$null
  git -C $tw fetch -q origin; git -C $tw checkout -q -B ws1 origin/dev
  Set-Content (Join-Path $tw 'e.txt') 'e'; git -C $tw add e.txt; git -C $tw commit -qm 'ws1'; git -C $tw push -q origin ws1 2>$null
  $t0 = Tip
  # the journal is NOT reset between cases: the earlier lands left `queued`/`land-*` lines behind, so only
  # the lines THIS call adds can be asserted on.
  $jLines0 = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl')).Count
  $o = AQ land -Branch ws1 -Onto dev -Purpose 'share bound expires' -WaitShare -WaitShareMin 0
  $jb = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | Select-Object -Skip $jLines0 | ForEach-Object { $_ | ConvertFrom-Json })
  Check '(c) -WaitShareMin 0: the bound expires at once and the land is refused as before (exit 3)' ($code -eq 3 -and $o -match 'REFUSED after waiting 0 min') $o
  Check '(c) bound expiry: the wait AND the refusal are both journaled' (@($jb | Where-Object event -eq 'land-share-wait').Count -ge 1 -and @($jb | Where-Object event -eq 'land-share-refused').Count -ge 1)
  Check '(c) bound expiry: nothing queued, no land ticket, no land lease, nothing pushed' (-not @($jb | Where-Object { $_.event -eq 'queued' -and "$($_.resource)" -like 'land:*' }).Count -and -not @($jb | Where-Object { $_.event -eq 'lease' -and "$($_.resource)" -like 'slot:*:land' }).Count -and ((Tip) -eq $t0))
  # half 2: admitted. The wait polls every 10 s; the competing lease is removed 3 s in, which is exactly
  # what a seat freeing looks like (no re-run by hand, and the pre-gate's green ledger entry is not thrown
  # away). The land then runs to completion for real.
  # The journal is not reset between the two halves either: half 1 journals its own `land-share-wait`, so
  # half 2 MUST be scanned from a boundary taken after half 1 finished. Off that boundary the poll below
  # would break on half 1's stale line 0.5 s in, free the seat before half 2's share probe runs, and the
  # land would simply land - passing a weaker test that never proves the wait.
  $jLines1 = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl')).Count
  $job = Start-Job -ScriptBlock {
    param($exe, $dir)
    Set-Location -LiteralPath $dir
    $o = @(& pwsh -NoProfile -File $exe land -Branch ws1 -Onto dev -Purpose 'share admits mid-wait' -WaitShare -WaitShareMin 5 2>&1 | ForEach-Object { "$_" })
    [pscustomobject]@{ code = $LASTEXITCODE; out = ($o -join "`n") }
  } -ArgumentList $Aq, $repo
  # WAIT until the land has actually ENTERED the wait before freeing the seat: the share probe runs after
  # the precheck, which costs a few seconds, so a fixed sleep can free the lease BEFORE the probe and the
  # land then never waits at all (it lands - passing a weaker test).
  $entered = $false
  $heldWhenEntered = $false
  foreach ($n in 1..120) {
    Start-Sleep -Milliseconds 500
    if (@(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | Select-Object -Skip $jLines1 | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.event -eq 'land-share-wait' }).Count) {
      $entered = $true
      # ...and the seat must STILL be held at that moment, or the wait was not entered under contention
      $heldWhenEntered = Test-Path $compLease
      break
    }
  }
  Check '(c) admitted: the land really entered the wait (journal land-share-wait) before the seat is freed' ($entered -and $heldWhenEntered)
  Remove-Item -LiteralPath $compLease -Force -ErrorAction SilentlyContinue
  $r = Receive-Job $job -Wait -AutoRemoveJob
  Check '(c) admitted: the land proceeds once the competing unit goes away (exit 0, landed)' ($r.code -eq 0 -and $r.out -match 'landed ws1') "code=$($r.code) :: $($r.out)"
  $jc = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | Select-Object -Skip $jLines1 | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq 'land-share-admitted')
  Check '(c) admitted: journaled land-share-admitted with the seconds waited' ($jc.Count -ge 1 -and "$($jc[0].waitedSec)" -match '^\d+$')
  Remove-Item Env:\AGENTQ_TEST_SLOT_BUDGET -ErrorAction SilentlyContinue
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_LAND_NO_PRECHECK') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  foreach ($v in 'AGENTQ_TEST_SLOT_BUDGET', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_AGENT_LIMIT', 'AGENTQ_NO_PRUNE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
