<#
.SYNOPSIS
  The ONE way agents create, list and remove git worktrees on this machine.

.DESCRIPTION
  Every worktree lives under  E:\gh\.wt\<repo>\<name>  (override: $env:CODAI_WT_ROOT).
  <repo> is derived from the COMMON git dir, so a worktree created from inside
  another worktree still lands under the real repo name (brivio, codai) instead
  of spawning "brivio-launch-p3-wt-deploy-wt"-style chains (root cause of 45
  sibling worktrees in E:\gh on 2026-09-27).

    worktree.ps1 new   -Name <n> [-Ref <sha|branch>] [-Branch <new-branch>] [-Purpose <text>] [-Install] [-NoEnvCopy]
    worktree.ps1 list  [-All]
    worktree.ps1 prune [-OlderThanHours 12] [-WhatIf] [-All]
    worktree.ps1 remove -Path <dir> [-Force]
    worktree.ps1 relocate [-All] [-OlderThanHours 3] [-WhatIf]

  relocate: worktrees that live OUTSIDE the managed root (legacy E:\gh\<repo>-x-wt) and are not
  removable (dirty / unpushed) are MOVED into <root>\<repo>\<name> once idle for -OlderThanHours
  and not referenced by any process. Before moving: diff -> <root>\_backup\<repo>-<name>-<ts>.patch,
  HEAD -> refs/backup/wt/<name>. `git worktree move` fails with "Permission denied" while any
  process (VS Code watcher, tsserver) has a handle inside; that worktree is simply retried next run.

  prune/remove delete ONLY worktrees that are provably disposable:
    - no tracked modifications and no untracked non-ignored files,
    - HEAD reachable from a remote ref (nothing unpushed would be lost),
    - no activity (git HEAD/index/logs mtime) within -OlderThanHours,
    - no deploy-clean slot lock currently held,
    - never the main working tree, never a locked worktree (`git worktree lock`).
  Deletion uses `cmd /c rmdir /s /q`, which removes junctions as LINKS. It never
  uses `git worktree remove --force`, which follows junctions and once emptied
  another clone's node_modules (memory: git-worktree-remove-follows-junctions).

  After removing a worktree, its local branch is deleted too when that branch is
  fully integrated (tip reachable from a remote ref); otherwise it is kept and
  reported. -KeepBranch disables this.

  Orphan dirs = directories under <root>\<repo>\ that are NOT registered worktrees
  (left behind by a crashed remove or a raw rm). `list` reports them; `prune`
  deletes one only when every non-node_modules file in it is byte-identical to a
  blob on the repo's upstream (or it has none), it is idle >= -OlderThanHours and
  no process references it. `.cargo-target-*` build caches count as orphans with
  no source files. Anything else is kept and listed with the reason.

  Run from inside the repo, or pass -Repo. -All = every repo under E:\gh that
  has worktrees (used by the scheduled task).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [Parameter(Position = 0, Mandatory = $true)][ValidateSet('new', 'list', 'prune', 'remove', 'relocate')][string]$Action,
  [string]$Repo,
  [string]$Name,
  [string]$Ref = 'HEAD',
  [string]$Branch,
  [string]$Purpose = '',
  [string]$Path,
  [double]$OlderThanHours = 12,
  [switch]$Install,
  [switch]$NoEnvCopy,
  [switch]$All,
  [switch]$Force,
  [switch]$KeepBranch
)
$ErrorActionPreference = 'Stop'
$WtRoot = if ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT } else { 'E:\gh\.wt' }
$script:ProcLines = $null
function Test-InUseByProcess([string]$p) {
  # Exclude this process: its own command line carries `-Path <wt>` and would always match.
  if ($null -eq $script:ProcLines) { $script:ProcLines = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessId -ne $PID } | ForEach-Object { "$($_.CommandLine)$($_.ExecutablePath)" } | Where-Object { $_ }) }
  $needles = @($p, $p.Replace('\', '/'))
  foreach ($l in $script:ProcLines) { foreach ($n in $needles) { if ($l.IndexOf($n, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true } } }
  return $false
}

function Get-MainRoot([string]$dir) {
  $common = git -C $dir rev-parse --path-format=absolute --git-common-dir 2>$null
  if ($LASTEXITCODE -ne 0 -or -not $common) { throw "worktree: $dir is not inside a git repository." }
  # <main>\.git  ->  <main>
  return (Split-Path -Parent ($common.Replace('/', '\'))).TrimEnd('\')
}

function Get-Worktrees([string]$main) {
  $list = @(); $cur = $null
  foreach ($l in (git -C $main worktree list --porcelain)) {
    if ($l -like 'worktree *') { $cur = [ordered]@{ Path = $l.Substring(9).Replace('/', '\'); Head = ''; Branch = ''; Locked = $false; Main = ($list.Count -eq 0) }; $list += [pscustomobject]$cur; $cur = $list[-1] }
    elseif ($l -like 'HEAD *') { $cur.Head = $l.Substring(5) }
    elseif ($l -like 'branch *') { $cur.Branch = $l.Substring(7).Replace('refs/heads/', '') }
    elseif ($l -like 'locked*') { $cur.Locked = $true }
  }
  return $list
}

function Get-Assessment($wt, [string]$main) {
  $r = [ordered]@{ Path = $wt.Path; Branch = $(if ($wt.Branch) { $wt.Branch } else { '(detached)' }); Head = $wt.Head.Substring(0, [Math]::Min(9, $wt.Head.Length)); IdleHours = $null; Removable = $false; Reason = '' }
  if ($wt.Main) { $r.Reason = 'main working tree'; return [pscustomobject]$r }
  if ($wt.Locked) { $r.Reason = 'locked (git worktree lock)'; return [pscustomobject]$r }
  if (-not (Test-Path -LiteralPath $wt.Path)) { $r.Removable = $true; $r.Reason = 'missing on disk (stale registration)'; return [pscustomobject]$r }
  $gitdir = (git -C $wt.Path rev-parse --path-format=absolute --git-dir 2>$null)
  if ($gitdir) {
    $gitdir = $gitdir.Replace('/', '\')
    # NOT the index (any `git status` rewrites it) and NOT file mtimes under logs/ (gc and
    # reflog-expire rewrite them). The last reflog ENTRY's own timestamp = last real use.
    $stamps = @()
    $ct = git -C $wt.Path log -g -1 --format=%ct 2>$null
    if ($ct) { $stamps += [DateTimeOffset]::FromUnixTimeSeconds([long]$ct).LocalDateTime }
    foreach ($f in 'HEAD', 'copilot-meta.json') { $p = Join-Path $gitdir $f; if (Test-Path -LiteralPath $p) { $stamps += (Get-Item -LiteralPath $p).LastWriteTime } }
    if (-not $stamps.Count) { $stamps = @((Get-Item -LiteralPath $gitdir).LastWriteTime) }
    $last = ($stamps | Sort-Object -Descending | Select-Object -First 1)
    $r.IdleHours = [Math]::Round(((Get-Date) - $last).TotalHours, 1)
  }
  $tracked = @(git --no-optional-locks -C $wt.Path status --porcelain --untracked-files=no 2>$null | Where-Object { $_ })
  if ($tracked.Count) { $r.Reason = "$($tracked.Count) tracked change(s)"; return [pscustomobject]$r }
  $untracked = @(git --no-optional-locks -C $wt.Path status --porcelain --untracked-files=normal 2>$null | Where-Object { $_ -like '??*' })
  if ($untracked.Count) { $r.Reason = "$($untracked.Count) untracked non-ignored path(s)"; return [pscustomobject]$r }
  $onRemote = @(git -C $main for-each-ref --count=1 --contains $wt.Head --format='%(refname)' refs/remotes 2>$null | Where-Object { $_ })
  if (-not $onRemote.Count) { $r.Reason = 'HEAD not on any remote ref (unpushed commits)'; return [pscustomobject]$r }
  $lockFile = "$($wt.Path).lock"
  if (Test-Path -LiteralPath $lockFile) {
    try { $s = [System.IO.File]::Open($lockFile, 'Open', 'ReadWrite', 'None'); $s.Dispose() }
    catch [System.IO.IOException] { $r.Reason = 'deploy slot lock held (deploy running)'; return [pscustomobject]$r }
  }
  if ($null -ne $r.IdleHours -and $r.IdleHours -lt $OlderThanHours) { $r.Reason = "active $($r.IdleHours)h ago (< $OlderThanHours h)"; return [pscustomobject]$r }
  if (Test-InUseByProcess $wt.Path) { $r.Reason = 'a running process references this path'; return [pscustomobject]$r }
  $r.Removable = $true; $r.Reason = 'clean, pushed, idle'
  return [pscustomobject]$r
}

function Remove-WorktreeSafe([string]$wtPath, [string]$main) {
  if (Test-Path -LiteralPath $wtPath) {
    # rmdir /s removes junctions/symlinks as links and does not recurse into their targets.
    cmd /c rmdir /s /q "`"$wtPath`"" 2>$null
    if (Test-Path -LiteralPath $wtPath) { cmd /c rmdir /s /q "`"$wtPath`"" 2>$null }
    if (Test-Path -LiteralPath $wtPath) { Write-Warning "could not fully delete $wtPath (file in use?)"; return $false }
  }
  $lockFile = "$wtPath.lock"
  if (Test-Path -LiteralPath $lockFile) { Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }
  git -C $main worktree prune 2>$null
  return $true
}

function Remove-BranchIfIntegrated([string]$branch, [string]$main) {
  if ($KeepBranch -or -not $branch -or $branch -eq '(detached)') { return }
  $tip = git -C $main rev-parse --verify -q "refs/heads/$branch" 2>$null
  if (-not $tip) { return }
  if (Get-Worktrees $main | Where-Object { $_.Branch -eq $branch }) { Write-Host "branch  $branch kept (checked out elsewhere)"; return }
  $onRemote = @(git -C $main for-each-ref --count=1 --contains $tip --format='%(refname)' refs/remotes 2>$null | Where-Object { $_ })
  if (-not $onRemote.Count) { Write-Host "branch  $branch kept (tip $($tip.Substring(0,9)) not on any remote ref)"; return }
  git -C $main update-ref -d "refs/heads/$branch" $tip 2>$null
  if ($LASTEXITCODE -eq 0) { Write-Host "branch  $branch deleted (integrated: $($onRemote[0]))" }
}

function Get-OrphanDirs([string]$main) {
  $repoDir = Join-Path $WtRoot (Split-Path -Leaf $main)
  if (-not (Test-Path -LiteralPath $repoDir)) { return @() }
  $registered = @(Get-Worktrees $main | ForEach-Object { $_.Path.TrimEnd('\').ToLowerInvariant() })
  $upstream = git -C $main rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null
  if (-not $upstream) { $upstream = 'HEAD' }
  $blobs = $null
  $out = @()
  foreach ($d in Get-ChildItem -LiteralPath $repoDir -Directory -Force -ErrorAction SilentlyContinue) {
    if ($d.Name -like '_*') { continue }
    if ($registered -contains $d.FullName.TrimEnd('\').ToLowerInvariant()) { continue }
    $lock = "$($d.FullName).lock"
    if (Test-Path -LiteralPath $lock) {
      $held = $false
      try { $fs = [IO.File]::Open($lock, 'Open', 'ReadWrite', 'None'); $fs.Dispose() } catch [IO.IOException] { $held = $true }
      if ($held) { $out += [pscustomobject]@{ Path = $d.FullName; IdleHours = $null; Removable = $false; Reason = 'orphan, deploy slot lock held' }; continue }
    }
    $idle = [Math]::Round(((Get-Date) - $d.LastWriteTime).TotalHours, 1)
    $isCache = $d.Name -like '.cargo-target-*'
    $unique = @(); $nFiles = 0
    if (-not $isCache) {
      if ($null -eq $blobs) { $blobs = @{}; git -C $main ls-tree -r $upstream --format='%(objectname) %(path)' 2>$null | ForEach-Object { $i = $_.IndexOf(' '); $blobs[$_.Substring($i + 1)] = $_.Substring(0, $i) } }
      $stack = New-Object System.Collections.Stack; $stack.Push($d.FullName)
      while ($stack.Count -and $unique.Count -lt 5) {
        $cur = $stack.Pop()
        foreach ($sub in [IO.Directory]::GetDirectories($cur)) {
          if ((Split-Path -Leaf $sub) -in 'node_modules', '.next', '.turbo', 'dist', 'target', '.copilot-tmp') { continue }
          if ((Get-Item -LiteralPath $sub -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
          $stack.Push($sub)
        }
        foreach ($f in [IO.Directory]::GetFiles($cur)) {
          $nFiles++
          $rel = $f.Substring($d.FullName.Length + 1).Replace('\', '/')
          $h = git -C $main hash-object --path=$rel -- $f 2>$null
          if (-not $blobs.ContainsKey($rel) -or $blobs[$rel] -ne $h) { $unique += $rel; if ($unique.Count -ge 5) { break } }
        }
      }
    }
    $note = if ($isCache) { 'build cache' } else { "$nFiles source file(s)" }
    $o = [ordered]@{ Path = $d.FullName; IdleHours = $idle; Removable = $false; Reason = '' }
    if ($unique.Count) { $o.Reason = "orphan, $($unique.Count)+ file(s) not on $upstream (e.g. $($unique[0]))" }
    elseif ($idle -lt $OlderThanHours) { $o.Reason = "orphan, active $idle h ago (< $OlderThanHours h)" }
    elseif (Test-InUseByProcess $d.FullName) { $o.Reason = 'orphan, a running process references this path' }
    else { $o.Removable = $true; $o.Reason = "orphan ($note, all on $upstream), idle" }
    $out += [pscustomobject]$o
  }
  return $out
}

function Get-TargetRepos {
  if ($All) {
    return Get-ChildItem 'E:\gh' -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container } |
      Where-Object { (Get-ChildItem -LiteralPath (Join-Path $_.FullName '.git\worktrees') -Directory -ErrorAction SilentlyContinue | Select-Object -First 1) } |
      ForEach-Object { $_.FullName }
  }
  $start = if ($Repo) { $Repo } else { (Get-Location).Path }
  return @(Get-MainRoot $start)
}

switch ($Action) {
  'new' {
    if (-not $Name -or $Name -notmatch '^[a-z0-9][a-z0-9._-]{0,40}$') { throw 'worktree new: -Name is required (lowercase, [a-z0-9._-], <= 41 chars).' }
    $main = Get-MainRoot $(if ($Repo) { $Repo } else { (Get-Location).Path })
    $repoName = Split-Path -Leaf $main
    $dest = Join-Path (Join-Path $WtRoot $repoName) $Name
    if (Test-Path -LiteralPath $dest) { throw "worktree new: $dest already exists. Pick another -Name or reuse it." }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    if ($Branch) { git -C $main worktree add -b $Branch $dest $Ref } else { git -C $main worktree add --detach $dest $Ref }
    if ($LASTEXITCODE -ne 0) { throw 'worktree new: git worktree add failed.' }
    $gitdir = (git -C $dest rev-parse --path-format=absolute --git-dir).Replace('/', '\')
    @{ created = (Get-Date).ToString('o'); purpose = $Purpose; ref = $Ref; creator = 'worktree.ps1' } | ConvertTo-Json | Set-Content (Join-Path $gitdir 'copilot-meta.json')
    if (-not $NoEnvCopy) {
      $n = 0
      $cands = @(Get-ChildItem -LiteralPath $main -File -Force -Filter '.env*' -ErrorAction SilentlyContinue)
      foreach ($d in 'apps', 'packages') { $b = Join-Path $main $d; if (Test-Path $b) { $cands += Get-ChildItem -LiteralPath $b -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Force -Filter '.env*' -ErrorAction SilentlyContinue } } }
      foreach ($f in $cands) { if ($f.Name -like '*.example') { continue }; $rel = $f.FullName.Substring($main.Length).TrimStart('\'); $t = Join-Path $dest $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $t) | Out-Null; Copy-Item -LiteralPath $f.FullName -Destination $t -Force; $n++ }
      Write-Host "worktree: copied $n env file(s)"
    }
    if ($Install -and (Test-Path (Join-Path $dest 'pnpm-lock.yaml'))) { Push-Location $dest; try { pnpm install --frozen-lockfile --prefer-offline } finally { Pop-Location } }
    Write-Host "worktree: created $dest @ $(git -C $dest rev-parse --short HEAD)"
    Write-Host "worktree: when done ->  pwsh -NoProfile -File `"$PSCommandPath`" remove -Path `"$dest`""
    $dest
  }
  'list' {
    foreach ($main in Get-TargetRepos) {
      Write-Host "== $main"
      Get-Worktrees $main | ForEach-Object { Get-Assessment $_ $main } | Format-Table Path, Branch, Head, IdleHours, Removable, Reason -AutoSize | Out-String -Width 220 | Write-Host
      $orph = @(Get-OrphanDirs $main)
      if ($orph.Count) { Write-Host '-- orphan dirs (not registered worktrees)'; $orph | Format-Table Path, IdleHours, Removable, Reason -AutoSize | Out-String -Width 220 | Write-Host }
    }
  }
  'prune' {
    $removed = 0; $kept = 0
    foreach ($main in Get-TargetRepos) {
      git -C $main worktree prune 2>$null
      foreach ($wt in Get-Worktrees $main) {
        $a = Get-Assessment $wt $main
        if ($wt.Main) { continue }
        if (-not $a.Removable) { $kept++; Write-Host ("keep    {0,-60} {1}" -f $a.Path, $a.Reason); continue }
        if ($PSCmdlet.ShouldProcess($a.Path, 'remove worktree')) {
          if (Remove-WorktreeSafe $a.Path $main) { $removed++; Write-Host ("removed {0,-60} {1}" -f $a.Path, $a.Reason); Remove-BranchIfIntegrated $wt.Branch $main } else { $kept++ }
        }
      }
      foreach ($o in Get-OrphanDirs $main) {
        if (-not $o.Removable) { $kept++; Write-Host ("keep    {0,-60} {1}" -f $o.Path, $o.Reason); continue }
        if ($PSCmdlet.ShouldProcess($o.Path, 'remove orphan dir')) {
          if (Remove-WorktreeSafe $o.Path $main) { $removed++; Write-Host ("removed {0,-60} {1}" -f $o.Path, $o.Reason) } else { $kept++ }
        }
      }
    }
    Write-Host "worktree prune: removed=$removed kept=$kept"
  }
  'relocate' {
    $moved = 0; $waiting = 0
    $rootNorm = [IO.Path]::GetFullPath($WtRoot).TrimEnd('\') + '\'
    $bkDir = Join-Path $WtRoot '_backup'
    foreach ($main in Get-TargetRepos) {
      $repoName = Split-Path -Leaf $main
      foreach ($wt in Get-Worktrees $main) {
        if ($wt.Main -or $wt.Locked -or -not (Test-Path -LiteralPath $wt.Path)) { continue }
        if (([IO.Path]::GetFullPath($wt.Path) + '\').StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $a = Get-Assessment $wt $main
        if ($a.Removable) { continue }   # prune handles clean+pushed+idle ones
        $blocking = $a.Reason -match '^(active|deploy slot lock|a running process)'
        if (-not $blocking -and (Test-InUseByProcess $wt.Path)) { $blocking = $true; $a.Reason = 'a running process references this path' }
        if ($blocking) { $waiting++; Write-Host ("wait    {0,-55} {1}" -f $wt.Path, $a.Reason); continue }
        $name = ((Split-Path -Leaf $wt.Path).TrimStart('.') -replace "^$([regex]::Escape($repoName))-", '' -replace '-wt$', '')
        if (-not $name) { $name = 'wt' }
        $dest = Join-Path (Join-Path $WtRoot $repoName) $name
        $n = 2; while (Test-Path -LiteralPath $dest) { $dest = Join-Path (Join-Path $WtRoot $repoName) "$name-$n"; $n++ }
        if (-not $PSCmdlet.ShouldProcess("$($wt.Path) -> $dest", 'relocate worktree')) { continue }
        New-Item -ItemType Directory -Force -Path $bkDir, (Split-Path -Parent $dest) | Out-Null
        $ts = Get-Date -Format 'yyyyMMdd-HHmm'
        git -C $wt.Path diff HEAD --binary 2>$null | Set-Content -LiteralPath (Join-Path $bkDir "$repoName-$name-$ts.patch")
        git -C $wt.Path ls-files --others --exclude-standard 2>$null | Set-Content -LiteralPath (Join-Path $bkDir "$repoName-$name-$ts.untracked.txt")
        git -C $main update-ref "refs/backup/wt/$name" $wt.Head 2>$null
        $out = git -C $main worktree move $wt.Path $dest 2>&1 | Where-Object { $_ -notmatch 'LF will be' }
        if (Test-Path -LiteralPath $wt.Path) { $waiting++; Write-Host ("wait    {0,-55} move failed (handle open?): {1}" -f $wt.Path, "$out") }
        else { $moved++; Remove-Item -LiteralPath "$($wt.Path).lock" -ErrorAction SilentlyContinue; Write-Host ("moved   {0,-55} -> {1} ({2})" -f $wt.Path, $dest, $a.Reason) }
      }
    }
    Write-Host "worktree relocate: moved=$moved waiting=$waiting"
  }
  'remove' {
    if (-not $Path) { throw 'worktree remove: -Path is required.' }
    $full = (Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue)?.Path ?? $Path
    $main = Get-MainRoot $(if ($Repo) { $Repo } elseif (Test-Path -LiteralPath $full) { $full } else { (Get-Location).Path })
    $wt = Get-Worktrees $main | Where-Object { $_.Path -ieq $full.TrimEnd('\') }
    if (-not $wt) { throw "worktree remove: $full is not a registered worktree of $main." }
    $a = Get-Assessment $wt $main
    $overridable = $a.Reason -like 'active*'
    if (-not $a.Removable -and -not ($Force -and $overridable)) { throw "worktree remove: refusing ($($a.Reason)). Commit+push or discard your own changes first; -Force only overrides the idle check." }
    if (Remove-WorktreeSafe $a.Path $main) { Write-Host "worktree: removed $($a.Path)"; Remove-BranchIfIntegrated $wt.Branch $main }
  }
}
