#!/usr/bin/env pwsh
<#
find-registries.ps1 - the one source of truth for "where do the tracker registries live".

WHY IT EXISTS
  Every repo onboarded to the tracker registry carries a committed
  .agentq/trackers.json. Something has to answer "which repos on this machine have
  one, and where is it" without a hand-maintained list, and without a second answer
  that drifts from `agentq tracker scan`. That answer is split across two files:
    * spec/machine-roots.json  the machine-local PARENT directories whose immediate
                               children may be repos. DATA, edited by hand; no code.
    * this script              the discovery recipe over those parents.
  Keeping the parents in DATA (not baked into the script) is the point: a new parent
  is a one-line edit that every reader of the registry sees, and this script and
  `agentq tracker scan` cannot disagree about where to look.

USAGE
  pwsh -NoProfile -File tools/find-registries.ps1
      Human output: one TAB-separated line per repo that HAS a registry, sorted by
      repo name:
          <repo-name><TAB><absolute repo root><TAB><registry path><TAB><tracker count>
      Tab-separated on purpose, so it pipes:
          ... | ForEach-Object { ($_ -split "`t")[0] }

  pwsh -NoProfile -File tools/find-registries.ps1 -Json
      One JSON object on stdout:
        { "version": 1,
          "parents": ["E:\\gh", "E:\\gh\\frontiers"],
          "repos": [ { "repo": "...", "root": "...", "registry": "...", "trackers": <n> } ] }

  pwsh -NoProfile -File tools/find-registries.ps1 -Roots 'E:\gh','E:\gh\frontiers'
      Override the parents from spec/machine-roots.json. Accepted forms, all equivalent:
          -Roots 'E:\gh','E:\gh\frontiers'   two tokens
          -Roots 'E:\gh,E:\gh\frontiers'     one comma-joined token
          -Roots 'E:\gh;E:\gh\frontiers'     one semicolon-joined token
          E:\gh E:\gh\frontiers              positional, no flag
      Repeating the flag (-Roots a -Roots b) is NOT accepted: PowerShell refuses a
      parameter specified more than once. The remaining-argument parameter is declared
      at position 1 precisely so a second bare token lands here rather than on -Depth -
      with the default order it bound to -Depth and died with "Cannot convert value
      'E:\gh' to type System.Int32" before this script's own code ever ran.

  pwsh -NoProfile -File tools/find-registries.ps1 -Depth 2
      How many directory levels under a parent a repo root may sit (default 1, which
      means an immediate child). Any depth >= 1 is walked; depth < 1 is REFUSED with a
      message rather than answered wrongly. Named only - it is not positional, so a
      stray argument can never be swallowed as a depth.

EXIT CODES
  0  the walk succeeded. Zero repos is NOT an error - the fleet may be mid-move; only
     an unreadable or nonexistent PARENT is.
  1  at least one parent could not be walked. The other parents are still walked and
     the failure is named on stderr.
  2  bad arguments (for example -Depth 0).

GUARANTEES
  * Read-only. It never writes, never reformats, never touches a repo it finds.
  * A repo is reported ONLY after its registry path is resolved and Test-Path'd as a
    file. A plausible-looking path that does not exist is never printed as a
    registry, and - the failure mode that actually matters - a real registry is never
    silently dropped: existence is proven, never assumed.
  * The walk skips node_modules, .git, dist, .wt, .copilot-tmp and EVERY dot-directory,
    so a nested worktree slot or a scratch clone is never mistaken for a second repo.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string[]] $Roots,
    [switch]   $Json,
    # Position 1 + remaining-args: every extra token is a parent, never a -Depth value.
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]] $Rest,
    [int]      $Depth = 1
)

$ErrorActionPreference = 'Stop'

$script:exitCode = 0
$specVersion = 1
$defaultParents = @('E:\gh', 'E:\gh\frontiers')

function Write-Err([string]$message) { [Console]::Error.WriteLine($message) }

# Directories that are never a repo root when walking under a parent. Every entry
# also starts with a '.', but they are named explicitly so the intent is readable;
# Test-SkipDir adds the generic dot-directory rule on top.
$skipNames = @('node_modules', '.git', 'dist', '.wt', '.copilot-tmp')
function Test-SkipDir([string]$name) {
    if ($name.StartsWith('.')) { return $true }
    return ($skipNames -contains $name)
}

# Repo roots already accepted, keyed by lowercased absolute path so the same repo
# reached from two parents (or at two depths) is reported exactly once.
$found = [ordered]@{}

function Add-Repo([string]$root, [string]$registry) {
    $key = $root.ToLowerInvariant()
    if ($found.Contains($key)) { return }
    $name = Split-Path -Leaf $root
    $count = 0
    try {
        $raw = Get-Content -LiteralPath $registry -Raw
        # A registry may hold keys that differ only by CASE (brivio has both 'backlog'
        # and 'BACKLOG' inside its status maps), which ConvertFrom-Json rejects unless
        # -AsHashtable is used. Try that first; fall back for Windows PowerShell 5.1,
        # where the switch does not exist.
        $asHash = $true
        try { $j = $raw | ConvertFrom-Json -AsHashtable }
        catch { $j = $raw | ConvertFrom-Json; $asHash = $false }
        if ($null -ne $j) {
            if ($asHash) {
                if ($j.ContainsKey('repo') -and $j['repo']) { $name = [string]$j['repo'] }
                if ($j.ContainsKey('trackers')) { $count = @($j['trackers']).Count }
            } else {
                if (($j.PSObject.Properties.Name -contains 'repo') -and $j.repo) { $name = [string]$j.repo }
                if ($j.PSObject.Properties.Name -contains 'trackers') { $count = @($j.trackers).Count }
            }
        }
    } catch {
        Write-Err ("find-registries: {0} is not valid JSON; counting 0 trackers." -f $registry)
    }
    $found[$key] = [pscustomobject]@{ repo = $name; root = $root; registry = $registry; trackers = $count }
}

# The registry path is BUILT from the directory being walked (Join-Path), never
# SPLIT out of a discovered path - a double Split-Path silently eats a path segment
# and hands back a plausible path that does not exist.
function Collect-Under([string]$dir, [int]$levelsLeft, [bool]$isParent) {
    $children = $null
    try {
        $children = @(Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction Stop)
    } catch {
        Write-Err ("find-registries: cannot read directory {0}: {1}" -f $dir, $_.Exception.Message)
        if ($isParent) { $script:exitCode = 1 }
        return
    }
    foreach ($child in $children) {
        if (Test-SkipDir -name $child.Name) { continue }
        $registry = Join-Path $child.FullName '.agentq\trackers.json'
        if (Test-Path -LiteralPath $registry -PathType Leaf) {
            Add-Repo -root $child.FullName -registry $registry
        }
        if ($levelsLeft -gt 1) { Collect-Under -dir $child.FullName -levelsLeft ($levelsLeft - 1) -isParent $false }
    }
}

# --- resolve the parents --------------------------------------------------------
$specPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\spec\machine-roots.json'))

$requested = @()
if ($Roots) { $requested += $Roots }
if ($Rest)  { $requested += $Rest }
$explicit = @()
foreach ($r in $requested) {
    foreach ($piece in ($r -split '[,;]')) {
        $piece = $piece.Trim()
        if ($piece) { $explicit += $piece }
    }
}

if ($explicit.Count -gt 0) {
    $parents = $explicit
} else {
    $fromSpec = $null
    if (Test-Path -LiteralPath $specPath -PathType Leaf) {
        try {
            $spec = Get-Content -LiteralPath $specPath -Raw | ConvertFrom-Json
            if ($null -ne $spec -and ($spec.PSObject.Properties.Name -contains 'parents')) {
                $fromSpec = @($spec.parents | Where-Object { $_ })
            }
        } catch {
            Write-Err ("find-registries: {0} is not valid JSON; using the built-in parents." -f $specPath)
        }
    }
    if ($fromSpec -and $fromSpec.Count -gt 0) {
        $parents = $fromSpec
    } else {
        $parents = $defaultParents
        Write-Err ("find-registries: no usable spec/machine-roots.json at {0}; falling back to {1}" -f $specPath, ($defaultParents -join ', '))
    }
}

if ($Depth -lt 1) {
    Write-Err ("find-registries: -Depth must be >= 1 (got {0}); refusing rather than answering wrongly." -f $Depth)
    exit 2
}

foreach ($parent in $parents) {
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        Write-Err ("find-registries: parent does not exist: {0}" -f $parent)
        $script:exitCode = 1
        continue
    }
    Collect-Under -dir $parent -levelsLeft $Depth -isParent $true
}

$repos = @($found.Values) | Sort-Object -Property repo

if ($Json) {
    $payload = [ordered]@{
        version = $specVersion
        parents = @($parents)
        repos   = @($repos)
    }
    $payload | ConvertTo-Json -Depth 6
} else {
    foreach ($r in $repos) {
        "{0}`t{1}`t{2}`t{3}" -f $r.repo, $r.root, $r.registry, $r.trackers
    }
}

exit $script:exitCode
