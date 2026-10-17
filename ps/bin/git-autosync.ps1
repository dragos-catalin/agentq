<#
git-autosync — keep a SHARED clone's branch at its upstream without touching anyone's work.

WHY (codai 2026-09-28): agents push from worktrees (worktree.ps1, deploy slots, publish-wt) and
cherry-pick their own shared-clone commits there, so the shared clone's `main` silently fell
behind origin and showed "ahead N / behind M" where the N were duplicates already on origin.

What one pass does, per repo (only when it is provably safe):
  1. skip if a git operation is in flight (index.lock, MERGE/CHERRY_PICK/REVERT_HEAD, rebase, bisect),
     HEAD is detached, the branch has no upstream, or an agentq commit:<repo> ticket is held;
  2. fetch the upstream;
  3. refuse if the branch has a commit whose PATCH is not on upstream (`git cherry` '+') — that is
     real unpushed work; `agentq commit` pushes it, never this tool;
  4. dirty paths that the move would change: if the working file already equals the upstream blob
     (typical: pushed from a worktree, or CRLF-only churn) stage it; otherwise refuse (conflict);
     if it equals an INTERMEDIATE upstream version of that path (a blob some commit in HEAD..upstream
     wrote - pushed from a worktree, then changed again upstream) it is a stale copy holding no unique
     work: its blob is kept in the object store, logged, and the path is taken from upstream
     (brivio 2026-10-15: 12 such files stranded the clone for 2 days);
  5. two-tree `git read-tree -m -u HEAD <upstream>` — exactly what `git checkout` does: updates only
     files that changed upstream and are clean locally, KEEPS every other staged/unstaged change;
  6. `git update-ref` the branch to upstream (old value kept in refs/backup/autosync/<branch>).

  PARK (2026-10-17, codai/brivio/dragoscatalin/dashy/vmui stuck 1-26 days on old drafts of work that
  had landed in another form): a dirty path that still collides after step 4 is resolved, never
  discarded. First the WHOLE dirty state (tracked + untracked) is committed on a temp index and
  pushed to <remote> refs/heads/backup/shared-clone/<repo>-<ts> (+ a local ref); if that push fails
  nothing happens. Then per path:
    - local change already contained upstream (every added line is there, every removed line is
      gone) -> superseded, upstream taken;
    - clean 3-way merge (EOL-normalised) -> the merged result stays in the worktree, uncommitted,
      exactly like `git rebase --autostash`;
    - real conflict / binary / delete-vs-modify / untracked unique -> copied to
      ~/.codai/parked/<repo>/<ts>/ (+ MANIFEST.tsv), blob written to the object store, upstream taken,
      journaled with `agentq note`. Only when the file is idle >= -ParkIdleHours (default 6) or -ParkNow.

  git-autosync.ps1 [-Repo E:\gh\codai[,E:\gh\brivio]] [-WhatIf] [-ParkNow] [-ParkIdleHours 6]
                   [-Loop -IntervalSec 120] [-Install] [-Status] [-Report]

  BACKUP TARGET (2026-10-17 audit): 15 of 25 repos are PUBLIC, so a backup branch on origin publishes
  WIP drafts. Private repos -> origin (objects already there, tiny push). Public or unknown visibility ->
  the private repo -BackupUrl (refs/heads/<repo>/<ts>). A thin local bundle is always written too.
  REPLAY (2026-10-17 audit): pushing from the shared clone ran pre-push over OTHER agents' dirty files
  (knip failed on a file not in the commit; could also pass falsely) and retried a full pre-push every
  pass. Now: commits go to origin autosync/replay-<branch> (--no-verify, own namespace) and land via
  `agentq land` (clean slot, dedupe, hooks on the clean result). A failed land backs off -ReplayBackoffMin.
Log: ~/.codai/git-autosync.log (one line per action). Exit 0 = in sync or moved, 3 = skipped/refused.
#>
param(
  [string[]]$Repo = @('E:\gh\codai', 'E:\gh\brivio', 'E:\gh\money', 'E:\gh\metu', 'E:\gh\mmo',
    'E:\gh\vitals', 'E:\gh\titi', 'E:\gh\HIDE', 'E:\gh\axiom', 'E:\gh\afti', 'E:\gh\dashy', 'E:\gh\caelia',
    'E:\gh\dragoscatalin', 'E:\gh\vmui', 'E:\gh\agentq', 'E:\gh\marcai', 'E:\gh\cursuri-studiai', 'E:\gh\notai',
    'E:\gh\selfie-screen', 'E:\gh\swami', 'E:\gh\watch-faces', 'E:\gh\scrin', 'E:\gh\notalone', 'E:\gh\unscroll-rules'),
  # Repos whose unpushed commits autosync may replay+push (agentq defers pushes there). Elsewhere an
  # unpushed commit only refuses: gta-nexus had 67 local-only commits that must never auto-land.
  [string[]]$ReplayRepos = @('codai', 'brivio', 'money', 'metu', 'mmo'),
  # Repos whose agents commit locally and never push by policy (vitals ADR-0019): unpushed commits are expected.
  [string[]]$LocalCommitRepos = @('vitals'),
  [switch]$WhatIf, [switch]$Loop, [int]$IntervalSec = 120, [switch]$Install, [switch]$Status,
  [switch]$ParkNow, [double]$ParkIdleHours = 6, [switch]$Report,
  [string]$BackupUrl = 'https://github.com/dragos-catalin/shared-clone-backups.git',
  [int]$ReplayBackoffMin = 60, [int]$FetchThrottle = 8
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
$Log = if ($env:GIT_AUTOSYNC_LOG) { $env:GIT_AUTOSYNC_LOG } else { Join-Path $HOME '.codai\git-autosync.log' }
$ParkRoot = if ($env:GIT_AUTOSYNC_PARK) { $env:GIT_AUTOSYNC_PARK } else { Join-Path $HOME '.codai\parked' }
$StateFile = if ($env:GIT_AUTOSYNC_STATE) { $env:GIT_AUTOSYNC_STATE } else { Join-Path $HOME '.codai\git-autosync-state.json' }
if ($env:GIT_AUTOSYNC_BACKUP_URL) { $BackupUrl = $env:GIT_AUTOSYNC_BACKUP_URL }
$script:NoFetch = $false
$LastMsg = @{}
$CoordQ = Join-Path $HOME '.codai\coord\queues'
$Repo = @($Repo | ForEach-Object { $_ -split ',' } | Where-Object { $_ })
$ReplayRepos = @($ReplayRepos | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
$LocalCommitRepos = @($LocalCommitRepos | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })

function Write-Log([string]$repo, [string]$msg) {
  $line = '{0} {1} {2}' -f ([DateTime]::UtcNow.ToString('o')), (Split-Path $repo -Leaf), $msg
  [IO.File]::AppendAllText($Log, $line + "`n", [Text.UTF8Encoding]::new($false))
  $line
}

function G([string]$repo) { & git -C $repo --no-optional-locks @args }

function Get-State { if (Test-Path $StateFile) { try { return (Get-Content $StateFile -Raw | ConvertFrom-Json -AsHashtable) } catch { } }; @{} }
function Set-State($s) { [IO.File]::WriteAllText($StateFile, ($s | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false)) }

# 'private' | 'public' | 'unknown', cached 24 h. GIT_AUTOSYNC_VISIBILITY overrides (tests).
function Get-Visibility([string]$r, [string]$remote) {
  if ($env:GIT_AUTOSYNC_VISIBILITY) { return $env:GIT_AUTOSYNC_VISIBILITY }
  $url = "$(G $r remote get-url $remote 2>$null)".Trim()
  $st = Get-State; if (-not $st.ContainsKey('visibility')) { $st['visibility'] = @{} }
  $c = $st['visibility'][$url]
  if ($c -and ([DateTime]::UtcNow - [DateTime]$c.at).TotalHours -lt 24) { return $c.v }
  $slug = $url -replace '^https://github\.com/', '' -replace '^git@github\.com:', '' -replace '\.git$', ''
  $v = 'unknown'
  if ($slug -ne $url -and (Get-Command gh -ErrorAction SilentlyContinue)) {
    $o = "$(& gh repo view $slug --json visibility -q .visibility 2>$null)".Trim().ToLowerInvariant()
    if ($o -in 'private', 'internal') { $v = 'private' } elseif ($o -eq 'public') { $v = 'public' }
  }
  $st['visibility'][$url] = @{ v = $v; at = [DateTime]::UtcNow.ToString('o') }; Set-State $st
  $v
}

# Byte-exact blob -> file (PowerShell pipes re-encode text; cmd redirection does not).
function Save-Blob([string]$repo, [string]$id, [string]$file) {
  cmd /c "git -C `"$repo`" cat-file blob $id > `"$file`""
  return ($LASTEXITCODE -eq 0)
}
function Test-Binary([byte[]]$b) { $n = [Math]::Min($b.Length, 8000); for ($i = 0; $i -lt $n; $i++) { if ($b[$i] -eq 0) { return $true } }; $false }
function Get-Lines([byte[]]$b) { @(([Text.Encoding]::UTF8.GetString($b) -replace "`r`n", "`n") -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
function Get-Bag([string[]]$lines) { $m = @{}; foreach ($ln in $lines) { $m[$ln] = 1 + $(if ($m.ContainsKey($ln)) { $m[$ln] } else { 0 }) }; $m }
function Get-Count($bag, [string]$k) { if ($bag.ContainsKey($k)) { $bag[$k] } else { 0 } }

# Is the local change (vs base) already contained in target? Added lines present, removed lines gone.
function Test-Contained([byte[]]$localBytes, [byte[]]$baseBytes, [byte[]]$targetBytes) {
  $tBag = Get-Bag (Get-Lines $targetBytes); $lBag = Get-Bag (Get-Lines $localBytes)
  if ($null -eq $baseBytes) { foreach ($k in $lBag.Keys) { if ((Get-Count $tBag $k) -lt $lBag[$k]) { return $false } }; return $true }
  $bBag = Get-Bag (Get-Lines $baseBytes)
  foreach ($k in $lBag.Keys) { if ($lBag[$k] -gt (Get-Count $bBag $k) -and (Get-Count $tBag $k) -lt $lBag[$k]) { return $false } }
  foreach ($k in $bBag.Keys) { $lc = Get-Count $lBag $k; if ($lc -lt $bBag[$k] -and (Get-Count $tBag $k) -gt $lc) { return $false } }
  $true
}
# Classify one colliding path: superseded | merged (with bytes) | park. Never writes the worktree.
function Resolve-Path3([string]$r, [string]$p, [string]$target, [bool]$untracked) {
  $full = Join-Path $r $p
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('gas-m-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory $tmp | Out-Null
  try {
    $exists = Test-Path -LiteralPath $full -PathType Leaf
    $tId = ((G $r rev-parse --verify --quiet "$($target):$p" 2>$null) | Select-Object -First 1)
    $bId = if ($untracked) { $null } else { ((G $r rev-parse --verify --quiet "HEAD:$p" 2>$null) | Select-Object -First 1) }
    if (-not $exists) {
      # local delete vs upstream modify: restoring the file loses nothing (old version is in HEAD).
      return [pscustomobject]@{ kind = 'park'; why = 'deleted-locally'; bytes = $null }
    }
    $o = [IO.File]::ReadAllBytes($full)
    if (-not $tId) { return [pscustomobject]@{ kind = 'park'; why = 'upstream-deleted'; bytes = $null } }
    Save-Blob $r $tId "$tmp\t" | Out-Null; $t = [IO.File]::ReadAllBytes("$tmp\t")
    $b = $null; if ($bId) { Save-Blob $r $bId "$tmp\b" | Out-Null; $b = [IO.File]::ReadAllBytes("$tmp\b") }
    if ((Test-Binary $o) -or (Test-Binary $t)) { return [pscustomobject]@{ kind = 'park'; why = 'binary'; bytes = $null } }
    # A staged version that differs from both HEAD and the worktree is separate work: it must also be
    # contained upstream, otherwise park (its blob is already in the object store + the backup).
    if (-not $untracked) {
      $iId = ((G $r rev-parse --verify --quiet ":$p" 2>$null) | Select-Object -First 1)
      $wId = ((G $r hash-object -- $p) | Select-Object -First 1)
      if ($iId -and $iId -ne $bId -and $iId -ne $wId) {
        Save-Blob $r $iId "$tmp\i" | Out-Null; $iBytes = [IO.File]::ReadAllBytes("$tmp\i")
        if ((Test-Binary $iBytes) -or -not (Test-Contained $iBytes $b $t)) { return [pscustomobject]@{ kind = 'park'; why = 'staged-unique'; bytes = $null } }
      }
    }    if (Test-Contained $o $b $t) { return [pscustomobject]@{ kind = 'superseded'; why = 'contained-upstream'; bytes = $null } }
    if ($null -eq $b) { return [pscustomobject]@{ kind = 'park'; why = 'untracked-unique'; bytes = $null } }
    $crlf = [Text.Encoding]::UTF8.GetString($o).Contains("`r`n")
    $u8 = [Text.UTF8Encoding]::new($false)
    foreach ($pair in @(@('o', $o), @('b', $b), @('t', $t))) {
      [IO.File]::WriteAllText("$tmp\$($pair[0]).n", ([Text.Encoding]::UTF8.GetString($pair[1]) -replace "`r`n", "`n"), $u8)
    }
    cmd /c "git merge-file -q -p `"$tmp\o.n`" `"$tmp\b.n`" `"$tmp\t.n`" > `"$tmp\m`" 2>nul"
    if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ kind = 'park'; why = "conflict($LASTEXITCODE)"; bytes = $null } }
    $m = [IO.File]::ReadAllText("$tmp\m", $u8)
    if ($crlf) { $m = $m -replace "`n", "`r`n" }
    $hasBom = $o.Length -ge 3 -and $o[0] -eq 0xEF -and $o[1] -eq 0xBB -and $o[2] -eq 0xBF
    $enc = if ($hasBom) { [Text.UTF8Encoding]::new($true) } else { $u8 }
    $mb = $enc.GetPreamble() + $enc.GetBytes($m.TrimStart([char]0xFEFF))
    return [pscustomobject]@{ kind = 'merged'; why = 'clean-3way'; bytes = [byte[]]$mb }
  } finally { cmd /c rmdir /s /q "`"$tmp`"" 2>$null }
}

# Whole dirty state -> commit on a temp index -> pushed backup branch + local ref. $null on failure.
function Save-Snapshot([string]$r, [string]$name, [string]$remote) {
  $ts = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss')
  $idx = Join-Path ([IO.Path]::GetTempPath()) "gas-snap-$name-$ts.idx"
  $old = $env:GIT_INDEX_FILE; $env:GIT_INDEX_FILE = $idx
  try {
    G $r read-tree HEAD | Out-Null
    G $r add -A -- . 2>&1 | Out-Null
    $tree = ((G $r write-tree) | Select-Object -First 1).Trim()
  } finally { if ($old) { $env:GIT_INDEX_FILE = $old } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }; Remove-Item $idx -ErrorAction SilentlyContinue }
  $sha = ((G $r commit-tree $tree -p HEAD -m "backup: dirty state of the $name shared clone before git-autosync park ($ts); nothing discarded") | Select-Object -First 1).Trim()
  G $r update-ref "refs/backup/shared-clone/$name-$ts" $sha | Out-Null
  # Thin local bundle (HEAD is the prerequisite): survives even if every remote is unreachable.
  $bdir = Join-Path $ParkRoot "$name\bundles"; New-Item -ItemType Directory -Force $bdir | Out-Null
  G $r bundle create -q (Join-Path $bdir "$ts.bundle") "refs/backup/shared-clone/$name-$ts" "^HEAD" 2>&1 | Out-Null
  if ((Get-Visibility $r $remote) -eq 'private') { $dest = $remote; $ref = "backup/shared-clone/$name-$ts" }
  else { $dest = $BackupUrl; $ref = "$name/$ts" }
  G $r push -q --no-verify $dest "$($sha):refs/heads/$ref" 2>&1 | Out-Null
  $remoteSha = ((G $r ls-remote $dest "refs/heads/$ref") -split '\s+' | Select-Object -First 1)
  if ($remoteSha -ne $sha) { return $null }
  $where = if ($dest -eq $remote) { $remote } else { ($BackupUrl -replace '^https://github\.com/', '' -replace '\.git$', '') }
  [pscustomobject]@{ sha = $sha; ref = $ref; ts = $ts; where = $where }
}

# Land the replayed commits through agentq (clean land slot, dedupe, hooks on the clean result), DETACHED:
# a codai land runs the full pre-push (20-40 min) and must not freeze the other repos' sync.
# Returns the started job record; a later pass reads its rc file.
function Start-ReplayLand([string]$r, [string]$remote, [string]$upBranch, [string]$branch, [string]$base, [string]$name) {
  $topic = "autosync/replay-$branch"
  G $r push -q --no-verify --force $remote "$($base):refs/heads/$topic" 2>&1 | Out-Null
  if ($LASTEXITCODE) { return $null }
  $land = if ($env:GIT_AUTOSYNC_LAND) { $env:GIT_AUTOSYNC_LAND } else { Join-Path $HOME '.copilot\bin\agentq.ps1' }
  $dir = if ($env:GIT_AUTOSYNC_LAND_DIR) { $env:GIT_AUTOSYNC_LAND_DIR } else { Join-Path $HOME ".codai\autosync-land" }; New-Item -ItemType Directory -Force $dir | Out-Null
  $id = "$name-$([DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))"
  $logf = Join-Path $dir "$id.log"; $rcf = Join-Path $dir "$id.rc"; $wrap = Join-Path $dir "$id.ps1"
  $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
  $body = @(
    "Set-Location -LiteralPath $(& $q $r)",
    "& pwsh -NoProfile -File $(& $q $land) land -Branch $(& $q $topic) -Onto $(& $q $upBranch) -Purpose $(& $q "git-autosync replay of deferred commits on $branch") *> $(& $q $logf)",
    "[IO.File]::WriteAllText($(& $q $rcf), [string]`$LASTEXITCODE)"
  ) -join "`n"
  [IO.File]::WriteAllText($wrap, $body, [Text.UTF8Encoding]::new($false))
  $p = Start-Process pwsh -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $wrap -WindowStyle Hidden -PassThru
  @{ pid = $p.Id; started = [DateTime]::UtcNow.ToString('o'); rc = $rcf; log = $logf; topic = $topic; head = ''; target = '' }
}

function Sync-Repo([string]$r) {
  if (-not (Test-Path (Join-Path $r '.git'))) { return @{ code = 3; msg = 'not a repo' } }
  $gd = (G $r rev-parse --absolute-git-dir).Trim()
  foreach ($m in 'index.lock', 'MERGE_HEAD', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'BISECT_LOG', 'rebase-merge', 'rebase-apply') {
    if (Test-Path (Join-Path $gd $m)) { return @{ code = 3; msg = "skip: $m present (operation in flight)" } }
  }
  $branch = (G $r symbolic-ref --quiet --short HEAD 2>$null)
  if (-not $branch) { return @{ code = 3; msg = 'skip: detached HEAD' } }
  $up = (G $r rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
  if (-not $up) { return @{ code = 3; msg = "skip: $branch has no upstream" } }
  $name = (Split-Path (Split-Path (G $r rev-parse --path-format=absolute --git-common-dir) -Parent) -Leaf).ToLowerInvariant()
  $cq = Join-Path $CoordQ ("commit_$name")
  if ((Test-Path $cq) -and (Get-ChildItem $cq -Filter '*.json' -File -ErrorAction SilentlyContinue)) { return @{ code = 3; msg = 'skip: agentq commit in progress' } }

  $remote = ($up -split '/')[0]
  if (-not $script:NoFetch) { G $r fetch -q $remote 2>&1 | Out-Null }
  $head = (G $r rev-parse HEAD).Trim(); $target = (G $r rev-parse $up).Trim()
  if ($head -eq $target) { return @{ code = 0; msg = 'in sync' } }
  $unique = @(G $r cherry $up HEAD | Where-Object { $_ -like '+*' } | ForEach-Object { ($_ -split ' ')[1] })
  # A finished detached land is collected first: once it succeeded nothing is unique any more, so this
  # cannot live inside the `$unique.Count` branch (topic + state were left behind, 2026-10-17 test 3).
  $stL = Get-State
  if ($stL.ContainsKey('landing') -and $stL['landing'].ContainsKey($name)) {
    $jb = $stL['landing'][$name]
    $done = Test-Path $jb.rc
    if (-not $done -and -not (Get-Process -Id $jb.pid -ErrorAction SilentlyContinue)) { $done = $true }
    if ($done -and -not $unique.Count) {
      $stL['landing'].Remove($name); Set-State $stL
      G $r push -q --no-verify $remote ":refs/heads/$($jb.topic)" 2>&1 | Out-Null
    }
  }
  # Local-commit repos (vitals ADR-0019: agents commit, only the owner pushes) are never replayed.
  if ($unique.Count -and $LocalCommitRepos -contains $name.ToLowerInvariant()) { return @{ code = 3; msg = "hold: $($unique.Count) local commit(s) awaiting the owner's push ($name policy: agents never push); not moved" } }
  if ($unique.Count -and $ReplayRepos -notcontains $name -and $ReplayRepos -notcontains '*') {
    return @{ code = 3; msg = "refuse: $($unique.Count) unpushed commit(s) not on $up and $name is not a replay repo; its owner must push them (or back them up to a branch)" }
  }
  $published = ''
  if ($unique.Count) {
    # agentq defers a push when a dirty file overlaps incoming changes; nobody else would ever push
    # these. Replay them onto upstream in the object store only (merge-tree, no worktree/index use),
    # push the result, and fast-forward to it below. A real content conflict -> refuse.
    $base = $target
    $replayed = 0
    # An owner who replayed a conflicting commit onto upstream by hand (worktree cherry-pick with
    # resolved conflicts) publishes the SAME author/date/subject with a different patch; the
    # original then conflicts forever and strands the clone (2026-09-29, f36becc8 vs b34abc2e).
    $upKeys = @{}; G $r log -n 2000 --format='%an%x1f%aI%x1f%s' $up | ForEach-Object { $upKeys[$_] = 1 }
    # Agents also REPUBLISH a deferred commit themselves (agentq land / temp-index commit rebased on
    # upstream): same author + subject, new date, slightly different patch, original left in the clone
    # -> conflicts forever (codai 2026-10-17 13:42-19:33, 88f1f08e vs 2e42f797). Twin = same author email
    # + subject in merge-base..upstream AND every file it touches is either a blob upstream already wrote
    # or a file the twin itself rewrote. The original is backed up (and its unique files listed) first.
    $mbase = (G $r merge-base HEAD $up | Select-Object -First 1).Trim()
    $twinKeys = @{}
    foreach ($ln in @(G $r log --format='%H%x1f%ae%x1f%s' "$mbase..$up")) { $tp = $ln -split [char]0x1f, 3; if ($tp.Count -eq 3 -and -not $twinKeys.ContainsKey("$($tp[1])$([char]0x1f)$($tp[2])")) { $twinKeys["$($tp[1])$([char]0x1f)$($tp[2])"] = $tp[0] } }
    $upBlobs = @{}
    foreach ($ln in @(G $r log --format= --raw --no-abbrev --no-renames "$mbase..$up")) { if ($ln -and $ln[0] -eq ':') { $upBlobs[(($ln.Substring(0, $ln.IndexOf("`t"))) -split ' ')[3]] = 1 } }
    $twins = @()
    foreach ($c in $unique) {
      if ($upKeys.ContainsKey(((G $r log -1 --format='%an%x1f%aI%x1f%s' $c) -join ''))) { continue }
      $tw = $twinKeys[((G $r log -1 --format='%ae%x1f%s' $c) -join '')]
      if ($tw) {
        $twPaths = @{}; G $r -c core.quotepath=off diff-tree --no-commit-id '-r' --name-only --no-renames $tw | ForEach-Object { $twPaths[$_] = 1 }
        # Fail CLOSED: a git error yields no lines, which must never read as "nothing unique".
        $cLines = @(G $r -c core.quotepath=off diff-tree --no-commit-id '-r' --no-renames $c | Where-Object { $_ -and $_[0] -eq ':' })
        $safe = ($LASTEXITCODE -eq 0 -and $cLines.Count -gt 0 -and $twPaths.Count -gt 0); $own = @()
        foreach ($ln in $(if ($safe) { $cLines } else { @() })) {
          $tab = $ln.IndexOf("`t"); $blob = ($ln.Substring(0, $tab) -split ' ')[3]; $pp = $ln.Substring($tab + 1)
          if ($upBlobs.ContainsKey($blob)) { continue }
          if ($blob -match '^0+$' -and -not (G $r rev-parse --verify --quiet "$($up):$pp")) { continue }
          if ($twPaths.ContainsKey($pp)) { $own += $pp; continue }
          $safe = $false; break
        }
        if ($safe) { $twins += [pscustomobject]@{ c = $c; twin = $tw; own = $own }; continue }
      }
      $parent = (G $r rev-parse --verify --quiet "$c^").Trim()
      $mt = @(G $r merge-tree --write-tree --merge-base $parent $base $c 2>$null); $mtCode = $LASTEXITCODE
      $tree = if ($mt.Count) { $mt[0] } else { $null }
      if ($mtCode -ne 0 -or -not $tree) { return @{ code = 3; msg = "refuse: unpushed commit $($c.Substring(0,8)) conflicts with $up; its owner must rebase" } }
      # Already upstream with a different patch-id (e.g. re-committed with other line endings from a
      # worktree): the replay changes nothing. Pushing it created one EMPTY duplicate commit per
      # 2-min cycle forever (2026-09-29, 4822c74a -> 6+ copies on origin/main). Skip it.
      if ($tree.Trim() -eq (G $r rev-parse --verify --quiet "$base^{tree}").Trim()) { continue }
      $replayed++
      $meta = G $r log -1 --format='%an%x00%ae%x00%aI' $c
      $an, $ae, $ad = $meta -split "`0"
      $msgFile = [IO.Path]::GetTempFileName()
      [IO.File]::WriteAllText($msgFile, ((G $r log -1 --format=%B $c) -join "`n"), [Text.UTF8Encoding]::new($false))
      $env:GIT_AUTHOR_NAME = $an; $env:GIT_AUTHOR_EMAIL = $ae; $env:GIT_AUTHOR_DATE = $ad
      try { $base = (G $r commit-tree $tree.Trim() -p $base -F $msgFile).Trim() }
      finally { Remove-Item Env:GIT_AUTHOR_NAME, Env:GIT_AUTHOR_EMAIL, Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue; Remove-Item $msgFile }
    }
    if ($twins.Count) {
      $tdesc = ($twins | ForEach-Object { "$($_.c.Substring(0,8))=>$($_.twin.Substring(0,8))" + $(if ($_.own.Count) { " (own lines kept in backup: $($_.own -join ' '))" } else { '' }) }) -join ', '
      if ($WhatIf) { return @{ code = 0; msg = "would drop $($twins.Count) local commit(s) already republished upstream [$tdesc], then move" } }
      $prev = @(G $r for-each-ref --format='%(refname)' --points-at $head 'refs/backup/shared-clone/' | Where-Object { $_ -like "*/$name-twins-*" })
      $tts = if ($prev.Count) { ($prev[0] -split "$name-twins-")[1] } else { [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') }
      if ((Get-Visibility $r $remote) -eq 'private') { $tdest = $remote; $tref = "backup/shared-clone/$name-twins-$tts" } else { $tdest = $BackupUrl; $tref = "$name/twins-$tts" }
      G $r update-ref "refs/backup/shared-clone/$name-twins-$tts" $head | Out-Null
      G $r push -q --no-verify $tdest "$($head):refs/heads/$tref" 2>&1 | Out-Null
      if ((((G $r ls-remote $tdest "refs/heads/$tref") -split '\s+') | Select-Object -First 1) -ne $head) { return @{ code = 3; msg = "refuse: backup push of local commits republished upstream failed; nothing dropped [$tdesc]" } }
      $tdir = Join-Path $ParkRoot "$name\$tts-twins"; New-Item -ItemType Directory -Force $tdir | Out-Null
      $tman = @("commit`ttwin`tsubject`tfiles_only_in_original`tbackup_ref") + @($twins | ForEach-Object { "$($_.c)`t$($_.twin)`t$((G $r log -1 --format=%s $_.c) -join '')`t$($_.own -join ' ')`t$($tdest):$tref" })
      [IO.File]::WriteAllText((Join-Path $tdir 'MANIFEST.tsv'), ($tman -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
      $published += "dropped $($twins.Count) local commit(s) already republished upstream [$tdesc], originals backed up as $($tdest -replace '^https://github\.com/', ''):$tref; "
    }
    if ($replayed -eq 0) { $unique = @() }
  }
  if ($unique.Count) {
    if ($WhatIf) { return @{ code = 0; msg = "would replay+push $($unique.Count) unpushed commit(s) onto $up, then move" } }
    $upBranch = $up.Substring($remote.Length + 1)
    $key = "$name|$head|$target"
    $st = Get-State; foreach ($k in 'replayFail', 'landing') { if (-not $st.ContainsKey($k)) { $st[$k] = @{} } }
    $job = $st['landing'][$name]
    if ($job) {
      if (-not (Test-Path $job.rc)) {
        $alive = Get-Process -Id $job.pid -ErrorAction SilentlyContinue
        if ($alive) { return @{ code = 3; msg = "skip: replay land running since $($job.started) (pid $($job.pid), log $($job.log))" } }
        $rcv = 'died'
      } else { $rcv = "$(Get-Content $job.rc -Raw)".Trim() }
      $st['landing'].Remove($name)
      if ($rcv -eq '0') {
        G $r push -q --no-verify $remote ":refs/heads/$($job.topic)" 2>&1 | Out-Null
        Set-State $st
        G $r fetch -q $remote 2>&1 | Out-Null
        $target = (G $r rev-parse $up).Trim()
        $twinSet = @($twins | ForEach-Object { $_.c })
        if (@(G $r cherry $up HEAD | Where-Object { $_ -like '+*' } | Where-Object { $twinSet -notcontains ($_ -split ' ')[1] }).Count) { return @{ code = 3; msg = "refuse: agentq land reported success but some commits are still not on $up; nothing moved" } }
        $published = "landed $($unique.Count) deferred commit(s) via agentq land; "
      } else {
        $st['replayFail'][$job.key] = @{ at = [DateTime]::UtcNow.ToString('o'); why = "agentq land exit $rcv (log $($job.log); topic $($job.topic) kept on $remote)" }
        Set-State $st
        return @{ code = 3; msg = "refuse: replay of $($unique.Count) unpushed commit(s) did not land (agentq land exit $rcv, log $($job.log)); next try after $ReplayBackoffMin min or when HEAD/$up moves" }
      }
    } else {
      # Backoff: the same (HEAD, upstream) pair that failed to land is not retried for ReplayBackoffMin.
      $f = $st['replayFail'][$key]
      if ($f -and ([DateTime]::UtcNow - [DateTime]$f.at).TotalMinutes -lt $ReplayBackoffMin) {
        return @{ code = 3; msg = "refuse: replay of $($unique.Count) commit(s) failed to land at $($f.at) ($($f.why)); backing off until HEAD or $up changes or $ReplayBackoffMin min pass" }
      }
      $job = Start-ReplayLand $r $remote $upBranch $branch $base $name
      if (-not $job) { return @{ code = 3; msg = "refuse: could not push autosync/replay-$branch to $remote; will retry" } }
      $job.key = $key
      $st = Get-State; if (-not $st.ContainsKey('landing')) { $st['landing'] = @{} }
      $st['landing'][$name] = $job; Set-State $st
      return @{ code = 3; msg = "replay: started agentq land of $($unique.Count) deferred commit(s) (pid $($job.pid), log $($job.log)); the move happens on a later pass" }
    }
  }
  $behind = [int](G $r rev-list --count "HEAD..$target"); $ahead = [int](G $r rev-list --count "$target..HEAD")

  # Blobs written per path by commits in HEAD..target: ONE git log for the whole range (per-path
  # calls took minutes on brivio's 541 moving paths while holding the pass mutex, 2026-10-17).
  $script:WrittenMap = $null
  function Get-Written([string]$path) {
    if ($null -eq $script:WrittenMap) {
      $script:WrittenMap = @{}
      foreach ($ln in @(G $r -c core.quotepath=off log --format= --raw --no-abbrev --no-renames "HEAD..$target")) {
        if (-not $ln -or $ln[0] -ne ':') { continue }
        $tab = $ln.IndexOf("`t"); if ($tab -lt 0) { continue }
        $meta = $ln.Substring(0, $tab) -split ' '; $pp = $ln.Substring($tab + 1)
        if (-not $script:WrittenMap.ContainsKey($pp)) { $script:WrittenMap[$pp] = [Collections.Generic.List[string]]::new() }
        $script:WrittenMap[$pp].Add($meta[3])
      }
    }
    if ($script:WrittenMap.ContainsKey($path)) { $script:WrittenMap[$path] } else { @() }
  }  # Paths the move changes vs paths with local changes (staged or not).
  $moving = @(G $r -c core.quotepath=off diff --no-renames --name-only HEAD $target)
  $dirty = @(G $r status --porcelain --untracked-files=no | ForEach-Object { $_.Substring(3).Trim('"') })
  $overlap = @($dirty | Where-Object { $moving -contains $_ })
  $stage = @(); $conflict = @(); $superseded = @()
  foreach ($p in $overlap) {
    $full = Join-Path $r $p
    $w = if (Test-Path -LiteralPath $full) { (G $r hash-object -- $p).Trim() } else { 'deleted' }
    $t = (G $r rev-parse --verify --quiet "$($target):$p" 2>$null)
    if ($w -eq $t -or ($w -eq 'deleted' -and -not $t)) { $stage += $p; continue }
    if ($w -ne 'deleted' -and $t) {
      # Blobs written to this path by commits between HEAD and the target (raw diff, new-side id).
      $written = @(Get-Written $p)
      if ($written -contains $w) { $superseded += [pscustomobject]@{ p = $p; w = $w; t = $t.Trim() }; continue }
      # Whitespace/EOL-only local change vs HEAD in BOTH index and worktree (formatter leftover of an
      # aborted commit: pre-commit prettier reflowed a plan/*.md table and restaged it; or a CRLF flip).
      # No unique content -> take the target; old blobs stay recoverable (2026-10-17, codai stuck 1 day
      # behind 62 on plan/codai-scheduler-parity-CANONICAL.md).
      $wsOpt = if ($p -match '\.(md|mdx|csv|txt)$') { '-w' } else { '--ignore-cr-at-eol' }   # code: EOL-only
      G $r diff --cached --quiet $wsOpt --ignore-cr-at-eol HEAD -- $p 2>$null | Out-Null; $wsIdx = -not $LASTEXITCODE
      G $r diff --quiet $wsOpt --ignore-cr-at-eol HEAD -- $p 2>$null | Out-Null; $wsWt = -not $LASTEXITCODE
      if ($wsIdx -and $wsWt) { $superseded += [pscustomobject]@{ p = $p; w = $w; t = $t.Trim() }; continue }
    }
    $conflict += $p
  }
  # Untracked files where upstream ADDS the path: read-tree -u refuses to overwrite them ("Untracked
  # working tree file ... would be overwritten"). A copy equal to the target or to an intermediate
  # upstream version (pushed from a worktree) holds no unique work -> blob kept, file removed, the
  # read-tree writes upstream. Anything else is someone's real new file -> refuse.
  $untrackedHit = @()
  $headPaths = [Collections.Generic.HashSet[string]]::new([string[]]@(G $r -c core.quotepath=off diff --no-renames --name-only --diff-filter=A HEAD $target))
  foreach ($p in $headPaths) {
    if ($dirty -contains $p) { continue }
    $full = Join-Path $r $p
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $w = (G $r hash-object -- $p) | Select-Object -First 1
    if (-not $w) { continue }
    $w = $w.Trim(); $t = ((G $r rev-parse --verify --quiet "$($target):$p" 2>$null) | Select-Object -First 1)
    $written = if ($w -eq $t) { @($w) } else { @(Get-Written $p) }
    if ($written -contains $w) { $untrackedHit += [pscustomobject]@{ p = $p; w = $w } } else { $conflict += "$p (untracked)" }
  }
  $resolved = @(); $hold = @()
  foreach ($c in $conflict) {
    $isU = $c.EndsWith(' (untracked)'); $p = $c -replace ' \(untracked\)$', ''
    $res = Resolve-Path3 $r $p $target $isU
    if ($res.kind -eq 'park' -and -not $ParkNow) {
      $full = Join-Path $r $p
      if ((Test-Path -LiteralPath $full) -and ((Get-Date) - (Get-Item -LiteralPath $full).LastWriteTime).TotalHours -lt $ParkIdleHours) { $hold += "$c [$($res.why), edited <$($ParkIdleHours)h ago]"; continue }
    }
    $resolved += [pscustomobject]@{ p = $p; untracked = $isU; kind = $res.kind; why = $res.why; bytes = $res.bytes }
  }
  if ($hold.Count) { return @{ code = 3; msg = "refuse: $($hold.Count) local edit(s) collide with incoming and are still being edited: $($hold -join ', ')" } }
  $what = "$($published)behind $behind, ahead $ahead (all on $up), staging $($stage.Count) already-upstream file(s)"
  if ($superseded.Count) { $what += ", replacing $($superseded.Count) stale copy(ies) of older upstream versions: " + (($superseded | ForEach-Object { "$($_.p)@$($_.w.Substring(0,10))" }) -join ', ') }
  if ($untrackedHit.Count) { $what += ", removing $($untrackedHit.Count) untracked copy(ies) of upstream-added files" }
  if ($resolved.Count) {
    $by = $resolved | Group-Object kind | ForEach-Object { "$($_.Count) $($_.Name)" }
    $what += ", collisions resolved: $($by -join ', ') [" + (($resolved | ForEach-Object { "$($_.p)=$($_.kind)" }) -join ', ') + ']'
  }
  if ($WhatIf) { return @{ code = 0; msg = "would move $($head.Substring(0,8)) -> $($target.Substring(0,8)): $what" } }

  $snap = $null; $parkDir = $null
  if ($resolved.Count) {
    $snap = Save-Snapshot $r $name $remote
    if (-not $snap) { return @{ code = 3; msg = "refuse: backup push of the dirty state failed (origin if private, else $BackupUrl); nothing parked or moved" } }
    $what += ", full dirty state backed up as $($snap.where):$($snap.ref) ($($snap.sha.Substring(0,10)))"
    $parkList = @($resolved | Where-Object { $_.kind -eq 'park' })
    if ($parkList.Count) {
      $parkDir = Join-Path $ParkRoot "$name\$($snap.ts)"
      New-Item -ItemType Directory -Force $parkDir | Out-Null
      $man = @("path`tkind`twhy`tlocal_blob`tstaged_blob`thead_blob`ttarget_blob`tbackup_ref")
      foreach ($x in $parkList) {
        $full = Join-Path $r $x.p; $lb = ''
        if (Test-Path -LiteralPath $full -PathType Leaf) {
          $lb = ((G $r hash-object -w -- $x.p) | Select-Object -First 1).Trim()
          $dst = Join-Path $parkDir $x.p; New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
          Copy-Item -LiteralPath $full -Destination $dst -Force
        }
        $hb = ((G $r rev-parse --verify --quiet "HEAD:$($x.p)" 2>$null) | Select-Object -First 1); $tb = ((G $r rev-parse --verify --quiet "$($target):$($x.p)" 2>$null) | Select-Object -First 1)
        $ib = ((G $r rev-parse --verify --quiet ":$($x.p)" 2>$null) | Select-Object -First 1)
        $man += "$($x.p)`t$(if ($x.untracked) {'untracked'} else {'tracked'})`t$($x.why)`t$lb`t$ib`t$hb`t$tb`t$($snap.where):$($snap.ref)"
      }
      [IO.File]::WriteAllText((Join-Path $parkDir 'MANIFEST.tsv'), ($man -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
      $what += ", parked $($parkList.Count) in $parkDir"
    }
    # Every resolved path -> index + worktree = target (or HEAD when upstream deletes it, so the
    # two-tree read-tree below removes it); untracked copies are removed. Merged bytes come back after.
    foreach ($x in $resolved) {
      $full = Join-Path $r $x.p
      if ($x.untracked) { Remove-Item -LiteralPath $full -Force; continue }
      $src = if ((G $r rev-parse --verify --quiet "$($target):$($x.p)" 2>$null)) { $target } else { 'HEAD' }
      $ls = (G $r ls-tree $src -- $x.p) -split '\s+'
      G $r update-index --add --cacheinfo "$($ls[0]),$($ls[2]),$($x.p)"
      G $r checkout-index -f -- $x.p
      if ($LASTEXITCODE) { return @{ code = 3; msg = "refuse: could not reset $($x.p) for the move; dirty state is safe in $($snap.where):$($snap.ref)" } }
    }
  }

  # Already-upstream paths: stage the TARGET entry (mode + blob) exactly. `git add` keeps the old mode
  # when core.filemode=false (Windows), so a 100755 -> 100644 change upstream left an index entry equal
  # to neither tree and read-tree refused "would be overwritten" (agentq cloud/runner-agent.mjs 2026-10-17).
  foreach ($p in $stage) {
    $ls = "$(G $r ls-tree $target -- $p)"
    if ($ls) { $parts = $ls -split '\s+'; G $r update-index --add --cacheinfo "$($parts[0]),$($parts[2]),$p" }
    else { G $r rm -q --cached --ignore-unmatch -- $p 2>&1 | Out-Null }
  }
  foreach ($sv in $superseded) {
    # Old bytes stay recoverable (git cat-file blob <id>, id in the log line); then index + worktree =
    # target blob, so the two-tree read-tree below sees index == target and leaves the path alone.
    G $r hash-object -w -- $sv.p | Out-Null
    $mode = ((G $r ls-tree $target -- $sv.p) -split '\s+')[0]
    G $r update-index --cacheinfo "$mode,$($sv.t),$($sv.p)"
    G $r checkout-index -f -- $sv.p
    if ($LASTEXITCODE) { return @{ code = 3; msg = "refuse: could not refresh stale copy $($sv.p); nothing moved" } }
  }
  foreach ($u in $untrackedHit) { G $r hash-object -w -- $u.p | Out-Null; Remove-Item -LiteralPath (Join-Path $r $u.p) -Force }
  G $r update-ref "refs/backup/autosync/$branch" $head
  # Stale stat info ("Entry ... not uptodate. Cannot merge", dragoscatalin 2026-10-17) makes read-tree refuse.
  G $r update-index -q --refresh 2>&1 | Out-Null
  $rtOut = @(G $r read-tree -m -u HEAD $target 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE) {
    $why = (@($rtOut | Where-Object { $_ -match 'error|fatal' }) | Select-Object -First 2) -join ' | '
    $prep = if ($resolved.Count -or $superseded.Count -or $stage.Count -or $untrackedHit.Count) { "; branch NOT moved but $($resolved.Count + $superseded.Count + $stage.Count + $untrackedHit.Count) path(s) were already set to upstream (dirty state backed up" + $(if ($snap) { " as $($snap.where):$($snap.ref)" } else { " in the object store" }) + "); the next pass completes the move" } else { '' }
    return @{ code = 3; msg = "refuse: read-tree -m failed ($why)$prep" }
  }
  G $r update-ref -m "git-autosync: fast-forward to $up" "refs/heads/$branch" $target $head
  if ($LASTEXITCODE) { return @{ code = 3; msg = "refuse: $branch moved concurrently (update-ref lost the race); will retry" } }
  foreach ($x in @($resolved | Where-Object { $_.kind -eq 'merged' })) { [IO.File]::WriteAllBytes((Join-Path $r $x.p), $x.bytes) }
  if ($resolved.Count) {
    $aq = Join-Path $HOME '.copilot\bin\agentq.ps1'
    if ((Test-Path $aq) -and -not $env:GIT_AUTOSYNC_NO_NOTE) {
      $note = "git-autosync: $name moved to $up; dirty state backed up as $($snap.where):$($snap.ref)" + $(if ($parkDir) { "; $(@($resolved | Where-Object kind -eq 'park').Count) colliding file(s) parked in $parkDir (MANIFEST.tsv) - re-apply by hand if still wanted" } else { '' })
      Push-Location $r; try { & pwsh -NoProfile -File $aq note -Message $note *> $null } finally { Pop-Location }
    }
  }
  return @{ code = 0; msg = "moved $($head.Substring(0,8)) -> $($target.Substring(0,8)): $what" }
}

if ($Report) {
  # Daily drift report: every repo that is behind its upstream, with the last autosync reason.
  $rows = @()
  $tail = if (Test-Path $Log) { @(Get-Content $Log -Tail 4000) } else { @() }
  foreach ($r in $Repo) {
    if (-not (Test-Path (Join-Path $r '.git'))) { continue }
    $n = Split-Path $r -Leaf
    G $r fetch -q 2>&1 | Out-Null
    $u = (G $r rev-parse --abbrev-ref '@{u}' 2>$null); if (-not $u) { continue }
    $ab = ((G $r rev-list --left-right --count "HEAD...$u") -split '\s+')
    if ([int]$ab[1] -eq 0) { continue }
    $last = $tail | Where-Object { $_ -match "^\S+ $([regex]::Escape($n)) " } | Select-Object -Last 1
    $why = if ($last) { ($last -split ' ', 3)[2] } else { 'no autosync log line' }
    $rows += "$n behind $($ab[1]) ahead $($ab[0]): $($why.Substring(0, [Math]::Min(240, $why.Length)))"
  }
  $msg = if ($rows.Count) { "git-autosync drift report: $($rows.Count) repo(s) behind upstream - " + ($rows -join ' | ') } else { 'git-autosync drift report: every repo is at its upstream' }
  $msg
  $aq = Join-Path $HOME '.copilot\bin\agentq.ps1'
  if ($rows.Count -and (Test-Path $aq)) { & pwsh -NoProfile -File $aq note -Message $msg *> $null }
  exit $(if ($rows.Count) { 3 } else { 0 })
}
if ($Status) {
  $t = Get-ScheduledTask -TaskName 'git-autosync' -ErrorAction SilentlyContinue
  if ($t) { "task: $($t.State)" } else { 'task: not installed' }
  if (Test-Path $Log) { Get-Content $Log -Tail 10 }
  exit 0
}
if ($Install) {
  $vbs = 'E:\gh\vmui\scripts\hidden-run.vbs'
  if (-not (Test-Path $vbs)) { throw "missing $vbs (hidden launcher)" }
  $pwsh = (Get-Command pwsh).Source
  $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Loop"
  $trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName 'git-autosync' -Action $act -Trigger $trg -Settings $set -Description 'fast-forward shared clones to upstream when safe' -Force | Out-Null
  Start-ScheduledTask -TaskName 'git-autosync'
  'installed + started scheduled task git-autosync'
  exit 0
}

if ($Loop) {
  $script:mx = [Threading.Mutex]::new($false, 'Global\git-autosync-loop')
  if (-not $script:mx.WaitOne(0)) { 'git-autosync: loop already running'; exit 0 }
}
$rc = 0
do {
  if ($Loop -and $Repo.Count -gt 1) {
    # One parallel fetch round per pass (sequential fetches made a 24-repo pass take ~6 min).
    $Repo | ForEach-Object -ThrottleLimit $FetchThrottle -Parallel {
      if (Test-Path (Join-Path $_ '.git')) { & git -C $_ --no-optional-locks fetch -q --all 2>&1 | Out-Null }
    }
    $script:NoFetch = $true
    try {
      $st = Get-State; $chg = $false
      if ($st.ContainsKey('replayFail')) { foreach ($k in @($st['replayFail'].Keys)) { if (([DateTime]::UtcNow - [DateTime]$st['replayFail'][$k].at).TotalHours -gt 24) { $st['replayFail'].Remove($k); $chg = $true } } }
      if ($chg) { Set-State $st }
      $ld = if ($env:GIT_AUTOSYNC_LAND_DIR) { $env:GIT_AUTOSYNC_LAND_DIR } else { Join-Path $HOME '.codai\autosync-land' }
      Get-ChildItem $ld -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { }
  }
  foreach ($r in $Repo) {
    # One pass at a time machine-wide: the -Loop task and a manual run must never interleave.
    $pm = [Threading.Mutex]::new($false, $(if ($env:GIT_AUTOSYNC_MUTEX) { $env:GIT_AUTOSYNC_MUTEX } else { 'Global\git-autosync-pass' }))
    try {
      if (-not $pm.WaitOne(60000)) { $res = @{ code = 3; msg = 'skip: another git-autosync pass is running' } }
      else { try { $res = Sync-Repo $r } catch { $res = @{ code = 3; msg = "error: $_ (line $($_.InvocationInfo.ScriptLineNumber): $("$($_.InvocationInfo.Line)".Trim()))" } } finally { $pm.ReleaseMutex() } }
    } finally { $pm.Dispose() }
    # Log only actions and refusals, not the steady "in sync" state.
    # Log actions and refusals, not the steady "in sync" state; in -Loop a repeated message is logged once.
    $repeat = $Loop -and $LastMsg[$r] -eq $res.msg; $LastMsg[$r] = $res.msg
    if ($res.msg -ne 'in sync' -and -not $repeat -and -not ($Loop -and $res.msg -like 'skip:*')) { Write-Log $r $res.msg } elseif (-not $Loop) { "$((Split-Path $r -Leaf)) $($res.msg)" }
    if ($res.code) { $rc = $res.code }
  }
  if ($Loop) { $rc = 0; Start-Sleep -Seconds $IntervalSec }
} while ($Loop)
exit $rc
