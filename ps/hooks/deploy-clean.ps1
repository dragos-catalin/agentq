<#
.SYNOPSIS
  Run a deploy/release command from a CLEAN, detached git worktree at an exact commit.

.DESCRIPTION
  The shared clone is never clean (other agents' in-progress files are in it by
  design). Building a deploy image there means the image tag names a commit whose
  content it does not contain, and half-finished foreign code ships. This wrapper:

    1. resolves -Ref (default HEAD) to a full SHA in the current repo,
    2. refuses if that SHA is not reachable from the current branch's upstream
       unless -AllowUnpushed (a deploy of an unpushed commit is untraceable later),
     3. creates/reuses a detached worktree at E:\gh\.wt\<repo>\deploy-N (pool of 6, keyed by
       the COMMON git dir, so running it from inside another worktree does not spawn
       "<wt>-deploy-wt" chains — that is how 45 worktrees piled up by 2026-09-27),
    4. copies gitignored env files the build needs (.env, .env.local, *.env, at
       repo root and one level under apps/*, packages/*) unless -NoEnvCopy,
    5. runs `pnpm install --frozen-lockfile --ignore-scripts` if a lockfile exists
       and node_modules is missing or the lockfile changed,
    6. runs -Command INSIDE the worktree with DEPLOY_REF/DEPLOY_SHA exported,
    7. prints the SHA and the worktree path in the trailer so the deploy is traceable.

  The worktree is kept between runs (fast re-deploys); pass -Remove to delete it.
  It is a git worktree of the SAME repo, so `git checkout --detach` inside it is
  safe — nobody else works there.

.EXAMPLE
  pwsh -NoProfile -File "$env:USERPROFILE\.copilot\hooks\deploy-clean.ps1" -Command 'pwsh -NoProfile -File scripts/ops/deploy-service-direct.ps1 -Service gateway'
.EXAMPLE
  pwsh -NoProfile -File "$env:USERPROFILE\.copilot\hooks\deploy-clean.ps1" -Ref 9eeea7ac -Command 'gcloud builds submit --config deploy/cloud-run/cloudbuild-gateway.yaml --substitutions=_TAG=$env:DEPLOY_SHA .'
#>
param(
  [Parameter(Mandatory = $true)][string]$Command,
  [string]$Ref = 'HEAD',
  [string]$Root,
  [string]$WorktreePath,
  [switch]$AllowUnpushed,
  [switch]$NoEnvCopy,
  [switch]$NoInstall,
  [switch]$Remove,
  # agentq resource name for this deploy: deploy:<repo>:<Target>. Default = derived from
  # the command (-Service X / --service X / a deploy-<x>.ps1 script), else 'any'. Two
  # deploys of the SAME target queue FIFO; different targets run in parallel.
  [string]$Target,
  [string]$Purpose,
  [int]$QueueTimeoutMin = 60
)
$ErrorActionPreference = 'Stop'

if (-not $Root) {
  $Root = (git rev-parse --show-toplevel 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $Root) { throw 'deploy-clean: not inside a git repository (pass -Root).' }
}
$Root = (Resolve-Path $Root).Path.TrimEnd('\', '/')
# Pool is per REPO, not per worktree: resolve the main working tree from the common git dir.
$common = (git -C $Root rev-parse --path-format=absolute --git-common-dir 2>$null)
$mainRoot = if ($common) { Split-Path -Parent ($common.Replace('/', '\')) } else { $Root }
$repoName = Split-Path -Leaf $mainRoot
$wtRoot = if ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT } else { 'E:\gh\.wt' }
$poolDir = Join-Path $wtRoot $repoName
New-Item -ItemType Directory -Force -Path $poolDir | Out-Null
if ($Remove) {
  if (-not $WorktreePath) { $WorktreePath = Join-Path $poolDir 'deploy-1' }
  if (Test-Path $WorktreePath) {
    cmd /c rmdir /s /q "`"$WorktreePath`""   # junction-safe; `worktree remove --force` follows junctions
    git -C $Root worktree prune
    Write-Host "deploy-clean: removed $WorktreePath"
  }
  exit 0
}

# 0a. agentq queue (2026-09-27): deploy:<repo>:<target>, FIFO, frozen/blocked marks refuse
#     with the reason, journaled. Re-enter this script under `agentq run`, unless we already
#     hold a deploy resource (AGENTQ_HELD) or agentq is missing (legacy behaviour only).
$agentq = Join-Path $env:USERPROFILE '.copilot\bin\agentq.ps1'
if ((Test-Path $agentq) -and ("$env:AGENTQ_HELD" -notmatch '(^|,)deploy:') -and -not $env:DEPLOY_CLEAN_NO_AGENTQ) {
  if (-not $Target) {
    if ($Command -match '(?i)-{1,2}service[=\s]+[''"]?([A-Za-z0-9_-]+)') { $Target = $Matches[1] }
    elseif ($Command -match '(?i)deploy-([a-z0-9-]+)\.(ps1|mjs|sh)') { $Target = $Matches[1] }
    elseif ($Command -match '(?i)scripts[\\/]deploy\.mjs\s+([a-z0-9-]+)') { $Target = $Matches[1] }
    else { $Target = 'any' }
  }
  $why = if ($Purpose) { $Purpose } else { "deploy $Target @ ${Ref}: $Command" }
  $self = @('-NoProfile', '-File', $PSCommandPath, '-Command', $Command, '-Ref', $Ref, '-Root', $Root, '-Target', $Target)
  foreach ($sw in 'AllowUnpushed', 'NoEnvCopy', 'NoInstall') { if ((Get-Variable $sw -ValueOnly)) { $self += "-$sw" } }
  if ($WorktreePath) { $self += @('-WorktreePath', $WorktreePath) }
  & pwsh -NoProfile -File $agentq run -Resource "deploy:$($Target.ToLowerInvariant())" -Purpose $why -TimeoutMin "$QueueTimeoutMin" -Repo $Root -- pwsh @self
  exit $LASTEXITCODE
}

# 0. exclusive worktree. Two concurrent deploys once shared <repo>-deploy-wt: the second
#    `checkout --detach` moved the tree under the first mid-build (2026-09-25, mgmt built
#    while a pay deploy re-pointed the tree to another SHA). Each run now holds an OS-level
#    exclusive lock on its worktree for its whole lifetime; a busy slot falls through to
#    <repo>-deploy-wt-2, -3, ... (a reusable pool, node_modules kept per slot). The lock is
#    released by the OS even if this process crashes.
$lockStream = $null
$candidatesWt = if ($WorktreePath) { @($WorktreePath) } else {
  1..6 | ForEach-Object { Join-Path $poolDir "deploy-$_" }
}
foreach ($cand in $candidatesWt) {
  try {
    $lockStream = [System.IO.File]::Open("$cand.lock", 'OpenOrCreate', 'ReadWrite', 'None')
    $WorktreePath = $cand
    break
  } catch [System.IO.IOException] { Write-Host "deploy-clean: $cand is in use by another deploy, trying the next slot" }
}
if (-not $lockStream) { throw 'deploy-clean: every deploy worktree slot is busy (6 concurrent deploys?). Retry later.' }

# 1. resolve the commit
$sha = (git -C $Root rev-parse --verify "$Ref^{commit}" 2>$null)
if ($LASTEXITCODE -ne 0 -or -not $sha) { throw "deploy-clean: cannot resolve ref '$Ref'." }
$short = $sha.Substring(0, 12)

# 2. traceability: the commit must exist on the remote unless explicitly allowed
if (-not $AllowUnpushed) {
  $upstream = (git -C $Root rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
  if ($LASTEXITCODE -eq 0 -and $upstream) {
    git -C $Root merge-base --is-ancestor $sha $upstream 2>$null
    if ($LASTEXITCODE -ne 0) {
      throw "deploy-clean: $short is NOT on $upstream. Push first (a deploy of an unpushed commit cannot be traced later), or pass -AllowUnpushed knowingly."
    }
  }
}

# 3. worktree at the exact commit
$existing = git -C $Root worktree list --porcelain | Select-String -Pattern "^worktree (.+)$" | ForEach-Object { $_.Matches[0].Groups[1].Value }
$wtNorm = $WorktreePath.Replace('\', '/')
if ($existing | Where-Object { $_.Replace('\', '/') -ieq $wtNorm }) {
  git -C $WorktreePath checkout --detach --quiet $sha
  if ($LASTEXITCODE -ne 0) { throw 'deploy-clean: checkout in worktree failed.' }
} else {
  git -C $Root worktree add --detach $WorktreePath $sha
  if ($LASTEXITCODE -ne 0) { throw 'deploy-clean: worktree add failed.' }
}
# Prove it is clean (tracked files). Untracked = env copies below, which is fine.
$st = git -C $WorktreePath status --porcelain --untracked-files=no
if ($st) { throw "deploy-clean: worktree is not clean after checkout:`n$st" }

# 4. env files (gitignored, never checked out)
if (-not $NoEnvCopy) {
  $copied = 0
  $candidates = @(Get-ChildItem -Path $Root -File -Force -Filter '.env*' -ErrorAction SilentlyContinue)
  foreach ($dir in 'apps', 'packages') {
    $base = Join-Path $Root $dir
    if (Test-Path $base) {
      $candidates += Get-ChildItem -Path $base -Directory | ForEach-Object { Get-ChildItem -Path $_.FullName -File -Force -Filter '.env*' -ErrorAction SilentlyContinue }
    }
  }
  foreach ($f in $candidates) {
    if ($f.Name -like '*.example') { continue }
    $rel = $f.FullName.Substring($Root.Length).TrimStart('\', '/')
    $dest = Join-Path $WorktreePath $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Copy-Item -Path $f.FullName -Destination $dest -Force
    $copied++
  }
  Write-Host "deploy-clean: copied $copied env file(s)"
}

# 5. dependencies
$lock = Join-Path $WorktreePath 'pnpm-lock.yaml'
if (-not $NoInstall -and (Test-Path $lock)) {
  $stamp = Join-Path $WorktreePath 'node_modules\.deploy-clean-lock.sha'
  $lockHash = (Get-FileHash $lock -Algorithm SHA256).Hash
  $prev = if (Test-Path $stamp) { Get-Content $stamp -Raw } else { '' }
  if ($prev.Trim() -ne $lockHash) {
    Write-Host 'deploy-clean: pnpm install --frozen-lockfile --ignore-scripts'
    Push-Location $WorktreePath
    try {
      pnpm install --frozen-lockfile --ignore-scripts
      if ($LASTEXITCODE -ne 0) { throw 'deploy-clean: pnpm install failed.' }
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stamp) | Out-Null
      Set-Content -Path $stamp -Value $lockHash -NoNewline
    } finally { Pop-Location }
  } else { Write-Host 'deploy-clean: node_modules up to date for this lockfile' }
}

# 6. run
Write-Host "deploy-clean: === $repoName @ $short  in  $WorktreePath ==="
Push-Location $WorktreePath
try {
  $env:DEPLOY_SHA = $sha
  $env:DEPLOY_REF = $Ref
  $env:DEPLOY_WORKTREE = $WorktreePath
  Invoke-Expression $Command
  $code = $LASTEXITCODE
} finally {
  Pop-Location
  Remove-Item Env:DEPLOY_SHA, Env:DEPLOY_REF, Env:DEPLOY_WORKTREE -ErrorAction SilentlyContinue
  if ($lockStream) { $lockStream.Dispose() }
}
Write-Host "deploy-clean: === done  sha=$sha  exit=$code ==="
exit ($code ?? 0)
