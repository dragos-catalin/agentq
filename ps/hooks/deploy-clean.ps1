<#
.SYNOPSIS
  Run a deploy/release command from the repo's leased `release` SLOT at an exact, pushed commit,
  as a supersede-aware RELEASE RUN (ADR 0001, E:\gh\agentq\docs\adr\0001-*.md).

.DESCRIPTION
  1. Coalesce: if a release of the same repo+target is already running, record our tip on it
     (preempt if still in a safe phase, else ONE pending run) and exit 0 - never a duplicate run.
  2. Queue deploy:<repo>:<target> (agentq run; frozen marks refuse with the reason).
  3. Lease the release slot (E:\gh\.wt\<repo>\release[-N]) - owned by THIS process, so a crash
     releases it - and reset it to the sha (env files copied, frozen install when the lockfile moved).
  4. agentq release-begin (follow = upstream branch) -> AGENTQ_RELEASE_FILE, DEPLOY_SHA/REF/WORKTREE.
     The command reports phases with `agentq release-phase -Phase <p> [-Unsafe]`; exit 4 there =
     SUPERSEDED, stop. Commands that never call it are one unsafe phase after `prepare`.
  5. release-end; with -Follow (default when the ref is a branch tip) loop: superseded -> rerun at
     the new tip; done + pending -> one more run at the newest pending tip; failure -> stop.

.EXAMPLE
  pwsh -NoProfile -File "$env:USERPROFILE\.copilot\hooks\deploy-clean.ps1" -Command 'node scripts/release.mjs run --yes'
.EXAMPLE
  pwsh -NoProfile -File "$env:USERPROFILE\.copilot\hooks\deploy-clean.ps1" -Ref 9eeea7ac -Target gateway -Command 'pwsh -NoProfile -File scripts/ops/deploy-service-direct.ps1 -Service gateway'
#>
param(
  [Parameter(Mandatory = $true)][string]$Command,
  [string]$Ref = 'HEAD',
  [string]$Root,
  [switch]$AllowUnpushed,
  [switch]$NoEnvCopy,
  [switch]$NoInstall,
  # deploy:<repo>:<Target>. Default: derived from the command (-Service X / deploy-<x>.ps1 /
  # deploy.mjs <x> / release.mjs -> 'release'), else 'any'.
  [string]$Target,
  [string]$Purpose,
  # Branch the run follows for supersede (default: the upstream branch of -Root). '' disables.
  [string]$Follow,
  [switch]$NoFollow,
  [int]$QueueTimeoutMin = 60,
  [int]$MaxRuns = 5,
  # internal: set when re-entered under agentq
  [switch]$Inner
)
$ErrorActionPreference = 'Stop'
$bin = Join-Path $env:USERPROFILE '.copilot\bin'
if ($env:AGENTQ_BIN) { $bin = $env:AGENTQ_BIN }
$agentq = Join-Path $bin 'agentq.ps1'

if (-not $Root) {
  $Root = (git rev-parse --show-toplevel 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $Root) { throw 'deploy-clean: not inside a git repository (pass -Root).' }
}
$Root = (Resolve-Path $Root).Path.TrimEnd('\', '/')
$common = (git -C $Root rev-parse --path-format=absolute --git-common-dir 2>$null)
$mainRoot = if ($common) { Split-Path -Parent ($common.Replace('/', '\')) } else { $Root }

if (-not $Target) {
  if ($Command -match '(?i)-{1,2}service[=\s]+[''"]?([A-Za-z0-9_-]+)') { $Target = $Matches[1] }
  elseif ($Command -match '(?i)deploy-([a-z0-9-]+)\.(ps1|mjs|sh)') { $Target = $Matches[1] }
  elseif ($Command -match '(?i)scripts[\\/]deploy\.mjs\s+([a-z0-9-]+)') { $Target = $Matches[1] }
  elseif ($Command -match '(?i)release\.mjs') { $Target = 'release' }
  else { $Target = 'any' }
}
$Target = $Target.ToLowerInvariant()
$upstream = (git -C $Root rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>$null)
if (-not $PSBoundParameters.ContainsKey('Follow')) {
  # Follow the upstream branch only when deploying its tip (HEAD / the branch); a pinned sha/tag
  # is an explicit choice and is never superseded.
  $Follow = if (-not $NoFollow -and $upstream -and $Ref -in 'HEAD', ($upstream -replace '^origin/', ''), $upstream) { $upstream -replace '^origin/', '' } else { '' }
}
if ($NoFollow) { $Follow = '' }

function Resolve-Sha([string]$r) {
  git -C $Root fetch -q origin 2>$null
  $s = (git -C $Root rev-parse --verify "$r^{commit}" 2>$null)
  if ($LASTEXITCODE -ne 0 -or -not $s) { throw "deploy-clean: cannot resolve ref '$r'." }
  $s.Trim()
}

# ---- outer: coalesce or queue -------------------------------------------------------------
if (-not $Inner) {
  $sha = Resolve-Sha $Ref
  if ($Follow) {
    # A run already in flight for this target absorbs us (preempt or pending) - no duplicate run.
    $j = & pwsh -NoProfile -File $agentq notify-landing -Repo $Root -Branch $Follow -Sha $sha -Target $Target -Json 2>$null | Select-Object -Last 1
    $acts = try { @(($j | ConvertFrom-Json).actions) } catch { @() }
    if ($acts) { Write-Host "deploy-clean: coalesced $($sha.Substring(0,12)) into the running $Target release ($($acts -join ', ')) - it will ship this tip next."; exit 0 }
  }
  $why = if ($Purpose) { $Purpose } else { "deploy $Target @ $($sha.Substring(0,12)): $Command" }
  $self = @('-NoProfile', '-File', $PSCommandPath, '-Inner', '-Command', $Command, '-Ref', $Ref, '-Root', $Root, '-Target', $Target, '-Follow', $Follow, '-MaxRuns', "$MaxRuns")
  foreach ($sw in 'AllowUnpushed', 'NoEnvCopy', 'NoInstall') { if ((Get-Variable $sw -ValueOnly)) { $self += "-$sw" } }
  if ($Purpose) { $self += @('-Purpose', $Purpose) }
  if ("$env:AGENTQ_HELD" -match "(^|,)deploy:") { & pwsh @self; exit $LASTEXITCODE }
  & pwsh -NoProfile -File $agentq run -Resource "deploy:$Target" -Purpose $why -TimeoutMin "$QueueTimeoutMin" -Repo $Root -- pwsh @self
  exit $LASTEXITCODE
}

# ---- inner: holds deploy:<repo>:<target> ------------------------------------------------
$lease = $null
$code = 1
try {
  $leaseJson = & pwsh -NoProfile -File $agentq lease -Repo $Root -Role release -OwnerPid $PID -Purpose "release $Target" -Ref $Ref -Json -TimeoutMin 30 | Select-Object -Last 1
  if ($LASTEXITCODE) { throw "deploy-clean: could not lease a release slot (exit $LASTEXITCODE)" }
  $lease = $leaseJson | ConvertFrom-Json
  $wt = $lease.path
  $nextRef = $Ref
  for ($run = 1; $run -le $MaxRuns; $run++) {
    $sha = Resolve-Sha $nextRef
    $short = $sha.Substring(0, 12)
    if (-not $AllowUnpushed -and $upstream) {
      git -C $Root merge-base --is-ancestor $sha $upstream 2>$null
      if ($LASTEXITCODE -ne 0) {
        $onAny = @(git -C $Root for-each-ref --count=1 --contains $sha --format='%(refname)' refs/remotes refs/tags 2>$null | Where-Object { $_ })
        if (-not $onAny) { throw "deploy-clean: $short is NOT on $upstream (or any remote ref/tag). Push first, or pass -AllowUnpushed knowingly." }
      }
    }
    git -C $wt checkout -q --detach $sha
    if ($LASTEXITCODE) { throw "deploy-clean: checkout $short in $wt failed" }
    git -C $wt reset -q --hard $sha
    $st = git -C $wt status --porcelain --untracked-files=no
    if ($st) { throw "deploy-clean: release slot is not clean after checkout:`n$st" }
    # dependencies (frozen; only when the lockfile changed)
    $lock = Join-Path $wt 'pnpm-lock.yaml'
    if (-not $NoInstall -and (Test-Path $lock)) {
      $stamp = Join-Path $wt 'node_modules\.deploy-clean-lock.sha'
      $h = (Get-FileHash $lock -Algorithm SHA256).Hash
      $prev = if (Test-Path $stamp) { (Get-Content $stamp -Raw).Trim() } else { '' }
      if ($prev -ne $h) {
        Write-Host 'deploy-clean: pnpm install --frozen-lockfile --ignore-scripts'
        Push-Location $wt
        try { pnpm install --frozen-lockfile --ignore-scripts; if ($LASTEXITCODE) { throw 'deploy-clean: pnpm install failed.' } } finally { Pop-Location }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stamp) | Out-Null
        Set-Content -Path $stamp -Value $h -NoNewline
      }
    }
    $rf = & pwsh -NoProfile -File $agentq release-begin -Repo $wt -Target $Target -Sha $sha -Ref $nextRef -Follow $Follow -OwnerPid $PID -Purpose $(if ($Purpose) { $Purpose } else { $Command }) | Select-Object -Last 1
    if ($LASTEXITCODE) { throw "deploy-clean: release-begin refused (exit $LASTEXITCODE)" }
    $env:AGENTQ_RELEASE_FILE = "$rf".Trim()
    & pwsh -NoProfile -File $agentq release-phase -Phase prepare | Out-Null
    if ($LASTEXITCODE -eq 4) { $code = 4 }
    else {
      Write-Host "deploy-clean: === run $run  $Target @ $short  in  $wt  (follow: $(if ($Follow) { $Follow } else { 'none' })) ==="
      Push-Location $wt
      try {
        $env:DEPLOY_SHA = $sha; $env:DEPLOY_REF = $nextRef; $env:DEPLOY_WORKTREE = $wt
        Invoke-Expression $Command
        $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
      } finally { Pop-Location; Remove-Item Env:DEPLOY_SHA, Env:DEPLOY_REF, Env:DEPLOY_WORKTREE -ErrorAction SilentlyContinue }
    }
    $endState = if ($code -eq 0) { 'done' } elseif ($code -eq 4) { 'superseded' } else { 'failed' }
    $end = (& pwsh -NoProfile -File $agentq release-end -State $endState | Select-Object -Last 1) | ConvertFrom-Json
    Remove-Item Env:AGENTQ_RELEASE_FILE -ErrorAction SilentlyContinue
    Write-Host "deploy-clean: === run $run $($end.state)  sha=$sha  exit=$code  next=$(if ($end.next) { $end.next } else { '-' }) ==="
    if ($end.state -eq 'superseded') { $code = 0 }
    if ($end.state -eq 'failed' -or -not $end.next -or -not $Follow) { break }
    $nextRef = $end.next
  }
} finally {
  Remove-Item Env:AGENTQ_RELEASE_FILE -ErrorAction SilentlyContinue
  if ($lease) { & pwsh -NoProfile -File $agentq unlease -Repo $lease.path -LeaseId $lease.leaseId -Reason 'release run finished' | Write-Host }
}
exit $code
