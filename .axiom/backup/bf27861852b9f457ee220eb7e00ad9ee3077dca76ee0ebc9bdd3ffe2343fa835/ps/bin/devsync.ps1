<#
  devsync: Mutagen sync of ONE project working tree between this PC and the devbox (ADR 0007, DEVBOX D4/D6).
    - never syncs .git (each side has its own clone; git moves via push/fetch)
    - never syncs dependencies / build output / agent scratch logs
    - default two-way-resolved after aligning both clones to the same commit (the PC's uncommitted edits win
      at the first cycle); -Safe = two-way-safe (conflicts are reported, nothing is overwritten)
    - one place at a time: `start` refuses while the devbox copy is dirty on a different commit/branch, and
      takes the system agentq workspace lease `ws:<project>` on the devbox (released by `stop`)
  Usage:
    devsync.ps1 start  -Project codai          # E:\gh\codai  <->  ws-devbox-ts:/work/codai
    devsync.ps1 status [-Project codai]
    devsync.ps1 flush  -Project codai
    devsync.ps1 stop   -Project codai
    devsync.ps1 plan   -Project codai          # print the mutagen arguments, touch nothing (tests)
#>
param(
  [Parameter(Mandatory, Position = 0)][ValidateSet('start', 'stop', 'status', 'flush', 'plan')][string]$Action,
  [string]$Project,
  [string]$LocalRoot = $(if ($IsWindows) { 'E:\gh' } else { Join-Path $HOME 'gh' }),
  [string]$RemoteRoot = '/work',
  [string]$RemoteHost = $(if ($env:DEVBOX_HOST) { $env:DEVBOX_HOST } else { 'ws-devbox-ts' }),
  [string]$Mutagen = $(if ($env:MUTAGEN) { $env:MUTAGEN } elseif ($IsWindows) { Join-Path $HOME '.local\bin\mutagen\mutagen.exe' } else { 'mutagen' }),
  [switch]$Safe, [switch]$NoLease
)
$ErrorActionPreference = 'Stop'
$slug = if ($Project) { $Project.ToLowerInvariant() -replace '[^a-z0-9-]', '-' } else { $null }
$name = if ($slug) { "dev-$slug" } else { $null }
$Ignores = @(
  '.git', 'node_modules', '.pnpm-store', '.pnpm-cache', '.next', '.nuxt', '.turbo', 'dist', 'build', 'out', 'target', '.gradle',
  '.venv', 'venv', '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.vitest-cache', '.cache', 'coverage',
  'playwright-report', 'test-results', 'obj', '*.tsbuildinfo',
  '.copilot-tmp/jobs', '.copilot-tmp/build-logs', '.copilot-tmp/e2e-cloud', '.copilot-tmp/**/*.log'
)
function Get-SyncArgs([string]$local, [string]$remote) {
  # the remote tree is group-shared (2770, setgid): files 0660 / dirs 2770 keep it readable by the repo
  # group only; 0644/0755 would make every synced file world-readable on a multi-user box
  $a = @('sync', 'create', '--name', $name, '--label', 'app=devsync', '--label', "project=$slug",
    '--sync-mode', $(if ($Safe) { 'two-way-safe' } else { 'two-way-resolved' }), '--ignore-vcs', '--symlink-mode', 'portable', '--permissions-mode', 'portable',
    '--default-file-mode-beta', '0660', '--default-directory-mode-beta', '2770')
  foreach ($i in $Ignores) { $a += @('--ignore', $i) }
  $a + @($local, "${RemoteHost}:$remote")
}
function Ssh([string]$cmd) { $o = & ssh -o BatchMode=yes -o ConnectTimeout=20 $RemoteHost $cmd 2>&1; [pscustomobject]@{ rc = $LASTEXITCODE; out = @($o | ForEach-Object { "$_" }) } }
switch ($Action) {
  'status' { if ($name) { & $Mutagen sync list $name } else { & $Mutagen sync list --label-selector app=devsync }; break }
  'flush' { & $Mutagen sync flush $name; break }
  'plan' {
    if (-not $Project) { throw '-Project required' }
    (Get-SyncArgs (Join-Path $LocalRoot $Project) "$RemoteRoot/$Project") -join "`n"
    break
  }
  'stop' {
    & $Mutagen sync terminate $name
    if (-not $NoLease) { $r = Ssh "agentq workspace release -Name $slug"; $r.out | Select-Object -Last 2 }
    "stopped $name"; break
  }
  'start' {
    if (-not $Project) { throw '-Project required' }
    $local = Join-Path $LocalRoot $Project
    if (-not (Test-Path (Join-Path $local '.git'))) { throw "$local is not a git repo" }
    $remote = "$RemoteRoot/$Project"
    # D6: the workspace is active in ONE place; the system agentq on the devbox arbitrates
    if (-not $NoLease) {
      $r = Ssh "agentq workspace take -Name $slug -Purpose 'devsync from $([Environment]::MachineName)'"
      if ($r.rc -ne 0) { throw "devbox refused workspace ${slug}: $($r.out -join ' ')" }
    }
    # both sides on the same commit before syncing the working tree (else a sync mixes two histories)
    $lh = (git -C $local rev-parse HEAD).Trim(); $lb = (git -C $local branch --show-current).Trim()
    $r = Ssh "git -C $remote rev-parse HEAD 2>/dev/null; git -C $remote branch --show-current 2>/dev/null; git -C $remote status --porcelain 2>/dev/null | wc -l"
    $rinfo = @($r.out | Where-Object { $_ })
    if ($rinfo.Count -lt 3) { throw "remote $remote missing or unreadable for you (clone it first: devbox-bootstrap, or ask for access to the repo)" }
    $rh, $rb, $rdirty = $rinfo[0].Trim(), $rinfo[1].Trim(), [int]$rinfo[2].Trim()
    if ($rh -ne $lh -or $rb -ne $lb) {
      if ($rdirty -gt 0) { throw "devbox copy is on $rb@$($rh.Substring(0,8)) with $rdirty dirty files, PC on $lb@$($lh.Substring(0,8)): resolve on the devbox first (commit+push), then start" }
      $r = Ssh "git -C $remote fetch -q --all && git -C $remote checkout -q -B $lb $lh"
      if ($r.rc -ne 0) { throw "could not move devbox to $lb@$lh - push it from the PC first" }
      "devbox aligned to $lb@$($lh.Substring(0,8))"
    }
    $a = Get-SyncArgs $local $remote
    & $Mutagen @a
    & $Mutagen sync flush $name
    & $Mutagen sync list $name
  }
}
