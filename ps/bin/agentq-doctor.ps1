# agentq doctor (ADR 0009 stage 0, OQ-011): a READ-ONLY health report.
#   agentq doctor [-Json] [-All] [-Repo <path>] [-Src <checkout>\ps]
# Dot-sourced by agentq.ps1 inside its script scope: shares $Root, $QDir, $MDir, $LDir, $RDir, $Journal,
# $Json, $All, $RepoArg, $Src and the helpers of agentq.ps1 / agentq-v2.ps1. It only READS: no repair, no
# delete, no journal line. Nothing here may call a helper that writes (Get-Live, Get-Capacity,
# Read-Releases, Write-Journal, Remove-Ticket, Clear-StaleIndexLock, Expire-Lease).
# Only functions and $script:Doctor* variables live at the top level of this file: any other assignment
# would land in agentq.ps1's script scope (and PowerShell names are case-insensitive: $repo IS $Repo).
#
# Rows: check, status (ok|warn|fail), kind (finding|info|summary), subject, detail, hint.
# Exit code ($script:DoctorExit): 1 when at least one `fail` row exists, else 0 (warnings alone = 0).
# Every check runs in its own try/catch: a check that throws becomes one `warn` row "check crashed".
#
# Scope: the slot checks (stale-index-lock, empty-package-store, dead-owner) look at the slots of the
# current repo (-Repo or cwd); with -All, or outside a repo, at every repo. The machine checks
# (install-drift, config-drift, dead-keeper, marks, state-size, scheduled-tasks) are always global.

$script:DoctorExit = 0
$script:DoctorRows = [System.Collections.Generic.List[object]]::new()
$script:DoctorGitCmds = $null
$script:DoctorLeases = $null
$script:DoctorInstall = $null
# thresholds
$script:DoctorLockAgeSec = 60       # an index.lock younger than this belongs to a git command still running
$script:DoctorStoreMaxRows = 20     # findings listed per slot before "+N more"
$script:DoctorDeadIdleMin = 30      # dead owner + idle this long = warning
$script:DoctorChatFreshMin = 30     # <lease>.chat touched within this = a chat keeps the lease alive
$script:DoctorJobDays = 3; $script:DoctorJobMax = 400
$script:DoctorMarkDays = 7
$script:DoctorHumanMaxRows = 25     # findings printed per check in the human report (-Json has all)
# core files compared between the source checkout and the installed copy (same relative path on both sides)
$script:DoctorCoreFiles = @(
  'bin\agentq.ps1', 'bin\agentq-v2.ps1', 'bin\agentq-prune.ps1', 'bin\agentq-doctor.ps1', 'bin\agentq-slo.mjs',
  'bin\agentq-store.mjs', 'bin\agentq-sync.ps1', 'bin\worktree.ps1', 'bin\job-start.ps1', 'bin\wait-job.ps1',
  'bin\jobs.ps1', 'hooks\run-build.ps1', 'hooks\deploy-clean.ps1', 'hooks\guard-tooluse.ps1', 'hooks\hook-pre.ps1'
)
$script:DoctorTasks = @('agentq-sync', 'copilot-worktree-prune', 'agentq-reap-terminals', 'git-autosync')

# ---- rows ---------------------------------------------------------------------------------
function Add-DoctorRow([string]$check, [string]$status, [string]$subject, [string]$detail, [string]$hint = '') {
  $rowKind = if ($status -eq 'ok') { 'info' } else { 'finding' }
  $script:DoctorRows.Add([pscustomobject][ordered]@{ check = $check; status = $status; kind = $rowKind; subject = $subject; detail = $detail; hint = $hint })
}
# One per check: what was looked at. Printed as the `ok` line when the check found nothing.
function Add-DoctorSummary([string]$check, [string]$detail) {
  $script:DoctorRows.Add([pscustomobject][ordered]@{ check = $check; status = 'ok'; kind = 'summary'; subject = ''; detail = $detail; hint = '' })
}
function Format-DoctorAge([double]$sec) {
  if ($sec -lt 120) { return "$([math]::Round($sec)) s" }
  if ($sec -lt 7200) { return "$([math]::Round($sec / 60)) min" }
  if ($sec -lt 172800) { return "$([math]::Round($sec / 3600, 1)) h" }
  "$([math]::Round($sec / 86400, 1)) d"
}
function Join-DoctorRel([string]$dir, [string]$rel) {
  $ds = [IO.Path]::DirectorySeparatorChar
  Join-Path $dir ($rel.Replace('\', "$ds").Replace('/', "$ds"))
}
function Get-DoctorSha256([string]$file) {
  $fs = [IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { $alg = [Security.Cryptography.SHA256]::Create(); try { [Convert]::ToHexString($alg.ComputeHash($fs)) } finally { $alg.Dispose() } }
  finally { $fs.Dispose() }
}
function Get-DoctorFileCount([string]$dir) {
  if (-not [IO.Directory]::Exists($dir)) { return 0 }
  $n = 0; foreach ($x in [IO.Directory]::EnumerateFiles($dir)) { $n++ }
  $n
}
# Same process as recorded? pidStart = StartTime UTC ticks (job registry); PIDs are recycled.
function Test-DoctorPid([int]$procId, $startTicks) {
  if ($procId -le 0) { return $false }
  $pr = $null
  try { $pr = Get-Process -Id $procId -ErrorAction Stop } catch { return $false }
  if ($startTicks) { try { return ([math]::Abs($pr.StartTime.ToUniversalTime().Ticks - [long]$startTicks) -lt 30000000) } catch { return $true } }
  $true
}
function Get-DoctorLeases {
  if ($null -eq $script:DoctorLeases) { $script:DoctorLeases = @(Read-Leases $null) }
  $script:DoctorLeases
}

# ---- scope: which slots ---------------------------------------------------------------------
# A slot = <wtroot>\<repo>\<dir> with a .git FILE (a worktree), whatever its name (legacy slots too).
function Get-DoctorScope {
  $wtRoot = Get-WtRoot
  $only = $null
  if (-not $All) {
    $info = $null
    try { $info = Get-RepoInfo $RepoArg } catch { $info = $null }
    if ($info) { $only = "$($info.Name)" }
  }
  $slots = [System.Collections.Generic.List[object]]::new()
  $repoDirs = @()
  if ($wtRoot -and [IO.Directory]::Exists($wtRoot)) {
    if ($only) { $one = Join-Path $wtRoot $only; if ([IO.Directory]::Exists($one)) { $repoDirs = @($one) } }
    else { $repoDirs = @([IO.Directory]::EnumerateDirectories($wtRoot)) }
  }
  foreach ($rd in $repoDirs) {
    $rn = [IO.Path]::GetFileName($rd)
    $subs = @(); try { $subs = @([IO.Directory]::EnumerateDirectories($rd)) } catch { $subs = @() }
    foreach ($sd in $subs) {
      if (-not [IO.File]::Exists((Join-Path $sd '.git'))) { continue }
      $slots.Add([pscustomobject]@{ repoName = $rn; path = $sd; label = "$rn/$([IO.Path]::GetFileName($sd))" })
    }
  }
  [pscustomobject]@{ wtRoot = "$wtRoot"; only = $only; slots = $slots; repoCount = $repoDirs.Count }
}

# ---- 1. stale-index-lock ----------------------------------------------------------------------
# Same gitdir parsing as Clear-StaleIndexLock (agentq-v2.ps1), which removes the lock; this only reports.
function Get-DoctorGitDir([string]$slotPath) {
  try {
    $gf = Join-Path $slotPath '.git'
    if (-not [IO.File]::Exists($gf)) { return $null }
    $gd = ([IO.File]::ReadAllText($gf) -replace '^gitdir:\s*', '').Trim()
    if (-not $gd) { return $null }
    if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $slotPath $gd }
    $gd
  } catch { $null }
}
# Command lines of every running git process, read once and only when a lock candidate exists
# (the CIM query costs ~0.5 s).
function Get-DoctorGitCmdLines {
  if ($null -ne $script:DoctorGitCmds) { return $script:DoctorGitCmds }
  # @(...) around the if: an empty array returned by a statement becomes $null
  $lines = @(if ($IsWindows) { Get-CimInstance Win32_Process -Filter "Name='git.exe'" -ErrorAction SilentlyContinue | ForEach-Object { "$($_.CommandLine)" } }
    else { Get-Process -Name git -ErrorAction SilentlyContinue | ForEach-Object { "$($_.CommandLine)" } })
  $script:DoctorGitCmds = @($lines | Where-Object { $_ } | ForEach-Object { if ($IsWindows) { $_.ToLowerInvariant().Replace('/', '\') } else { $_ } })
  $script:DoctorGitCmds
}
function Test-DoctorGitBusy([string]$slotPath, [string]$gitDir) {
  $cmds = @(Get-DoctorGitCmdLines)
  if (-not $cmds.Count) { return $false }
  foreach ($cand in @($slotPath, $gitDir)) {
    if (-not $cand) { continue }
    $needle = $cand.TrimEnd('\', '/')
    if ($IsWindows) { $needle = $needle.ToLowerInvariant().Replace('/', '\') }
    # ...\task-1 must not match a command that names ...\task-10
    $rx = [regex]::Escape($needle) + '(?![A-Za-z0-9_-])'
    foreach ($c in $cmds) { if ($c -cmatch $rx) { return $true } }
  }
  $false
}
function Test-DoctorIndexLocks($scope) {
  $found = 0
  foreach ($s in $scope.slots) {
    $gd = Get-DoctorGitDir $s.path
    if (-not $gd) { continue }
    $lock = Join-Path $gd 'index.lock'
    if (-not [IO.File]::Exists($lock)) { continue }
    $ageSec = ((Now) - [IO.File]::GetLastWriteTimeUtc($lock)).TotalSeconds
    if ($ageSec -lt $script:DoctorLockAgeSec) { continue }
    if (Test-DoctorGitBusy $s.path $gd) { continue }
    $found++
    Add-DoctorRow 'stale-index-lock' 'fail' $s.label "index.lock is $(Format-DoctorAge $ageSec) old and no git process uses the slot ($lock)" 'lease the slot again (agentq lease removes a stale lock), or delete the lock after checking that no git process uses the slot'
  }
  Add-DoctorSummary 'stale-index-lock' "$($scope.slots.Count) slot(s) checked"
}

# ---- 2. empty-package-store -------------------------------------------------------------------
# node_modules\.pnpm\<entry>\node_modules\<name> must hold a package.json. An interrupted install or
# a copied slot leaves the folder empty and every import of that package fails far from the cause.
# <entry> = <name>@<version>[_<peers>], scope and name joined with '+': the name ends at the first '@'
# after position 0 (a name never contains '@'; names like string_decoder do contain '_', and a peer
# suffix may contain '@', so neither the first '_' nor the last '@' is a safe cut).
#
#
# Speed: a real machine has ~75,000 entries in ~40 slots. A PowerShell statement per entry cost 10 s
# (5 s of it name parsing), and one runspace per slot was no faster. So there is NO PowerShell work per
# entry: one regex pass turns the whole directory listing of a slot into the package.json paths, and
# File.Exists runs over them as a method-group delegate in PLINQ. Measured: 3.0 s for the same result.
function Test-DoctorPackageStore($scope) {
  $maxRows = [int]$script:DoctorStoreMaxRows
  $ds = [IO.Path]::DirectorySeparatorChar
  $nul = [string][char]0
  $rxOpt = [Text.RegularExpressions.RegexOptions]'Multiline, CultureInvariant'
  # a line that is an entry of an npm package -> NUL + its package.json path; every other line (the
  # .pnpm\node_modules folder, dot folders, old git/tarball entries whose folder name is unknowable)
  # keeps no NUL and is dropped by the second pass
  $toPkg = [regex]::new('^(?<dir>[^\n]*[\\/](?:(?<scope>@[A-Za-z0-9~][A-Za-z0-9._~-]*)\+)?(?<pkg>[A-Za-z0-9~][A-Za-z0-9._~-]*)@[^\\/\n]*)$', $rxOpt)
  $drop = [regex]::new('^[^\x00\n][^\n]*\n?', $rxOpt)
  $repl = $nul + '${dir}' + $ds + 'node_modules' + $ds + '${scope}' + $ds + '${pkg}' + $ds + 'package.json'
  $exists = [Func[string, bool]][IO.File]::Exists
  $withStore = 0; $entries = 0; $bad = 0
  foreach ($s in $scope.slots) {
    $store = [IO.Path]::Combine($s.path, 'node_modules', '.pnpm')
    if (-not [IO.Directory]::Exists($store)) { continue }
    $withStore++
    $dirs = [IO.Directory]::GetDirectories($store)
    if (-not $dirs.Length) { continue }
    $text = $drop.Replace($toPkg.Replace(([string]::Join("`n", $dirs) + "`n"), $repl), '').Replace($nul, '')
    $paths = [string[]]$text.Split([char[]]"`n", [StringSplitOptions]::RemoveEmptyEntries)
    if (-not $paths.Length) { continue }
    $entries += $paths.Length
    $have = $null
    try {
      $pq = [Linq.ParallelEnumerable]::WithDegreeOfParallelism[string]([Linq.ParallelEnumerable]::AsParallel[string]($paths), 16)
      $have = [string[]][Linq.Enumerable]::ToArray[string]([Linq.ParallelEnumerable]::Where[string]($pq, $exists))
    } catch { $have = $null }
    # same answer, one path at a time, when the parallel query is not available
    if ($null -eq $have) { $have = [string[]]@(foreach ($pj in $paths) { if ([IO.File]::Exists($pj)) { $pj } }) }
    if ($have.Length -eq $paths.Length) { continue }
    $miss = [string[]][Linq.Enumerable]::ToArray[string]([Linq.Enumerable]::Except[string]($paths, $have))
    $bad += $miss.Length
    $shown = 0
    foreach ($pj in $miss) {
      if ($shown -ge $maxRows) { break }
      $shown++
      # an unscoped package leaves an empty ${scope}: collapse the doubled separator for the report
      $tail = $pj.Substring($store.Length).Replace("$ds$ds", "$ds")
      $pd = [IO.Path]::GetDirectoryName($store + $tail)
      $en = $tail.TrimStart($ds).Split($ds)[0]
      $why = if ([IO.Directory]::Exists($pd)) { 'package directory has no package.json' } else { 'package directory is missing' }
      Add-DoctorRow 'empty-package-store' 'fail' "$($s.label) $en" "${why}: $pd" 'remove that node_modules\.pnpm entry and run a frozen install through agentq (agentq run -Resource install), or copy the entry from a healthy slot'
    }
    if ($miss.Length -gt $maxRows) {
      Add-DoctorRow 'empty-package-store' 'fail' $s.label "+$($miss.Length - $maxRows) more broken entries in $store ($($miss.Length) in total)" 'this many broken entries: remove node_modules in the slot and run a frozen install through agentq (agentq run -Resource install)'
    }
  }
  Add-DoctorSummary 'empty-package-store' "$entries package entries in $withStore slot(s) with a pnpm store, $bad broken ($($scope.slots.Count) slot(s) looked at)"
}

# ---- 3. install-drift + config-drift ------------------------------------------------------------
# installed copy: $env:AGENTQ_INSTALL_DIR (tests) or ~/.copilot. Source: -Src, $env:AGENTQ_SRC, or the
# `src` the installer recorded in <installed>\bin\agentq-install.json:
#   { "src": "<ps dir>", "sha": "<commit>", "at": "<ISO>", "files": { "<installed relative path>": "<SHA256>" } }
function Get-DoctorInstallContext {
  if ($null -ne $script:DoctorInstall) { return $script:DoctorInstall }
  $inst = if ($env:AGENTQ_INSTALL_DIR) { $env:AGENTQ_INSTALL_DIR } elseif ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.copilot' } else { Join-Path $HOME '.copilot' }
  $mf = Join-DoctorRel $inst 'bin\agentq-install.json'
  $man = $null; $manBad = $false
  if ([IO.File]::Exists($mf)) {
    try { $man = [IO.File]::ReadAllText($mf) | ConvertFrom-Json -AsHashtable -DateKind String } catch { $man = $null }
    # not JSON, or JSON that is not an object: say so instead of treating the install as unrecorded
    if ($man -isnot [System.Collections.IDictionary]) { $man = $null; $manBad = $true }
  }
  $srcDir = $null; $srcFrom = ''
  if ($Src) { $srcDir = "$Src"; $srcFrom = '-Src' }
  elseif ($env:AGENTQ_SRC) { $srcDir = $env:AGENTQ_SRC; $srcFrom = 'AGENTQ_SRC' }
  elseif ($null -ne $man -and $man.ContainsKey('src') -and $man['src']) { $srcDir = "$($man['src'])"; $srcFrom = 'install manifest' }
  $script:DoctorInstall = [pscustomobject]@{ inst = $inst; manifestFile = $mf; manifest = $man; manifestBad = $manBad; srcDir = $srcDir; srcFrom = $srcFrom }
  $script:DoctorInstall
}
function Test-DoctorInstall {
  $ctx = Get-DoctorInstallContext
  $man = $ctx.manifest
  $rerun = 're-run the installer from the source checkout (ps\install.ps1)'
  if ($ctx.manifestBad) { Add-DoctorRow 'install-drift' 'warn' 'bin\agentq-install.json' 'the install manifest is not readable JSON' $rerun }
  $listed = 0
  if ($null -ne $man -and $man.ContainsKey('files') -and $man['files'] -is [System.Collections.IDictionary]) {
    foreach ($rel in @($man['files'].Keys)) {
      $listed++
      $fp = Join-DoctorRel $ctx.inst "$rel"
      if (-not [IO.File]::Exists($fp)) { Add-DoctorRow 'install-drift' 'fail' "$rel" 'installed file is missing (listed in the install manifest)' $rerun; continue }
      if ((Get-DoctorSha256 $fp) -ne "$($man['files'][$rel])") {
        # the config is the one installed file that is meant to be edited in place (local overrides);
        # config-drift compares it key by key
        if ("$rel".Replace('/', '\') -ieq 'bin\agentq-config.json') { Add-DoctorRow 'install-drift' 'ok' "$rel" 'changed after install (local overrides are legitimate; see config-drift)'; continue }
        Add-DoctorRow 'install-drift' 'fail' "$rel" 'installed file was changed after install (hand edit): the change is not in the source checkout and the next install overwrites it' 'move the change into the source checkout, then re-run the installer (ps\install.ps1)'
      }
    }
  }
  $compared = 0; $srcText = 'source checkout unknown'
  if ($ctx.srcDir) {
    if (-not [IO.Directory]::Exists($ctx.srcDir)) {
      $srcText = "source $($ctx.srcDir) ($($ctx.srcFrom)) not found"
      Add-DoctorRow 'install-drift' 'warn' "$($ctx.srcDir)" "source checkout not found (from $($ctx.srcFrom))" 'pass -Src <checkout>\ps'
    } else {
      foreach ($rel in $script:DoctorCoreFiles) {
        $sp = Join-DoctorRel $ctx.srcDir $rel
        if (-not [IO.File]::Exists($sp)) { continue }
        $compared++
        $ip = Join-DoctorRel $ctx.inst $rel
        if (-not [IO.File]::Exists($ip)) { Add-DoctorRow 'install-drift' 'warn' $rel 'installed copy differs from the source checkout: the file is not installed' $rerun; continue }
        if ((Get-DoctorSha256 $sp) -ne (Get-DoctorSha256 $ip)) { Add-DoctorRow 'install-drift' 'warn' $rel 'installed copy differs from the source checkout' $rerun }
      }
      $srcText = "source $($ctx.srcDir) ($($ctx.srcFrom)): $compared core file(s) compared"
      # a git checkout: say which commit the source is at and whether the install came from another one
      $head = $null; $srcPath = "$($ctx.srcDir)"
      try { $head = "$(& git --no-optional-locks -C $srcPath rev-parse HEAD 2>$null)".Trim() } catch { $head = $null }
      if ($head -and $head -match '^[0-9a-f]{7,64}$') {
        $manSha = if ($null -ne $man -and $man.ContainsKey('sha') -and $man['sha']) { "$($man['sha'])".Trim() } else { '' }
        $short = $head.Substring(0, 9)
        $note = if (-not $manSha) { 'the install manifest records no commit' }
        elseif ($head.StartsWith($manSha, [StringComparison]::OrdinalIgnoreCase) -or $manSha.StartsWith($head, [StringComparison]::OrdinalIgnoreCase)) { 'same commit as the installed copy' }
        else { "the installed copy came from $($manSha.Substring(0, [math]::Min(9, $manSha.Length))): the source has moved since the install" }
        Add-DoctorRow 'install-drift' 'ok' 'source' "HEAD $short; $note"
      }
    }
  } elseif ($null -eq $man) {
    Add-DoctorRow 'install-drift' 'warn' '' 'source checkout unknown: pass -Src <checkout>\ps' 'agentq doctor -Src <checkout>\ps (or set AGENTQ_SRC); the installer records the source in bin\agentq-install.json'
  }
  $manText = if ($null -ne $man) { "manifest: $listed file(s) verified" } elseif ($ctx.manifestBad) { 'manifest unreadable' } else { 'no install manifest' }
  Add-DoctorSummary 'install-drift' "installed $($ctx.inst); $manText; $srcText"
}
# Canonical text of a JSON value (keys sorted), so nested objects compare by content, not key order.
function ConvertTo-DoctorCanon($v) {
  if ($null -eq $v) { return 'null' }
  if ($v -is [string]) { return (ConvertTo-Json -InputObject $v -Compress) }
  if ($v -is [bool]) { return "$v".ToLowerInvariant() }
  if ($v -is [System.Collections.IDictionary]) {
    $parts = foreach ($k in @($v.Keys | ForEach-Object { "$_" } | Sort-Object)) { (ConvertTo-Json -InputObject $k -Compress) + ':' + (ConvertTo-DoctorCanon $v[$k]) }
    return '{' + (@($parts) -join ',') + '}'
  }
  if ($v -is [System.Collections.IEnumerable]) {
    $parts = foreach ($e in $v) { ConvertTo-DoctorCanon $e }
    return '[' + (@($parts) -join ',') + ']'
  }
  if ($v -is [ValueType]) { return [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $v) }
  ConvertTo-Json -InputObject $v -Compress -Depth 8
}
function Read-DoctorConfig([string]$file) {
  try { $c = [IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable -DateKind String } catch { return $null }
  if ($c -is [System.Collections.IDictionary]) { $c } else { $null }
}
function Test-DoctorConfig {
  $ctx = Get-DoctorInstallContext
  if (-not $ctx.srcDir -or -not [IO.Directory]::Exists($ctx.srcDir)) { Add-DoctorSummary 'config-drift' 'skipped: source checkout unknown'; return }
  $srcCfg = Join-DoctorRel $ctx.srcDir 'bin\agentq-config.json'
  $instCfg = Join-DoctorRel $ctx.inst 'bin\agentq-config.json'
  if (-not [IO.File]::Exists($srcCfg)) { Add-DoctorSummary 'config-drift' 'skipped: the source checkout has no bin\agentq-config.json'; return }
  $rerun = 're-run the installer (ps\install.ps1), or add the key to the installed bin\agentq-config.json'
  if (-not [IO.File]::Exists($instCfg)) {
    Add-DoctorRow 'config-drift' 'warn' 'bin\agentq-config.json' 'the installed config is missing: every knob runs on its built-in default' $rerun
    Add-DoctorSummary 'config-drift' "$instCfg not found"; return
  }
  $srcMap = Read-DoctorConfig $srcCfg; $instMap = Read-DoctorConfig $instCfg
  if ($null -eq $srcMap) { Add-DoctorRow 'config-drift' 'warn' 'bin\agentq-config.json' "the source config is not valid JSON ($srcCfg)" 'fix the file in the source checkout'; Add-DoctorSummary 'config-drift' 'source config unreadable'; return }
  if ($null -eq $instMap) { Add-DoctorRow 'config-drift' 'warn' 'bin\agentq-config.json' "the installed config is not valid JSON ($instCfg): agentq fails to start on it" 'fix the installed file, or restore it from the source checkout'; Add-DoctorSummary 'config-drift' 'installed config unreadable'; return }
  $overrides = @(); $localOnly = @(); $missing = 0
  foreach ($k in @($srcMap.Keys)) {
    if (-not $instMap.ContainsKey($k)) {
      $missing++
      $val = ConvertTo-DoctorCanon $srcMap[$k]
      if ($val.Length -gt 80) { $val = $val.Substring(0, 77) + '...' }
      Add-DoctorRow 'config-drift' 'warn' "$k" "new key not installed (source value $val)" $rerun
    } elseif ((ConvertTo-DoctorCanon $srcMap[$k]) -cne (ConvertTo-DoctorCanon $instMap[$k])) { $overrides += "$k" }
  }
  foreach ($k in @($instMap.Keys)) { if (-not $srcMap.ContainsKey($k)) { $localOnly += "$k" } }
  if ($overrides.Count) { Add-DoctorRow 'config-drift' 'ok' 'local override' ($overrides -join ', ') }
  if ($localOnly.Count) { Add-DoctorRow 'config-drift' 'ok' 'only in the installed copy' ($localOnly -join ', ') }
  Add-DoctorSummary 'config-drift' "$(@($srcMap.Keys).Count) source key(s) compared with $instCfg ($missing not installed)"
}

# ---- 3b. install-proof + stale-install: is the installed agentq really the repo's? --------------
# install.ps1 writes <installed>\bin\agentq-install.json = { src, sha, dirty, at, files:{rel:sha256} }.
# The install gate can finish "green" and copy NOTHING (2026-11-21: it printed 24 of 45 suites green,
# stopped with no footer and no `installed ...` line, the shell free - while the live files kept their
# old sha and mtime and three new files were absent; only a hand hash comparison caught it). These two
# checks make that ONE command. install-proof PROVES that every file the manifest records is installed
# and unchanged; stale-install says how far the installed copy (and the source checkout itself) is
# BEHIND refs/remotes/origin/main. Both are READ-ONLY and NEVER touch the network (no fetch, ever).
# A suite that asserts exact row counts can switch both off with AGENTQ_DOCTOR_NO_STALE=1, the way
# AGENTQ_DOCTOR_NO_TASKS / AGENTQ_DOCTOR_NO_MEMORY already work.
function Invoke-DoctorGit([string]$path, [string[]]$gitArgs) {
  # Native git that never throws: @{ code; out }. A missing git or a path that is not a repo is a code,
  # not an exception. --no-optional-locks keeps a read-only probe from refreshing the index.
  try { $out = @(& git --no-optional-locks -C $path @gitArgs 2>$null | ForEach-Object { "$_" }) }
  catch { return [pscustomobject]@{ code = -1; out = @() } }
  [pscustomobject]@{ code = [int]$LASTEXITCODE; out = $out }
}
function Format-DoctorSha([string]$sha) { if (-not $sha) { return '' }; $sha.Substring(0, [math]::Min(9, $sha.Length)) }
function Test-DoctorInstallProof {
  if ($env:AGENTQ_DOCTOR_NO_STALE -eq '1') { Add-DoctorSummary 'install-proof' 'skipped (AGENTQ_DOCTOR_NO_STALE=1)'; return }
  $ctx = Get-DoctorInstallContext
  $rerun = 're-run the installer from the source checkout (agentq install / ps\install.ps1)'
  if ($ctx.manifestBad) {
    Add-DoctorRow 'install-proof' 'warn' 'bin\agentq-install.json' 'the install manifest is not readable JSON: the install cannot be proven' $rerun
    Add-DoctorSummary 'install-proof' "installed $($ctx.inst); manifest unreadable"; return
  }
  $man = $ctx.manifest
  if ($null -eq $man) {
    # no manifest is NOT an ok: without it nothing records what was copied, so a silent no-op install is
    # invisible (exactly today's failure). Say "cannot prove", never "ok".
    Add-DoctorRow 'install-proof' 'warn' "$($ctx.manifestFile)" 'no manifest - cannot prove this installed copy is the repo''s (nothing records what was copied)' $rerun
    Add-DoctorSummary 'install-proof' "installed $($ctx.inst); no install manifest - cannot prove the install"; return
  }
  $manSha = if ($man.ContainsKey('sha') -and $man['sha']) { "$($man['sha'])".Trim() } else { '' }
  $dirty = [bool]($man.ContainsKey('dirty') -and ("$($man['dirty'])".ToLowerInvariant() -in @('true', '1')))
  $prov = "install $($ctx.inst); recorded commit $(if ($manSha) { Format-DoctorSha $manSha } else { '(none)' })$(if ($dirty) { ' (dirty tree)' })"
  $files = if ($man.ContainsKey('files') -and $man['files'] -is [System.Collections.IDictionary]) { $man['files'] } else { $null }
  if ($null -eq $files -or @($files.Keys).Count -eq 0) {
    Add-DoctorRow 'install-proof' 'warn' 'files' "$prov; the manifest records no files - cannot prove the install" $rerun
    Add-DoctorSummary 'install-proof' "$prov; 0 file(s) recorded"; return
  }
  $n = @($files.Keys).Count; $ok = 0; $drift = 0; $gone = 0
  foreach ($rel in @($files.Keys)) {
    $fp = Join-DoctorRel $ctx.inst "$rel"
    if (-not [IO.File]::Exists($fp)) { $gone++; Add-DoctorRow 'install-proof' 'fail' "$rel" "$prov; recorded in the manifest but NOT installed (the copy step did not run for it)" $rerun; continue }
    if ((Get-DoctorSha256 $fp) -ne "$($files[$rel])") { $drift++; Add-DoctorRow 'install-proof' 'fail' "$rel" "$prov; content differs from the recorded hash (the installed file changed after install, or the copy silently failed)" $rerun; continue }
    $ok++
  }
  Add-DoctorSummary 'install-proof' "$prov; $ok of $n recorded file(s) verified$(if ($drift -or $gone) { " ($drift drifted, $gone missing)" } else { '' })"
}
function Test-DoctorStale {
  if ($env:AGENTQ_DOCTOR_NO_STALE -eq '1') { Add-DoctorSummary 'stale-install' 'skipped (AGENTQ_DOCTOR_NO_STALE=1)'; return }
  $ctx = Get-DoctorInstallContext
  if (-not $ctx.srcDir -or -not [IO.Directory]::Exists($ctx.srcDir)) { Add-DoctorSummary 'stale-install' 'skipped: source checkout unknown (no -Src / AGENTQ_SRC / manifest src)'; return }
  $co = "$($ctx.srcDir)"
  $top = Invoke-DoctorGit $co @('rev-parse', '--show-toplevel')
  $repoRoot = if ($top.code -eq 0 -and $top.out.Count) { "$($top.out[-1])".Trim() } else { '' }
  if (-not $repoRoot) { Add-DoctorSummary 'stale-install' "source $co is not a git checkout: nothing to compare with origin/main"; return }
  # origin/main = whatever the LAST fetch left. This doctor never fetches (no network), so an absent ref
  # is SAID, never silently treated as up to date.
  $om = Invoke-DoctorGit $repoRoot @('rev-parse', '--verify', '--quiet', 'refs/remotes/origin/main')
  $omSha = if ($om.code -eq 0 -and $om.out.Count) { "$($om.out[-1])".Trim() } else { '' }
  if (-not $omSha) {
    Add-DoctorRow 'stale-install' 'ok' '' "source $repoRoot has no origin/main known locally (this doctor never fetches): how far behind the installed copy is cannot be told here" 'git fetch (or agentq install, which fetches) to refresh origin/main'
    Add-DoctorSummary 'stale-install' 'origin/main not known locally (no fetch)'; return
  }
  $omS = Format-DoctorSha $omSha
  $manSha = if ($null -ne $ctx.manifest -and $ctx.manifest.ContainsKey('sha') -and $ctx.manifest['sha']) { "$($ctx.manifest['sha'])".Trim() } else { '' }
  if (-not $manSha) {
    Add-DoctorRow 'stale-install' 'ok' 'installed' "the install manifest records no commit: cannot compare the installed copy with origin/main ($omS)"
  } else {
    # a doctor never fetches, so a recorded sha the repo does not know is common after a rebase: prove it
    # exists locally BEFORE counting (rev-list would otherwise fail on an unknown object).
    $have = Invoke-DoctorGit $repoRoot @('cat-file', '-e', "$manSha^{commit}")
    if ($have.code -ne 0) {
      Add-DoctorRow 'stale-install' 'warn' 'installed' "the install manifest records commit $(Format-DoctorSha $manSha), not present in $repoRoot (never fetched, or rewritten): cannot count how far behind" 'agentq install (re-installs the checkout HEAD)'
    } else {
      $cnt = Invoke-DoctorGit $repoRoot @('rev-list', '--count', "$manSha..origin/main")
      $nb = 0; if ($cnt.code -eq 0 -and $cnt.out.Count) { [void][int]::TryParse("$($cnt.out[-1])".Trim(), [ref]$nb) }
      if ($nb -gt 0) { Add-DoctorRow 'stale-install' 'warn' 'installed' "the installed copy is $nb commit(s) behind origin/main ($(Format-DoctorSha $manSha) -> $omS): a landed fix may not be live" 'agentq install  (re-installs the checkout HEAD, which fetches)' }
      else { Add-DoctorRow 'stale-install' 'ok' 'installed' "the installed copy matches origin/main ($omS)" }
    }
  }
  # the source checkout's own ps/ behind origin/main - the case that hides a fix from every future install
  $head = Invoke-DoctorGit $repoRoot @('rev-parse', 'HEAD')
  $headSha = if ($head.code -eq 0 -and $head.out.Count) { "$($head.out[-1])".Trim() } else { '' }
  if ($headSha -and $headSha -ine $omSha) {
    $anc = Invoke-DoctorGit $repoRoot @('merge-base', '--is-ancestor', 'HEAD', 'origin/main')
    if ($anc.code -eq 0) {
      $cnt2 = Invoke-DoctorGit $repoRoot @('rev-list', '--count', 'HEAD..origin/main')
      $ns = 0; if ($cnt2.code -eq 0 -and $cnt2.out.Count) { [void][int]::TryParse("$($cnt2.out[-1])".Trim(), [ref]$ns) }
      Add-DoctorRow 'stale-install' 'warn' 'source' "the source checkout of ps/ is $ns commit(s) behind origin/main ($(Format-DoctorSha $headSha) -> $omS): re-installing from it would install stale code" 'git -C <checkout> pull --ff-only, then agentq install'
    } else {
      Add-DoctorRow 'stale-install' 'ok' 'source' "the source checkout is not behind origin/main ($(Format-DoctorSha $headSha))"
    }
  } elseif ($headSha) {
    Add-DoctorRow 'stale-install' 'ok' 'source' "the source checkout is at origin/main ($omS)"
  }
  Add-DoctorSummary 'stale-install' "origin/main $omS; installed $(if ($manSha) { Format-DoctorSha $manSha } else { '(none)' }), source $(if ($headSha) { Format-DoctorSha $headSha } else { '(unknown)' }) - no fetch"
}

# ---- 4a. dead-owner: leases whose owner process is gone ------------------------------------------
# lease hygiene (ADR 0012): a slot nobody touched for a while is a slot another agent waits for, and the
# loss counters are the SLO that must stay at zero. Reported per repo, so the owner sees WHICH pool is
# clogged instead of discovering it from an agent that gave up waiting.
function Test-DoctorLeaseHygiene($scope) {
  $leases = @(Get-DoctorLeases)
  if ($scope.only) { $leases = @($leases | Where-Object { "$(P $_ 'repo' '')" -eq $scope.only }) }
  if (-not $leases.Count) { Add-DoctorSummary 'lease-hygiene' 'no leases'; return }
  $stale = @($leases | Where-Object { $_.PSObject.Properties['stale'] -and $_.stale })
  $warm = @($leases | Where-Object { -not ($_.PSObject.Properties['stale'] -and $_.stale) -and [double]$_.idleMin -ge 30 })
  $byRepo = @($leases | Group-Object { "$(P $_ 'repo' '')" } | Sort-Object Count -Descending | ForEach-Object { "$($_.Name):$($_.Count)" }) -join ' '
  Add-DoctorSummary 'lease-hygiene' "$($leases.Count) lease(s) [$byRepo]; $($stale.Count) stale (the sweep backs them up and takes them); $($warm.Count) idle >= 30 min"
  foreach ($l in ($stale | Select-Object -First 20)) {
    Add-DoctorRow 'lease-hygiene' 'warn' "$(P $l 'repo' '')/$(P $l 'slot' '')" "STALE: slot idle $([math]::Round([double]$l.idleMin)) min, session $(P $l 'session' '?') '$(P $l 'purpose' '')'" 'the sweep (task copilot-worktree-prune, every 30 min) reclaims it; `agentq who` lists every lease with its work clock'
  }
  foreach ($l in ($warm | Select-Object -First 5)) {
    Add-DoctorRow 'lease-hygiene' 'info' "$(P $l 'repo' '')/$(P $l 'slot' '')" "idle $([math]::Round([double]$l.idleMin)) min (reclaimed at leaseIdleMin 45 / leaseOwnerIdleMin 90), session $(P $l 'session' '?')" 'if the work is real but outside the slot, renew it: agentq renew -LeaseId <id> (or lease -Hold -HoldMin <n>)'
  }
  # Loss counters (24 h): the SLO numbers that must stay at zero. Cheap: one journal tail.
  try {
    $losses = @(Get-RecentLeaseLosses 24)
    $exp = @($losses | Where-Object { (JProp $_ 'event') -eq 'lease-expire' }).Count
    $brk = @($losses | Where-Object { (JProp $_ 'event') -eq 'lease-break' }).Count
    $lvl = @($exp + $brk)
    if ($lvl -gt 5) { Add-DoctorRow 'lease-hygiene' 'warn' 'losses-24h' "$exp expired + $brk broken in 24 h" 'agentq who -> find the holder and coordinate; every expiry is backed up to refs/backup/wt/<repo>/<slot>/<ts>' }
    else { Add-DoctorRow 'lease-hygiene' 'ok' 'losses-24h' "$exp expired + $brk broken in 24 h" }
  } catch { }
}

function Test-DoctorLeaseOwners($scope) {
  $looked = 0; $dead = 0; $kept = 0
  foreach ($l in @(Get-DoctorLeases)) {
    if ("$(P $l 'role' '')" -notin 'task', 'pinned') { continue }
    $ln = "$(P $l 'repo' '')"
    if ($scope.only -and $ln -ne $scope.only) { continue }
    $looked++
    if ($l.alive) { continue }
    $dead++
    $idle = [double]$l.idleMin
    if ($idle -lt $script:DoctorDeadIdleMin) { continue }
    $label = "$ln/$(P $l 'slot' '')"
    $who = "lease $(P $l 'leaseId' '?'), idle $([math]::Round($idle)) min, session $(P $l 'session' '?'), purpose '$(P $l 'purpose' '')'"
    $cf = "$($l.file).chat"
    if ([IO.File]::Exists($cf) -and ((Now) - [IO.File]::GetLastWriteTimeUtc($cf)).TotalMinutes -lt $script:DoctorChatFreshMin) {
      $kept++
      Add-DoctorRow 'dead-owner' 'ok' $label "kept alive by a chat ($who)"
      continue
    }
    $tail = if ($l.stale) { '; STALE: the next sweep or lease takes the slot' } else { '' }
    Add-DoctorRow 'dead-owner' 'warn' $label "owner process gone; the slot lives only on activity ($who$tail)" 'work still live: agentq renew -LeaseId <id>; finished: agentq unlease -Repo <slot path> -LeaseId <id>'
  }
  Add-DoctorSummary 'dead-owner' "$looked task/pinned lease(s) checked, $dead with a dead owner process ($kept kept alive by a chat)"
}

# ---- 4b/4c. dead-keeper: the job registry ---------------------------------------------------------
# (b) a job still marked running whose process is gone; (c) a live job that looks like a keeper
# (label or command contains "keeper") for a slot nobody leases any more.
function Test-DoctorJobs($scope) {
  $jd = Join-Path $Root 'jobs'
  if (-not [IO.Directory]::Exists($jd)) { Add-DoctorSummary 'dead-keeper' 'no job registry'; return }
  $cut = (Now).AddDays(-$script:DoctorJobDays)
  $files = @([IO.DirectoryInfo]::new($jd).EnumerateFiles('*.json') | Where-Object { $_.LastWriteTimeUtc -gt $cut } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $script:DoctorJobMax)
  # lease paths for (c); when the leases cannot be read, (c) is skipped rather than guessed
  $leasePaths = $null
  try { $leasePaths = @(Get-DoctorLeases | ForEach-Object { $lp = "$(P $_ 'path' '')"; if ($lp) { Norm-Dir $lp } }) } catch { $leasePaths = $null }
  $slotRx = $null; $wtFull = ''
  if ($scope.wtRoot) {
    $wtFull = [IO.Path]::GetFullPath($scope.wtRoot).TrimEnd('\', '/')
    $opt = if ($IsWindows) { [Text.RegularExpressions.RegexOptions]::IgnoreCase } else { [Text.RegularExpressions.RegexOptions]::None }
    $slotRx = [regex]::new(([regex]::Escape($wtFull).Replace('\\', '[\\/]')) + '[\\/]([A-Za-z0-9._-]+)[\\/]([A-Za-z0-9._-]+)', $opt)
  }
  $running = 0; $gone = 0; $keepers = 0
  foreach ($f in $files) {
    $raw = $null
    try { $raw = [IO.File]::ReadAllText($f.FullName) } catch { continue }
    if ($raw -notmatch '"state"\s*:\s*"running"') { continue }
    $j = $null
    try { $j = $raw | ConvertFrom-Json -DateKind String } catch { continue }
    if ("$(P $j 'state' '')" -ne 'running') { continue }
    $running++
    $jp = 0; try { $jp = [int](P $j 'pid' 0) } catch { $jp = 0 }
    $jid = "$(P $j 'id' $f.BaseName)"
    $jl = "$(P $j 'label' '')"; $jc = "$(P $j 'command' '')"; $jcwd = "$(P $j 'cwd' '')"
    if (-not (Test-DoctorPid $jp (P $j 'pidStart' $null))) {
      $gone++
      $what = if ($jl) { $jl } else { $jc }
      if ($what.Length -gt 90) { $what = $what.Substring(0, 87) + '...' }
      Add-DoctorRow 'dead-keeper' 'fail' $jid "job marked running but its process is gone (pid $jp, '$what', log $(P $j 'log' '-'))" 'read the log for how it ended; jobs.ps1 list shows such a job as dead, and whatever waits on it (wait-job, a lease it kept alive) never gets its result'
      continue
    }
    if (-not ($jl -match 'keeper' -or $jc -match 'keeper')) { continue }
    $keepers++
    if ($null -eq $leasePaths -or $null -eq $slotRx) { continue }
    # the slot the keeper is for: the one its cwd names, else the ones its command names
    $named = @()
    foreach ($text in @($jcwd, "$jc $(P $j 'args' '')")) {
      $named = @(foreach ($mt in $slotRx.Matches($text)) { Join-Path (Join-Path $wtFull $mt.Groups[1].Value) $mt.Groups[2].Value })
      if ($named.Count) { break }
    }
    if (-not $named.Count) { continue }
    $leased = @($named | Where-Object { $leasePaths -contains (Norm-Dir $_) })
    if (-not $leased.Count) {
      Add-DoctorRow 'dead-keeper' 'warn' $jid "keeper still running for a slot that is no longer leased (pid $jp, slot $($named[0]), '$jl')" 'stop it: jobs.ps1 kill <id> (nothing is left for it to keep alive)'
    }
  }
  Add-DoctorSummary 'dead-keeper' "$($files.Count) job file(s) of the last $($script:DoctorJobDays) days read: $running marked running, $gone with a dead process, $keepers live keeper(s)"
}

# ---- 5. marks ---------------------------------------------------------------------------------
function Test-DoctorMarks {
  $n = 0
  if ([IO.Directory]::Exists($MDir)) {
    foreach ($f in @([IO.DirectoryInfo]::new($MDir).EnumerateFiles('*.json'))) {
      $m = $null
      try { $m = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json -DateKind String } catch { continue }
      if ($null -eq $m) { continue }
      $n++
      $at = $f.LastWriteTimeUtc
      try { $at = ParseUtc (P $m 'at' '') } catch { $at = $f.LastWriteTimeUtc }
      $ageDays = ((Now) - $at).TotalDays
      if ($ageDays -le $script:DoctorMarkDays) { continue }
      $res = "$(P $m 'resource' $f.BaseName)"
      Add-DoctorRow 'marks' 'warn' $res "$(P $m 'state' 'marked') for $([math]::Round($ageDays, 1)) days (since $(Iso $at), session $(P $m 'session' '?')): '$(P $m 'reason' '')' - forgotten freeze?" 'resolved: agentq mark -Resource <resource> -State clear -Reason "<why it is safe again>"'
    }
  }
  Add-DoctorSummary 'marks' "$n mark(s) checked (older than $($script:DoctorMarkDays) days = warning)"
}

# ---- 6. state-size ----------------------------------------------------------------------------
function Test-DoctorMachineMemory {
  # The free-RAM/commit floors are a property of the MACHINE, not of the fixture state, so a suite that
  # asserts exact warning counts must be able to switch the check off (same idea as AGENTQ_DOCTOR_NO_TASKS).
  if ($env:AGENTQ_DOCTOR_NO_MEMORY -eq '1') { Add-DoctorSummary 'machine-memory' 'skipped (AGENTQ_DOCTOR_NO_MEMORY=1)'; return }
  $mm = Get-MachineMemory ([double]$MinFreeGB)
  $nums = ($mm.floors -join ' / ')
  $detail = "ram $($mm.ramGB) GB, commit $($mm.commitGB) GB free; floors: queue $($mm.queueFloorGB) GB, burst $($mm.burstFloorGB) GB, commit guard $($mm.commitGuardGB) GB, adaptive ram $($mm.ramFloorGB) GB / commit $($mm.commitFloorGB) GB"
  if ($mm.unified) { Add-DoctorRow 'machine-memory' 'pass' '' "$detail (one number everywhere)" }
  else { Add-DoctorRow 'machine-memory' 'warn' '' "$detail - $($mm.floors.Count) different floors ($nums); nothing is broken, each is a real gate, see ADR 0014 D3" 'set machineCapAdaptive.minFreeRamGB/minFreeCommitGB (adaptive) and -MinFreeGB (queue) to ONE number when you decide which' }
}
function Test-DoctorStateSize {
  $hint = 'agentq prune (-WhatIf shows what it would remove)'
  $agents = Get-DoctorFileCount (Join-Path $Root 'agents')
  $jobs = Get-DoctorFileCount (Join-Path $Root 'jobs')
  $notices = Get-DoctorFileCount (Join-Path $Root 'notices')
  $releases = Get-DoctorFileCount $RDir
  $queues = 0; $emptyQ = 0
  if ([IO.Directory]::Exists($QDir)) {
    foreach ($qd in [IO.Directory]::EnumerateDirectories($QDir)) {
      $queues++
      $has = $false
      foreach ($tf in [IO.Directory]::EnumerateFiles($qd, '*.json')) {
        $tn = [IO.Path]::GetFileName($tf)
        if ($tn -ne 'adaptive.json' -and $tn -ne 'burst.json') { $has = $true; break }
      }
      if (-not $has) { $emptyQ++ }
    }
  }
  if ($agents -gt 2000) { Add-DoctorRow 'state-size' 'warn' 'agents' "$agents files in $(Join-Path $Root 'agents') (limit 2000)" $hint }
  if ($jobs -gt 4000) { Add-DoctorRow 'state-size' 'warn' 'jobs' "$jobs files in $(Join-Path $Root 'jobs') (limit 4000)" $hint }
  if ($notices -gt 300) { Add-DoctorRow 'state-size' 'warn' 'notices' "$notices files in $(Join-Path $Root 'notices') (limit 300)" $hint }
  if ($emptyQ -gt 100) { Add-DoctorRow 'state-size' 'warn' 'queues' "$emptyQ of $queues queue folders hold no ticket (limit 100)" $hint }
  $cfg = Get-Config
  $rotMB = 64.0
  if ($cfg.ContainsKey('journalRotateMB') -and $cfg['journalRotateMB']) { $rotMB = [double]$cfg['journalRotateMB'] }
  $jMB = 0.0
  if ([IO.File]::Exists($Journal)) { $jMB = [IO.FileInfo]::new($Journal).Length / 1MB }
  if ($jMB -gt 1.5 * $rotMB) { Add-DoctorRow 'state-size' 'warn' 'journal' "journal is $([math]::Round($jMB, 1)) MB, over 1.5x journalRotateMB ($rotMB MB): rotation is not happening" 'agentq rotate' }
  Add-DoctorSummary 'state-size' "agents $agents, jobs $jobs, notices $notices, releases $releases, queue folders $queues ($emptyQ without a ticket), journal $([math]::Round($jMB, 1)) MB"
}

# ---- 7. scheduled-tasks (Windows) ---------------------------------------------------------------
function Test-DoctorTasks {
  if ($env:AGENTQ_DOCTOR_NO_TASKS -eq '1') { Add-DoctorSummary 'scheduled-tasks' 'skipped (AGENTQ_DOCTOR_NO_TASKS=1)'; return }
  if (-not $IsWindows) { Add-DoctorSummary 'scheduled-tasks' 'skipped (not Windows)'; return }
  # 0 = ok, 267009 = running now, 267011 = has not run yet
  $fine = @(0, 267009, 267011)
  try {
    $tasks = @(Get-ScheduledTask -TaskName $script:DoctorTasks -ErrorAction SilentlyContinue)
    foreach ($tn in $script:DoctorTasks) {
      $t = @($tasks | Where-Object { $_.TaskName -eq $tn }) | Select-Object -First 1
      if (-not $t) { Add-DoctorRow 'scheduled-tasks' 'warn' $tn 'scheduled task is missing: what it keeps alive (sync, sweep, terminal reaper, fast-forward) does not run' 'register it again (the installer / setup script of that tool)'; continue }
      if ("$($t.State)" -eq 'Disabled') { Add-DoctorRow 'scheduled-tasks' 'warn' $tn 'scheduled task is disabled' 'Enable-ScheduledTask, or accept that this part does not run'; continue }
      $ti = $t | Get-ScheduledTaskInfo -ErrorAction Stop
      $rc = [long]$ti.LastTaskResult
      if ($fine -notcontains $rc) {
        $ranAt = if ($ti.LastRunTime) { ([datetime]$ti.LastRunTime).ToUniversalTime().ToString('o') } else { 'unknown' }
        Add-DoctorRow 'scheduled-tasks' 'warn' $tn "last run ended with code $rc (0x$('{0:X}' -f $rc)), last run $ranAt" 'run the task action by hand to see the error'
      }
    }
    Add-DoctorSummary 'scheduled-tasks' "$($script:DoctorTasks.Count) task(s) checked: $($script:DoctorTasks -join ', ')"
  } catch {
    Add-DoctorRow 'scheduled-tasks' 'ok' '' "scheduled tasks could not be queried: $($_.Exception.Message)"
    Add-DoctorSummary 'scheduled-tasks' 'not checked'
  }
}

# ---- 8. git-autosync (the daemon health), via its own -Doctor -----------------------------------
# One command covers everything: instead of re-implementing its checks (scheduled task, snapshot
# freshness, ghost keys, long-lived loops), call `git-autosync -Doctor` and fold its verdict into this
# report. A FAIL line makes this doctor exit non-zero; WARN lines are counted as warnings; OK/INFO
# lines are printed as info rows. Bounded (120 s). A missing or unreadable tool is a WARNING, never a
# FAIL and never a crash: a machine without git-autosync is a valid install.
function Get-DoctorGitAutosyncPath {
  # an explicit override wins (tests point this at a fake); missing at that path is reported, not ignored
  if ($env:AGENTQ_GIT_AUTOSYNC) { return "$($env:AGENTQ_GIT_AUTOSYNC)" }
  $ctx = Get-DoctorInstallContext
  # the installed copy (what the scheduled task runs), else the source checkout, else next to this script
  $cands = @((Join-DoctorRel $ctx.inst 'bin\git-autosync.ps1'))
  if ($ctx.srcDir) { $cands += (Join-DoctorRel $ctx.srcDir 'bin\git-autosync.ps1') }
  if ($PSScriptRoot) { $cands += (Join-Path $PSScriptRoot 'git-autosync.ps1') }
  foreach ($c in $cands) { if ($c -and [IO.File]::Exists($c)) { return $c } }
  $null
}
function Test-DoctorGitAutosync {
  $tool = Get-DoctorGitAutosyncPath
  if (-not $tool -or -not [IO.File]::Exists($tool)) {
    $where = if ($tool) { $tool } else { 'no installed copy and none next to this script' }
    Add-DoctorRow 'git-autosync' 'warn' '' "(git-autosync not installed): $where" 'install it (git-autosync.ps1 -Install) or point AGENTQ_GIT_AUTOSYNC at it'
    Add-DoctorSummary 'git-autosync' 'not installed'
    return
  }
  $timeoutSec = 120
  $psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
  foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $tool, '-Doctor')) { $psi.ArgumentList.Add($a) }
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  try { $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch { }
  $proc = $null; $outTask = $null; $errTask = $null
  try {
    $proc = [Diagnostics.Process]::Start($psi)
    # read async so a full pipe can never deadlock a long run
    $outTask = $proc.StandardOutput.ReadToEndAsync(); $errTask = $proc.StandardError.ReadToEndAsync()
  } catch {
    if ($proc) { try { $proc.Dispose() } catch { } }
    Add-DoctorRow 'git-autosync' 'warn' '' "(git-autosync not installed - could not start $tool): $($_.Exception.Message)" 'run it by hand: pwsh -NoProfile -File "<git-autosync.ps1>" -Doctor'
    Add-DoctorSummary 'git-autosync' 'could not run'
    return
  }
  if (-not $proc.WaitForExit($timeoutSec * 1000)) {
    try { $proc.Kill($true) } catch { }
    try { $proc.WaitForExit(5000) | Out-Null } catch { }
    $proc.Dispose()
    Add-DoctorRow 'git-autosync' 'warn' '' "git-autosync -Doctor did not finish within $timeoutSec s (killed): it may be wedged" 'run it by hand: pwsh -NoProfile -File "<git-autosync.ps1>" -Doctor'
    Add-DoctorSummary 'git-autosync' "timed out after $timeoutSec s"
    return
  }
  try { $proc.WaitForExit() } catch { }   # let the async readers drain before reading the result
  $stdout = ''; $stderr = ''
  try { $stdout = "$($outTask.GetAwaiter().GetResult())" } catch { }
  try { $stderr = "$($errTask.GetAwaiter().GetResult())" } catch { }
  $exit = 0; try { $exit = $proc.ExitCode } catch { }
  $proc.Dispose()
  $fails = 0; $summary = ''
  $outLines = @($stdout -split "`r?`n" | Where-Object { "$_".Trim() })
  foreach ($ln in $outLines) {
    $t = "$ln".Trim()
    if ($t -match '^FAIL\b') { $fails++; Add-DoctorRow 'git-autosync' 'fail' '' ($t -replace '^FAIL[ \t:]+', '') "run it by hand: pwsh -NoProfile -File `"$tool`" -Doctor" }
    elseif ($t -match '^WARN\b') { Add-DoctorRow 'git-autosync' 'warn' '' ($t -replace '^WARN[ \t:]+', '') }
    elseif ($t -match '^DOCTOR:') { $summary = $t }
    else { Add-DoctorRow 'git-autosync' 'ok' '' $t }
  }
  # its own exit code is authoritative: exit 3 is a problem even if no FAIL line was parsed
  if ($exit -eq 3 -and $fails -eq 0) { $fails++; Add-DoctorRow 'git-autosync' 'fail' '' 'git-autosync -Doctor exited 3 but printed no FAIL line' "run it by hand: pwsh -NoProfile -File `"$tool`" -Doctor" }
  if ($stderr.Trim()) { Add-DoctorRow 'git-autosync' 'ok' '' "stderr: $($stderr.Trim())" }
  $sum = if ($summary) { $summary } else { "$($outLines.Count) line(s), exit $exit" }
  Add-DoctorSummary 'git-autosync' "$sum  [$tool]"
}

# ---- 9. daemons: the health records agentq-sync writes (git-autosync, ...) -----------------------
# Each <root>/daemons/<name>.json is { name, at, verdict, okCount, warnCount, failCount, lines,
# failStreak, history }. A `fail` verdict is a problem (a daemon is not doing its job); `warn` is a
# warning. Written by agentq-sync, so an absent dir just means nothing has been collected yet.
function Test-DoctorDaemons {
  $dir = Join-Path $Root 'daemons'
  if (-not [IO.Directory]::Exists($dir)) { Add-DoctorSummary 'daemons' 'no daemon records yet'; return }
  $n = 0; $failed = 0
  foreach ($f in @([IO.DirectoryInfo]::new($dir).EnumerateFiles('*.json'))) {
    $rec = $null
    try { $rec = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json -DateKind String } catch { }
    if ($null -eq $rec) { Add-DoctorRow 'daemons' 'warn' $f.BaseName 'daemon record is not readable JSON' 'let the owning daemon rewrite it (agentq-sync collects it each pass)'; continue }
    $n++
    $name = "$(P $rec 'name' $f.BaseName)"; $verdict = "$(P $rec 'verdict' '?')"
    $streak = 0; try { $streak = [int](P $rec 'failStreak' 0) } catch { }
    $counts = "$(P $rec 'okCount' 0) ok, $(P $rec 'warnCount' 0) warn, $(P $rec 'failCount' 0) fail, $streak consecutive"
    if ($verdict -eq 'fail') {
      $failed++
      $lines = @(P $rec 'lines' @())
      $firstFail = @($lines | Where-Object { "$_" -match '^FAIL' } | Select-Object -First 1)
      $why = if ($firstFail.Count) { " ($($firstFail[0]))" } else { '' }
      Add-DoctorRow 'daemons' 'fail' $name "daemon verdict fail: $counts$why" 'run it by hand: pwsh -NoProfile -File <the daemon tool> -Doctor'
    } elseif ($verdict -eq 'warn') {
      Add-DoctorRow 'daemons' 'warn' $name "daemon verdict warn: $counts"
    }
  }
  Add-DoctorSummary 'daemons' "$n daemon record(s), $failed failing"
}

# ---- report -----------------------------------------------------------------------------------
function Format-DoctorText($row) { if ($row.subject) { "$($row.subject): $($row.detail)" } else { "$($row.detail)" } }
function Write-DoctorReport([object[]]$rows, [string[]]$order, [string]$header, [int]$fails, [int]$warns) {
  $header
  foreach ($c in $order) {
    $mine = @($rows | Where-Object { $_.check -eq $c })
    if (-not $mine.Count) { continue }
    $finds = @($mine | Where-Object { $_.status -ne 'ok' })
    $sums = @($mine | Where-Object { $_.kind -eq 'summary' })
    $sumText = if ($sums.Count) { "$($sums[0].detail)" } else { '' }
    if (-not $finds.Count) { '{0,-4} {1,-20} {2}' -f 'ok', $c, $sumText }
    else {
      $shown = 0
      foreach ($r in $finds) {
        if ($shown -ge $script:DoctorHumanMaxRows) { break }
        $shown++
        '{0,-4} {1,-20} {2}' -f $(if ($r.status -eq 'fail') { 'FAIL' } else { 'warn' }), $c, (Format-DoctorText $r)
      }
      if ($finds.Count -gt $shown) { '{0,-25} ... +{1} more (-Json lists all)' -f '', ($finds.Count - $shown) }
      foreach ($ht in @($finds | ForEach-Object { $_.hint } | Where-Object { $_ } | Select-Object -Unique)) { '{0,-25} hint: {1}' -f '', $ht }
      if ($sumText) { '{0,-25} checked: {1}' -f '', $sumText }
    }
    foreach ($r in @($mine | Where-Object { $_.kind -eq 'info' })) { '{0,-4} {1,-20} {2}' -f 'info', $c, (Format-DoctorText $r) }
  }
  "doctor: $fails problem(s), $warns warning(s)"
}

function Invoke-Doctor {
  $script:DoctorExit = 0
  $script:DoctorRows = [System.Collections.Generic.List[object]]::new()
  $script:DoctorGitCmds = $null; $script:DoctorLeases = $null; $script:DoctorInstall = $null
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $scope = $null
  try { $scope = Get-DoctorScope }
  catch {
    Add-DoctorRow 'scope' 'warn' '' "check crashed: $($_.Exception.Message)"
    $scope = [pscustomobject]@{ wtRoot = ''; only = $null; slots = @(); repoCount = 0 }
  }
  $checks = [ordered]@{
    'stale-index-lock'    = { Test-DoctorIndexLocks $scope }
    'empty-package-store' = { Test-DoctorPackageStore $scope }
    'install-drift'       = { Test-DoctorInstall }
    'config-drift'        = { Test-DoctorConfig }
    'install-proof'       = { Test-DoctorInstallProof }
    'stale-install'       = { Test-DoctorStale }
    'dead-owner'          = { Test-DoctorLeaseOwners $scope }
    'lease-hygiene'       = { Test-DoctorLeaseHygiene $scope }
    'dead-keeper'         = { Test-DoctorJobs $scope }
    'marks'               = { Test-DoctorMarks }
    'machine-memory'      = { Test-DoctorMachineMemory }
    'state-size'          = { Test-DoctorStateSize }
    'scheduled-tasks'     = { Test-DoctorTasks }
    'git-autosync'        = { Test-DoctorGitAutosync }
    'daemons'             = { Test-DoctorDaemons }
  }
  $timings = [ordered]@{}
  foreach ($cn in @($checks.Keys)) {
    $t0 = $sw.ElapsedMilliseconds
    try {
      # test hook: AGENTQ_DOCTOR_FAULT=<check> makes that check throw, to prove the others still run
      if ($env:AGENTQ_DOCTOR_FAULT -eq $cn) { throw "fault injected by AGENTQ_DOCTOR_FAULT" }
      & $checks[$cn]
    } catch { Add-DoctorRow $cn 'warn' '' "check crashed: $($_.Exception.Message)" 'a doctor check must never throw: report this message' }
    $timings[$cn] = [int]($sw.ElapsedMilliseconds - $t0)
  }
  $rows = @($script:DoctorRows)
  $fails = @($rows | Where-Object { $_.status -eq 'fail' }).Count
  $warns = @($rows | Where-Object { $_.status -eq 'warn' }).Count
  $script:DoctorExit = if ($fails) { 1 } else { 0 }
  $scopeText = if ($scope.only) { "repo $($scope.only)" } else { "all repos ($($scope.repoCount))" }
  if ($Json) {
    # ONE JSON object on stdout (the frozen shape `{ at, scope, rows, problems, warnings, exit }` callers
    # consume) instead of the human table; the exit code is unchanged. `scope` mirrors the header.
    [ordered]@{
      at = (Iso (Now))
      scope = [ordered]@{ only = "$($scope.only)"; repos = [int]$scope.repoCount; slots = @($scope.slots).Count; wtRoot = "$($scope.wtRoot)"; text = $scopeText }
      rows = $rows
      problems = $fails
      warnings = $warns
      exit = $script:DoctorExit
    } | ConvertTo-Json -Depth 6 -Compress
    return
  }
  $header = "agentq doctor  $(Iso (Now))  scope: $scopeText, $($scope.slots.Count) slot(s) under $($scope.wtRoot)  state: $Root  $([math]::Round($sw.Elapsed.TotalSeconds, 1)) s"
  Write-DoctorReport $rows (@('scope') + @($checks.Keys)) $header $fails $warns
}
