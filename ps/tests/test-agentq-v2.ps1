# Behavioural tests for agentq v2 (ADR 0001): slot leases, stale expiry + backup, break-by-id,
# release phases + supersede + coalescing, landing queue (dedupe, CHANGELOG union, conflict).
# Isolated: AGENTQ_HOME, CODAI_WT_ROOT and AGENTQ_CONFIG point into %TEMP%; a bare repo = origin.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqv2-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_SESSION = 'test-A'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"pinned":{"repo":["db-live"]},"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t
Set-Content (Join-Path $repo 'a.txt') 'a'; Set-Content (Join-Path $repo 'CHANGELOG.md') "# Changelog`n"
git -C $repo add a.txt CHANGELOG.md; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
Push-Location $repo
try {
  # --- leases ---------------------------------------------------------------------------
  $o = AQ lease -Purpose 'feature x' -Branch feat/x -Json
  $l1 = $o | Select-Object -Last 1 | ConvertFrom-Json
  Check 'lease task -> task-1 under wt root' ($code -eq 0 -and $l1.slot -eq 'task-1' -and (Test-Path (Join-Path $l1.path 'a.txt'))) $o
  Check 'lease checks out the branch' ((git -C $l1.path rev-parse --abbrev-ref HEAD) -eq 'feat/x')
  $o = AQ lease -Purpose 'feature y' -Json; $l2 = $o | Select-Object -Last 1 | ConvertFrom-Json
  Check 'second lease -> task-2' ($l2.slot -eq 'task-2') $o
  $o = AQ lease -Purpose 'too many' -NoWait
  Check 'per-repo task cap refuses (exit 3)' ($code -eq 3) $o
  $o = AQ lease -Slot 'v3-dmarc' -Purpose 'ad hoc'
  Check 'non-standard slot name refused' ($code -ne 0 -and $o -match 'not a standard slot') $o
  $o = AQ lease -Slot 'db-live' -Purpose 'pinned' -Json; $lp = $o | Select-Object -Last 1 | ConvertFrom-Json
  Check 'pinned slot from config works' ($lp.role -eq 'pinned') $o
  # machine cap = 3 tasks: a second repo's task lease is refused while 2 are held here? cap counts tasks only (2 held) -> allowed once
  $o = AQ lease-check -Path (Join-Path $l1.path 'sub\dir')
  Check 'lease-check inside slot -> LEASED exit 3' ($code -eq 3 -and $o -match 'LEASED repo/task-1') $o
  $o = AQ lease-check -Path $env:CODAI_WT_ROOT
  Check 'lease-check on parent dir -> LEASED' ($code -eq 3) $o
  $o = AQ lease-check -Path (Join-Path $env:CODAI_WT_ROOT 'repo\task-3')
  Check 'lease-check unrelated path -> FREE' ($code -eq 0) $o
  $st = AQ status -Json | ConvertFrom-Json
  Check 'status -Json lists leases' (@($st.leases).Count -eq 3) "$(@($st.leases).Count)"

  # break-by-id: foreign session without id / without reason refused
  $env:AGENTQ_SESSION = 'test-B'
  $o = AQ unlease -Repo $l1.path
  Check 'unlease without -LeaseId refused (exit 2)' ($code -eq 2) $o
  $o = AQ unlease -Repo $l1.path -LeaseId $l1.leaseId
  Check 'foreign unlease without -Reason refused' ($code -eq 2) $o
  $env:AGENTQ_SESSION = 'test-A'

  # unlease with dirty + untracked + unpushed state -> backup ref on origin, proven
  Set-Content (Join-Path $l1.path 'a.txt') 'edited'; Set-Content (Join-Path $l1.path 'new.txt') 'untracked'
  git -C $l1.path -c user.email=t@t -c user.name=t commit -qm 'local only' --allow-empty
  $o = AQ unlease -Repo $l1.path -LeaseId $l1.leaseId
  $ref = ([regex]::Match($o, 'refs/backup/wt/[^\s)]+')).Value
  Check 'unlease backs up to refs/backup/wt/... ' ($code -eq 0 -and $ref) $o
  $remoteSha = ((git -C $repo ls-remote origin $ref) -split '\s+')[0]
  Check 'backup ref exists on origin' ([bool]$remoteSha)
  Check 'backup contains tracked edit' ((git -C $repo --git-dir=$bare show "${remoteSha}:a.txt") -eq 'edited')
  Check 'backup contains untracked file' ((git -C $repo --git-dir=$bare show "${remoteSha}:new.txt") -eq 'untracked')
  Check 'backup parent = unpushed local commit' ((git --git-dir=$bare log -1 --format=%s "$remoteSha^") -eq 'local only')
  Check 'no stash used' (-not (git -C $repo stash list))
  Check 'branches untouched (feat/x still exists)' ([bool](git -C $repo rev-parse --verify -q refs/heads/feat/x))

  # reuse: next lease of task-1 is reset clean at the ref
  $o = AQ lease -Slot task-1 -Purpose 'reuse' -Json; $l3 = $o | Select-Object -Last 1 | ConvertFrom-Json
  Check 'reused slot is clean at origin/dev' ((Test-Path (Join-Path $l3.path 'new.txt')) -eq $false -and (Get-Content (Join-Path $l3.path 'a.txt')) -eq 'a') $o

  # stale: dead owner + idle > 1 min -> sweep backs up and expires
  $lf = Join-Path $env:AGENTQ_HOME 'leases\repo\task-2.json'
  $j = Get-Content $lf -Raw | ConvertFrom-Json; $j.pid = 999999; $j | ConvertTo-Json | Set-Content $lf
  Set-Content (Join-Path $l2.path 'wip.txt') 'wip'
  [IO.File]::SetLastWriteTimeUtc("$lf.hb", [DateTime]::UtcNow.AddMinutes(-3))
  $st = AQ status -Json | ConvertFrom-Json
  Check 'dead owner + idle > deadIdle -> STALE' ((@($st.leases) | Where-Object slot -eq 'task-2').stale -eq $true)
  $o = AQ sweep
  Check 'sweep expires stale lease' ($o -match 'expired repo/task-2' -and -not (Test-Path $lf)) $o
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'lease-expire' })
  Check 'expire journaled with backup ref' ($j.Count -eq 1 -and $j[0].ref -like 'refs/backup/wt/repo/task-2/*')
  # alive owner but idle > max -> stale too; alive + recently active -> not stale
  $lf3 = Join-Path $env:AGENTQ_HOME 'leases\repo\task-1.json'
  $st = AQ status -Json | ConvertFrom-Json
  Check 'alive recent lease not stale' ((@($st.leases) | Where-Object slot -eq 'task-1').stale -eq $false)
  # renew via agentq call from inside the slot
  [IO.File]::SetLastWriteTimeUtc("$lf3.hb", [DateTime]::UtcNow.AddMinutes(-4))
  Push-Location $l3.path; AQ note -Message 'activity' | Out-Null; Pop-Location
  $age = ([DateTime]::UtcNow - (Get-Item "$lf3.hb").LastWriteTimeUtc).TotalSeconds
  Check 'agentq call inside slot renews lease' ($age -lt 30) "age ${age}s"
  [IO.File]::SetLastWriteTimeUtc("$lf3.hb", [DateTime]::UtcNow.AddMinutes(-6))
  $st = AQ status -Json | ConvertFrom-Json
  Check 'alive owner but idle > maxIdle -> STALE' ((@($st.leases) | Where-Object slot -eq 'task-1').stale -eq $true)
  AQ renew -Path $l3.path | Out-Null
  # failed backup keeps the lease (fail closed): break origin, make dirty, expire
  git -C $repo remote set-url origin (Join-Path $tmp 'missing.git')
  Set-Content (Join-Path $l3.path 'x.txt') 'x'
  [IO.File]::SetLastWriteTimeUtc("$lf3.hb", [DateTime]::UtcNow.AddMinutes(-6))
  $o = AQ sweep
  Check 'backup failure keeps the lease' ((Test-Path $lf3) -and $o -match 'KEPT') $o
  git -C $repo remote set-url origin $bare
  AQ unlease -Repo $l3.path -LeaseId $l3.leaseId | Out-Null
  AQ unlease -Repo $lp.path -LeaseId $lp.leaseId | Out-Null

  # --- release runs -----------------------------------------------------------------------
  $sha1 = (git -C $repo rev-parse HEAD).Trim()
  $rf = AQ release-begin -Target web -Sha $sha1 -Follow dev -OwnerPid $PID -Purpose 'r1'
  $env:AGENTQ_RELEASE_FILE = ($rf -split "`n" | Select-Object -Last 1).Trim()
  Check 'release-begin writes record' (Test-Path $env:AGENTQ_RELEASE_FILE) $rf
  $o = AQ release-begin -Target web -Sha $sha1 -OwnerPid $PID
  Check 'second release-begin same target refused' ($code -eq 3) $o
  AQ release-phase -Phase preflight | Out-Null
  Check 'safe phase -> exit 0' ($code -eq 0)
  # landing during safe phase -> preempt; next checkpoint exits 4
  Set-Content (Join-Path $repo 'b.txt') 'b'; git -C $repo add b.txt; git -C $repo commit -qm b
  $o = AQ commit -Purpose 'land b' -Message 'feat: b' -Paths 'c.txt' 2>&1
  git -C $repo push -q origin dev 2>$null
  $sha2 = (git -C $repo rev-parse HEAD).Trim()
  $o = AQ notify-landing -Branch dev -Sha $sha2
  Check 'landing during safe phase -> preempt' ($o -match 'web:preempt') $o
  AQ release-phase -Phase build | Out-Null
  Check 'checkpoint after preempt -> exit 4 SUPERSEDED' ($code -eq 4)
  $e = AQ release-end -State failed | ConvertFrom-Json
  Check 'release-end after supersede -> next = new tip' ($e.state -eq 'superseded' -and $e.next -eq $sha2) ($e | ConvertTo-Json -Compress)
  # new run on sha2; unsafe phase -> landings coalesce into ONE pending
  $rf = AQ release-begin -Target web -Sha $sha2 -Follow dev -OwnerPid $PID
  $env:AGENTQ_RELEASE_FILE = ($rf -split "`n" | Select-Object -Last 1).Trim()
  AQ release-phase -Phase staging -Unsafe | Out-Null
  $o = AQ notify-landing -Branch dev -Sha 'aaaaaaaaaaaa'
  $o2 = AQ notify-landing -Branch dev -Sha 'bbbbbbbbbbbb'
  Check 'landing during unsafe phase -> pending' ($o -match 'web:pending' -and $o2 -match 'web:pending') "$o / $o2"
  AQ release-phase -Phase prod -Unsafe | Out-Null
  Check 'committed run is NOT preempted (exit 0)' ($code -eq 0)
  $o = AQ release-cancel -Target web -Reason 'test'
  Check 'release-cancel refused after unsafe phase' ($code -eq 3) $o
  $e = AQ release-end -State done | ConvertFrom-Json
  Check 'done run -> next = NEWEST pending only' ($e.next -eq 'bbbbbbbbbbbb') ($e | ConvertTo-Json -Compress)
  # failed committed run: no next
  $rf = AQ release-begin -Target web -Sha $sha2 -Follow dev -OwnerPid $PID
  $env:AGENTQ_RELEASE_FILE = ($rf -split "`n" | Select-Object -Last 1).Trim()
  AQ release-phase -Phase prod -Unsafe | Out-Null
  AQ notify-landing -Branch dev -Sha 'cccccccccccc' | Out-Null
  $e = AQ release-end -State failed | ConvertFrom-Json
  Check 'failed run never auto-starts the next' ($e.next -eq '') ($e | ConvertTo-Json -Compress)
  # dead release process -> failed on next read
  $holder = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 30' -PassThru -WindowStyle Hidden
  $rf = AQ release-begin -Target api -Sha $sha2 -Follow dev -OwnerPid $holder.Id
  Stop-Process -Id $holder.Id -Force; Start-Sleep -Milliseconds 300
  $st = AQ status -Json | ConvertFrom-Json
  Check 'dead release process -> failed' ((@($st.releases) | Where-Object target -eq 'api').state -eq 'failed')
  Remove-Item Env:AGENTQ_RELEASE_FILE
  AQ release-phase -Phase anything | Out-Null
  Check 'release-phase outside a run is a no-op exit 0' ($code -eq 0)

  # --- landing queue -----------------------------------------------------------------------
  # topic branch with 2 commits, one already upstream as a cherry-pick (dedupe), CHANGELOG conflict
  git -C $repo fetch -q origin
  git -C $repo branch -q topic origin/dev
  $tw = Join-Path $tmp 'topic'
  git -C $repo worktree add -q $tw topic 2>$null
  git -C $tw config user.email t@t; git -C $tw config user.name t
  Set-Content (Join-Path $tw 'dup.txt') 'dup'; git -C $tw add dup.txt; git -C $tw commit -qm 'dup'
  $dup = (git -C $tw rev-parse HEAD).Trim()
  Add-Content (Join-Path $tw 'CHANGELOG.md') '- topic entry'; Set-Content (Join-Path $tw 't.txt') 't'; git -C $tw add CHANGELOG.md t.txt; git -C $tw commit -qm 'topic work'
  git -C $tw push -q origin topic 2>$null
  # upstream: picks dup + its own CHANGELOG entry
  git -C $repo cherry-pick -q $dup 2>$null
  Add-Content (Join-Path $repo 'CHANGELOG.md') '- upstream entry'; git -C $repo add CHANGELOG.md; git -C $repo commit -qm 'upstream log'
  git -C $repo push -q origin dev 2>$null
  # a release following dev in a safe phase -> landing must preempt it
  $rf = AQ release-begin -Target web -Sha (git -C $repo rev-parse HEAD) -Follow dev -OwnerPid $PID
  $o = AQ land -Branch topic -Onto dev -Purpose 'land topic'
  Check 'land exits 0' ($code -eq 0) $o
  git -C $repo fetch -q origin
  $files = @(git -C $repo ls-tree --name-only origin/dev)
  Check 'landed content on origin/dev' ($files -contains 't.txt')
  $cl = (git -C $repo show origin/dev:CHANGELOG.md) -join "`n"
  Check 'CHANGELOG union keeps both entries, no markers' ($cl -match 'topic entry' -and $cl -match 'upstream entry' -and $cl -notmatch '<<<<<<<') $cl
  Check 'dedupe: dup commit not picked twice' (@(git -C $repo log origin/dev --format=%s | Where-Object { $_ -eq 'dup' }).Count -eq 1)
  Check 'land notified the release (preempt)' ($o -match 'web:preempt') $o
  Check 'land slot lease released' (-not (Test-Path (Join-Path $env:AGENTQ_HOME 'leases\repo\land.json')))
  $o = AQ land -Branch topic -Onto dev
  Check 'second land = already landed, exit 0' ($code -eq 0 -and $o -match 'already on origin/dev') $o
  # conflict on a non-CHANGELOG file -> exit 5, nothing pushed
  Set-Content (Join-Path $tw 'a.txt') 'topic-a'; git -C $tw commit -qam 'topic a'; git -C $tw push -q origin topic 2>$null
  git -C $repo pull -q --no-rebase origin dev 2>$null
  Set-Content (Join-Path $repo 'a.txt') 'upstream-a'; git -C $repo commit -qam 'upstream a'; git -C $repo push -q origin dev 2>$null
  $before = (git -C $repo ls-remote origin refs/heads/dev).Split("`t")[0]
  $o = AQ land -Branch topic -Onto dev
  $after = (git -C $repo ls-remote origin refs/heads/dev).Split("`t")[0]
  Check 'real conflict -> exit 5, names file' ($code -eq 5 -and $o -match 'a.txt') $o
  Check 'nothing pushed on conflict' ($before -eq $after)
  $o = AQ land -Branch topic -Onto dev -Gate 'exit 9'
  Check 'gate is only reached after picks (conflict still 5)' ($code -eq 5)
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_RELEASE_FILE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
