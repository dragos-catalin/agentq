# agentq v2 (ADR 0001, docs/adr/0001-slots-leases-release-supersede.md): worktree SLOTS + LEASES,
# RELEASE RUNS + SUPERSEDE, LANDING QUEUE. Dot-sourced by agentq.ps1 (shares its script scope:
# $Root, $Session, $RepoArg, $Slot, ... and helpers Write-Journal, New-Ticket, Wait-Turn, Test-Alive).

# PowerShell variables are case-insensitive: `$repo = Get-RepoInfo `$Repo` inside a function REPLACES
# the -Repo argument. v2 code reads the argument only through `$RepoArg`.
$RepoArg = $Repo
$LDir = Join-Path $Root 'leases'
$RDir = Join-Path $Root 'releases'
foreach ($d in $LDir, $RDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }

# ---- policy -------------------------------------------------------------------------------
# AGENTQ_CONFIG overrides the file (tests); missing keys fall back to these defaults.
$script:Cfg = $null
$script:LeaseActivity = $null
function Get-Config {
  if ($script:Cfg) { return $script:Cfg }
  $c = @{
    taskSlotsPerRepo = 3; taskSlotsMachine = 10; releaseSlots = @{}; pinned = @{}
    leaseDeadIdleMin = 120; leaseMaxIdleMin = 1440; unleasedRemoveIdleHours = 168; minFreeCommitGB = 12
    # v3 scheduler (devcloud F1): machine cap, soft slots, aging, idle-yield watchdog, override limits.
    machineCap = 2; quickBurst = 1; agingMin = 5; idleYieldMin = 5; idleCpuSec = 10
    bumpMax = 50; burstMax = 2; burstMaxMin = 60; overridesPerHour = 6; runBuildTimeoutMin = 240
    journalRotateMB = 64
  }
  $f = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $PSScriptRoot 'agentq-config.json' }
  if (Test-Path -LiteralPath $f) {
    $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable
    foreach ($k in $j.Keys) { $c[$k] = $j[$k] }
  }
  $script:Cfg = $c
  $c
}
function Get-WtRoot { if ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT } else { 'E:\gh\.wt' } }
function Get-ReleaseSlotCount([string]$repoName) { $r = (Get-Config).releaseSlots; if ($r -and $r.ContainsKey($repoName)) { [int]$r[$repoName] } else { 1 } }
function Get-PinnedSlots([string]$repoName) { $p = (Get-Config).pinned; if ($p -and $p.ContainsKey($repoName)) { @($p[$repoName]) } else { @() } }
# The ONLY slot names that exist. Anything else is legacy and gets migrated away.
function Get-SlotRole([string]$repoName, [string]$slot) {
  if ($slot -match '^task-(\d+)$') { if ([int]$Matches[1] -ge 1 -and [int]$Matches[1] -le (Get-Config).taskSlotsPerRepo) { return 'task' }; return $null }
  if ($slot -eq 'release') { return 'release' }
  if ($slot -match '^release-(\d+)$') { if ([int]$Matches[1] -ge 2 -and [int]$Matches[1] -le (Get-ReleaseSlotCount $repoName)) { return 'release' }; return $null }
  if ($slot -eq 'land') { return 'land' }
  if ((Get-PinnedSlots $repoName) -contains $slot) { return 'pinned' }
  $null
}

# ---- helpers ------------------------------------------------------------------------------
function P($o, [string]$n, $d = '') { if ($null -ne $o -and $o.PSObject.Properties.Name -contains $n -and $null -ne $o.$n) { $o.$n } else { $d } }
function Write-JsonAtomic([string]$file, $obj) {
  $dir = Split-Path -Parent $file
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $tmp = "$file.$PID.tmp"
  [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move($tmp, $file, $true)
}
function Read-JsonFile([string]$file) {
  for ($r = 0; $r -lt 5; $r++) {
    try { return (Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -DateKind String) } catch { if (-not (Test-Path -LiteralPath $file)) { return $null } }
    Start-Sleep -Milliseconds 40
  }
  'UNREADABLE'
}
function With-Mutex([string]$name, [scriptblock]$body) {
  $m = [Threading.Mutex]::new($false, "Global\agentq-$(Safe $name)$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  try { try { [void]$m.WaitOne(30000) } catch [Threading.AbandonedMutexException] {} ; & $body }
  finally { try { $m.ReleaseMutex() } catch {} ; $m.Dispose() }
}
function Get-MainTop($repo) { Split-Path -Parent $repo.Common }
function Get-SlotPath([string]$repoName, [string]$slot) { Join-Path (Join-Path (Get-WtRoot) $repoName) $slot }
function Get-LeaseFile([string]$repoName, [string]$slot) { Join-Path (Join-Path $LDir $repoName) "$slot.json" }
function Get-DefaultOwner { if ($OwnerPid -gt 0) { return $OwnerPid }; if ($env:AGENTQ_OWNER_PID) { return [int]$env:AGENTQ_OWNER_PID }; try { (Get-Process -Id $PID).Parent.Id } catch { $PID } }
function Short([string]$s, [int]$n = 10) { if (-not $s) { return '' }; $s.Substring(0, [math]::Min($n, $s.Length)) }

# ---- lease activity beyond the slot (ADR 0003 W1-3) ---------------------------------------------
# 24 leases of live work expired in 15 days (ADR 0002) and ~9 more after DC-021: the owner shell died
# or the work ran OUTSIDE the slot (job-start gates, run-build, land, agentq calls from the main clone).
# A lease is now also active while (a) a live agentq ticket runs with its repo inside the slot,
# (b) a running job-start job has its cwd or command inside the slot, or (c) an agentq call names the
# lease (-LeaseId) or comes from the lease's session. Computed once per process (Read-Leases runs
# on every status/sync call).
function Get-ExtraLeaseActivity {
  if ($null -ne $script:LeaseActivity) { return $script:LeaseActivity }
  $acts = @()
  try {
    foreach ($d in @(Get-ChildItem $QDir -Directory -ErrorAction SilentlyContinue)) {
      foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
          $t = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -DateKind String
          if (-not $t.repo -or -not (Test-Alive $t)) { continue }
          $hb = "$($f.FullName).hb"; $at = if (Test-Path -LiteralPath $hb) { (Get-Item -LiteralPath $hb).LastWriteTimeUtc } else { $f.LastWriteTimeUtc }
          $acts += [pscustomobject]@{ path = (Norm-Dir "$($t.repo)"); text = ''; at = $at }
        } catch {}
      }
    }
    $jd = Join-Path $Root 'jobs'
    if (Test-Path -LiteralPath $jd) {
      $cut = (Now).AddDays(-2)
      foreach ($f in @(Get-ChildItem -LiteralPath $jd -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -gt $cut } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 200)) {
        try {
          $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -DateKind String
          if ((P $j 'state' '') -ne 'running' -or -not (P $j 'pid' 0)) { continue }
          if (-not (Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue)) { continue }
          $log = P $j 'log' ''; $at = if ($log -and (Test-Path -LiteralPath $log)) { (Get-Item -LiteralPath $log).LastWriteTimeUtc } else { $f.LastWriteTimeUtc }
          $acts += [pscustomobject]@{ path = $(if (P $j 'cwd' '') { Norm-Dir "$($j.cwd)" } else { '' }); text = "$(P $j 'command' '')".ToLowerInvariant(); at = $at }
        } catch {}
      }
    }
  } catch {}
  $script:LeaseActivity = $acts
  $acts
}
function Get-LeaseExtraBeat($l) {
  $lp = "$(P $l 'path' '')"; if (-not $lp) { return $null }
  $ln = Norm-Dir $lp; $lt = $lp.ToLowerInvariant()
  $best = $null
  foreach ($a in @(Get-ExtraLeaseActivity)) {
    $hit = ($a.path -and $a.path.StartsWith($ln)) -or ($a.text -and $a.text.Contains($lt))
    if ($hit -and (-not $best -or $a.at -gt $best)) { $best = $a.at }
  }
  $best
}
# Any agentq call from the lease's own session, or naming it with -LeaseId, renews it.
function Renew-ForSession {
  try {
    foreach ($f in @(Get-ChildItem -LiteralPath $LDir -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $raw = [IO.File]::ReadAllText($f.FullName)
      if (-not ($raw.Contains("`"$Session`"") -or ($LeaseId -and $raw.Contains("`"$LeaseId`"")))) { continue }
      $l = $raw | ConvertFrom-Json
      if (($LeaseId -and (P $l 'leaseId') -eq $LeaseId) -or ((P $l 'session') -eq $Session)) { Touch-Lease ([pscustomobject]@{ file = $f.FullName }) }
    }
  } catch {}
}

# ---- lease-loss notices (ADR 0003 W1-3) -------------------------------------------------------
# An expired or broken lease used to be discovered only by finding foreign files in "my" slot. The
# holder's session now gets a notice that agentq prints (stderr) on its next call, and `status`
# lists losses of the last 24 h with the backup ref to restore from.
function Add-LeaseNotice($l, [string]$event, [string]$why, [string]$ref) {
  try {
    $nd = Join-Path $Root 'notices'; if (-not (Test-Path -LiteralPath $nd)) { New-Item -ItemType Directory -Force $nd | Out-Null }
    $n = [ordered]@{ ts = (Iso (Now)); event = $event; repo = $l.repo; slot = $l.slot; leaseId = (P $l 'leaseId'); purpose = (P $l 'purpose'); branch = (P $l 'branch'); reason = $why; ref = $ref; by = $Session }
    [IO.File]::AppendAllText((Join-Path $nd ((Safe "$(P $l 'session')") + '.jsonl')), (($n | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
  } catch {}
}
function Show-LeaseNotices {
  try {
    $f = Join-Path (Join-Path $Root 'notices') ((Safe $Session) + '.jsonl')
    if (-not (Test-Path -LiteralPath $f)) { return }
    $lines = @(Get-Content -LiteralPath $f | Where-Object { $_ })
    Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    foreach ($ln in $lines) {
      $n = $ln | ConvertFrom-Json
      $restore = if ($n.ref) { " Unsaved state is in $($n.ref): git diff --binary <base> $($n.ref) --output=x.patch, then git apply --3way x.patch in a NEW lease." } else { ' Nothing unsaved was in it.' }
      [Console]::Error.WriteLine("agentq: NOTICE your lease $($n.leaseId) on $($n.repo)/$($n.slot) ('$($n.purpose)') ended at $($n.ts): $($n.event) - $($n.reason).$restore Do not write to that slot again.")
    }
  } catch {}
}
function Get-RecentLeaseLosses([int]$hours = 24) {
  try {
    $cut = (Now).AddHours(-$hours)
    @(Get-Content -LiteralPath $Journal -Tail 4000 -ErrorAction Stop | Where-Object { $_ -match '"event":"(lease-expire|lease-break)"' } | ForEach-Object { try { $_ | ConvertFrom-Json -DateKind String } catch { $null } } | Where-Object { $_ -and (ParseUtc $_.ts) -gt $cut })
  } catch { @() }
}

# ---- leases -------------------------------------------------------------------------------
# Liveness for AGENTS (no long-lived process): owner shell pid + activity heartbeat (guard hook on
# every tool call touching the slot, agentq calls from inside it, renew).
# Stale = (owner dead AND idle > leaseDeadIdleMin, 3 min for the land slot) OR idle > leaseMaxIdleMin.
function Read-Leases([string]$repoName) {
  $dirs = if ($repoName) { @(Join-Path $LDir $repoName) } else { @(Get-ChildItem $LDir -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName) }
  $cfg = Get-Config
  $out = @()
  foreach ($d in $dirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    foreach ($f in Get-ChildItem -LiteralPath $d -Filter '*.json' -File) {
      $l = Read-JsonFile $f.FullName
      if ($null -eq $l) { continue }
      if ($l -eq 'UNREADABLE') {
        # Fail closed: an unreadable lease still holds its slot (owner = us, so it looks alive).
        $rn = Split-Path $d -Leaf
        $l = [pscustomobject]@{ leaseId = 'unreadable'; repo = $rn; slot = $f.BaseName; role = '?'; path = (Get-SlotPath $rn $f.BaseName); branch = ''; purpose = 'unreadable lease file'; session = '?'; pid = $PID; procStart = $null; created = (Iso (Now)) }
      }
      $hb = "$($f.FullName).hb"
      $beat = if (Test-Path -LiteralPath $hb) { (Get-Item -LiteralPath $hb).LastWriteTimeUtc } else { ParseUtc (P $l 'created' (Iso (Now))) }
      # DC-021: work in a slot from ANOTHER shell (owner shell died) or from a script outside agentq
      # still touches the slot's git index (status/add/commit/checkout). Count it as activity: 24
      # leases of live work were expired in 15 days because only the owner pid + .hb counted.
      $act = Get-SlotGitActivity (P $l 'path' '')
      # Ignore the index writes of the lease's own checkout (first 2 min after creation).
      $createdAt = ParseUtc (P $l 'created' (Iso (Now)))
      if ($act -and $act -gt $beat -and $act -gt $createdAt.AddMinutes(2)) { $beat = $act }
      $alive = Test-Alive ([pscustomobject]@{ pid = [int](P $l 'pid' 0); procStart = (P $l 'procStart' $null) })
      $idle = ((Now) - $beat).TotalMinutes
      # The land lease owner is the agentq land process itself (20 s heartbeat): dead owner = land over.
      $deadIdle = if ((P $l 'role' '') -eq 'land') { 3 } else { $cfg.leaseDeadIdleMin }
      $stale = ((-not $alive) -and $idle -gt $deadIdle) -or ($idle -gt $cfg.leaseMaxIdleMin)
      # W1-3: the ticket/job scan costs seconds on a big registry, so only a lease that would be
      # stale pays for it (most calls see no stale lease and never scan).
      if ($stale) {
        $xa = Get-LeaseExtraBeat $l
        if ($xa -and $xa -gt $beat) { $beat = $xa; $idle = ((Now) - $beat).TotalMinutes; $stale = ((-not $alive) -and $idle -gt $deadIdle) -or ($idle -gt $cfg.leaseMaxIdleMin) }
      }
      $l | Add-Member -NotePropertyName file -NotePropertyValue $f.FullName -Force
      $l | Add-Member -NotePropertyName beat -NotePropertyValue $beat -Force
      $l | Add-Member -NotePropertyName alive -NotePropertyValue $alive -Force
      $l | Add-Member -NotePropertyName idleMin -NotePropertyValue ([math]::Round($idle, 1)) -Force
      $l | Add-Member -NotePropertyName stale -NotePropertyValue $stale -Force
      $out += $l
    }
  }
  $out
}
function Norm-Dir([string]$p) { ([IO.Path]::GetFullPath($p).TrimEnd('\', '/') + '\').ToLowerInvariant() }
function Get-SlotGitActivity([string]$slotPath) {
  if (-not $slotPath) { return $null }
  try {
    $gf = Join-Path $slotPath '.git'
    if (-not (Test-Path -LiteralPath $gf -PathType Leaf)) { return $null }
    $gd = ((Get-Content -LiteralPath $gf -Raw) -replace '^gitdir:\s*', '').Trim()
    if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $slotPath $gd }
    $times = foreach ($n in 'index', 'HEAD', 'logs\HEAD') { $p = Join-Path $gd $n; if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTimeUtc } }
    @($times | Sort-Object -Descending)[0]
  } catch { $null }
}
# Lease whose slot contains $path, or whose slot lies inside $path (deleting a parent dir hits it too).
function Find-LeaseForPath([string]$path) {
  if (-not $path) { return $null }
  $p = Norm-Dir $path
  foreach ($l in Read-Leases $null) {
    $lp = Norm-Dir "$(P $l 'path')"
    if ($p.StartsWith($lp) -or $lp.StartsWith($p)) { return $l }
  }
  $null
}
function Touch-Lease($l) { try { if (-not (Test-Path -LiteralPath "$($l.file).hb")) { [IO.File]::WriteAllText("$($l.file).hb", '') }; [IO.File]::SetLastWriteTimeUtc("$($l.file).hb", (Now)) } catch {} }
function Renew-ForCwd {
  # Any agentq call from inside a slot (cwd or -Repo) counts as activity for that slot's lease.
  try {
    $start = if ($RepoArg) { $RepoArg } else { (Get-Location).Path }
    if ((Norm-Dir $start).StartsWith((Norm-Dir (Get-WtRoot)))) { $l = Find-LeaseForPath $start; if ($l) { Touch-Lease $l } }
  } catch {}
}
function Test-GitClean([string]$path) { -not @(& git --no-optional-locks -C $path status --porcelain --untracked-files=normal 2>$null | Where-Object { $_ }).Count }
function Test-OnRemote([string]$path, [string]$sha) {
  if (-not $sha) { return $false }
  [bool]@(& git -C $path for-each-ref --count=1 --contains $sha --format='%(refname)' refs/remotes 2>$null | Where-Object { $_ }).Count
}

# Snapshot EVERYTHING not on a remote (tracked edits, untracked non-ignored files, unpushed commits)
# into one commit via a TEMP index - never a stash (stashes are shared by all worktrees of a repo,
# memory 2026-09-30) - and publish it as refs/backup/wt/<repo>/<slot>/<ts>: not a branch, so no CI
# (verified on GitHub 2026-10-06). Repos without origin get a bundle in <wtroot>\_bundles.
# Returns the ref, '' when nothing is unique; THROWS when the backup could not be proven.
# -CommitsOnly (release slots): tracked/untracked changes there are build byproducts, only unpushed
# commits are worth keeping.
function Backup-Slot([string]$path, [string]$repoName, [string]$slot, [string]$why, [switch]$CommitsOnly) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return '' }
  $head = (& git -C $path rev-parse --verify -q HEAD 2>$null)
  if ($LASTEXITCODE -or -not $head) { throw "backup: $path has no valid HEAD (broken worktree) - inspect by hand" }
  $clean = $CommitsOnly -or (Test-GitClean $path)
  if ($clean -and (Test-OnRemote $path $head)) { return '' }
  $commit = $head; $big = @()
  if (-not $clean) {
    $gitDir = (& git -C $path rev-parse --path-format=absolute --git-dir).Replace('/', '\')
    $tmpIdx = Join-Path ([IO.Path]::GetTempPath()) ("aq-idx-" + [guid]::NewGuid().ToString('N'))
    $idx = Join-Path $gitDir 'index'
    if (Test-Path -LiteralPath $idx) { Copy-Item -LiteralPath $idx $tmpIdx -Force }
    $prevIdx = $env:GIT_INDEX_FILE
    try {
      $env:GIT_INDEX_FILE = $tmpIdx
      & git -C $path add -A 2>$null | Out-Null
      if ($LASTEXITCODE) { throw "backup: git add -A on a temp index failed in $path" }
      # GitHub rejects blobs > 100 MB: leave huge untracked files out and name them in the message.
      $big = @(& git -C $path diff --cached --name-only --diff-filter=A HEAD 2>$null | Where-Object { $_ } | Where-Object { $f = Join-Path $path $_; (Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 50MB })
      foreach ($b in $big) { & git -C $path rm -q --cached -- $b 2>$null | Out-Null }
      $tree = (& git -C $path write-tree).Trim()
      if ($LASTEXITCODE -or -not $tree) { throw 'backup: write-tree failed' }
    } finally {
      if ($prevIdx) { $env:GIT_INDEX_FILE = $prevIdx } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
      Remove-Item -LiteralPath $tmpIdx -Force -ErrorAction SilentlyContinue
    }
    $msgFile = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($msgFile, "agentq backup ${repoName}/${slot}: $why`n`nhead: $head`nsession: $Session`nskipped-large: $($big -join ', ')`n", [Text.UTF8Encoding]::new($false))
    $commit = (& git -C $path -c user.name=agentq -c user.email=agentq@localhost commit-tree $tree -p $head -F $msgFile).Trim()
    Remove-Item $msgFile -Force
    if ($LASTEXITCODE -or -not $commit) { throw 'backup: commit-tree failed' }
  }
  $ref = "refs/backup/wt/$repoName/$slot/$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))-$(Short ([guid]::NewGuid().ToString('N')) 4)"
  & git -C $path update-ref $ref $commit
  if ($LASTEXITCODE) { throw "backup: update-ref $ref failed" }
  $hasOrigin = [bool](@(& git -C $path remote 2>$null) -contains 'origin')
  $pushError = ''; $bundle = ''
  if ($hasOrigin) {
    # --no-verify: a backup ref is not a release; pre-push gates (minutes) would make expiry unusable.
    # Output is CAPTURED (it used to go to $null): a refused push (GitHub GH001 on a >100 MB blob,
    # 2026-10-15) then surfaced only as "could not be verified (got '')" and wedged every later land.
    $pushOut = @(& git -C $path push --no-verify origin "${commit}:$ref" 2>&1 | ForEach-Object { "$_" })
    $pushCode = $LASTEXITCODE
    $remote = ''
    for ($try = 1; $try -le 3 -and -not $pushCode; $try++) {
      $remote = "$((& git -C $path ls-remote origin $ref 2>$null) | Select-Object -First 1)" -split '\s+' | Select-Object -First 1
      if ($remote -eq $commit) { break }
      Start-Sleep -Milliseconds (500 * $try)
    }
    if ($pushCode -or $remote -ne $commit) {
      $pushError = (@($pushOut | Where-Object { $_ -match '\S' } | Select-Object -Last 6) -join ' | ')
      if (-not $pushError) { $pushError = "push exit $pushCode; ls-remote got '$remote'" }
      $pushError = $pushError.Substring(0, [math]::Min(500, $pushError.Length))
    }
  }
  # Origin unreachable (network, wrong URL) = fail closed, the caller keeps the lease. Only an origin
  # that answered and REFUSED the ref (GH001 size limit, a hook) gets the local-bundle fallback.
  if ($pushError -and $pushError -notmatch 'remote rejected|pre-receive hook declined|GH001|rejected') {
    throw "backup: push of $ref to origin failed ($pushError); local ref kept"
  }
  if (-not $hasOrigin -or $pushError) {
    # No origin, or origin refused the ref: keep a LOCAL bundle and prove it with `bundle verify`.
    # With origin only the commits not on it go in (brivio's full history would be GBs).
    $bdir = Join-Path (Get-WtRoot) '_bundles'; New-Item -ItemType Directory -Force $bdir | Out-Null
    $bundle = Join-Path $bdir "$repoName-$slot-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$(Short ([guid]::NewGuid().ToString('N')) 4).bundle"
    $bargs = @('bundle', 'create', '-q', $bundle, $ref); if ($hasOrigin) { $bargs += @('--not', '--remotes=origin') }
    & git -C $path @bargs 2>$null
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $bundle)) { throw "backup: bundle $bundle failed (local ref $ref kept)$(if ($pushError) { "; origin refused the push: $pushError" })" }
    & git -C $path bundle verify -q $bundle 2>$null | Out-Null
    if ($LASTEXITCODE) { throw "backup: bundle $bundle does not verify (local ref $ref kept)$(if ($pushError) { "; origin refused the push: $pushError" })" }
    if ($pushError) { [Console]::Error.WriteLine("agentq: backup push of $ref refused by origin ($pushError); kept as verified bundle $bundle") }
  }
  $j = @{ event = 'backup'; resource = "slot:${repoName}:$slot"; sha = $commit; ref = $ref; reason = $why; repo = $repoName }
  if ($pushError) { $j.pushError = $pushError }
  if ($bundle) { $j.bundle = $bundle }
  Write-Journal $j
  if ($pushError) { "$ref (bundle $bundle)" } else { $ref }
}

# ---- slot readiness (ADR 0003 W1-4) ---------------------------------------------------------------
# A stale <gitdir>/index.lock left by a killed checkout made `lease` fail with "checkout origin/main
# failed" 54 times and blocked prod releases for 3 h (2026-10-15). Remove it only when no git process
# is using that worktree.
function Clear-StaleIndexLock([string]$path) {
  try {
    $gf = Join-Path $path '.git'
    if (-not (Test-Path -LiteralPath $gf -PathType Leaf)) { return }
    $gd = ((Get-Content -LiteralPath $gf -Raw) -replace '^gitdir:\s*', '').Trim()
    if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $path $gd }
    $lock = Join-Path $gd 'index.lock'
    if (-not (Test-Path -LiteralPath $lock)) { return }
    $needle = $path.TrimEnd('\').ToLowerInvariant()
    $busy = @(Get-CimInstance Win32_Process -Filter "Name='git.exe'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)".ToLowerInvariant().Contains($needle) })
    if ($busy.Count) { return }
    if (((Now) - (Get-Item -LiteralPath $lock).LastWriteTimeUtc).TotalSeconds -lt 30) { return }
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    Write-Journal @{ event = 'slot-unlock'; resource = "slot:$path"; reason = 'stale index.lock removed (no git process on the worktree)' }
  } catch {}
}
# Fresh slots failed their first commit/gate ~19 times: missing node_modules after a lockfile change,
# no .husky/_ (hooks silently skipped), unbuilt workspace dists. Prepare-Slot makes the slot usable:
#  - repo script scripts/slot-prep.ps1 -Worktree <path> -Main <main> if present (repo knows best);
#  - else for pnpm repos: frozen install under install:<repo> when the lockfile differs from the last
#    prep, and .husky/_ copied from the main clone when the worktree lacks it.
# Never fails the lease: problems are printed + journaled (slot-prep-failed) and the slot is marked
# not ready in <coord>/prep/<repo>--<slot>.json, so the agent knows before its first commit.
function Prepare-Slot([string]$main, [string]$path, [string]$repoName) {
  if ($env:AGENTQ_NO_PREP -eq '1') { return }
  # State lives in the coord dir, not in the slot: an untracked file there made every clean slot look
  # dirty (unlease backed it up, worktree v2 test 2026-10-18).
  $pd = Join-Path $Root 'prep'; if (-not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Force $pd | Out-Null }
  $stateF = Join-Path $pd ((Safe "$repoName--$(Split-Path $path -Leaf)") + '.json')
  $st = [ordered]@{ at = (Iso (Now)); lock = ''; steps = @(); ready = $true }
  try {
    $custom = Join-Path $path 'scripts\slot-prep.ps1'
    if (Test-Path -LiteralPath $custom) {
      $out = @(& pwsh -NoProfile -File $custom -Worktree $path -Main $main 2>&1 | ForEach-Object { "$_" })
      $st.steps += "slot-prep.ps1 rc=$LASTEXITCODE"
      if ($LASTEXITCODE) { $st.ready = $false; $out | Select-Object -Last 15 | ForEach-Object { [Console]::Error.WriteLine("  slot-prep: $_") } }
    } elseif (Test-Path -LiteralPath (Join-Path $path 'pnpm-lock.yaml')) {
      $lockHash = (Get-FileHash -LiteralPath (Join-Path $path 'pnpm-lock.yaml') -Algorithm SHA1).Hash
      $prev = $null; if (Test-Path -LiteralPath $stateF) { try { $prev = Get-Content -LiteralPath $stateF -Raw | ConvertFrom-Json } catch {} }
      $st.lock = $lockHash
      $nm = Test-Path -LiteralPath (Join-Path $path 'node_modules\.modules.yaml')
      if (-not $nm -or -not $prev -or (P $prev 'lock' '') -ne $lockHash -or -not (P $prev 'ready' $false)) {
        $aq = Join-Path $PSScriptRoot 'agentq.ps1'
        $out = @(& pwsh -NoProfile -File $aq run -Resource install -Purpose "slot prep $repoName/$(Split-Path $path -Leaf)" -Repo $path -- pnpm install --frozen-lockfile --prefer-offline 2>&1 | ForEach-Object { "$_" })
        $st.steps += "pnpm install rc=$LASTEXITCODE"
        if ($LASTEXITCODE) { $st.ready = $false; $out | Select-Object -Last 12 | ForEach-Object { [Console]::Error.WriteLine("  slot-prep: $_") } }
      } else { $st.steps += 'pnpm install skipped (lockfile unchanged)' }
    }
    $hp = "$(& git -C $path config --get core.hooksPath 2>$null)".Trim()
    if ($hp -eq '.husky/_' -and -not (Test-Path -LiteralPath (Join-Path $path '.husky\_\pre-commit'))) {
      $srcH = Join-Path $main '.husky\_'
      if (Test-Path -LiteralPath $srcH) { Copy-Item -LiteralPath $srcH -Destination (Join-Path $path '.husky') -Recurse -Force; $st.steps += 'copied .husky/_ from main clone' }
      else { $st.ready = $false; $st.steps += '.husky/_ missing (run pnpm exec husky)' }
    }
  } catch { $st.ready = $false; $st.steps += "error: $($_.Exception.Message)" }
  try { [IO.File]::WriteAllText($stateF, ($st | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)) } catch {}
  if (-not $st.ready) {
    Write-Journal @{ event = 'slot-prep-failed'; resource = "slot:${repoName}:$(Split-Path $path -Leaf)"; reason = ($st.steps -join '; '); repo = $repoName }
    [Console]::Error.WriteLine("agentq: WARNING slot $path is not ready: $($st.steps -join '; ')")
  }
  $st
}

# Bring a slot to a fresh state at $ref (+ optional branch). The caller holds the lease and has
# already backed up anything unique, so discarding inside THIS slot is safe by construction.
function Initialize-Slot([string]$main, [string]$path, [string]$ref, [string]$branch, [bool]$copyEnv) {
  & git -C $main worktree prune 2>$null
  $registered = @(& git -C $main worktree list --porcelain | Where-Object { $_ -like 'worktree *' } | ForEach-Object { $_.Substring(9).Replace('/', '\').TrimEnd('\').ToLowerInvariant() })
  $isReg = $registered -contains $path.TrimEnd('\').ToLowerInvariant()
  if (-not $isReg) {
    if (Test-Path -LiteralPath $path) {
      $left = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'node_modules', '.copilot-tmp' })
      if ($left.Count) { throw "slot ${path}: directory exists but is not a worktree of $main ($($left.Count) entries) - run 'worktree.ps1 migrate' first" }
      cmd /c rmdir /s /q "`"$path`"" 2>$null
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    & git -C $main worktree add -q --detach $path $ref 2>&1 | Out-Null
    if ($LASTEXITCODE) { throw "slot ${path}: git worktree add failed" }
  } else {
    Clear-StaleIndexLock $path
    foreach ($op in 'merge', 'cherry-pick', 'rebase') { & git -C $path $op --abort 2>$null | Out-Null }
    & git -C $path reset -q --hard 2>$null
    & git -C $path checkout -q --detach $ref 2>$null
    if ($LASTEXITCODE) { Clear-StaleIndexLock $path; & git -C $path reset -q --hard 2>$null; & git -C $path checkout -q -f --detach $ref 2>$null }
    if ($LASTEXITCODE) { $why = @(& git -C $path checkout -q --detach $ref 2>&1 | ForEach-Object { "$_" }) -join ' | '; throw "slot ${path}: checkout $ref failed ($why)" }
    & git -C $path reset -q --hard $ref
    & git -C $path clean -fdq 2>$null   # not -x: keeps node_modules and build caches (the point of reuse)
  }
  if ($branch) {
    if ((& git -C $path rev-parse --verify -q "refs/heads/$branch" 2>$null)) { & git -C $path checkout -q $branch 2>$null }
    elseif ((& git -C $path rev-parse --verify -q "refs/remotes/origin/$branch" 2>$null)) { & git -C $path checkout -q -b $branch --track "origin/$branch" 2>$null }
    else { & git -C $path checkout -q -b $branch $ref 2>$null }
    if ($LASTEXITCODE) { throw "slot ${path}: cannot check out branch $branch (checked out in another worktree?)" }
  }
  if ($copyEnv) {
    $cands = @(Get-ChildItem -LiteralPath $main -File -Force -Filter '.env*' -ErrorAction SilentlyContinue)
    foreach ($d in 'apps', 'packages') { $b = Join-Path $main $d; if (Test-Path $b) { $cands += Get-ChildItem -LiteralPath $b -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Force -Filter '.env*' -ErrorAction SilentlyContinue } } }
    foreach ($f in $cands) { if ($f.Name -like '*.example') { continue }; $rel = $f.FullName.Substring($main.Length).TrimStart('\'); $t = Join-Path $path $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $t) | Out-Null; Copy-Item -LiteralPath $f.FullName -Destination $t -Force }
  }
}

function Remove-LeaseRecord($l, [string]$event, [string]$why, [string]$backupRef) {
  # Free the agent's branch: a slot left on `feat/x` blocks `git checkout feat/x` everywhere else and
  # makes deleting the branch impossible. State is already backed up (or clean) at this point.
  $p = "$(P $l 'path')"
  if ($event -notin 'lease-failed', 'lease-expire-failed' -and $p -and (Test-Path -LiteralPath (Join-Path $p '.git'))) { & git -C $p checkout -q --detach 2>$null | Out-Null }
  Remove-Item -LiteralPath $l.file, "$($l.file).hb" -Force -ErrorAction SilentlyContinue
  if ($event -in 'lease-expire', 'lease-break' -and (P $l 'session') -ne $Session) { Add-LeaseNotice $l $event $why $backupRef }
  Write-Journal @{ event = $event; resource = "slot:$($l.repo):$($l.slot)"; ticket = (P $l 'leaseId'); holderSession = (P $l 'session'); purpose = (P $l 'purpose'); reason = $why; ref = $backupRef; repo = $l.repo }
}
# Expire = back up (proven) THEN drop the record. A failed backup keeps the lease (fail closed).
function Expire-Lease($l, [string]$why) {
  try { $ref = Backup-Slot (P $l 'path') $l.repo $l.slot $why -CommitsOnly:((P $l 'role') -eq 'release') }
  catch { Write-Journal @{ event = 'lease-expire-failed'; resource = "slot:$($l.repo):$($l.slot)"; reason = "$why; $($_.Exception.Message)"; repo = $l.repo }; return $false }
  Remove-LeaseRecord $l 'lease-expire' $why $ref
  $true
}
function Get-TaskLeaseCount { @(Read-Leases $null | Where-Object { (P $_ 'role') -eq 'task' }).Count }

# Take a slot lease (exclusive). Task role picks the first free task-N. Returns the lease object.
function New-Lease($repo, [string]$slot, [string]$role, [string]$purpose, [string]$branch, [int]$owner, [int]$timeoutMin, [bool]$noWait) {
  $repoName = $repo.Name
  $cfg = Get-Config
  if ($slot) {
    $r = Get-SlotRole $repoName $slot
    if (-not $r) { throw "agentq lease: '$slot' is not a standard slot for $repoName (task-1..$($cfg.taskSlotsPerRepo), release$(if ((Get-ReleaseSlotCount $repoName) -gt 1) { ', release-2..' + (Get-ReleaseSlotCount $repoName) }), land$(if (Get-PinnedSlots $repoName) { ', pinned: ' + ((Get-PinnedSlots $repoName) -join ',') })) - ADR 0001" }
    $role = $r
  } elseif (-not $role) { $role = 'task' }
  $deadline = (Now).AddMinutes($timeoutMin)
  $announced = $false
  while ($true) {
    $got = With-Mutex "lease-$repoName" {
      $leases = @(Read-Leases $repoName)
      $cands = if ($slot) { @($slot) }
      elseif ($role -eq 'task') { @(1..$cfg.taskSlotsPerRepo | ForEach-Object { "task-$_" }) }
      elseif ($role -eq 'release') { @('release') + @(2..([math]::Max(2, (Get-ReleaseSlotCount $repoName))) | Where-Object { $_ -le (Get-ReleaseSlotCount $repoName) } | ForEach-Object { "release-$_" }) }
      else { @($role) }
      $capHit = $false
      foreach ($s in $cands) {
        $cur = $leases | Where-Object { $_.slot -eq $s } | Select-Object -First 1
        if ($cur -and $cur.stale) { if (-not (Expire-Lease $cur "stale (idle $($cur.idleMin) min, owner alive=$($cur.alive)) - reclaimed by $Session")) { continue }; $cur = $null }
        if ($cur) { continue }
        if ($role -eq 'task' -and (Get-TaskLeaseCount) -ge $cfg.taskSlotsMachine) { $capHit = $true; break }
        $p = Get-SlotPath $repoName $s
        $st = Get-ProcStart $owner
        $l = [ordered]@{
          leaseId = [guid]::NewGuid().ToString('N').Substring(0, 8); repo = $repoName; slot = $s; role = $role; path = $p
          branch = "$branch"; purpose = $purpose; session = $Session; pid = $owner; procStart = $(if ($st) { Iso $st } else { $null }); created = (Iso (Now)); host = $env:COMPUTERNAME
        }
        $f = Get-LeaseFile $repoName $s
        Write-JsonAtomic $f $l
        [IO.File]::WriteAllText("$f.hb", '')
        Write-Journal @{ event = 'lease'; resource = "slot:${repoName}:$s"; ticket = $l.leaseId; purpose = $purpose; branch = "$branch"; repo = $repoName }
        return ([pscustomobject]$l | Add-Member -NotePropertyName file -NotePropertyValue $f -PassThru)
      }
      if ($capHit) { 'MACHINE-CAP' } else { $null }
    }
    if ($got -and $got -isnot [string]) { return $got }
    if ($noWait -or (Now) -gt $deadline) {
      $why = if ($got -eq 'MACHINE-CAP') { "machine-wide task slot cap ($($cfg.taskSlotsMachine)) reached" } else { "no free $role slot in $repoName" }
      $held = (@(Read-Leases $repoName) | ForEach-Object { "$($_.slot)=$($_.session) '$($_.purpose)' idle $($_.idleMin)m" }) -join '; '
      [Console]::Error.WriteLine("agentq: $why. Held: $held")
      exit 3
    }
    if (-not $announced) { [Console]::Error.WriteLine("agentq: waiting for a free $role slot in $repoName ..."); $announced = $true }
    Start-Sleep -Seconds 3
  }
}

function Invoke-Lease {
  $repo = Get-RepoInfo $RepoArg
  Assert-ExpectedRepo $repo
  if (-not $repo) { throw 'agentq lease: not in a git repo (pass -Repo)' }
  if (-not $Purpose) { throw 'agentq lease: -Purpose is required (other agents read it)' }
  $main = Get-MainTop $repo
  $owner = Get-DefaultOwner
  $l = New-Lease $repo $Slot $Role $Purpose $Branch $owner $TimeoutMin $NoWait
  try {
    & git -C $main fetch -q origin 2>$null
    $refToUse = if ($Ref) { $Ref } else { $up = (& git -C $main rev-parse --abbrev-ref '@{u}' 2>$null); if ($up) { $up } else { 'HEAD' } }
    # Anything still unique in the dir (previous holder crashed between backup and release, a legacy
    # tree) is backed up before the reset. A failed backup aborts the lease: nothing is discarded.
    if (Test-Path -LiteralPath $l.path) { [void](Backup-Slot $l.path $repo.Name $l.slot "pre-reset for new lease $($l.leaseId)" -CommitsOnly:($l.role -eq 'release')) }
    Initialize-Slot $main $l.path $refToUse $Branch (-not $env:AGENTQ_NO_ENV_COPY)
    if ($l.role -in 'task', 'pinned') { [void](Prepare-Slot $main $l.path $repo.Name) }
  } catch {
    Remove-LeaseRecord $l 'lease-failed' "$($_.Exception.Message)" ''
    throw
  }
  $res = [pscustomobject]@{ leaseId = $l.leaseId; repo = $l.repo; slot = $l.slot; role = $l.role; path = $l.path; branch = "$Branch"; head = "$(& git -C $l.path rev-parse --short HEAD)".Trim() }
  if ($Json) { $res | ConvertTo-Json -Compress } else {
    Write-Output "leased $($l.repo)/$($l.slot) ($($l.leaseId)) -> $($l.path) @ $($res.head)$(if ($Branch) { " on $Branch" })"
    Write-Output "release when done: pwsh -NoProfile -File `"$PSCommandPath`" unlease -Repo `"$($l.path)`" -LeaseId $($l.leaseId)"
  }
}

function Invoke-Unlease {
  $repo = Get-RepoInfo $RepoArg
  $repoName = if ($repo) { $repo.Name } else { $null }
  if (-not $Slot -and $RepoArg) { $l0 = Find-LeaseForPath $RepoArg; if ($l0) { $script:Slot = $l0.slot; $repoName = $l0.repo } }
  if (-not $Slot -or -not $repoName) { throw 'agentq unlease -Repo <slot dir> [-Slot <slot>] -LeaseId <id> [-Reason ...]' }
  $l = (Read-Leases $repoName | Where-Object { $_.slot -eq $Slot } | Select-Object -First 1)
  if (-not $l) { Write-Output "no lease on $repoName/$Slot"; return }
  # Releasing a lease needs its exact id (break-by-id, ADR 0001 section 2); a foreign one also a reason.
  if ($LeaseId -ne $l.leaseId) {
    [Console]::Error.WriteLine("agentq: $repoName/$Slot is leased by $($l.session) ($($l.leaseId), '$($l.purpose)', idle $($l.idleMin)m, alive=$($l.alive)). Pass -LeaseId $($l.leaseId)$(if ($l.session -ne $Session) { " -Reason '...'" })")
    exit 2
  }
  $foreign = ($l.session -ne $Session)
  if ($foreign -and -not $Reason) { [Console]::Error.WriteLine("agentq: lease belongs to $($l.session); breaking it needs -Reason"); exit 2 }
  $why = if ($Reason) { $Reason } else { 'released by holder' }
  try { $ref = Backup-Slot (P $l 'path') $repoName $Slot $why -CommitsOnly:((P $l 'role') -eq 'release') }
  catch { [Console]::Error.WriteLine("agentq: NOT released - backup failed: $($_.Exception.Message)"); exit 3 }
  Remove-LeaseRecord $l $(if ($foreign) { 'lease-break' } else { 'unlease' }) $why $ref
  Write-Output "released $repoName/$Slot$(if ($ref) { " (unsaved state backed up to $ref)" } else { ' (clean, nothing to back up)' })"
}

function Invoke-Renew {
  $p = if ($WtPath) { $WtPath } else { (Get-Location).Path }
  $l = if ($LeaseId) { Read-Leases $null | Where-Object { (P $_ 'leaseId') -eq $LeaseId } | Select-Object -First 1 } else { Find-LeaseForPath $p }
  if ($l) { Touch-Lease $l; Write-Output "renewed $($l.repo)/$($l.slot)" } else { Write-Output "no lease covers $p" }
}

function Invoke-Sweep {
  $n = 0; $kept = 0
  foreach ($l in Read-Leases $null) {
    if (-not $l.stale) { continue }
    if (Expire-Lease $l "stale (idle $($l.idleMin) min, owner alive=$($l.alive))") { $n++; Write-Output "expired $($l.repo)/$($l.slot) ($($l.session) '$($l.purpose)')" }
    else { $kept++; Write-Output "KEPT $($l.repo)/$($l.slot): backup failed (journal: lease-expire-failed)" }
  }
  [void](Read-Releases $null)   # side effect: dead runs are recorded as failed
  try { Invoke-RotateJournal } catch { Write-Output "rotate skipped: $_" }
  Write-Output "sweep: expired=$n kept=$kept"
}

# For scripts and guards: exit 3 + holder when -Path is (inside, or a parent of) a leased slot.
function Invoke-LeaseCheck {
  $l = Find-LeaseForPath $WtPath
  if ($l) { Write-Output "LEASED $($l.repo)/$($l.slot) by $($l.session) ($($l.leaseId)) '$($l.purpose)' idle $($l.idleMin)m stale=$($l.stale)"; exit 3 }
  Write-Output 'FREE'; exit 0
}

# Back up an arbitrary worktree (migration of legacy, non-standard trees). Prints the ref or ''.
function Invoke-Backup {
  if (-not $WtPath) { throw 'agentq backup -Path <worktree> [-Slot <name>] -Reason "..."' }
  $l = Find-LeaseForPath $WtPath
  if ($l) { [Console]::Error.WriteLine("agentq: $WtPath is leased by $($l.session) ($($l.leaseId)) - refusing"); exit 3 }
  $ri = Get-RepoInfo $WtPath
  if (-not $ri) { throw "agentq backup: $WtPath is not a git worktree" }
  $name = if ($Slot) { $Slot } else { Split-Path $WtPath -Leaf }
  Write-Output (Backup-Slot $WtPath $ri.Name $name $(if ($Reason) { $Reason } else { 'manual backup' }))
}

# ---- release runs -------------------------------------------------------------------------
function Get-ReleaseFile([string]$repoName, [string]$target) { Join-Path $RDir "$(Safe $repoName)__$(Safe $target.ToLowerInvariant()).json" }
function Read-Releases([string]$repoName) {
  $out = @()
  foreach ($f in Get-ChildItem $RDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
    if ($repoName -and -not $f.Name.StartsWith("$(Safe $repoName)__")) { continue }
    $r = Read-JsonFile $f.FullName
    if (-not $r -or $r -eq 'UNREADABLE') { continue }
    $alive = Test-Alive ([pscustomobject]@{ pid = [int](P $r 'pid' 0); procStart = (P $r 'procStart' $null) })
    if (-not $alive -and (P $r 'state') -in 'running', 'preempting') {
      # The release process died without release-end: record it as failed (never auto-restarted).
      $r.state = 'failed'; $r | Add-Member -NotePropertyName endedReason -NotePropertyValue 'process died' -Force
      Write-JsonAtomic $f.FullName $r
      Write-Journal @{ event = 'release-dead'; resource = "deploy:$($r.repo):$($r.target)"; sha = $r.sha; reason = 'release process died'; repo = $r.repo }
    }
    $r | Add-Member -NotePropertyName file -NotePropertyValue $f.FullName -Force
    $r | Add-Member -NotePropertyName alive -NotePropertyValue $alive -Force
    $out += $r
  }
  $out
}
function Get-ReleaseRecord {
  $f = $null
  if ($env:AGENTQ_RELEASE_FILE -and (Test-Path -LiteralPath $env:AGENTQ_RELEASE_FILE)) { $f = $env:AGENTQ_RELEASE_FILE }
  elseif ($Target) { $ri = Get-RepoInfo $RepoArg; if ($ri) { $c = Get-ReleaseFile $ri.Name $Target; if (Test-Path -LiteralPath $c) { $f = $c } } }
  if (-not $f) { return $null }
  $r = Read-JsonFile $f
  if (-not $r -or $r -eq 'UNREADABLE') { return $null }
  $r | Add-Member -NotePropertyName file -NotePropertyValue $f -Force -PassThru
}
function Save-Release($r) { Write-JsonAtomic $r.file ($r | Select-Object * -ExcludeProperty file, alive) }

function Invoke-ReleaseBegin {
  $repo = Get-RepoInfo $RepoArg
  if (-not $repo -or -not $Target -or -not $Sha) { throw 'agentq release-begin -Repo <r> -Target <t> -Sha <sha> [-Ref r] [-Follow branch] [-OwnerPid n]' }
  $f = Get-ReleaseFile $repo.Name $Target
  $owner = Get-DefaultOwner
  $script:rbOut = $null
  With-Mutex "release-$($repo.Name)-$Target" {
    $cur = (Read-Releases $repo.Name | Where-Object { $_.file -eq $f } | Select-Object -First 1)
    if ($cur -and $cur.alive -and (P $cur 'state') -in 'running', 'preempting') { [Console]::Error.WriteLine("agentq: release $($repo.Name)/$Target already running: $($cur.runId) @ $($cur.sha)"); exit 3 }
    $st = Get-ProcStart $owner
    $r = [ordered]@{
      runId = $(if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N').Substring(0, 8) }); repo = $repo.Name; target = $Target.ToLowerInvariant()
      sha = $Sha; ref = "$Ref"; follow = "$Follow"; phase = 'prepare'; preemptible = $true; committed = $false; phaseAt = (Iso (Now))
      state = 'running'; supersedeSha = ''; pendingSha = ''; session = $Session; pid = $owner; procStart = $(if ($st) { Iso $st } else { $null }); started = (Iso (Now)); purpose = "$Purpose"
    }
    Write-JsonAtomic $f $r
    Write-Journal @{ event = 'release-begin'; resource = "deploy:$($repo.Name):$($r.target)"; sha = $Sha; ticket = $r.runId; purpose = "$Purpose"; branch = "$Follow"; repo = $repo.Name }
    $script:rbOut = $f
  }
  Write-Output $script:rbOut
}

# Checkpoint. Exit 0 = continue; exit 4 = SUPERSEDED: stop NOW, without further side effects.
# No-op (exit 0) outside a release run, so release scripts also work standalone.
function Invoke-ReleasePhase {
  $r = Get-ReleaseRecord
  if (-not $r) { exit 0 }
  if (-not $Phase) { throw 'agentq release-phase -Phase <name> [-Unsafe]' }
  $script:phaseCode = 0
  With-Mutex "release-$($r.repo)-$($r.target)" {
    $x = Read-JsonFile $r.file | Add-Member -NotePropertyName file -NotePropertyValue $r.file -Force -PassThru
    if ($x.state -eq 'preempting' -and -not $x.committed) {
      $x.state = 'superseded'; $x.phase = "stopped-before:$Phase"; $x.phaseAt = (Iso (Now))
      Save-Release $x
      Write-Journal @{ event = 'release-superseded'; resource = "deploy:$($x.repo):$($x.target)"; sha = $x.sha; reason = "superseded by $($x.supersedeSha) before phase $Phase"; repo = $x.repo }
      [Console]::Error.WriteLine("agentq: release $($x.runId) @ $(Short $x.sha 12) SUPERSEDED by $($x.supersedeSha) - stopping before '$Phase'")
      $script:phaseCode = 4
      return
    }
    if ($x.state -eq 'superseded') { $script:phaseCode = 4; return }
    $x.phase = $Phase; $x.phaseAt = (Iso (Now))
    if ($Unsafe) { $x.committed = $true }
    $x.preemptible = -not $x.committed
    Save-Release $x
    Write-Journal @{ event = 'release-phase'; resource = "deploy:$($x.repo):$($x.target)"; sha = $x.sha; state = $Phase; reason = $(if ($Unsafe) { 'unsafe' } else { 'safe' }); repo = $x.repo }
  }
  exit $script:phaseCode
}

# Ends a run; prints {state, next} - next = sha to release next (supersede tip / pending), or ''.
function Invoke-ReleaseEnd {
  $r = Get-ReleaseRecord
  if (-not $r) { Write-Output '{}'; return }
  if (-not $State) { throw 'agentq release-end -State done|failed|superseded' }
  $script:reOut = $null
  With-Mutex "release-$($r.repo)-$($r.target)" {
    $x = Read-JsonFile $r.file | Add-Member -NotePropertyName file -NotePropertyValue $r.file -Force -PassThru
    if ($x.state -ne 'superseded') { $x.state = $(if ($State -eq 'superseded' -and $x.committed) { 'failed' } else { $State }) }
    $x.phaseAt = (Iso (Now))
    $next = switch ($x.state) { 'superseded' { $x.supersedeSha } 'done' { $x.pendingSha } default { '' } }
    if ($next -eq 'cancel') { $next = '' }
    Save-Release $x
    Write-Journal @{ event = 'release-end'; resource = "deploy:$($x.repo):$($x.target)"; sha = $x.sha; state = $x.state; reason = "next=$next"; repo = $x.repo }
    $script:reOut = [pscustomobject]@{ runId = $x.runId; state = $x.state; next = $next; follow = $x.follow } | ConvertTo-Json -Compress
  }
  Write-Output $script:reOut
}

# A landing (sha now on origin/<branch>) during a running release of that branch: preempt if the run
# has not crossed an unsafe phase, else coalesce into ONE pending run at the newest tip.
# -OnlyTarget restricts to one target (deploy-clean coalescing). Returns 'target:action' strings.
function Notify-Landing([string]$repoName, [string]$branch, [string]$sha, [string]$onlyTarget) {
  $script:notifyActs = @()
  foreach ($r in Read-Releases $repoName) {
    if (-not $r.alive -or (P $r 'state') -notin 'running', 'preempting') { continue }
    if ($onlyTarget -and $r.target -ne $onlyTarget.ToLowerInvariant()) { continue }
    if ((P $r 'follow') -ne $branch -or $r.sha -eq $sha) { continue }
    With-Mutex "release-$($r.repo)-$($r.target)" {
      $x = Read-JsonFile $r.file | Add-Member -NotePropertyName file -NotePropertyValue $r.file -Force -PassThru
      if ($x.state -notin 'running', 'preempting') { return }
      if ($x.committed) { $x.pendingSha = $sha; $act = 'pending' } else { $x.state = 'preempting'; $x.supersedeSha = $sha; $act = 'preempt' }
      Save-Release $x
      Write-Journal @{ event = "release-$act"; resource = "deploy:$($x.repo):$($x.target)"; sha = $sha; reason = "landing on $branch during run $($x.runId) @ $(Short $x.sha 12) phase $($x.phase)"; repo = $x.repo }
      $script:notifyActs += "$($x.target):$act"
    }
  }
  $script:notifyActs
}
function Invoke-NotifyLanding {
  $repo = Get-RepoInfo $RepoArg
  if (-not $repo -or -not $Branch) { throw 'agentq notify-landing -Repo <r> -Branch <b> [-Sha <sha>] [-Target <t>]' }
  $s = if ($Sha) { $Sha } else { "$(& git -C $repo.Top rev-parse "origin/$Branch")".Trim() }
  $acts = @(Notify-Landing $repo.Name $Branch $s $Target)
  if ($Json) { @{ sha = $s; actions = $acts } | ConvertTo-Json -Compress; return }
  Write-Output "notify-landing $($repo.Name) $Branch @ $(Short $s 12): $(if ($acts) { $acts -join ', ' } else { 'no running release follows it' })"
  if ($Target -and -not $acts) { exit 1 }
}
function Invoke-ReleaseCancel {
  $repo = Get-RepoInfo $RepoArg
  if (-not $repo -or -not $Target -or -not $Reason) { throw 'agentq release-cancel -Target <t> -Reason "..."' }
  $f = Get-ReleaseFile $repo.Name $Target
  $script:rcCode = 0
  With-Mutex "release-$($repo.Name)-$Target" {
    $r = Read-JsonFile $f
    if (-not $r -or $r -eq 'UNREADABLE' -or $r.state -ne 'running') { Write-Output "no running release $($repo.Name)/$Target"; return }
    if ($r.committed) { [Console]::Error.WriteLine("agentq: release $($r.runId) is past an unsafe phase ($($r.phase)); it cannot be preempted. Freeze deploy:$($repo.Name):$Target to stop the NEXT run."); $script:rcCode = 3; return }
    $r.state = 'preempting'; $r.supersedeSha = 'cancel'
    Write-JsonAtomic $f $r
    Write-Journal @{ event = 'release-cancel'; resource = "deploy:$($repo.Name):$Target"; sha = $r.sha; reason = $Reason; repo = $repo.Name }
    Write-Output "release $($r.runId) will stop at its next checkpoint"
  }
  exit $script:rcCode
}

# ---- landing queue ------------------------------------------------------------------------
# Union-merge one conflicted path IN BYTES: git writes the three stages to files and merges them in
# place; nothing is decoded by PowerShell. The old resolver piped `git show :N:path` through the
# pipeline (native output decoded with the console code page, CP437 under pwsh) and re-wrote it as
# UTF-8, so every non-ASCII byte became 2-3 bytes on each land - brivio's CHANGELOG went 24 -> 124 MB
# and GitHub refused the push (GH001, 2026-10-15). Order: ours (onto) then theirs (the pick).
function Merge-UnionBytes([string]$wt, [string]$p) {
  $line = "$(& git -C $wt checkout-index --stage=all --temp -- $p 2>$null)".Trim()
  if ($LASTEXITCODE -or -not $line) { return $false }
  $names = ($line -split "`t")[0] -split ' '
  if ($names.Count -lt 3) { return $false }
  $tmps = @($names | Where-Object { $_ -ne '.' } | ForEach-Object { Join-Path $wt $_ })
  try {
    if ($names[1] -eq '.' -or $names[2] -eq '.') { return $false }   # delete/modify: not a union case
    $base = if ($names[0] -eq '.') { $e = Join-Path $wt ('.aq-empty-' + [guid]::NewGuid().ToString('N')); [IO.File]::WriteAllBytes($e, [byte[]]@()); $tmps += $e; $e } else { Join-Path $wt $names[0] }
    $ours = Join-Path $wt $names[1]; $theirs = Join-Path $wt $names[2]
    & git -C $wt merge-file --union $ours $base $theirs 2>$null | Out-Null
    if ($LASTEXITCODE) { return $false }   # --union never leaves conflicts; non-zero = error
    Copy-Item -LiteralPath $ours -Destination (Join-Path $wt $p) -Force
    & git -C $wt add -- $p
    return (-not $LASTEXITCODE)
  } finally { foreach ($x in $tmps) { Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue } }
}

# A CHANGELOG blob that grows past 1.5x its size on origin is a resolver bug, never a real entry
# (a real one adds KBs to a 24 MB file). Returns 'path: old -> new' strings for offenders.
function Get-OversizedChangelogs([string]$wt, [string]$baseRef, [double]$factor = 1.5) {
  $out = @()
  foreach ($p in @(& git -C $wt diff --name-only $baseRef HEAD 2>$null | Where-Object { $_ -match '(^|/)CHANGELOG\.md$' })) {
    $old = "$(& git -C $wt cat-file -s "${baseRef}:$p" 2>$null)".Trim()
    if ($LASTEXITCODE -or -not $old) { continue }   # new file: nothing to compare against
    $new = "$(& git -C $wt cat-file -s "HEAD:$p" 2>$null)".Trim()
    if ($LASTEXITCODE -or -not $new) { continue }   # deleted
    if ([double]$new -gt $factor * [double]$old) { $out += "${p}: $old -> $new bytes" }
  }
  $out
}
# ADR 0003 W2-3: a push refused by the pre-push hook ONLY because of machine load (vitest worker start
# timeouts, hook timeouts, EBUSY/EPERM on Windows temp files) is retried once; the journal records it
# as a flake. Real failures (assertions, type errors, lint) never match these patterns.
$InfraFlakePatterns = @(
  'Failed to start (forks|threads) worker', 'Timeout starting (forks|threads) runner', 'Hook timed out in \d+ms',
  'Test timed out in \d+ms', 'EBUSY: resource busy or locked', 'EPERM: operation not permitted, (rename|unlink|open)',
  'ENOTEMPTY: directory not empty, rmdir .*vitest', 'spawn .* ENOMEM', 'JavaScript heap out of memory', 'Worker exited unexpectedly'
)
function Test-InfraFlake([string[]]$out) {
  $txt = $out -join "`n"
  if ($txt -match '(AssertionError|error TS\d+|✗ .*lint|Expected .* to (be|equal))') { return $null }
  foreach ($p in $InfraFlakePatterns) { if ($txt -match $p) { return $Matches[0] } }
  $null
}
# One land slot per repo: pick the topic's not-yet-upstream commits onto origin/<onto>, resolve the
# documented conflicts, gate, push (never forced), notify running releases. Exit 0 landed / already
# landed, 5 conflict, 6 gate failed, 7 push refused, 8 CHANGELOG grew > 1.5x (refused before push),
# 9 repo land-finalize refused, 3 busy/remote kept moving.
function Invoke-Land {
  $repo = Get-RepoInfo $RepoArg
  Assert-ExpectedRepo $repo
  if (-not $repo -or -not $Branch -or -not $Onto) { throw 'agentq land -Branch <topic> -Onto <dev|main> [-Gate "<cmd>"] -Purpose "why"' }
  $why = if ($Purpose) { $Purpose } else { "land $Branch -> $Onto" }
  $main = Get-MainTop $repo
  $res = "land:$($repo.Name)"
  Assert-NotMarked $res
  $t = New-Ticket $res $why "land $Branch -> $Onto" $main
  Write-Journal @{ event = 'queued'; resource = $res; ticket = $t.id; purpose = $why; repo = $repo.Name }
  $lease = $null; $hb = $null
  $script:LandExit = 1
  try {
    Wait-Turn $t $TimeoutMin $null
    $lease = New-Lease $repo 'land' 'land' $why '' $PID 10 $false
    $hb = Start-ThreadJob -ArgumentList (, @("$($t.file).hb", "$($lease.file).hb")) -ScriptBlock { param($fs) while ($true) { foreach ($f in $fs) { try { [IO.File]::SetLastWriteTimeUtc($f, [DateTime]::UtcNow) } catch {} }; Start-Sleep -Seconds 20 } }
    $env:AGENTQ_HELD = (@($env:AGENTQ_HELD, $res) | Where-Object { $_ }) -join ','
    $wt = $lease.path
    & git -C $main fetch -q origin 2>$null
    $topicRef = if ((& git -C $main rev-parse --verify -q "refs/heads/$Branch" 2>$null)) { "refs/heads/$Branch" } elseif ((& git -C $main rev-parse --verify -q "refs/remotes/origin/$Branch" 2>$null)) { "refs/remotes/origin/$Branch" } else { throw "land: branch $Branch not found locally or on origin" }
    $landed = $null; $nothing = $false; $flakeRetried = $false
    for ($round = 1; $round -le 3 -and -not $landed; $round++) {
      & git -C $main fetch -q origin $Onto 2>$null
      if (Test-Path -LiteralPath $wt) { [void](Backup-Slot $wt $repo.Name 'land' 'leftover in land slot') }
      Initialize-Slot $main $wt "origin/$Onto" '' $true
      # Dedupe: commits whose patch is already upstream (cherry-picked / rebased copies) are skipped.
      $picks = @(& git -C $wt rev-list --reverse --no-merges --cherry-pick --right-only "origin/$Onto...$topicRef" 2>$null | Where-Object { $_ })
      # A pick whose conflicts were resolved (CHANGELOG union) has a different patch-id, so also skip
      # commits named by a `(cherry picked from commit X)` trailer upstream (land picks with -x).
      $mb = "$(& git -C $wt merge-base "origin/$Onto" $topicRef 2>$null)".Trim()
      $range = if ($mb) { "$mb..origin/$Onto" } else { "origin/$Onto" }
      $done = @{}; foreach ($m in [regex]::Matches((@(& git -C $wt log --format=%B $range 2>$null) -join "`n"), 'cherry picked from commit ([0-9a-f]{40})')) { $done[$m.Groups[1].Value] = $true }
      $picks = @($picks | Where-Object { -not $done.ContainsKey($_) })
      if (-not $picks.Count) { Write-Output "land: $Branch is already on origin/$Onto (nothing to pick)"; $landed = "$(& git -C $wt rev-parse HEAD)".Trim(); $nothing = $true; break }
      foreach ($c in $picks) {
        & git -C $wt cherry-pick -x --allow-empty $c 2>&1 | Out-Null
        if (-not $LASTEXITCODE) { continue }
        $conf = @(& git -C $wt diff --name-only --diff-filter=U 2>$null | Where-Object { $_ })
        if (-not $conf.Count) { & git -C $wt cherry-pick --skip 2>$null | Out-Null; continue }   # became empty
        $resolver = Join-Path $wt 'scripts\land-resolve.ps1'
        if (Test-Path -LiteralPath $resolver) { & pwsh -NoProfile -File $resolver -Paths ($conf -join ',') -Worktree $wt 2>&1 | ForEach-Object { Write-Output "  resolver: $_" } }
        foreach ($p in @(& git -C $wt diff --name-only --diff-filter=U 2>$null | Where-Object { $_ -match '(^|/)CHANGELOG\.md$' })) {
          if (-not (Merge-UnionBytes $wt $p)) { break }
        }
        $left = @(& git -C $wt diff --name-only --diff-filter=U 2>$null | Where-Object { $_ })
        $markers = @(& git -C $wt diff --cached --name-only 2>$null | Where-Object { $_ } | Where-Object { $f = Join-Path $wt $_; (Test-Path -LiteralPath $f -PathType Leaf) -and (Select-String -LiteralPath $f -Pattern '^(<{7}|>{7})( |$)' -Quiet) })
        if ($left.Count -or $markers.Count) {
          & git -C $wt cherry-pick --abort 2>$null | Out-Null
          Write-Journal @{ event = 'land-conflict'; resource = $res; sha = $c; paths = @($left + $markers); reason = "conflict picking $(Short $c) onto origin/$Onto"; repo = $repo.Name }
          [Console]::Error.WriteLine("land: CONFLICT picking $(Short $c) onto origin/${Onto}: $(@($left + $markers) -join ', '). Nothing pushed. Rebase $Branch on origin/$Onto in your task slot, push it, and land again.")
          $script:LandExit = 5; return
        }
        # Resolution can make the pick empty (its change is already upstream, e.g. a union-merged
        # CHANGELOG from an earlier landing): skip it instead of failing --continue.
        & git -C $wt diff --cached --quiet 2>$null
        if (-not $LASTEXITCODE) { & git -C $wt cherry-pick --skip 2>&1 | Out-Null; continue }
        & git -C $wt -c core.editor=true cherry-pick --continue 2>&1 | Out-Null
        if ($LASTEXITCODE) { & git -C $wt cherry-pick --abort 2>$null | Out-Null; throw "land: cherry-pick --continue failed for $c" }
      }
      if ($Gate) {
        $rb = if ($env:AGENTQ_RUN_BUILD) { $env:AGENTQ_RUN_BUILD } else { Join-Path $env:USERPROFILE '.copilot\hooks\run-build.ps1' }
        & pwsh -NoProfile -File $rb -Root $wt -Wait -TimeoutMin 120 -Purpose "land gate $Branch" -Command $Gate
        if ($LASTEXITCODE) { Write-Journal @{ event = 'land-gate-failed'; resource = $res; exit = $LASTEXITCODE; reason = $Gate; repo = $repo.Name }; [Console]::Error.WriteLine("land: gate failed ($LASTEXITCODE) - nothing pushed"); $script:LandExit = 6; return }
      }
      # Repo-owned land finalize (ADR 0003 W3, changelog fragments): assembles changes/*.md into ONE
      # chore(release) commit on the CURRENT origin/<onto>, so two topics never claim the same version.
      $finalizer = Join-Path $wt 'scripts\land-finalize.ps1'
      if (Test-Path -LiteralPath $finalizer) {
        $baseSha = "$(& git -C $wt rev-parse "origin/$Onto" 2>$null)".Trim()
        $fo = @(& pwsh -NoProfile -File $finalizer -Worktree $wt -Onto $Onto -Base $baseSha -Branch $Branch 2>&1 | ForEach-Object { "$_" })
        $frc = $LASTEXITCODE
        $fo | ForEach-Object { Write-Output "  finalize: $_" }
        if ($frc) {
          $why2 = "$(@($fo | Select-Object -Last 3) -join ' | ')"
          Write-Journal @{ event = 'land-finalize-failed'; resource = $res; exit = $frc; branch = $Onto; reason = $why2.Substring(0, [math]::Min(500, $why2.Length)); repo = $repo.Name }
          [Console]::Error.WriteLine("land: scripts/land-finalize.ps1 exit $frc - nothing pushed. Fix the fragment(s) on $Branch and land again.")
          Initialize-Slot $main $wt "origin/$Onto" '' $false
          $script:LandExit = 9; return
        }
      }
      $big = @(Get-OversizedChangelogs $wt "origin/$Onto")
      if ($big.Count) {
        Write-Journal @{ event = 'land-oversized'; resource = $res; exit = 8; branch = $Onto; paths = $big; reason = "CHANGELOG grew past 1.5x origin/$Onto"; repo = $repo.Name }
        [Console]::Error.WriteLine("land: REFUSED - CHANGELOG grew past 1.5x its size on origin/${Onto}: $($big -join '; '). Nothing pushed. Rebuild $Branch on origin/$Onto (take its CHANGELOG, re-add your entry) and land again.")
        # Drop the bad result so the land-finished backup does not try to push it to origin.
        Initialize-Slot $main $wt "origin/$Onto" '' $false
        $script:LandExit = 8; return
      }
      $out = @(& git -C $wt push origin "HEAD:$Onto" 2>&1 | ForEach-Object { "$_" })
      if (-not $LASTEXITCODE) { $landed = "$(& git -C $wt rev-parse HEAD)".Trim(); break }
      $flake = if (-not $flakeRetried -and -not ($out -match 'non-fast-forward|fetch first|Updates were rejected')) { Test-InfraFlake $out } else { $null }
      if ($flake) {
        $flakeRetried = $true
        Write-Journal @{ event = 'flake'; resource = $res; exit = 7; branch = $Onto; reason = "pre-push infra failure, retrying once: $flake"; repo = $repo.Name }
        Write-Output "land: pre-push failed on an infrastructure pattern ($flake) - retrying the push once"
        $out = @(& git -C $wt push origin "HEAD:$Onto" 2>&1 | ForEach-Object { "$_" })
        if (-not $LASTEXITCODE) { $landed = "$(& git -C $wt rev-parse HEAD)".Trim(); break }
      }
      if ($out -match 'non-fast-forward|fetch first|Updates were rejected') { Write-Output "land: origin/$Onto moved, retry round $($round + 1)"; continue }
      $out | Select-Object -Last 20 | ForEach-Object { [Console]::Error.WriteLine($_) }
      $tail = (@($out | Select-Object -Last 6) -join ' | ')
      Write-Journal @{ event = 'land-push-failed'; resource = $res; exit = 7; branch = $Onto; reason = $tail.Substring(0, [math]::Min(500, $tail.Length)); repo = $repo.Name }
      $script:LandExit = 7; return
    }
    if (-not $landed) { [Console]::Error.WriteLine('land: origin kept moving (3 rounds) - try again'); $script:LandExit = 3; return }
    if (-not $nothing) {
      $acts = @(Notify-Landing $repo.Name $Onto $landed '')
      Write-Journal @{ event = 'land'; resource = $res; sha = $landed; branch = $Onto; purpose = $why; reason = "$Branch -> $Onto; releases: $($acts -join ',')"; repo = $repo.Name }
      Write-Output "landed $Branch -> origin/$Onto @ $(Short $landed 12)$(if ($acts) { " (releases: $($acts -join ', '))" })"
    }
    $script:LandExit = 0
  } finally {
    if ($hb) { Stop-Job $hb -ErrorAction SilentlyContinue; Remove-Job $hb -Force -ErrorAction SilentlyContinue }
    if ($lease) {
      $l = (Read-Leases $repo.Name | Where-Object { $_.slot -eq 'land' -and $_.leaseId -eq $lease.leaseId } | Select-Object -First 1)
      if ($l) { $ref = try { Backup-Slot $l.path $repo.Name 'land' 'land finished' } catch { "backup-failed: $($_.Exception.Message)" }; Remove-LeaseRecord $l 'unlease' 'land finished' $ref }
    }
    Remove-Item -LiteralPath $t.file, "$($t.file).hb" -Force -ErrorAction SilentlyContinue
  }
}

# ---- publish (ADR 0003 W1-2) -------------------------------------------------------------
# The supported form of the hand-written "temp-index plumbing commit" (reinvented ~18 times, 2026-10).
# Takes ONLY -Paths from the current working tree (any clone or slot), builds a commit whose parent is
# the CURRENT origin/<Onto> tip in a throwaway index (the shared index/worktree are never touched),
# refuses when the result would delete lines in a file the caller did not change relative to its own
# base (= reverting work that landed meanwhile), pushes a fresh topic, verifies it on the remote, and
# with -Land hands it to Invoke-Land. Blobs are written from the file bytes via the repo's own
# clean filters (git hash-object --path), so EOL/attributes match what a normal commit would store.
function Invoke-Publish {
  $repo = Get-RepoInfo $RepoArg
  Assert-ExpectedRepo $repo
  if (-not $repo) { throw 'agentq publish: not in a git repo' }
  if (-not $Purpose -or -not $Message) { throw 'agentq publish -Paths a,b -Message "type(scope): msg" -Purpose "why" [-Onto main] [-Base <ref>] [-Land] [-NoPush]' }
  $plist = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() -replace '\\', '/' } | Where-Object { $_ })
  if (-not $plist) { throw 'agentq publish: -Paths a,b,c is required' }
  $top = $repo.Top
  $onto = if ($Onto) { $Onto } else { $b = "$(& git -C $top rev-parse --abbrev-ref '@{u}' 2>$null)".Trim(); if ($b -match '^[^/]+/(.+)$') { $Matches[1] } else { 'main' } }
  & git -C $top fetch -q origin $onto 2>$null
  if ($LASTEXITCODE) { throw "agentq publish: git fetch origin $onto failed" }
  $tip = "$(& git -C $top rev-parse "origin/$onto")".Trim()
  # Base = the commit the caller edited on top of; default HEAD. Used only for the revert guard.
  $base = if ($Base) { "$(& git -C $top rev-parse --verify "$Base^{commit}" 2>$null)".Trim() } else { "$(& git -C $top rev-parse HEAD)".Trim() }
  if (-not $base) { throw "agentq publish: -Base $Base is not a commit" }
  $idx = Join-Path ([IO.Path]::GetTempPath()) ("aq-pub-" + [guid]::NewGuid().ToString('N') + '.idx')
  $oldIdx = $env:GIT_INDEX_FILE
  $reverts = @(); $changed = @()
  try {
    $env:GIT_INDEX_FILE = $idx
    & git -C $top read-tree $tip; if ($LASTEXITCODE) { throw 'read-tree failed' }
    foreach ($p in $plist) {
      $full = Join-Path $top $p
      if (Test-Path -LiteralPath $full -PathType Leaf) {
        $blob = "$(& git -C $top hash-object -w --path $p -- $full)".Trim()
        if (-not $blob) { throw "hash-object failed for $p" }
        $mode = "$(& git -C $top ls-tree $tip -- $p)".Trim() -split '\s+' | Select-Object -First 1
        if (-not $mode) { $mode = "$(& git -C $top ls-files -s -- $p)".Trim() -split '\s+' | Select-Object -First 1 }
        if (-not $mode) { $mode = '100644' }
        & git -C $top update-index --add --cacheinfo "$mode,$blob,$p"; if ($LASTEXITCODE) { throw "update-index failed for $p" }
      } else {
        & git -C $top update-index --force-remove -- $p
      }
    }
    $tree = "$(& git -C $top write-tree)".Trim()
  } finally { if ($oldIdx) { $env:GIT_INDEX_FILE = $oldIdx } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }; Remove-Item -LiteralPath $idx -Force -ErrorAction SilentlyContinue }
  if ($tree -eq "$(& git -C $top rev-parse "$tip^{tree}")".Trim()) { Write-Output "publish: nothing to publish - origin/$onto already has these $($plist.Count) path(s) as on disk"; return }
  # Revert guard: for every path, compare (base -> disk) with (tip -> result). Lines the tip has that
  # base did not have, and that our result drops, would be someone else's landed work being undone.
  foreach ($p in $plist) {
    $onTip = "$(& git -C $top rev-parse --verify -q "$($tip):$p" 2>$null)".Trim()
    $onBase = "$(& git -C $top rev-parse --verify -q "$($base):$p" 2>$null)".Trim()
    $ours = "$(& git -C $top rev-parse --verify -q "$($tree):$p" 2>$null)".Trim()
    if ($onTip -ne $ours) { $changed += $p }
    if ($onTip -and $onBase -and $onTip -ne $onBase -and $ours -ne $onTip) {
      $tipAdds = @(& git -C $top diff --no-color --unified=0 $onBase $onTip 2>$null | Where-Object { $_ -match '^\+[^+]' } | ForEach-Object { $_.Substring(1) })
      $dropped = @(& git -C $top diff --no-color --unified=0 $onTip $ours 2>$null | Where-Object { $_ -match '^-[^-]' } | ForEach-Object { $_.Substring(1) })
      $lost = @($tipAdds | Where-Object { $dropped -contains $_ })
      if ($lost.Count) { $reverts += "$p ($($lost.Count) line(s) landed after your base would be removed)" }
    }
    if ($onTip -and -not $ours -and $onBase -ne $onTip) { $reverts += "$p (deleted, but origin/$onto changed it after your base)" }
  }
  if ($reverts.Count -and -not $Force) {
    Write-Journal @{ event = 'publish-refused'; resource = "commit:$($repo.Name)"; purpose = $Purpose; paths = $plist; reason = ($reverts -join '; '); repo = $repo.Name }
    [Console]::Error.WriteLine("publish: REFUSED - would revert work that landed on origin/$onto after your base $(Short $base):`n  " + ($reverts -join "`n  ") + "`nRebase those files on origin/$onto (or pass -Force if the removal is intended).")
    exit 5
  }
  $msgFile = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($msgFile, "$Message`n`nAgent-Session: $Session`nAgent-Purpose: $Purpose", [Text.UTF8Encoding]::new($false))
  $sha = "$(& git -C $top commit-tree $tree -p $tip -F $msgFile)".Trim(); Remove-Item $msgFile -Force
  if (-not $sha) { throw 'commit-tree failed' }
  $stat = @(& git -C $top diff --numstat $tip $sha)
  Write-Output "publish: $(Short $sha 12) on origin/$onto @ $(Short $tip 12) ($($changed.Count) file(s))"
  $stat | ForEach-Object { Write-Output "  $_" }
  Write-Journal @{ event = 'publish'; resource = "commit:$($repo.Name)"; sha = $sha; branch = $onto; purpose = $Purpose; message = $Message; paths = $changed; repo = $repo.Name }
  if ($NoPush) { Write-Output "publish: -NoPush, commit $sha exists only locally"; return }
  $topic = if ($Branch) { $Branch } else { "publish/$(($Session -replace '[^A-Za-z0-9-]', '-').ToLowerInvariant())-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))" }
  $out = @(& git -C $top push -q --no-verify origin "$($sha):refs/heads/$topic" 2>&1 | ForEach-Object { "$_" })
  $remote = "$(& git -C $top ls-remote origin "refs/heads/$topic")".Trim() -split '\s+' | Select-Object -First 1
  if ($remote -ne $sha) { $out | Select-Object -Last 10 | ForEach-Object { [Console]::Error.WriteLine($_) }; throw "publish: push of $topic not verified on origin (got '$remote')" }
  Write-Output "publish: pushed origin/$topic = $(Short $sha 12)"
  if (-not $DoLand) { Write-Output "publish: land it with: agentq land -Branch $topic -Onto $onto -Purpose `"$Purpose`""; return }
  $script:Branch = $topic; $script:Onto = $onto
  Invoke-Land
  if ($script:LandExit -eq 0) { & git -C $top push -q --no-verify origin ":refs/heads/$topic" 2>$null | Out-Null }
}


# ---- status sections (called from Show-Status) -------------------------------------------
function Get-V2Status([string]$repoName) {
  $leases = @(Read-Leases $repoName)
  $rels = @(Read-Releases $repoName | Where-Object { (P $_ 'state') -in 'running', 'preempting' -or ((Now) - (ParseUtc (P $_ 'phaseAt' (Iso (Now))))).TotalHours -lt 6 })
  [pscustomobject]@{ leases = $leases; releases = $rels }
}
function Format-V2Status($v) {
  if ($v.releases) {
    Write-Output '== RELEASES'
    foreach ($r in $v.releases) {
      $extra = @(); if ($r.supersedeSha) { $extra += "supersede->$(Short $r.supersedeSha)" }; if ($r.pendingSha) { $extra += "pending->$(Short $r.pendingSha)" }
      Write-Output ("{0,-28} {1,-11} {2,-10} phase={3}{4} follow={5} {6} {7}" -f "$($r.repo)/$($r.target)", "$($r.state)".ToUpper(), (Short $r.sha), $r.phase, $(if ($r.committed) { ' (committed)' } else { ' (preemptible)' }), $r.follow, $r.session, ($extra -join ' '))
    }
  }
  $lost = @(Get-RecentLeaseLosses 24)
  if ($lost.Count) {
    Write-Output '== LEASES LOST (24 h) - restore from the ref'
    $lost | Format-Table @{n = 'when'; e = { "$($_.ts)".Substring(0, 16) } }, event, resource, holderSession, purpose, ref -AutoSize | Out-String -Width 220 | Write-Output
  }
  if ($v.leases) {
    Write-Output '== SLOTS (leases)'
    $v.leases | Sort-Object repo, slot | Format-Table @{n = 'slot'; e = { "$($_.repo)/$($_.slot)" } }, role, @{n = 'state'; e = { if ($_.stale) { 'STALE' } elseif (-not $_.alive) { 'owner-gone' } else { 'ok' } } }, idleMin, branch, session, purpose, leaseId -AutoSize | Out-String -Width 220 | Write-Output
  }
}
function ConvertTo-V2Json($v) {
  @{
    leases = @($v.leases | ForEach-Object { [pscustomobject]@{ leaseId = $_.leaseId; repo = $_.repo; slot = $_.slot; role = $_.role; path = $_.path; branch = $_.branch; purpose = $_.purpose; session = $_.session; pid = $_.pid; created = $_.created; beat = (Iso $_.beat); idleMin = $_.idleMin; alive = $_.alive; stale = $_.stale } })
    releases = @($v.releases | ForEach-Object { $_ | Select-Object * -ExcludeProperty file })
  }
}
