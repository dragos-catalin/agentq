<#
.SYNOPSIS
  Frees disk by deleting REBUILDABLE build output under E:\gh, E:\GitHub, E:\GitHub METU:
  Cargo target/ (with CACHEDIR.TAG or debug|release), Gradle build/ (next to build.gradle[.kts]),
  .next/, .turbo/, and Gradle .gradle/ caches. Never touches node_modules, sources or .git.

  Why: 2026-10-17 E: had 88 GB free of 1.86 TB; 578 GB was build output (codai desktop target 170 GB).

  Safety: skips anything written in the last -MinIdleHours (default 24) so running or recent builds
  keep their incremental cache, and skips agentq-leased worktree slots.

  LIVENESS (a slot someone is working in must never lose its build output). Two independent signals are
  cross-checked, and a slot EITHER one marks in use is skipped:
    1. the authoritative lease list, `agentq status -All -Json` -> leases[].path;
    2. the per-slot lease FILES, <coord>/leases/**/*.json (a couple of stats, no subprocess), which
       catch a holder whose lease the list missed (a released lease whose process still runs, or a slot
       taken by something that is not agentq).
  The check FAILS SAFE. When liveness cannot be determined - the lease list is empty/unparseable AND the
  lease-file directory is missing, unreadable or holds no lease - the run prints `live NOT DETERMINED
  (<reason>)` plus a NOTE, and SKIPS every candidate under a worktree slot root (<CODAI_WT_ROOT>,
  default E:\gh\.wt) instead of reading the empty scan as "nothing is in use". It does NOT refuse the
  whole run: repo working-tree output, which no lease protects, is still cleaned. Skipping too much is
  the deliberate, safer direction (deleting a live slot's cache is unrecoverable for that agent).

.EXAMPLE
  pwsh -NoProfile -File clean-build-artifacts.ps1 -WhatIf
  pwsh -NoProfile -File clean-build-artifacts.ps1 -MinIdleHours 2 -MinGB 0.3
#>
[CmdletBinding()]
param(
  [string[]]$Roots = @('E:\gh', 'E:\GitHub', 'E:\GitHub METU'),
  [double]$MinIdleHours = 24,
  [double]$MinGB = 0.5,
  [switch]$WhatIf,
  [string]$Log = (Join-Path $env:USERPROFILE '.codai\clean-build-artifacts.log'),
  # liveness inputs (all overridable so a test can inject fixtures without touching the live fleet)
  [string]$CoordDir = (Join-Path $env:USERPROFILE '.codai\coord'),
  [string]$AgentqExe = (Join-Path $env:USERPROFILE '.copilot\bin\agentq.ps1'),
  [string]$StatusJson = $null,           # $null = run agentq; a string = use it verbatim (offline/tests)
  [string[]]$SlotRoots = @()             # default: $env:CODAI_WT_ROOT, else E:\gh\.wt
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force (Split-Path $Log) | Out-Null
function Say($m) { $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $m; $line | Add-Content $Log; Write-Output $line }

# ---- path helpers: ordinal, case-insensitive (Windows paths are case-insensitive) ----------------
function ConvertTo-NormPath([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return '' }
  $p.Trim().TrimEnd([char[]]@('\', '/')).Replace('/', '\').ToLowerInvariant()
}
# True when $child is $parent itself or lies below it (boundary-aware, so task-10 is not under task-1).
function Test-PathUnder([string]$child, [string]$parent) {
  $c = ConvertTo-NormPath $child; $pp = ConvertTo-NormPath $parent
  if (-not $c -or -not $pp) { return $false }
  ($c -eq $pp) -or $c.StartsWith($pp + '\')
}

# ---- signal 1: the authoritative lease list ------------------------------------------------------
# An EMPTY / unparseable list is unusable, never "nothing is leased": the two are indistinguishable
# from a failed query, and guessing is exactly how a live slot's cache gets deleted.
function Read-StatusLease([string]$text) {
  if ([string]::IsNullOrWhiteSpace($text)) { return @{ Ok = $false; Reason = 'no output from agentq status -All -Json'; Paths = @() } }
  $j = $null
  try { $j = $text | ConvertFrom-Json } catch { return @{ Ok = $false; Reason = "lease list is not JSON ($($_.Exception.Message))"; Paths = @() } }
  if ($null -eq $j -or -not ($j.PSObject.Properties.Name -contains 'leases')) { return @{ Ok = $false; Reason = 'lease list has no leases[] array'; Paths = @() } }
  $ls = @($j.leases)
  if ($ls.Count -eq 0) { return @{ Ok = $false; Reason = 'agentq reported ZERO leases (indistinguishable from a broken query)'; Paths = @() } }
  $paths = @($ls | ForEach-Object { if ($_ -and $_.path) { ConvertTo-NormPath ([string]$_.path) } } | Where-Object { $_ })
  if ($paths.Count -eq 0) { return @{ Ok = $false; Reason = 'leases[] present but none carried a path'; Paths = @() } }
  @{ Ok = $true; Reason = ''; Paths = $paths }
}

# ---- signal 2: the per-slot lease files ----------------------------------------------------------
# A missing, unreadable or (critically) EMPTY directory is "not determined", not "nothing in use".
function Read-LeaseFiles([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) { return @{ Ok = $false; Reason = "no lease directory at $dir"; Paths = @() } }
  $files = @()
  try { $files = @(Get-ChildItem -LiteralPath $dir -File -Recurse -ErrorAction Stop | Where-Object { $_.Name.EndsWith('.json', [StringComparison]::OrdinalIgnoreCase) }) }
  catch { return @{ Ok = $false; Reason = "lease directory unreadable ($($_.Exception.Message))"; Paths = @() } }
  if ($files.Count -eq 0) { return @{ Ok = $false; Reason = "lease directory holds no lease file at $dir"; Paths = @() } }
  $paths = @()
  foreach ($f in $files) {
    try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; if ($j -and $j.path) { $paths += ConvertTo-NormPath ([string]$j.path) } } catch { }
  }
  @{ Ok = $true; Reason = ''; Paths = $paths }
}

$status = if ($null -ne $StatusJson) { Read-StatusLease $StatusJson } else {
  $txt = ''
  if (Test-Path -LiteralPath $AgentqExe) { try { $txt = (& pwsh -NoProfile -File $AgentqExe status -All -Json 2>$null | Out-String) } catch { $txt = '' } }
  Read-StatusLease $txt
}
$files = Read-LeaseFiles (Join-Path $CoordDir 'leases')

$inUse = @(@($status.Paths) + @($files.Paths) | Where-Object { $_ } | Sort-Object -Unique)
$known = [bool]$status.Ok -or [bool]$files.Ok
$reason = ''
if (-not $known) { $reason = "lease list: $($status.Reason); lease files: $($files.Reason)" }
$resolvedSlotRoots = if (@($SlotRoots).Count) { @($SlotRoots) } elseif ($env:CODAI_WT_ROOT) { @($env:CODAI_WT_ROOT) } else { @('E:\gh\.wt') }

# ---- walk + measure ------------------------------------------------------------------------------
$all = [IO.EnumerationOptions]::new(); $all.RecurseSubdirectories = $true; $all.IgnoreInaccessible = $true; $all.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
$one = [IO.EnumerationOptions]::new(); $one.IgnoreInaccessible = $true; $one.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
$names = @('target', '.next', '.turbo', 'build', '.gradle')
$cut = (Get-Date).AddHours(-$MinIdleHours)

function Measure-Dir([string]$p) {
  $s = [long]0; $newest = [datetime]::MinValue
  foreach ($f in [IO.DirectoryInfo]::new($p).EnumerateFiles('*', $all)) { $s += $f.Length; if ($f.LastWriteTime -gt $newest) { $newest = $f.LastWriteTime } }
  [pscustomobject]@{ Bytes = $s; Newest = $newest }
}

$found = [Collections.Generic.List[object]]::new()
function Walk([string]$dir, [int]$depth) {
  if ($depth -gt 6) { return }
  foreach ($d in [IO.DirectoryInfo]::new($dir).EnumerateDirectories('*', $one)) {
    if ($d.Name -in 'node_modules', '.git') { continue }
    if ($names -contains $d.Name) {
      $ok = $true
      if ($d.Name -eq 'target') { $ok = (Test-Path (Join-Path $d.FullName 'CACHEDIR.TAG')) -or (Test-Path (Join-Path $d.FullName 'debug')) -or (Test-Path (Join-Path $d.FullName 'release')) }
      if ($d.Name -eq 'build') { $ok = (Test-Path (Join-Path $dir 'build.gradle.kts')) -or (Test-Path (Join-Path $dir 'build.gradle')) }
      if ($d.Name -eq '.gradle') { $ok = (Test-Path (Join-Path $dir 'settings.gradle.kts')) -or (Test-Path (Join-Path $dir 'settings.gradle')) }
      if ($ok) { $found.Add($d.FullName); continue }
    }
    Walk $d.FullName ($depth + 1)
  }
}

$vol = $Roots[0].Substring(0, 1)
$before = (Get-Volume -DriveLetter $vol).SizeRemaining
Say ('start free {0:N1} GB, idle >= {1} h, min {2} GB, whatif={3}' -f ($before / 1GB), $MinIdleHours, $MinGB, [bool]$WhatIf)
Say ('liveness: lease-list={0}; lease-files={1}; in-use {2} path(s)' -f `
    $(if ($status.Ok) { "ok ($($status.Paths.Count))" } else { "unusable: $($status.Reason)" }), `
    $(if ($files.Ok) { "ok ($($files.Paths.Count))" } else { "unusable: $($files.Reason)" }), $inUse.Count)
if (-not $known) {
  Say "live NOT DETERMINED ($reason)"
  Say ('NOTE  no usable lease signal; candidates under a slot root (' + ($resolvedSlotRoots -join ', ') + ') are SKIPPED, not deleted. Repo working-tree output is still cleaned.')
} elseif (-not $status.Ok) {
  Say "WARN live: lease list unusable ($($status.Reason)) - relying on the lease files alone"
} elseif (-not $files.Ok) {
  Say "WARN live: lease-file probe unavailable ($($files.Reason)) - relying on the lease list alone"
}
foreach ($r in $Roots) { if (Test-Path $r) { Walk $r 0 } }

$empty = Join-Path $env:TEMP 'clean-build-artifacts-empty'
New-Item -ItemType Directory -Force $empty | Out-Null
$total = [long]0
foreach ($p in $found) {
  $owner = $null
  foreach ($u in $inUse) { if (Test-PathUnder $p $u) { $owner = $u; break } }
  if ($owner) {
    $src = if (@($status.Paths) -contains $owner) { 'agentq lease list' } else { 'live lease file' }
    Say "SKIP in-use (skip)  $p  (in use: $src)"
    continue
  }
  if (-not $known) {
    $underSlot = $null
    foreach ($sr in $resolvedSlotRoots) { if (Test-PathUnder $p $sr) { $underSlot = $sr; break } }
    if ($underSlot) { Say "SKIP not-determined (skip)  $p  (live NOT DETERMINED; under slot root $underSlot)"; continue }
  }
  $m = Measure-Dir $p
  if ($m.Bytes -lt $MinGB * 1GB) { continue }
  if ($m.Newest -gt $cut) { Say ('SKIP recent  {0,7:N1} GB  {1}  (newest {2:yyyy-MM-dd HH:mm})' -f ($m.Bytes / 1GB), $p, $m.Newest); continue }
  if ($WhatIf) { Say ('WOULD DELETE {0,7:N1} GB  {1}' -f ($m.Bytes / 1GB), $p); $total += $m.Bytes; continue }
  # robocopy /MIR from an empty dir handles deep trees and long paths far faster than Remove-Item
  robocopy $empty $p /MIR /NFL /NDL /NJH /NJS /NP /R:0 /W:0 | Out-Null
  Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue
  $total += $m.Bytes
  Say ('DELETED      {0,7:N1} GB  {1}{2}' -f ($m.Bytes / 1GB), $p, $(if (Test-Path -LiteralPath $p) { '  (partially, files in use)' } else { '' }))
}
$after = (Get-Volume -DriveLetter $vol).SizeRemaining
Say ('end free {0:N1} GB; candidates {1:N1} GB; measured change {2:N1} GB' -f ($after / 1GB), ($total / 1GB), (($after - $before) / 1GB))
