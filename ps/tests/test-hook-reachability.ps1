# Reachability gate for the preToolUse hook tree (2026-11-28).
#
# Incident it exists for: a hook file (ps/hooks/nudge-parallel.ps1) sat UNREACHED for months because
# NOTHING verified that every hook .ps1 is NOMINATED from something that actually runs it - a hook could
# be added to ps/hooks/ and never wired, and no gate would notice.
#
# For every ps/hooks/*.ps1 (TOP LEVEL only - lib\, resident\, tests\ and node_modules\ are excluded; a
# non-recursive Get-ChildItem never descends, so the exclusion holds by construction), the suite requires
# the file to be named in at least one REACHING source:
#   * ps/hooks/hook-pre.ps1       - the single preToolUse dispatcher that SPAWNS its child hooks
#   * ps/hooks/codai-hooks.json   - the harness hook registration, when the repo carries one
#   * the install map in ps/install.ps1 - the list of files that travel to ~/.copilot
# plus ONE sharper rule: a guard (guard-*.ps1) is RUN only by the dispatcher, so being COPIED by the
# install map is not being REACHED - a guard must be named in hook-pre.ps1. This is the one case where
# the install map cannot stand in for a real wiring source: drop a guard from the dispatcher's child
# list and it is dead code even though it stays "installed" and the union check still passes green.
#
# Everything is read as TEXT ([IO.File]::ReadAllText) and matched on the FILE NAME (a substring), never
# on a whole line, so the check is immune to CRLF/LF/BOM and to whitespace reflow. Exit 0 only if every
# hook is reached; 1 otherwise (the run-all.ps1 convention).
[CmdletBinding(PositionalBinding = $false)]
param([string]$Hooks = '', [string]$Install = '')
$ErrorActionPreference = 'Continue'
$fail = 0
function Ok([bool]$c, [string]$name, [string]$detail = '') { if ($c) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name $detail"; $script:fail++ } }
function Read-Text([string]$p) { if (Test-Path -LiteralPath $p) { try { return [IO.File]::ReadAllText($p) } catch { return $null } } return $null }
function Named-In([string]$text, [string]$name) { ($text) -and ($text.IndexOf($name, [StringComparison]::OrdinalIgnoreCase) -ge 0) }

# Default layout: tests\ -> ps\ -> {hooks\, install.ps1}. Parametrised so the mutation arms can point the
# suite at a throwaway copy without touching the repo.
$psRoot = Split-Path -Parent $PSScriptRoot
if (-not $Hooks) { $Hooks = Join-Path $psRoot 'hooks' }
if (-not $Install) { $Install = Join-Path $psRoot 'install.ps1' }
$hookPre = Join-Path $Hooks 'hook-pre.ps1'
$hookReg = Join-Path $Hooks 'codai-hooks.json'

$srcDispatcher = Read-Text $hookPre
$srcReg = Read-Text $hookReg
$srcInstall = Read-Text $Install

Ok (Test-Path -LiteralPath $Hooks) "the hook directory exists: $Hooks"
Ok ($null -ne $srcDispatcher) 'the dispatcher hook-pre.ps1 is readable'
Ok ($null -ne $srcInstall) "the install map is readable: $Install"
if ($null -eq $srcDispatcher -or $null -eq $srcInstall) { Write-Host ''; Write-Host "$([math]::Max($fail, 1)) FAILED"; exit 1 }
if ($null -eq $srcReg) { Write-Host '  note  codai-hooks.json is absent from the repo (the harness registration lives on the machine); only hook-pre.ps1 + the install map are consulted' }

# NOTE: do NOT name this `$hooks` - variables are case-insensitive, so `$hooks` IS the [string]$Hooks
# parameter and the array would be coerced back to a single string (the same trap run-all.ps1 documents
# for `$list` vs `-List`). Measured here on the first run: count 1, an empty name matching everything.
$hookFiles = @(Get-ChildItem -LiteralPath $Hooks -File -Filter '*.ps1' -ErrorAction SilentlyContinue | Sort-Object Name)
Ok ($hookFiles.Count -ge 1) 'the hook directory carries at least one .ps1 hook' "found $($hookFiles.Count)"

# --- reachability: every hook must be named in at least one reaching source ------------------------
$unreached = @()
foreach ($h in $hookFiles) {
  $via = @()
  if (Named-In $srcDispatcher $h.Name) { $via += 'hook-pre.ps1' }
  if (Named-In $srcReg $h.Name) { $via += 'codai-hooks.json' }
  if (Named-In $srcInstall $h.Name) { $via += 'install map' }
  Ok ($via.Count -ge 1) "reached: $($h.Name)" 'named in NONE of hook-pre.ps1 / codai-hooks.json / the install map'
  if ($via.Count -eq 0) { $unreached += $h.Name } else { Write-Host "         via $($via -join ', ')" }
}

# --- the dispatcher owns the guards ----------------------------------------------------------------
# hook-pre.ps1 is the ONLY thing that SPAWNS a guard; the install map merely copies it. A guard the
# dispatcher does not name is dead code, so it is a failure even though the union check above passed it.
$guards = @($hookFiles | Where-Object { $_.Name -like 'guard-*.ps1' })
Ok ($guards.Count -ge 1) 'there is at least one guard hook for the dispatcher to run' "found $($guards.Count)"
foreach ($g in $guards) {
  Ok (Named-In $srcDispatcher $g.Name) "dispatched: $($g.Name) is named by hook-pre.ps1 (a guard the dispatcher does not run is dead code)"
}

Write-Host ''
Write-Host "checked $($hookFiles.Count) hook(s) against hook-pre.ps1 / codai-hooks.json / the install map"
if ($unreached.Count) { Write-Host "unreached hook(s): $($unreached -join ', ')" }
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
