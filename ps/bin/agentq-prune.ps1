# agentq prune (ADR 0009 stage 0, OQ-006): delete state nobody needs any more, and nothing else.
# Dot-sourced by agentq.ps1 INSIDE its script scope (verb `prune`, and `sweep` calls Invoke-Prune -Quiet):
# it reads the parsed arguments $WhatIf, $Days, $Json and the layout $Root, $QDir, $RDir, and uses the
# helpers Get-Config, Write-Journal, Now, Iso, ParseUtc, Safe, P, Get-WtRoot, Get-ProcStart.
#
# Baseline that motivated it (2026-11-11): 3,893 agent files, 3,234 job files, 608 notices, 91 release
# records and 227 ticket-less queue folders in one user store; every `status`/sync call walked them.
#
# WHAT IT REMOVES (defaults; config key `prune` overrides each number, `-Days n` the four *Days at once)
#   agents    <Root>/agents/*.json      older than agentsDays (3)   AND the shell pid is not alive
#                                       (pid gone, or its start time differs > 3 s from shellStart);
#                                       an unparseable old file goes too.
#   jobs      <Root>/jobs/*.json        process not alive AND reference time (endedAt, else startedAt,
#                                       else file time) older than jobsDays (3). A live pid is never removed.
#   notices   <Root>/notices/*.jsonl    older than noticesDays (7).
#   releases  <RDir>/*.json             process not alive AND phaseAt (else file time) older than
#                                       releasesDays (7). A live pid is never removed.
#   queueFolders <QDir>/<name>/         no ticket (a ticket = *.json other than adaptive.json/burst.json),
#                                       name != build_machine, every file AND the folder itself idle for
#                                       queueIdleHours (24), and no sticky capacity other than 1 (a
#                                       `-Capacity n` given once lives only in that folder). Checked +
#                                       deleted under the same named mutex New-Ticket takes
#                                       (Global\agentq-<name>), 2 s timeout -> skipped; see the note
#                                       at the delete for what that mutex does not cover. Never in a
#                                       multi-user system store (root provisions those folders).
#   queueFiles in folders that stay:    *.tmp older than tmpHours (1); *.hb / *.wedged whose ticket .json
#                                       is gone and that are older than tmpHours.
#   prep      <Root>/prep/<repo>--<slot>.json  slot dir <wtroot>/<repo>/<slot> gone AND older than prepDays (7).
#   batches   <Root>/batches/**/*.json  older than batchesDays (1); then subfolders that are empty and were
#                                       idle for batchesDays before this pass.
#   dayFiles  <Root>/hooks/cost-*.jsonl, <Root>/load/probe-*.jsonl  older than dayFilesDays (14) by the
#                                       yyyyMMdd in the name (else file time).
#   chats     <Root>/chats/*.json       older than chatsDays (7).
#   tmp       leftover *.tmp in agents/, jobs/, releases/ older than tmpHours (1).
# NEVER touched: leases, marks, the journal + its archive, agentq.db*, flakes, green, quarantine,
# cloud-down, leases-archive, workspaces, anything not listed, anything outside $Root/$QDir/$RDir.
#
# A JSON file is read only when its age already makes it a candidate (release records are the exception:
# at most one per repo x target, all are read); liveness comes from ONE Get-Process snapshot (pid set)
# plus a per-pid start-time cache, not a call per file. Every delete is try/catch: a
# locked file counts as `skipped`, never an error. -WhatIf deletes nothing and prints what it would remove
# (20 paths per class; -All lists every path).

$script:PruneClasses = @('agents', 'jobs', 'notices', 'releases', 'queueFolders', 'queueFiles', 'prep', 'batches', 'dayFiles', 'chats', 'tmp')

function New-PruneState([bool]$dry) {
  $r = [ordered]@{}; $k = [ordered]@{}; $s = [ordered]@{}; $w = @{}
  foreach ($c in $script:PruneClasses) { $r[$c] = 0; $k[$c] = 0; $s[$c] = 0; $w[$c] = [Collections.Generic.List[string]]::new() }
  @{ removed = $r; kept = $k; skipped = $s; whatIf = $dry; would = $w; pids = $null; starts = @{} }
}

function Get-PruneNumber($pc, [string]$key, [double]$default) {
  if ($pc -is [hashtable] -and $pc.ContainsKey($key) -and $null -ne $pc[$key]) { try { return [double]$pc[$key] } catch { return $default } }
  if ($null -ne $pc -and -not ($pc -is [hashtable])) { $v = P $pc $key $null; if ($null -ne $v) { try { return [double]$v } catch { return $default } } }
  $default
}

# Files of one directory whose name ends with $suffix (ordinal, case-insensitive). No recursion; no
# EnumerateFiles pattern, whose 3-character-extension quirk would also match "x.tmpX".
function Get-PruneFiles([string]$dir, [string]$suffix) {
  if (-not [IO.Directory]::Exists($dir)) { return @() }
  @([IO.Directory]::EnumerateFiles($dir) | Where-Object { $_.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase) })
}
# .NET answers 1601-01-01 for a path that vanished meanwhile: report "now" so it is never a candidate.
function Get-PruneLastWrite([string]$path) { try { $t = [IO.File]::GetLastWriteTimeUtc($path); if ($t.Year -le 1601) { Now } else { $t } } catch { Now } }
function Read-PruneJson([string]$path) { try { [IO.File]::ReadAllText($path) | ConvertFrom-Json -DateKind String } catch { $null } }
function ConvertTo-PruneInt($v) { if ($null -eq $v -or "$v" -eq '') { return 0 }; try { [int]$v } catch { 0 } }
function ConvertTo-PruneUtc($v) {
  if ($null -eq $v -or "$v" -eq '') { return $null }
  try {
    if ($v -is [datetime]) { return $v.ToUniversalTime() }
    if ($v -is [long] -or $v -is [int] -or $v -is [double] -or $v -is [decimal]) { return [DateTime]::new([long]$v, [DateTimeKind]::Utc) }  # job pidStart = UTC ticks
    ParseUtc "$v"
  } catch { $null }
}

# Alive = pid in the snapshot AND (no recorded start, or the start time matches within 3 s). A pid whose
# start time cannot be read (access denied) counts as alive: never delete what might be running.
# -NeedStart (records that already say they finished): without a recorded start the pid proves nothing,
# it has most likely been recycled, so the record is not alive.
function Test-PruneAlive([hashtable]$st, [int]$procId, $start, [switch]$NeedStart) {
  if ($procId -le 0) { return $false }
  if ($null -eq $st.pids) {
    $st.pids = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $st.pids[[int]$p.Id] = $true }
  }
  if (-not $st.pids.ContainsKey($procId)) { return $false }
  $want = ConvertTo-PruneUtc $start
  if ($null -eq $want) { return (-not $NeedStart) }
  if (-not $st.starts.ContainsKey($procId)) { $st.starts[$procId] = Get-ProcStart $procId }
  $s = $st.starts[$procId]
  if ($null -eq $s) { return $true }
  [math]::Abs(($s - $want).TotalSeconds) -lt 3
}

# One delete. Returns nothing; counts removed (or "would remove") / skipped on the class.
function Remove-PruneItem([hashtable]$st, [string]$class, [string]$path, [bool]$isDir) {
  if ($st.whatIf) { $st.would[$class].Add($path); $st.removed[$class] = $st.removed[$class] + 1; return }
  try {
    if ($isDir) { [IO.Directory]::Delete($path, $true) } else { [IO.File]::Delete($path) }
    $st.removed[$class] = $st.removed[$class] + 1
  } catch { $st.skipped[$class] = $st.skipped[$class] + 1 }
}
function Add-PruneKept([hashtable]$st, [string]$class) { $st.kept[$class] = $st.kept[$class] + 1 }

function Invoke-Prune {
  param([switch]$Quiet)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $dry = [bool]$script:WhatIf
  $st = New-PruneState $dry
  $cfg = Get-Config
  $pc = if ($cfg -is [hashtable] -and $cfg.ContainsKey('prune')) { $cfg['prune'] } else { $null }
  $agentsDays = Get-PruneNumber $pc 'agentsDays' 3
  $jobsDays = Get-PruneNumber $pc 'jobsDays' 3
  $noticesDays = Get-PruneNumber $pc 'noticesDays' 7
  $releasesDays = Get-PruneNumber $pc 'releasesDays' 7
  $queueIdleHours = Get-PruneNumber $pc 'queueIdleHours' 24
  $tmpHours = Get-PruneNumber $pc 'tmpHours' 1
  $dayFilesDays = Get-PruneNumber $pc 'dayFilesDays' 14
  $chatsDays = Get-PruneNumber $pc 'chatsDays' 7
  $batchesDays = Get-PruneNumber $pc 'batchesDays' 1
  $prepDays = Get-PruneNumber $pc 'prepDays' 7
  $daysArg = [double]$script:Days
  if ($daysArg -gt 0) { $agentsDays = $daysArg; $jobsDays = $daysArg; $noticesDays = $daysArg; $releasesDays = $daysArg }
  $now = Now
  $cutAgents = $now.AddDays(-$agentsDays); $cutJobs = $now.AddDays(-$jobsDays); $cutNotices = $now.AddDays(-$noticesDays)
  $cutReleases = $now.AddDays(-$releasesDays); $cutQueue = $now.AddHours(-$queueIdleHours); $cutTmp = $now.AddHours(-$tmpHours)
  $cutDay = $now.AddDays(-$dayFilesDays); $cutChats = $now.AddDays(-$chatsDays); $cutBatches = $now.AddDays(-$batchesDays); $cutPrep = $now.AddDays(-$prepDays)
  $sfx = if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') } else { '' }

  # 1 agents
  $agentsDir = Join-Path $Root 'agents'
  foreach ($f in Get-PruneFiles $agentsDir '.json') {
    if ((Get-PruneLastWrite $f) -ge $cutAgents) { Add-PruneKept $st 'agents'; continue }
    $o = Read-PruneJson $f
    if ($o -and (Test-PruneAlive $st (ConvertTo-PruneInt (P $o 'shellPid' 0)) (P $o 'shellStart' $null))) { Add-PruneKept $st 'agents'; continue }
    Remove-PruneItem $st 'agents' $f $false
  }

  # 2 jobs
  $jobsDir = Join-Path $Root 'jobs'
  foreach ($f in Get-PruneFiles $jobsDir '.json') {
    $lw = Get-PruneLastWrite $f
    if ($lw -ge $cutJobs) { Add-PruneKept $st 'jobs'; continue }
    $o = Read-PruneJson $f
    if ($o) {
      $active = "$(P $o 'state' '')" -in 'running', 'starting'
      if (Test-PruneAlive $st (ConvertTo-PruneInt (P $o 'pid' 0)) (P $o 'pidStart' $null) -NeedStart:(-not $active)) { Add-PruneKept $st 'jobs'; continue }
      $refAt = ConvertTo-PruneUtc (P $o 'endedAt' $null)
      if ($null -eq $refAt) { $refAt = ConvertTo-PruneUtc (P $o 'startedAt' $null) }
      if ($null -eq $refAt) { $refAt = $lw }
      if ($refAt -ge $cutJobs) { Add-PruneKept $st 'jobs'; continue }
    }
    Remove-PruneItem $st 'jobs' $f $false
  }

  # tmp leftovers of atomic writes (agents/, jobs/, releases/)
  foreach ($d in @($agentsDir, $jobsDir, $RDir)) {
    foreach ($f in Get-PruneFiles $d '.tmp') {
      if ((Get-PruneLastWrite $f) -lt $cutTmp) { Remove-PruneItem $st 'tmp' $f $false } else { Add-PruneKept $st 'tmp' }
    }
  }

  # 3 notices
  foreach ($f in Get-PruneFiles (Join-Path $Root 'notices') '.jsonl') {
    if ((Get-PruneLastWrite $f) -lt $cutNotices) { Remove-PruneItem $st 'notices' $f $false } else { Add-PruneKept $st 'notices' }
  }

  # 4 release run records. Judged by phaseAt, not by the file time: sweep/status rewrite the record of a
  # run whose process died (state failed) without moving phaseAt, and that must not restart the clock.
  # At most one record per repo x target, so reading each is cheap.
  foreach ($f in Get-PruneFiles $RDir '.json') {
    $lw = Get-PruneLastWrite $f
    $o = Read-PruneJson $f
    if (-not $o -and $lw -ge $cutReleases) { Add-PruneKept $st 'releases'; continue }
    if ($o) {
      $active = "$(P $o 'state' '')" -in 'running', 'preempting'
      if (Test-PruneAlive $st (ConvertTo-PruneInt (P $o 'pid' 0)) (P $o 'procStart' $null) -NeedStart:(-not $active)) { Add-PruneKept $st 'releases'; continue }
      $refAt = ConvertTo-PruneUtc (P $o 'phaseAt' $null)
      if ($null -eq $refAt) { $refAt = $lw }
      if ($refAt -ge $cutReleases) { Add-PruneKept $st 'releases'; continue }
    }
    Remove-PruneItem $st 'releases' $f $false
  }

  # 5 queue folders. On a multi-user machine (system store, ADR 0007) the queue folders are provisioned
  # by root with a group and mode per repo: there only stale files go, never a folder.
  $sysStore = ("$SysRoot" -ne "$Root")
  if ([IO.Directory]::Exists($QDir)) {
    foreach ($d in @([IO.Directory]::EnumerateDirectories($QDir))) {
      $name = Split-Path $d -Leaf
      $files = @([IO.Directory]::EnumerateFiles($d))
      $tickets = @($files | Where-Object { $_.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $_ -Leaf) -notin 'adaptive.json', 'burst.json' })
      $hasSub = @([IO.Directory]::EnumerateDirectories($d)).Count -gt 0
      # idle = every file and the folder itself older than the cut, and no sticky capacity to lose
      $allIdle = {
        param($fs)
        foreach ($x in $fs) { if ((Get-PruneLastWrite $x) -ge $cutQueue) { return $false } }
        if ([IO.Directory]::GetLastWriteTimeUtc($d) -ge $cutQueue) { return $false }
        $capFile = Join-Path $d 'capacity'
        if ([IO.File]::Exists($capFile)) { try { if ([IO.File]::ReadAllText($capFile).Trim() -ne '1') { return $false } } catch { return $false } }
        $true
      }
      if ($tickets.Count -eq 0 -and $name -ne 'build_machine' -and -not $hasSub -and -not $sysStore -and (& $allIdle $files)) {
        $m = [Threading.Mutex]::new($false, "Global\agentq-$(Safe $name)$sfx")
        $got = $false
        try {
          try { $got = $m.WaitOne(2000) } catch [Threading.AbandonedMutexException] { $got = $true }
          if (-not $got) { $st.skipped['queueFolders'] = $st.skipped['queueFolders'] + 1; continue }
          # Re-check while holding the ticket mutex: a ticket published by a creator that held the mutex
          # before us is seen here and the folder stays. NOT covered: New-Ticket tests/creates the folder
          # BEFORE it takes this mutex and writes `seq` after, so a creation that is past that test but
          # not yet holding the mutex at this instant fails once with "Could not find a part of the
          # path ...\seq" (no ticket, nothing held; the caller retries). The window is the few ms between
          # those two lines, on a resource idle for queueIdleHours. Closing it needs New-Ticket to
          # (re)create the folder after it takes the mutex.
          $files2 = @([IO.Directory]::EnumerateFiles($d))
          $tickets2 = @($files2 | Where-Object { $_.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $_ -Leaf) -notin 'adaptive.json', 'burst.json' })
          if ($tickets2.Count -eq 0 -and (& $allIdle $files2)) { Remove-PruneItem $st 'queueFolders' $d $true; continue }
          Add-PruneKept $st 'queueFolders'
        } finally { if ($got) { try { $m.ReleaseMutex() } catch {} }; $m.Dispose() }
        continue
      }
      Add-PruneKept $st 'queueFolders'
      # the folder stays: only stale write leftovers and orphan sidecars go
      foreach ($f in $files) {
        $leaf = Split-Path $f -Leaf
        if ($leaf.EndsWith('.tmp', [StringComparison]::OrdinalIgnoreCase)) {
          if ((Get-PruneLastWrite $f) -lt $cutTmp) { Remove-PruneItem $st 'queueFiles' $f $false } else { Add-PruneKept $st 'queueFiles' }
          continue
        }
        if ($leaf.EndsWith('.hb', [StringComparison]::OrdinalIgnoreCase) -or $leaf.EndsWith('.wedged', [StringComparison]::OrdinalIgnoreCase)) {
          $ticket = $f.Substring(0, $f.LastIndexOf('.'))
          if (-not [IO.File]::Exists($ticket) -and (Get-PruneLastWrite $f) -lt $cutTmp) { Remove-PruneItem $st 'queueFiles' $f $false } else { Add-PruneKept $st 'queueFiles' }
        }
      }
    }
  }

  # 6 prep state of slots that no longer exist
  $wtRoot = Get-WtRoot
  foreach ($f in Get-PruneFiles (Join-Path $Root 'prep') '.json') {
    $stem = [IO.Path]::GetFileNameWithoutExtension($f)
    $ix = $stem.LastIndexOf('--')
    if ($ix -lt 1) { Add-PruneKept $st 'prep'; continue }
    $slotDir = Join-Path (Join-Path $wtRoot $stem.Substring(0, $ix)) $stem.Substring($ix + 2)
    if (-not [IO.Directory]::Exists($slotDir) -and (Get-PruneLastWrite $f) -lt $cutPrep) { Remove-PruneItem $st 'prep' $f $false } else { Add-PruneKept $st 'prep' }
  }

  # 7 land batch results
  $bDir = Join-Path $Root 'batches'
  if ([IO.Directory]::Exists($bDir)) {
    # a subfolder goes only when no land wrote into it for batchesDays (its time BEFORE this pass) and it is
    # empty afterwards: a land holder creating its result file there right now is never tripped up
    $idleDirs = @([IO.Directory]::EnumerateDirectories($bDir, '*', 'AllDirectories') | Where-Object { (Get-PruneLastWrite $_) -lt $cutBatches } | Sort-Object { $_.Length } -Descending)
    foreach ($f in @([IO.Directory]::EnumerateFiles($bDir, '*', 'AllDirectories') | Where-Object { $_.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) })) {
      if ((Get-PruneLastWrite $f) -lt $cutBatches) { Remove-PruneItem $st 'batches' $f $false } else { Add-PruneKept $st 'batches' }
    }
    if (-not $dry) {
      foreach ($sd in $idleDirs) {
        try { if (@([IO.Directory]::EnumerateFileSystemEntries($sd)).Count -eq 0) { [IO.Directory]::Delete($sd) } } catch {}
      }
    }
  }

  # 8 day files (hooks/cost-yyyyMMdd.jsonl, load/probe-yyyyMMdd.jsonl)
  foreach ($pair in @(@('hooks', 'cost-'), @('load', 'probe-'))) {
    $dd = Join-Path $Root $pair[0]
    foreach ($f in Get-PruneFiles $dd '.jsonl') {
      $leaf = Split-Path $f -Leaf
      if (-not $leaf.StartsWith($pair[1], [StringComparison]::OrdinalIgnoreCase)) { continue }
      $at = $null
      if ($leaf -match '(\d{8})') { try { $at = [DateTime]::ParseExact($Matches[1], 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal) } catch { $at = $null } }
      if ($null -eq $at) { $at = Get-PruneLastWrite $f }
      if ($at -lt $cutDay) { Remove-PruneItem $st 'dayFiles' $f $false } else { Add-PruneKept $st 'dayFiles' }
    }
  }

  # 9 chats
  foreach ($f in Get-PruneFiles (Join-Path $Root 'chats') '.json') {
    if ((Get-PruneLastWrite $f) -lt $cutChats) { Remove-PruneItem $st 'chats' $f $false } else { Add-PruneKept $st 'chats' }
  }

  $sw.Stop()
  $total = 0; $totalKept = 0; $totalSkipped = 0; $parts = @()
  foreach ($c in $script:PruneClasses) {
    $total += [int]$st.removed[$c]; $totalKept += [int]$st.kept[$c]; $totalSkipped += [int]$st.skipped[$c]
    if ([int]$st.removed[$c] -gt 0) { $parts += "$c=$($st.removed[$c])" }
  }
  if ($total -gt 0 -and -not $dry) {
    Write-Journal @{ event = 'prune'; resource = 'agentq'; removed = $total; reason = ($parts -join ' ') }
  }
  $result = [ordered]@{ whatIf = $dry; removed = $st.removed; kept = $st.kept; skipped = $totalSkipped; tookMs = [int]$sw.ElapsedMilliseconds }
  if ($Quiet) {
    # plain hashtables for the caller (sweep): .ContainsKey works, nothing is printed
    $rm = @{}; $kp = @{}
    foreach ($c in $script:PruneClasses) { $rm[$c] = [int]$st.removed[$c]; $kp[$c] = [int]$st.kept[$c] }
    return @{ whatIf = $dry; removed = $rm; kept = $kp; skipped = $totalSkipped; total = $total; tookMs = [int]$sw.ElapsedMilliseconds }
  }
  if ($script:Json) { Write-Output ($result | ConvertTo-Json -Depth 4); return }
  if ($dry) {
    $listMax = if ($script:All) { [int]::MaxValue } else { 20 }
    foreach ($c in $script:PruneClasses) {
      $list = $st.would[$c]
      $shown = 0
      foreach ($path in $list) { if ($shown -ge $listMax) { break }; Write-Output "would remove $c $path"; $shown++ }
      if ($list.Count -gt $shown) { Write-Output "would remove $c ... and $($list.Count - $shown) more (-All lists every path)" }
    }
  }
  Write-Output "== agentq prune$(if ($dry) { ' -WhatIf (nothing deleted)' }) in $Root"
  Write-Output ("   {0,-14} {1,8} {2,8} {3,8}" -f 'class', $(if ($dry) { 'would' } else { 'removed' }), 'kept', 'skipped')
  foreach ($c in $script:PruneClasses) { Write-Output ("   {0,-14} {1,8} {2,8} {3,8}" -f $c, $st.removed[$c], $st.kept[$c], $st.skipped[$c]) }
  Write-Output ("   {0,-14} {1,8} {2,8} {3,8}   took {4} ms" -f 'total', $total, $totalKept, $totalSkipped, [int]$sw.ElapsedMilliseconds)
}
