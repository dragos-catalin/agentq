<#
  git-wip-snapshot (rule G6): snapshot the uncommitted state of an ACTIVE shared clone (and its leased
  worktree slots) without touching branch, index or worktree. The commit is built in a temporary index
  (tracked changes + untracked-not-ignored + sops-encrypted secrets under .wip-secrets/), stored at
  refs/wip/<host>/<slot>/latest and pushed to:
    origin                                  when origin is PRIVATE (or not on GitHub = self-hosted)
    -BackupUrl (refs/wip/<repo>/<host>/...) when origin is public/internal
  A tree identical to the previous snapshot is not pushed again.

    git-wip-snapshot.ps1 -Repo E:\gh\codai [-IncludeSlots]
    git-wip-snapshot.ps1 -All          # every repo with slots under the worktree root (+ -PublicList repos)
  Restore (G7): git fetch origin 'refs/wip/*:refs/wip/*'; git checkout refs/wip/<host>/<slot>/latest -- .
#>
param(
  [string]$Repo, [switch]$IncludeSlots, [switch]$All,
  [string]$BackupUrl = $(if ($env:AGENTQ_WIP_BACKUP_URL) { $env:AGENTQ_WIP_BACKUP_URL } else { 'https://github.com/dragos-catalin/shared-clone-backups.git' }),
  [string]$HostName = $(if ($env:AGENTQ_WIP_HOST) { $env:AGENTQ_WIP_HOST } else { [Environment]::MachineName.ToLowerInvariant() }),
  [string]$WtRoot = $(if ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT } elseif ($IsWindows) { 'E:\gh\.wt' } else { '/work/.wt' }),
  [string]$ReposRoot = $(if ($IsWindows) { 'E:\gh' } else { '/work' }),
  # extra repos (public-origin clones) one path per line; `SKIP <path>: ... is PUBLIC` lines also accepted
  [string]$PublicList = (Join-Path $HOME '.codai/git/public-origin.txt'),
  [string]$AgeKeyFile = $(if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $HOME '.config/sops/age/keys.txt' }),
  [string]$Log = (Join-Path $HOME '.codai/logs/wip-snapshot.log')
)
$ErrorActionPreference = 'Stop'
if (-not $Repo -and -not $All) { throw 'git-wip-snapshot: -Repo <path> or -All' }

if ($All) {
  try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch {}
  New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null
  $t0 = Get-Date
  $repos = @(Get-ChildItem -LiteralPath $WtRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '_*' -and (Test-Path (Join-Path (Join-Path $ReposRoot $_.Name) '.git')) } | ForEach-Object { Join-Path $ReposRoot $_.Name })
  if (Test-Path -LiteralPath $PublicList) {
    $repos += @(Get-Content -LiteralPath $PublicList | ForEach-Object { if ($_ -match '^SKIP (.+?): .*is (PUBLIC|INTERNAL)') { $Matches[1] } elseif ($_ -and $_ -notmatch '^\s*#') { $_.Trim() } } | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
  }
  $repos = @($repos | Select-Object -Unique)
  foreach ($r in $repos) {
    $out = & pwsh -NoProfile -File $PSCommandPath -Repo $r -IncludeSlots -BackupUrl $BackupUrl -HostName $HostName -WtRoot $WtRoot -AgeKeyFile $AgeKeyFile 2>&1 | Out-String
    $pushed = ([regex]::Matches($out, '\bpushed\b')).Count; $failed = ([regex]::Matches($out, 'PUSH-FAILED')).Count
    Add-Content $Log ('{0:o} {1} pushed={2} failed={3}' -f (Get-Date), $r, $pushed, $failed)
  }
  Add-Content $Log ('{0:o} done repos={1} sec={2}' -f (Get-Date), $repos.Count, [int]((Get-Date) - $t0).TotalSeconds)
  "done repos=$($repos.Count)"
  return
}

$Repo = (Resolve-Path -LiteralPath $Repo).Path.TrimEnd('\', '/')
$name = Split-Path $Repo -Leaf
$o = git -C $Repo remote get-url origin 2>$null
$private = $true
if ($o -match 'github\.com[:/](.+?)(\.git)?$') { $private = ((gh repo view $Matches[1] --json visibility -q .visibility 2>$null) -eq 'PRIVATE') }
$age = $null
if (Test-Path -LiteralPath $AgeKeyFile) { $age = ((Get-Content -LiteralPath $AgeKeyFile | Select-String '^# public key: (.+)$' | Select-Object -First 1).Matches[0].Groups[1].Value); $env:SOPS_AGE_KEY_FILE = $AgeKeyFile }
$dirs = @($Repo)
$slotRoot = Join-Path $WtRoot $name
if ($IncludeSlots -and (Test-Path -LiteralPath $slotRoot)) { $dirs += @(Get-ChildItem -LiteralPath $slotRoot -Directory | Where-Object { Test-Path (Join-Path $_.FullName '.git') } | ForEach-Object FullName) }
$results = foreach ($d in $dirs) {
  $slot = if ($d -eq $Repo) { 'main' } else { Split-Path $d -Leaf }
  $dirty = @(git -C $d status --porcelain 2>$null).Count
  if (-not $dirty) { [pscustomobject]@{ slot = $slot; status = 'clean' }; continue }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wip-idx-' + [guid]::NewGuid().ToString('n'))
  $encDir = Join-Path ([IO.Path]::GetTempPath()) ('wip-enc-' + [guid]::NewGuid().ToString('n'))
  $sec = @()
  $env:GIT_INDEX_FILE = $tmp
  try {
    git -C $d read-tree HEAD
    git -C $d add -A -- . ':(exclude).copilot-tmp' 2>$null
    # secrets: encrypted into the snapshot tree only (never written into the worktree); skipped without a key
    $sec = @(& rg --files --hidden --no-ignore --no-messages -g '.env*' -g '*.pem' -g '*.key' -g 'local.properties' -g '.dev.vars' -g '!*.example' -g '!**/node_modules/**' -g '!**/.git/**' -g '!**/.copilot-tmp/**' $d)
    if ($sec -and -not $age) { $sec = @() }
    foreach ($f in $sec) {
      $rel = $f.Substring($d.Length + 1)
      $enc = Join-Path $encDir ($rel + '.enc'); New-Item -ItemType Directory -Force (Split-Path $enc) | Out-Null
      & sops --encrypt --age $age --input-type binary --output-type json --output $enc $f
      if ($LASTEXITCODE) { throw "sops failed on $rel" }
      $blob = (git -C $d hash-object -w -- $enc).Trim()
      git -C $d update-index --add --cacheinfo "100644,$blob,.wip-secrets/$($rel.Replace('\', '/')).enc"
    }
    $tree = (git -C $d write-tree).Trim()
  } finally { Remove-Item Env:GIT_INDEX_FILE; Remove-Item $tmp, $encDir -Recurse -Force -ErrorAction SilentlyContinue }
  $ref = "refs/wip/$HostName/$slot/latest"
  $prev = git -C $d rev-parse --verify --quiet $ref 2>$null
  if ($prev -and (git -C $d rev-parse "$prev^{tree}").Trim() -eq $tree) { [pscustomobject]@{ slot = $slot; status = 'unchanged'; dirty = $dirty }; continue }
  $parents = @('-p', 'HEAD'); if ($prev) { $parents += @('-p', $prev.Trim()) }
  $c = (git -C $d commit-tree $tree @parents -m "wip($HostName/$slot): $dirty changed paths on $(git -C $d branch --show-current) $(Get-Date -Format o)").Trim()
  git -C $d update-ref $ref $c
  if ($private) { $dest = 'origin'; $rref = $ref } else { $dest = $BackupUrl; $rref = "refs/wip/$name/$HostName/$slot/latest" }
  git -C $d push -q --force --no-verify $dest "${c}:$rref" 2>&1 | Out-Null
  [pscustomobject]@{ slot = $slot; status = $(if ($LASTEXITCODE -eq 0) { 'pushed' } else { 'PUSH-FAILED' }); dirty = $dirty; secrets = $sec.Count; dest = $(if ($private) { 'origin' } else { 'backup' }); ref = $rref }
}
$results | Format-Table -AutoSize | Out-String -Width 200
