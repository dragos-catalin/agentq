<#
shared-clone-janitor — unstick a SHARED clone by PUBLISHING its unowned debris, never by throwing it away.

WHY (verified 2026-11-22): E:\gh\codai is a shared clone (agentq-config.json
`sharedCloneModeRepos: { "codai": "refuse" }`) used by ~26 concurrent agents. It carried 13 uncommitted
files nobody owned, so `git-autosync` could not fast-forward main for about four hours and kept printing
  refuse: <N> local edit(s) collide with incoming and are still being edited
It was fixed BY HAND: recompute a union against the CURRENT origin/main, `agentq publish` those paths,
then a path-scoped `git stash push -u -m "<reason>" -- <paths>`. This automates exactly that, with the
guards that made the hand fix safe.

WHAT ONE PASS DOES, per repo whose config marks it `sharedCloneMode=refuse` and that has a slots dir
`<parent>\.wt\<repo>`:
  1. `git status --porcelain` -> the dirty set. Empty -> nothing to do (the steady state, and the reason
     the log stays quiet).
  2. SKIP that repo (journal `skipped`, with the reason) when ANY of:
       * an agentq `commit:<repo>` ticket is HELD (the queue's own `held` flag). A WAITER never blocks, and
         a `land:<repo>` ticket never blocks either - held or queued - because a land works in its own slot
         (Invoke-LandPregate takes a scratch slot; Initialize-Slot/gate/land-finalize/push all run in
         E:\gh\.wt\<repo>\land) and never writes this clone. Before 2026-11-23 this gate counted ANY queued
         ticket, so a permanently deep land queue starved the janitor at every 2-minute tick: E:\gh\codai
         refused to fast-forward for 2h44m over a 2h-stale 35-path draft while 10 lands drained one at a
         time, and the tool that exists to fix exactly that never ran;
       * a dirty file's mtime is newer than now - -LiveWriterSec (120 s): a live writer owns it;
       * a rebase/merge/cherry-pick is in progress (.git\rebase-merge, .git\rebase-apply, .git\MERGE_HEAD,
         .git\CHERRY_PICK_HEAD, .git\REVERT_HEAD, .git\index.lock);
       * the dirty set is larger than -MaxFiles (50): a big dirty set is a live agent, not debris.
  3. FIRST copy every dirty path into ~/.codai/backups/shared-clone/<repo>/<yyyyMMdd-HHmmss>/, path
     preserving, with git's own relative paths, and write manifest.json (git path, size, sha256, mtime).
  4. Then push those explicit paths through agentq's own publish path (`agentq publish -Paths ... \
     -Message ... -Purpose ...`): a plumbing commit parented on the CURRENT origin/<branch> tip, built in
     a throwaway index (the shared index/worktree are never touched by it), with agentq's revert guard.
     If it refuses (exit 5: the result would drop lines that landed upstream after the caller's base),
     NOTHING else happens — the journal gets `publish-refused` with agentq's own message and the tree is
     left exactly as it was.
  5. ONLY after the publish is verified on origin (publish verifies its own push): clean EXACTLY those
     paths with
       git stash push -u -m "shared-clone-janitor <repo> <ts>: published by <session>" -- <paths>
     then require `git status --porcelain -- <paths>` to be empty. NEVER a bare stash, never
     checkout/restore/reset, never `git add -A`. A writer that appears DURING the pass aborts the clean
     (the published topic already holds the salvaged copy; the tree keeps its newer edit).
  6. Every step is one JSON line in <coord>\journal.jsonl — the shape git-autosync.ps1 / agentq.ps1 write
     (ts, session, event, ...), mutex-guarded by the same helper name.

  shared-clone-janitor.ps1 [-Repo <name|path>[,...]] [-Apply] [-WhatIf] [-MaxFiles 50]
                           [-LiveWriterSec 120] [-Message "<type(scope): msg>"] [-Purpose "<why>"]

  DEFAULT IS A DRY RUN: it prints the dirty set, each path's age, the keep/skip decision with its reason
  and the exact commands it WOULD run, and touches nothing. -Apply acts; -WhatIf is the same as the
  default (accepted so a caller can be explicit). -Repo filters the configured list by name, or selects a
  repo by path (an explicit path still has to pass every gate).
  Exit: 0 = nothing to do (every selected repo clean); 3 = something was skipped, or a dry run would
        have acted; 1 = an unexpected error (a repo that failed mid-act is journaled `error`).

  NOT INSTALLED BY THIS FILE (a scheduled task created by a test run would be worse than none). To run it
  on the same 2-minute tick git-autosync uses — one pass per tick, hidden launcher, IgnoreNew, a
  30-minute cap so a wedged pass cannot block every later tick — register it the way
  `git-autosync.ps1 -Install` registers its own task:
    $vbs  = 'E:\gh\vmui\scripts\hidden-run.vbs'; $pwsh = (Get-Command pwsh).Source    # optional hidden launch
    $act  = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"<this script>`" -Apply"
    $trg  = @((New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
              (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) -RepetitionInterval (New-TimeSpan -Minutes 2)))
    $set  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew
    Register-ScheduledTask -TaskName 'shared-clone-janitor' -Action $act -Trigger $trg -Settings $set -Force

  A stale ticket blocks a repo until agentq reaps it (any working verb does); that is deliberate — this
  tool never decides a held ticket is dead.
Environment overrides (tests): SHARED_CLONE_JANITOR_LOG, SHARED_CLONE_JANITOR_BACKUP,
SHARED_CLONE_JANITOR_COORD (also honours AGENTQ_HOME), SHARED_CLONE_JANITOR_AGENTQ, AGENTQ_CONFIG.
Log: ~/.codai/shared-clone-janitor.log (one line per action); Journal: <coord>\journal.jsonl.
#>
param(
  [string[]]$Repo = @(),
  # Acting requires this. Default (and -WhatIf) is a dry run that only prints the plan.
  [switch]$Apply, [switch]$WhatIf,
  # Above this many dirty paths the set is a live agent, not debris.
  [int]$MaxFiles = 50,
  # A dirty file written within this many seconds belongs to a live writer.
  [int]$LiveWriterSec = 120,
  # Override the published commit subject / purpose (defaults name the repo and the path count).
  [string]$Message, [string]$Purpose
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
# Paths may be non-ASCII; decode git's output as UTF-8 (same as agentq's publish plumbing).
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

$Log = if ($env:SHARED_CLONE_JANITOR_LOG) { $env:SHARED_CLONE_JANITOR_LOG } else { Join-Path $HOME '.codai\shared-clone-janitor.log' }
$BackupRoot = if ($env:SHARED_CLONE_JANITOR_BACKUP) { $env:SHARED_CLONE_JANITOR_BACKUP } else { Join-Path $HOME '.codai\backups\shared-clone' }
# The coord root holds the journal and the queue dirs; same resolution agentq.ps1 / git-autosync.ps1 use.
$CoordRoot = if ($env:SHARED_CLONE_JANITOR_COORD) { $env:SHARED_CLONE_JANITOR_COORD }
  elseif ($env:AGENTQ_HOME) { $env:AGENTQ_HOME }
  else { Join-Path (Join-Path $HOME '.codai') 'coord' }
$CoordQ = Join-Path $CoordRoot 'queues'
$CfgPath = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $HOME '.copilot\bin\agentq-config.json' }
$AgentqPath = if ($env:SHARED_CLONE_JANITOR_AGENTQ) { $env:SHARED_CLONE_JANITOR_AGENTQ } else { Join-Path $HOME '.copilot\bin\agentq.ps1' }
$Session = if ($env:AGENTQ_SESSION) { $env:AGENTQ_SESSION }
  elseif ($env:COPILOT_SESSION_ID) { $env:COPILOT_SESSION_ID }
  elseif ($env:CLAUDE_SESSION_ID) { $env:CLAUDE_SESSION_ID }
  else { "scj-$PID" }
# Dry run unless -Apply was given (and -WhatIf always wins).
$dry = (-not $Apply) -or $WhatIf
$sep = [IO.Path]::DirectorySeparatorChar
$script:HeadSha = ''

foreach ($d in @($Log, $BackupRoot, $CfgPath, $AgentqPath)) {
  if ($d -and $d -ne $CfgPath -and $d -ne $AgentqPath) {
    $p = Split-Path $d -Parent
    if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force $p | Out-Null }
  }
}

# One line per action in the text log, same shape the daemon log uses (ISO ts, repo leaf, message).
# It returns NOTHING on purpose: every value a function writes to the pipeline becomes part of its return
# value, and Invoke-Repo returns a record the caller reads (`$res.lines`). A log helper that also emitted
# turned that record into an array and the caller died with PropertyNotFoundException 'lines'.
function Write-Log([string]$repo, [string]$msg) {
  $line = '{0} {1} {2}' -f ([DateTime]::UtcNow.ToString('o')), (Split-Path $repo -Leaf), $msg
  try { [IO.File]::AppendAllText($Log, $line + "`n", [Text.UTF8Encoding]::new($false)) } catch { }
}

# One JSON line appended to the coord journal — the SAME shape agentq.ps1 Write-Journal / git-autosync.ps1
# Write-DaemonJournal use (ts, session, event, ...), mutex-guarded. agentq's own Write-Journal is not
# reachable from this process, so the line is appended here directly. Best effort: a failure must never
# break a pass.
function Write-Journal([hashtable]$e) {
  if (-not $e.ContainsKey('ts')) { $e.ts = ([DateTime]::UtcNow.ToString('o')) }
  if (-not $e.ContainsKey('session')) { $e.session = $Session }
  try {
    $jf = Join-Path $CoordRoot 'journal.jsonl'
    $dir = Split-Path $jf -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $line = ($e | ConvertTo-Json -Compress -Depth 6)
    $m = [Threading.Mutex]::new($false, "Global\agentq-journal$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
    try { [void]$m.WaitOne(5000); [IO.File]::AppendAllText($jf, $line + "`n", [Text.UTF8Encoding]::new($false)) }
    finally { try { $m.ReleaseMutex() } catch { }; $m.Dispose() }
  } catch { }
}

# Only the MAIN worktree is the shared clone; every other worktree of the repo is a leased slot, which is
# exactly where agents are supposed to be dirty (agentq.ps1 Test-IsMainWorktree, verbatim).
function Test-IsMainWorktree([string]$top) {
  $gd = "$(& git -C $top rev-parse --path-format=absolute --git-dir 2>$null)".Trim()
  $cd = "$(& git -C $top rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
  if (-not $gd -or -not $cd) { return $false }   # cannot prove it is the main tree -> do not act
  $norm = { param($p) ([IO.Path]::GetFullPath("$p")).TrimEnd([char[]]@('\', '/')).ToLowerInvariant() }
  ((& $norm $gd) -eq (& $norm $cd))
}

# The dirty set, as git's own relative paths (forward slashes, core.quotepath=off so non-ASCII is literal).
# A rename contributes BOTH sides: publishing only the new path would leave the old one as a pending
# delete in the worktree.
function Get-DirtyPaths([string]$top) {
  $out = [Collections.Generic.List[object]]::new()
  $raw = @(& git -C $top -c core.quotepath=off status --porcelain -uall 2>$null)
  foreach ($l in $raw) {
    $s = "$l"
    if ($s.Length -lt 4) { continue }
    $xy = $s.Substring(0, 2)
    $rest = $s.Substring(3)
    if ($rest -match ' -> ') { foreach ($p in @($rest -split ' -> ')) { $out.Add([pscustomobject]@{ xy = $xy; path = "$p".Trim() }) } }
    else { $out.Add([pscustomobject]@{ xy = $xy; path = $rest.Trim() }) }
  }
  $out
}

function Format-Age($sec) {
  if ($null -eq $sec) { return '-' }
  $s = [int]$sec
  if ($s -lt 90) { return "${s}s" }
  if ($s -lt 5400) { return "$([int]($s / 60))m" }
  return "$([math]::Round($s / 3600, 1))h"
}

# Step 3: copy every dirty path, path preserving, and write manifest.json next to it.
function New-Backup([string]$top, [string]$name, [string]$ts, [object[]]$rows) {
  $dest = Join-Path (Join-Path $BackupRoot $name) $ts
  New-Item -ItemType Directory -Force $dest | Out-Null
  $man = [Collections.Generic.List[object]]::new()
  foreach ($row in $rows) {
    $rel = "$($row.path)".Replace('/', $sep)
    $src = Join-Path $top $rel
    $entry = [ordered]@{ path = "$($row.path)"; status = "$($row.xy)"; present = $false; deleted = $true; size = 0; sha256 = $null; mtime = $null }
    if (Test-Path -LiteralPath $src -PathType Leaf) {
      $item = Get-Item -LiteralPath $src
      $tgt = Join-Path $dest $rel
      $pdir = Split-Path $tgt -Parent
      if ($pdir -and -not (Test-Path -LiteralPath $pdir)) { New-Item -ItemType Directory -Force $pdir | Out-Null }
      Copy-Item -LiteralPath $src -Destination $tgt -Force
      $entry.present = $true; $entry.deleted = $false; $entry.size = [long]$item.Length
      $entry.sha256 = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.ToLowerInvariant()
      $entry.mtime = $item.LastWriteTimeUtc.ToString('o')
    }
    $man.Add($entry)
  }
  $doc = [ordered]@{ repo = $name; at = $ts; tree = $top; head = "$($script:HeadSha)"; count = $man.Count; paths = @($man) }
  [IO.File]::WriteAllText((Join-Path $dest 'manifest.json'), ($doc | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
  $dest
}

# ---------------------------------------------------------------- per repo
function Invoke-Repo([string]$top) {
  $L = [Collections.Generic.List[string]]::new()
  $r = @{ code = 0; decision = 'clean'; reason = ''; lines = @(); acted = $false; paths = @() }
  $name = (Split-Path $top -Leaf).ToLowerInvariant()
  $L.Add("== $name  ($top)")

  if (-not (Test-Path -LiteralPath (Join-Path $top '.git'))) {
    $r.decision = 'skip'; $r.reason = 'not a git worktree'; $r.code = 3
    $L.Add("   skip: not a git worktree (no .git under $top)")
    $r.lines = $L.ToArray(); return $r
  }
  if (-not (Test-IsMainWorktree $top)) {
    $r.decision = 'skip'; $r.reason = 'linked worktree (a leased slot), not the shared clone'; $r.code = 3
    $L.Add('   skip: linked worktree (a leased slot), not the shared clone')
    $r.lines = $L.ToArray(); return $r
  }
  $mode = $globalMode
  if ($modeMap -is [System.Collections.IDictionary] -and $modeMap.ContainsKey($name)) { $mode = "$($modeMap[$name])" }
  if ($mode -ne 'refuse') {
    $r.decision = 'skip'; $r.reason = "sharedCloneMode for ${name} is '$mode', not 'refuse'"; $r.code = 3
    $L.Add("   skip: agentq-config sharedCloneMode for $name is '$mode', not 'refuse'")
    $r.lines = $L.ToArray(); return $r
  }
  $slots = Join-Path (Split-Path $top -Parent) ('.wt' + $sep + $name)
  if (-not (Test-Path -LiteralPath $slots)) {
    $r.decision = 'skip'; $r.reason = "no slots dir $slots"; $r.code = 3
    $L.Add("   skip: no slots dir $slots (repo is not slot-managed)")
    $r.lines = $L.ToArray(); return $r
  }
  $L.Add("   mode refuse   slots $slots")

  # ---- the dirty set
  $root = "$(& git -C $top rev-parse --show-toplevel 2>$null)".Trim()
  $script:HeadSha = "$(& git -C $top rev-parse --short HEAD 2>$null)".Trim()
  $dirty = @(Get-DirtyPaths $top)
  if (-not $dirty.Count) {
    $r.decision = 'clean'; $r.code = 0
    $L.Add('   clean: nothing uncommitted')
    if ($root) { $L.Add("   head $($script:HeadSha)") }
    $r.lines = $L.ToArray(); return $r
  }
  $rows = [Collections.Generic.List[object]]::new()
  foreach ($d in $dirty) {
    $src = Join-Path $top ("$($d.path)".Replace('/', $sep))
    $present = Test-Path -LiteralPath $src -PathType Leaf
    $size = $null; $age = $null; $mtime = $null
    if ($present) {
      $i = Get-Item -LiteralPath $src
      $size = [long]$i.Length; $mtime = $i.LastWriteTime
      $age = [int](([DateTime]::Now) - $mtime).TotalSeconds
    }
    $rows.Add([pscustomobject]@{ xy = "$($d.xy)"; path = "$($d.path)"; present = $present; size = $size; ageSec = $age; mtime = $mtime })
  }
  $r.paths = @($rows | ForEach-Object { $_.path })
  $L.Add("   dirty $($rows.Count) path(s):")
  foreach ($row in $rows) { $L.Add(('     {0,5}  {1,9}  {2}  {3}' -f (Format-Age $row.ageSec), $(if ($null -ne $row.size) { "$($row.size)B" } else { 'gone' }), $row.xy, $row.path)) }

  # ---- gate: git operation in flight
  $gd = "$(& git -C $top rev-parse --absolute-git-dir 2>$null)".Trim()
  $marker = $null
  if ($gd) { foreach ($m in 'rebase-merge', 'rebase-apply', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'index.lock') { if (Test-Path (Join-Path $gd $m)) { $marker = $m; break } } }
  if (-not $gd) {
    $r.decision = 'skip'; $r.reason = 'could not read the git dir'; $r.code = 3
    $L.Add('   skip: could not read the git dir (git returned nothing)')
    Write-Journal @{ event = 'skipped'; repo = $name; reason = $r.reason; tool = 'shared-clone-janitor' }
    $r.lines = $L.ToArray(); return $r
  }
  if ($marker) {
    $r.decision = 'skip'; $r.reason = "$marker present (operation in flight)"; $r.code = 3
    $L.Add("   skip: $marker present (a git operation is in flight)")
    Write-Journal @{ event = 'skipped'; repo = $name; reason = $r.reason; tool = 'shared-clone-janitor' }
    $r.lines = $L.ToArray(); return $r
  }

  # ---- gate: an agentq COMMIT ticket is HELD for this repo
  # Reads the queue's own `held` flag; a waiter is not a writer (it is blocked precisely because someone
  # else holds the resource). Only a HELD commit can be touching this shared index/worktree.
  # A land ticket is NOT a reason to skip, held or not: Invoke-LandPregate takes its own scratch slot and
  # every later step runs in `E:\gh\.wt\<repo>\land` (Initialize-Slot / gate / land-finalize / push), so it
  # never writes this clone. Treating queued lands as "active" starved the janitor permanently on
  # 2026-11-23: E:\gh\codai refused to fast-forward for 1h27m over a 2.1h-stale 35-path draft while 10
  # lands drained one at a time, so a `land:codai` ticket was present at every single tick.
  $q = Join-Path $CoordQ "commit_$name"
  if ((Test-Path -LiteralPath $q)) {
    $tk = @(Get-ChildItem -LiteralPath $q -Filter '*.json' -File -ErrorAction SilentlyContinue)
    $held = @($tk | Where-Object {
        try { $t = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json; [bool]$t.held } catch { $false }
      })
    if ($held.Count) {
      $r.decision = 'skip'; $r.reason = "agentq commit ticket HELD ($($held[0].Name))"; $r.code = 3
      $L.Add("   skip: agentq commit ticket HELD ($($held[0].Name))")
      Write-Journal @{ event = 'skipped'; repo = $name; reason = $r.reason; ticket = $held[0].Name; tool = 'shared-clone-janitor' }
      $r.lines = $L.ToArray(); return $r
    }
    if ($tk.Count) { $L.Add("   note: $($tk.Count) commit ticket(s) queued, none HELD - waiters are not writers, continuing") }
  }
  $lq = Join-Path $CoordQ "land_$name"
  if (Test-Path -LiteralPath $lq) {
    $lt = @(Get-ChildItem -LiteralPath $lq -Filter '*.json' -File -ErrorAction SilentlyContinue)
    if ($lt.Count) { $L.Add("   note: $($lt.Count) land ticket(s) present - land works in its own slot, not here, continuing") }
  }

  # ---- gate: too many dirty paths = a live agent, not debris
  if ($rows.Count -gt $MaxFiles) {
    $r.decision = 'skip'; $r.reason = "too-many: $($rows.Count) dirty path(s) > -MaxFiles $MaxFiles"; $r.code = 3
    $L.Add("   skip: too-many - $($rows.Count) dirty path(s) > -MaxFiles $MaxFiles (a large dirty set is a live agent, not debris)")
    Write-Journal @{ event = 'too-many'; repo = $name; dirty = $rows.Count; maxFiles = $MaxFiles; tool = 'shared-clone-janitor' }
    $r.lines = $L.ToArray(); return $r
  }

  # ---- gate: a live writer owns one of the paths
  $live = @($rows | Where-Object { $null -ne $_.ageSec -and $_.ageSec -lt $LiveWriterSec })
  if ($live.Count) {
    $names = @($live | ForEach-Object { "$($_.path) (age $(Format-Age $_.ageSec))" })
    $r.decision = 'skip'; $r.reason = "$($live.Count) path(s) written in the last ${LiveWriterSec}s (a live writer): $($names -join '; ')"; $r.code = 3
    $L.Add("   skip: a live writer - $($live.Count) path(s) written in the last ${LiveWriterSec}s:")
    foreach ($n in $names) { $L.Add("     $n") }
    Write-Journal @{ event = 'skipped'; repo = $name; reason = "live writer: $($live.Count) path(s) written in the last ${LiveWriterSec}s"; paths = @($live | ForEach-Object { $_.path }); tool = 'shared-clone-janitor' }
    $r.lines = $L.ToArray(); return $r
  }

  # ---- would act (or act)
  $ts = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
  $paths = @($rows | ForEach-Object { $_.path })
  $comma = @($paths | Where-Object { $_ -match ',' })
  if ($comma.Count) {
    $r.decision = 'skip'; $r.reason = "path contains a comma ($($comma[0])); agentq publish takes a comma-joined -Paths list"; $r.code = 3
    $L.Add("   skip: $($r.reason)")
    Write-Journal @{ event = 'skipped'; repo = $name; reason = $r.reason; tool = 'shared-clone-janitor' }
    $r.lines = $L.ToArray(); return $r
  }
  $msg = if ($Message) { $Message } else { "chore(shared-clone): salvage unowned edits in $name ($($paths.Count) path(s))" }
  $purp = if ($Purpose) { $Purpose } else { "shared-clone-janitor $name ${ts}: publish the debris nobody owned so git-autosync can fast-forward" }
  $stashMsg = "shared-clone-janitor $name ${ts}: published by $Session"
  $dest = Join-Path (Join-Path $BackupRoot $name) $ts
  $joined = ($paths -join ',')
  $qPaths = ($paths | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '

  $r.decision = 'act'; $r.code = 3
  $verb = if ($dry) { 'would run' } else { 'run' }
  $L.Add("   $(if ($dry) { 'WOULD ACT' } else { 'ACT' }): $($rows.Count) unowned path(s) -> publish then clean")
  $L.Add("   ${verb}:  backup  $($rows.Count) path(s) -> $dest  (+ manifest.json)")
  $L.Add("   ${verb}:  pwsh -NoProfile -ExecutionPolicy Bypass -File `"$AgentqPath`" publish -Paths `"$joined`" -Message `"$msg`" -Purpose `"$purp`" -Repo $top")
  $L.Add("   ${verb}:  git -C $top stash push -u -m `"$stashMsg`" -- $qPaths")
  $L.Add("   ${verb}:  git -C $top status --porcelain -- $qPaths   (must be empty)")
  if ($dry) {
    $L.Add('   dry run: nothing was touched (re-run with -Apply to act)')
    $r.lines = $L.ToArray(); return $r
  }

  try {
    # ---- 3. backup first, always
    $backupDir = New-Backup $top $name $ts $rows.ToArray()
    Write-Journal @{ event = 'backup'; repo = $name; paths = $paths; backup = $backupDir; head = $script:HeadSha; tool = 'shared-clone-janitor' }
    $L.Add("   backed up -> $backupDir")

    # ---- 4. publish through agentq's own path
    if (-not (Test-Path -LiteralPath $AgentqPath)) { throw "agentq not found at $AgentqPath" }
    # The repo is named explicitly (-Repo $top), so a stale AGENTQ_EXPECT_REPO left in the caller's
    # environment (deploy-clean, an agent shell) must not make agentq's own assert refuse this publish.
    $savedExpect = $env:AGENTQ_EXPECT_REPO
    try {
      if ($null -ne $savedExpect) { Remove-Item Env:\AGENTQ_EXPECT_REPO -ErrorAction SilentlyContinue }
      $pub = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $AgentqPath publish -Paths $joined -Message $msg -Purpose $purp -Repo $top 2>&1)
      $pubRc = $LASTEXITCODE
    } finally {
      if ($null -ne $savedExpect) { $env:AGENTQ_EXPECT_REPO = $savedExpect }
    }
    $pubText = (@($pub | ForEach-Object { "$_" }) -join "`n").Trim()
    if ($pubRc -eq 5) {
      Write-Journal @{ event = 'publish-refused'; repo = $name; paths = $paths; reason = $pubText; backup = $backupDir; tool = 'shared-clone-janitor' }
      $L.Add('   publish REFUSED by agentq (exit 5) - the tree was left exactly as it was:')
      foreach ($ln in @($pub | ForEach-Object { "$_" })) { if ($ln.Trim()) { $L.Add("     $ln") } }
      $r.decision = 'skip'; $r.reason = 'publish refused (exit 5)'; $r.code = 3
      $L.Add('   nothing was stashed')
      $r.lines = $L.ToArray(); return $r
    }
    if ($pubRc -ne 0) {
      Write-Journal @{ event = 'error'; repo = $name; stage = 'publish'; exit = $pubRc; reason = $pubText; backup = $backupDir; tool = 'shared-clone-janitor' }
      foreach ($ln in @($pub | ForEach-Object { "$_" })) { if ($ln.Trim()) { $L.Add("     $ln") } }
      $L.Add("   publish FAILED (exit $pubRc) - nothing was stashed; the backup of all $($rows.Count) path(s) holds the copies")
      $r.decision = 'error'; $r.reason = "publish failed (exit $pubRc)"; $r.code = 1
      $r.lines = $L.ToArray(); return $r
    }
    $topic = ''
    # agentq returns 0 with 'nothing to publish' when origin already has exactly this content (the edit
    # was landed by someone else): then there is no topic to hand over, and the clean step is still right.
    if ($pubText -match 'pushed origin/(\S+)\s*=\s*([0-9a-f]+)') { $topic = $Matches[1] }
    $where = if ($topic) { "origin/$topic" } else { 'origin (it already had exactly this content)' }
    Write-Journal @{ event = $(if ($topic) { 'published' } else { 'already-on-origin' }); repo = $name; paths = $paths; topic = $topic; backup = $backupDir; tool = 'shared-clone-janitor' }
    foreach ($ln in @($pub | ForEach-Object { "$_" })) { if ($ln.Trim()) { $L.Add("     $ln") } }

    # ---- 4b. the writer that appeared while publish ran keeps its newer edit
    $fresh = @()
    foreach ($row in $rows) {
      if (-not $row.present) { continue }
      $src = Join-Path $top ("$($row.path)".Replace('/', $sep))
      if (Test-Path -LiteralPath $src -PathType Leaf) {
        $age = [int](([DateTime]::Now) - (Get-Item -LiteralPath $src).LastWriteTime).TotalSeconds
        if ($age -lt $LiveWriterSec) { $fresh += "$($row.path) (age $(Format-Age $age))" }
      }
    }
    if ($fresh.Count) {
      Write-Journal @{ event = 'skipped'; repo = $name; reason = 'a writer appeared during the pass'; paths = $fresh; topic = $topic; tool = 'shared-clone-janitor' }
      $L.Add("   skip clean: $($fresh.Count) path(s) were written while publish ran - the newer edit is kept:")
      foreach ($f in $fresh) { $L.Add("     $f") }
      $L.Add("   the salvaged copy is on $where; the tree was NOT cleaned")
      $r.decision = 'skip'; $r.reason = 'a writer appeared during the pass'; $r.code = 3
      $r.lines = $L.ToArray(); return $r
    }

    # ---- 5. clean EXACTLY those paths
    $stashOut = @(& git -C $top stash push -u -m $stashMsg -- $paths 2>&1)
    $stashRc = $LASTEXITCODE
    if ($stashRc -ne 0) {
      Write-Journal @{ event = 'clean-failed'; repo = $name; paths = $paths; exit = $stashRc; reason = (@($stashOut | ForEach-Object { "$_" }) -join ' | '); topic = $topic; tool = 'shared-clone-janitor' }
      foreach ($ln in $stashOut) { if ("$ln".Trim()) { $L.Add("     $ln") } }
      $L.Add("   stash FAILED (exit $stashRc) - the tree keeps its files; the salvaged copy is on $where")
      $r.decision = 'error'; $r.reason = "stash failed (exit $stashRc)"; $r.code = 1
      $r.lines = $L.ToArray(); return $r
    }
    $left = @(& git -C $top status --porcelain -- $paths 2>$null)
    if ($left.Count) {
      Write-Journal @{ event = 'clean-failed'; repo = $name; paths = $paths; residual = @($left | ForEach-Object { "$_" }); topic = $topic; tool = 'shared-clone-janitor' }
      $L.Add("   stash left $($left.Count) path(s) dirty:")
      foreach ($ln in $left) { $L.Add("     $ln") }
      $L.Add("   the salvaged copy is on $where")
      $r.decision = 'error'; $r.reason = "stash left $($left.Count) path(s) dirty"; $r.code = 1
      $r.lines = $L.ToArray(); return $r
    }
    $stashRef = "$(& git -C $top stash list --format=%gd -1 2>$null)".Trim()
    Write-Journal @{ event = 'cleaned'; repo = $name; paths = $paths; stash = $stashRef; topic = $topic; backup = $backupDir; tool = 'shared-clone-janitor' }
    if ($topic) { $L.Add("   published origin/$topic  (land it later: agentq land -Branch $topic -Onto <main> -Purpose `"$purp`")") }
    else { $L.Add('   origin already had exactly this content - nothing needed publishing') }
    $L.Add("   cleaned $($paths.Count) path(s) into stash $stashRef; git status --porcelain -- <those paths> is empty")
    Write-Log $top "published $($paths.Count) path(s) as origin/$topic, stashed $stashRef"
    $r.acted = $true; $r.decision = 'act'; $r.code = 0
    $r.lines = $L.ToArray(); return $r
  } catch {
    try { Write-Journal @{ event = 'error'; repo = $name; reason = "$_"; tool = 'shared-clone-janitor' } } catch { }
    $L.Add("   ERROR: $_")
    $r.decision = 'error'; $r.reason = "$_"; $r.code = 1
    $r.lines = $L.ToArray(); return $r
  }
}

# ---------------------------------------------------------------- config + selection
$cfg = $null
if (Test-Path -LiteralPath $CfgPath) { try { $cfg = Get-Content -LiteralPath $CfgPath -Raw | ConvertFrom-Json -AsHashtable } catch { $cfg = $null } }
$globalMode = if ($cfg -and $cfg.ContainsKey('sharedCloneMode')) { "$($cfg['sharedCloneMode'])" } else { 'warn' }
$modeMap = if ($cfg -and $cfg.ContainsKey('sharedCloneModeRepos')) { $cfg['sharedCloneModeRepos'] } else { $null }
$autoCfg = if ($cfg -and $cfg.ContainsKey('autosync')) { $cfg['autosync'] } else { $null }
$cfgRepos = @()
if ($autoCfg -is [System.Collections.IDictionary] -and $autoCfg.ContainsKey('repos') -and $autoCfg['repos']) { $cfgRepos = @($autoCfg['repos']) }
# The repo list is fleet policy, not tool code: honour the same `autosync.repos` git-autosync.ps1 reads,
# and fall back to git-autosync's own default list when the config has none.
$DefaultRepos = @('E:\gh\codai', 'E:\gh\brivio', 'E:\gh\money', 'E:\gh\metu', 'E:\gh\mmo',
  'E:\gh\vitals', 'E:\gh\titi', 'E:\gh\HIDE', 'E:\gh\axiom', 'E:\gh\afti', 'E:\gh\dashy', 'E:\gh\caelia',
  'E:\gh\dragoscatalin', 'E:\gh\vmui', 'E:\gh\agentq', 'E:\gh\marcai', 'E:\gh\cursuri-studiai', 'E:\gh\notai',
  'E:\gh\selfie-screen', 'E:\gh\swami', 'E:\gh\watch-faces', 'E:\gh\scrin', 'E:\gh\notalone', 'E:\gh\unscroll-rules')
$candidates = if ($cfgRepos.Count) { $cfgRepos } else { $DefaultRepos }

$selected = [Collections.Generic.List[string]]::new()
$want = @($Repo | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
if ($want.Count) {
  foreach ($w in $want) {
    # A path selects that repo directly (it still passes every gate below); a bare name filters the list.
    if (Test-Path -LiteralPath $w -PathType Container) { $selected.Add((Resolve-Path -LiteralPath $w).Path) }
    else { foreach ($c in $candidates) { if ((Split-Path $c -Leaf) -ieq $w) { $selected.Add($c) } } }
  }
} else {
  foreach ($c in $candidates) { $selected.Add($c) }
}
$targets = @($selected | Where-Object { $_ } | Select-Object -Unique)

"shared-clone-janitor: $(if ($dry) { 'DRY RUN (nothing will be touched)' } else { 'APPLY' }) - $($targets.Count) repo(s) selected, config $CfgPath"
''
$rc = 0; $nClean = 0; $nSkip = 0; $nAct = 0; $nErr = 0
foreach ($t in $targets) {
  $res = Invoke-Repo $t
  $res.lines | ForEach-Object { $_ }
  ''
  switch ($res.decision) {
    'clean' { $nClean++ }
    'skip' { $nSkip++ }
    'act' { if ($res.acted) { $nAct++ } else { $nSkip++ } }
    'error' { $nErr++; Write-Log $t "error: $($res.reason)" }
  }
  if ($res.code -eq 1) { $rc = 1 }
  elseif ($res.code -eq 3 -and $rc -eq 0) { $rc = 3 }
}
$parts = @("$nClean clean", "$nAct acted", "$($nSkip) skipped$(if ($dry) { ' (or would act)' })")
if ($nErr) { $parts += "$nErr error" }
"shared-clone-janitor: $($targets.Count) repo(s) - $($parts -join ', ')"
exit $rc
