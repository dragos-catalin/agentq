# 2026-11-23 (`agentq slo` lostWorkIncidents = 6, 5 of them the SAME broken worktree, and the slot stayed
# held): a worktree with no valid HEAD can never be backed up - Backup-Slot refuses it - so Expire-Lease
# failed closed on EVERY sweep and re-counted the same directory each time.
# That ONE failure is now terminal: the tree is moved under <wtroot>\_orphans (every file kept) with a
# MOVED.txt naming repo/slot/leaseId/session and the backup error, the lease is released with ref '', and
# removal happens before the record so ONE `lease-orphan` event is journalled - a second sweep neither
# raises the incident again nor finds the slot (scenario A). Every OTHER backup failure still keeps the
# lease, fail closed (scenario B) - the trigger was NOT widened.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqorph-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:CODAI_GH_ROOT = Join-Path $tmp 'gh'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_PRUNE = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
# leaseChatGraceMin 0 + leaseDirtyIdleMin 0 keep the staleness decision purely on the work clock, and
# minFreeCommitGB 0 keeps the (resource-derived) budget out of a temp-dir test.
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseScratchIdleMin":15,"leaseIdleMin":15,"leaseOwnerIdleMin":20,"leaseChatGraceMin":0,"leaseDirtyIdleMin":0,"leaseMaxIdleMin":600,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Journal { @(Get-Content -LiteralPath (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue) | Where-Object { "$_".Trim() } | ForEach-Object { "$_" | ConvertFrom-Json -DateKind String } }
function SlotEvents([string]$slot) { @(Journal | Where-Object { "$($_.resource)" -eq "slot:repo:$slot" }) }
# The events that END a lease on this slot (the creation event `lease` shares the same resource).
function EndEvents([string]$slot) { @(SlotEvents $slot | Where-Object { "$($_.event)" -match '^lease-(orphan|orphan-failed|expire|expire-failed|break|failed)$' }) }
# The incident as the sweep/SLO sees it: a terminal outcome recorded for this slot. One is the target; two
# is the defect (one per sweep, for ever).
function IncidentCount([string]$slot) { @(SlotEvents $slot | Where-Object { $_.event -in 'lease-orphan', 'lease-expire-failed' }).Count }
function LeaseFile([string]$slot) { Join-Path $env:AGENTQ_HOME "leases\repo\$slot.json" }
function Backdate([string]$f) { if (-not (Test-Path -LiteralPath $f)) { [IO.File]::AppendAllText($f, '') }; [IO.File]::SetLastWriteTimeUtc($f, [DateTime]::UtcNow.AddMinutes(-90)) }
function Park([string]$slot) {
  # The lease's whole work clock - hb, work, chat - moved 90 min into the past: a genuinely stale lease
  # (90 > leaseScratchIdleMin 15), with no dependence on pids or on the unsaved-work guard.
  $lf = LeaseFile $slot
  foreach ($s in '.hb', '.work', '.chat') { if ($s -eq '.hb' -or (Test-Path -LiteralPath "$lf$s")) { Backdate "$lf$s" } }
}
function OrphanDirs([string]$slot) { @(Get-ChildItem -LiteralPath (Join-Path $env:CODAI_WT_ROOT '_orphans') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "repo-$slot-*" }) }
function OrphanDirCount { @(Get-ChildItem -LiteralPath (Join-Path $env:CODAI_WT_ROOT '_orphans') -Directory -ErrorAction SilentlyContinue).Count }
function Lease([string]$id) { $env:AGENTQ_SESSION = 'observer'; $st = AQ status -All -Json | ConvertFrom-Json; @($st.leases | Where-Object { $_.leaseId -eq $id }) | Select-Object -First 1 }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  # ---- scenario A: a BROKEN worktree (no valid HEAD) is orphanned, exactly once -------------------
  $env:AGENTQ_SESSION = 'breaker'
  $o = AQ lease -Role scratch -Purpose 'orphan test A: broken worktree' -Json
  $la = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check 'A0 setup: scratch lease taken' ($la -and $la.leaseId -and $la.path) $o
  $lfA = LeaseFile $la.slot
  Check 'A0b setup: the lease record exists where the sweep looks' (Test-Path -LiteralPath $lfA) $lfA
  # Break the worktree the way a killed/half-created one looks: the .git file points nowhere, so
  # `git rev-parse --verify HEAD` fails exactly as Backup-Slot's guard expects - the CONTENT stays.
  # git marks a worktree's .git file HIDDEN on Windows, and .NET refuses to overwrite a hidden file.
  $gf = Join-Path $la.path '.git'
  [IO.File]::SetAttributes($gf, [IO.FileAttributes]::Normal)
  [IO.File]::WriteAllText($gf, "gitdir: $tmp\no-such-gitdir`n")
  [IO.File]::WriteAllText((Join-Path $la.path 'keep-me.txt'), 'unique-content-preserved-12345')
  Park $la.slot
  Check 'A1 the broken lease is stale (so the sweep takes it)' ((Lease $la.leaseId).stale)

  $env:AGENTQ_SESSION = 'sweeper'
  $o = AQ sweep
  Check 'A2 sweep reports the slot as orphaned, not as a plain expiry or KEPT' ($o -match "orphaned repo/$($la.slot)" -and $o -match 'orphaned=1' -and $o -notmatch 'KEPT ') $o
  Check 'A3 the lease is released (record gone)' (-not (Test-Path -LiteralPath $lfA)) ''
  Check 'A4 the worktree directory left the slot pool' (-not (Test-Path -LiteralPath $la.path)) $la.path
  $od = OrphanDirs $la.slot
  Check 'A5 exactly ONE directory under _orphans, named <repo>-<slot>-<yyyymmdd-hhmm>' ($od.Count -eq 1 -and $od[0].Name -match "^repo-$([regex]::Escape($la.slot))-\d{8}-\d{4}$") (($od | ForEach-Object Name) -join ',')
  $note = if ($od.Count) { Join-Path $od[0].FullName 'MOVED.txt' } else { '' }
  $noteTxt = if ($note -and (Test-Path -LiteralPath $note)) { Get-Content -LiteralPath $note -Raw } else { '' }
  Check 'A6 MOVED.txt names repo, slot, leaseId, session and the backup error' `
    ($noteTxt -match 'repo:\s+repo' -and $noteTxt -match "slot:\s+$([regex]::Escape($la.slot))" -and $noteTxt -match "leaseId:\s+$($la.leaseId)" -and $noteTxt -match 'session:\s+breaker' -and $noteTxt -match 'no valid HEAD') $noteTxt
  $keptTxt = if ($od.Count) { Join-Path $od[0].FullName 'keep-me.txt' } else { '' }
  Check 'A7 every file inside was preserved (the content, not a copy of nothing)' ($keptTxt -and (Test-Path -LiteralPath $keptTxt) -and ((Get-Content -LiteralPath $keptTxt -Raw).Trim() -eq 'unique-content-preserved-12345')) ''
  Check 'A8 the tracked file of the repo travelled with it too' ($od.Count -and (Test-Path -LiteralPath (Join-Path $od[0].FullName 'a.txt'))) ''
  $ev = @(EndEvents $la.slot)
  Check 'A9 ONE terminal event for this slot, and it is lease-orphan with ref ""' ($ev.Count -eq 1 -and $ev[0].event -eq 'lease-orphan' -and "$($ev[0].ref)" -eq '') (@($ev | ForEach-Object { "$($_.event) ref='$($_.ref)'" }) -join '; ')
  Check 'A10 the fail-closed path was NOT taken (no lease-expire-failed)' (@($ev | Where-Object { $_.event -eq 'lease-expire-failed' }).Count -eq 0) ''
  $inc1 = IncidentCount $la.slot
  Check 'A11 the incident is counted ONCE' ($inc1 -eq 1) "incidents=$inc1"
  $orph1 = OrphanDirCount

  $o = AQ sweep
  Check 'A12 a second sweep does not raise the incident again' ((IncidentCount $la.slot) -eq $inc1 -and @(EndEvents $la.slot).Count -eq 1) "incidents=$(IncidentCount $la.slot) endings=$(@(EndEvents $la.slot).Count)"
  $orphNames = (@(Get-ChildItem -LiteralPath (Join-Path $env:CODAI_WT_ROOT '_orphans') -Force -ErrorAction SilentlyContinue | ForEach-Object Name) -join ',')
  Check 'A13 ... and does not find the slot any more (no new _orphans directory, path still gone)' ($orph1 -eq 1 -and (OrphanDirCount) -eq 1 -and -not (Test-Path -LiteralPath $la.path)) "$o | orphans=$orph1->$(OrphanDirCount) [$orphNames]"

  # ---- scenario B: any OTHER backup failure keeps the lease (the trigger was not widened) ----------
  $env:AGENTQ_SESSION = 'breaker'
  $o = AQ lease -Role scratch -Purpose 'orphan test B: an unrelated backup failure' -Json
  $lb = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check 'B0 setup: second scratch lease taken' ($lb -and $lb.leaseId -and $lb.path) $o
  $lfB = LeaseFile $lb.slot
  # Valid HEAD, dirty tree, origin unreachable: Backup-Slot's own push guard refuses the ref and THROWS.
  [IO.File]::WriteAllText((Join-Path $lb.path 'dirty.txt'), 'unpushed work')
  & git -C $lb.path remote set-url origin (Join-Path $tmp 'missing-origin.git') 2>$null
  Park $lb.slot
  Check 'B1 that lease is stale too' ((Lease $lb.leaseId).stale)
  $env:AGENTQ_SESSION = 'sweeper'
  $o = AQ sweep
  Check 'B2 sweep keeps it: fail closed, lease kept' ($o -match "KEPT repo/$($lb.slot)" -and (Test-Path -LiteralPath $lfB) -and (Lease $lb.leaseId)) $o
  Check 'B3 the failure is named in the journal (lease-expire-failed), not silent' (@(SlotEvents $lb.slot | Where-Object { $_.event -eq 'lease-expire-failed' }).Count -eq 1) ((@(SlotEvents $lb.slot | ForEach-Object event)) -join ',')
  Check 'B4 nothing was orphaned for it (the orphan pool did not grow)' ((OrphanDirCount) -eq $orph1) "orphans=$(OrphanDirCount) (was $orph1)"
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'CODAI_GH_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_PRUNE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
