<#
  ADR 0001 migration of MAIN clones in E:\gh (worktrees/orphans are worktree.ps1 migrate's job).
  Per repo, never touching the working tree or the index:
    1. dirty state  -> temp-index commit -> refs/backup/main/<repo>/<ts> (origin, verified)
    2. stashes      -> refs/backup/stash/<repo>/<n>-<ts> (origin, verified); then dropped, newest
                       index first, only stashes older than -MinAgeHours (a fresh one may be in use)
    3. local branches whose tip is on NO remote ref -> refs/backup/branch/<repo>/<name> (verified),
                       then deleted unless checked out anywhere or touched < -MinAgeHours ago
       branches whose tip IS on a remote ref and are not checked out / recently used -> deleted
    4. repo without origin -> git bundle --all (+ the dirty-state ref) in <wtroot>\_bundles; nothing
                       else is changed there (retired/local repos: backup only).
  -WhatIf prints the plan. Writes a JSON report line per repo to -Report.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
  [string[]]$Repos,
  [double]$MinAgeHours = 12,
  [string]$Report = (Join-Path $env:USERPROFILE '.codai\repo-migrate-report.jsonl'),
  [switch]$NoBranchDelete,
  # Retired repos (CLAUDE.md "Retired Projects"): bundle only, nothing changed, like a no-origin repo.
  [string[]]$BundleOnly = @('evocrm')
)
$ErrorActionPreference = 'Stop'
# Long-lived branch names are never deleted, even when not checked out and fully integrated.
$Protected = '^(main|master|dev|develop|preview|staging|production|release|gh-pages)$'
$WtRoot = if ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT } else { 'E:\gh\.wt' }
$ts = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$bundles = Join-Path $WtRoot '_bundles'
New-Item -ItemType Directory -Force $bundles | Out-Null

function Push-Ref([string]$r, [string]$sha, [string]$ref) {
  & git -C $r update-ref $ref $sha
  & git -C $r push -q --no-verify origin "${sha}:$ref" 2>$null
  $remote = "$((& git -C $r ls-remote origin $ref 2>$null) | Select-Object -First 1)" -split '\s+' | Select-Object -First 1
  if ($remote -ne $sha) { throw "push $ref not verified on origin" }
}
function Snapshot-Dirty([string]$r) {
  $head = "$(& git -C $r rev-parse --verify -q HEAD 2>$null)".Trim()
  $gitDir = "$(& git -C $r rev-parse --path-format=absolute --git-dir)".Trim()
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("rm-idx-" + [guid]::NewGuid().ToString('N'))
  $idx = Join-Path $gitDir 'index'
  if (Test-Path -LiteralPath $idx) { Copy-Item -LiteralPath $idx $tmp }
  $prev = $env:GIT_INDEX_FILE
  try {
    $env:GIT_INDEX_FILE = $tmp
    & git -C $r add -A 2>$null | Out-Null
    $big = @(& git -C $r diff --cached --name-only --diff-filter=AM HEAD 2>$null | Where-Object { $_ } | Where-Object { $f = Join-Path $r $_; (Test-Path -LiteralPath $f -PathType Leaf) -and (Get-Item -LiteralPath $f).Length -gt 50MB })
    foreach ($b in $big) { & git -C $r rm -q --cached -- $b 2>$null | Out-Null }
    $tree = "$(& git -C $r write-tree)".Trim()
  } finally { if ($prev) { $env:GIT_INDEX_FILE = $prev } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }; Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  $mf = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($mf, "repo-migrate: dirty state of the main clone (ADR 0001)`n`nhead: $(if ($head) { $head } else { '(unborn)' })`nskipped-large: $($big -join ', ')`n")
  # unborn HEAD (repo with no commit yet): a parentless snapshot of the files
  $parent = if ($head) { @('-p', $head) } else { @() }
  $c = "$(& git -C $r -c user.name=agentq -c user.email=agentq@localhost commit-tree $tree @parent -F $mf)".Trim()
  Remove-Item $mf
  [pscustomobject]@{ commit = $c; skipped = $big }
}
function Idle-Hours([string]$r, [string]$ref) {
  $ct = "$(& git -C $r log -g -1 --format=%ct $ref 2>$null)".Trim()
  if (-not $ct) { $ct = "$(& git -C $r log -1 --format=%ct $ref 2>$null)".Trim() }
  if (-not $ct) { return 9999 }
  ((Get-Date) - [DateTimeOffset]::FromUnixTimeSeconds([long]$ct).LocalDateTime).TotalHours
}

# NOT `ForEach-Object FullName`: under -WhatIf that member call is a ShouldProcess op and yields nothing.
$targets = if ($Repos) { $Repos } else { @(Get-ChildItem 'E:\gh' -Directory -Force | Where-Object { $_.Name -ne '.wt' -and (Test-Path -LiteralPath (Join-Path $_.FullName '.git') -PathType Container) }).FullName }
foreach ($r in $targets) {
  $name = (Split-Path $r -Leaf).ToLowerInvariant() -replace '[^a-z0-9._-]', '_'
  $rep = [ordered]@{ repo = $name; ts = $ts; dirtyRef = ''; stashRefs = @(); branchBackups = @(); branchesDeleted = @(); bundle = ''; errors = @() }
  try {
    $hasOrigin = @(& git -C $r remote 2>$null) -contains 'origin'
    $dirtyN = @(& git --no-optional-locks -C $r status --porcelain --untracked-files=normal 2>$null).Count
    $stashes = @(& git -C $r stash list --format='%gd %H %ct' 2>$null | Where-Object { $_ })
    $checkedOut = @(& git -C $r worktree list --porcelain 2>$null | Where-Object { $_ -like 'branch *' } | ForEach-Object { $_.Substring(18) })
    $branches = @(& git -C $r for-each-ref --format='%(refname:short) %(objectname)' refs/heads 2>$null | Where-Object { $_ })
    if (-not $dirtyN -and -not $stashes.Count -and -not ($branches | Where-Object { ($_ -split ' ')[0] -notin $checkedOut })) { continue }
    if (-not $hasOrigin -or ($BundleOnly -contains $name)) {
      if ($PSCmdlet.ShouldProcess($r, "bundle --all + dirty snapshot ($dirtyN dirty, $($stashes.Count) stash)")) {
        if ($dirtyN) { $s = Snapshot-Dirty $r; if ($s) { $ref = "refs/backup/main/$name/$ts"; & git -C $r update-ref $ref $s.commit; $rep.dirtyRef = $ref } }
        $b = Join-Path $bundles "$name-$ts.bundle"
        # git writes progress/"is okay" to stderr; under ErrorActionPreference=Stop a 2>$null
        # redirect of a native command still throws -> judge by exit code only.
        $ErrorActionPreference = 'Continue'
        & git -C $r bundle create -q $b --all *> $null; $bc = $LASTEXITCODE
        if (-not $bc) { & git -C $r bundle verify -q $b *> $null; $vc = $LASTEXITCODE } else { $vc = 1 }
        $ErrorActionPreference = 'Stop'
        if ($bc -or -not (Test-Path -LiteralPath $b)) { throw "bundle create failed ($bc)" }
        if ($vc) { throw "bundle verify failed ($vc)" }
        $rep.bundle = $b
      }
      $rep.note = $(if ($hasOrigin) { 'retired: bundle only, nothing else changed' } else { 'no origin: backup only, nothing else changed' })
    } else {
      if ($dirtyN -and $PSCmdlet.ShouldProcess($r, "snapshot $dirtyN dirty path(s) -> refs/backup/main")) {
        $s = Snapshot-Dirty $r
        if ($s) { $ref = "refs/backup/main/$name/$ts"; Push-Ref $r $s.commit $ref; $rep.dirtyRef = $ref; $rep.skippedLarge = $s.skipped }
      }
      # stashes: back up all, then drop old ones from the highest index down (indices stay valid)
      $drop = @()
      foreach ($st in $stashes) {
        $gd, $sha, $ct = $st -split ' '
        $n = [regex]::Match($gd, '\{(\d+)\}').Groups[1].Value
        $age = ((Get-Date) - [DateTimeOffset]::FromUnixTimeSeconds([long]$ct).LocalDateTime).TotalHours
        if ($PSCmdlet.ShouldProcess("$r $gd", "back up stash -> refs/backup/stash")) {
          $ref = "refs/backup/stash/$name/$n-$ts"; Push-Ref $r $sha $ref; $rep.stashRefs += $ref
          if ($age -ge $MinAgeHours) { $drop += [pscustomobject]@{ n = [int]$n; sha = $sha } }
        }
      }
      foreach ($d in $drop | Sort-Object n -Descending) {
        # re-check the entry is still the one we backed up (another agent may have stashed meanwhile)
        $now = "$(& git -C $r rev-parse "stash@{$($d.n)}" 2>$null)".Trim()
        if ($now -eq $d.sha) { & git -C $r stash drop -q "stash@{$($d.n)}" 2>$null }
      }
      if (-not $NoBranchDelete) {
        foreach ($b in $branches) {
          $bn, $sha = $b -split ' '
          if ($checkedOut -contains $bn -or $bn -match $Protected) { continue }
          if ((Idle-Hours $r "refs/heads/$bn") -lt $MinAgeHours) { continue }
          $onRemote = [bool]@(& git -C $r for-each-ref --count=1 --contains $sha --format='%(refname)' refs/remotes 2>$null | Where-Object { $_ }).Count
          if (-not $PSCmdlet.ShouldProcess("$r $bn", $(if ($onRemote) { 'delete (integrated)' } else { 'back up -> refs/backup/branch, delete' }))) { continue }
          if (-not $onRemote) { $ref = "refs/backup/branch/$name/$($bn -replace '[^A-Za-z0-9._/-]', '_')"; Push-Ref $r $sha $ref; $rep.branchBackups += $ref }
          & git -C $r update-ref -d "refs/heads/$bn" $sha
          if (-not $LASTEXITCODE) { $rep.branchesDeleted += $bn }
        }
      }
    }
  } catch { $rep.errors += "$($_.Exception.Message)" }
  if (-not $WhatIfPreference) { ($rep | ConvertTo-Json -Compress -Depth 4) | Add-Content $Report }
  Write-Host ("{0,-22} dirty->{1} stashes={2} branchBackups={3} deleted={4} bundle={5} {6}" -f $name, $(if ($rep.dirtyRef) { 'ref' } else { '-' }), $rep.stashRefs.Count, $rep.branchBackups.Count, $rep.branchesDeleted.Count, $(if ($rep.bundle) { Split-Path $rep.bundle -Leaf } else { '-' }), ($rep.errors -join '; '))
}
