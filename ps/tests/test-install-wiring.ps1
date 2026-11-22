# Guards the WIRING between the gate list (tests/run-all.ps1) and the install map (install.ps1) - the
# 2026-11-22 gap that let `install.ps1 -Check` print "in sync" while the installed gate could not run a
# suite whose tool it never installed. It is the same defect class as `test-land-default-gate.ps1` (a
# suite in run-all that is absent from the map), found by reading rather than by running.
#
# Checks, all static except the -RepoSuites ones (a `pwsh` spawn of run-all, no suite is executed):
#   1  every file a suite references (Join-Path $PSScriptRoot/$stage/$bin/$hooks/$root) is a map key
#   2  every key in the map exists in THIS checkout (a fresh clone otherwise throws in install.ps1)
#   3  every mapped tests/ file is tracked by git (an untracked one breaks CI even though it works here)
#   4  gateSuites.<repo> names real suites, is non-empty, contains `status readonly` (owner, 2026-11-22)
#      and every suite it names is fully installed - a gate you cannot install is a gate that cannot run
#   5  landGate.<repo> exists and drives that persisted list (-RepoSuites), never a repeated literal list
#   6  `run-all.ps1 -RepoSuites -List` prints exactly the persisted names
#   7  a config without gateSuites.<repo> is refused (exit 2) instead of silently running everything
#   8  an unknown name in the list is refused (exit 2) naming it
#   9  MUTATION: a suite referencing a tool that is not in the map is DETECTED (checks 1 is not vacuous)
#  10  MUTATION: an unknown name in gateSuites is DETECTED (check 4 is not vacuous)
[CmdletBinding(PositionalBinding = $false)]
param([string]$Ps = (Join-Path $PSScriptRoot '..'))
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { $script:pass++; Write-Output "PASS $Name" } else { $script:fail++; Write-Output "FAIL $Name$(if ($Detail) { ' - ' + $Detail })" }
}
function Note([string]$Text) { Write-Output "note: $Text" }

$psRoot = (Resolve-Path -LiteralPath $Ps).Path
$runAll = Join-Path $psRoot 'tests\run-all.ps1'
$install = Join-Path $psRoot 'install.ps1'
$repoRoot = Split-Path -Parent $psRoot
# The repo NAME, not the directory leaf (a leased slot is `task-1` or `land`, not `agentq`): the same
# derivation run-build's Get-RepoLeafName and agentq's Get-RepoInfo use, so the guard tests the key the
# code looks up - including when the gate runs inside a slot worktree.
function Resolve-RepoName([string]$Top) {
  $common = "$(& git -C $Top rev-parse --path-format=absolute --git-common-dir 2>$null)".Trim()
  if ($LASTEXITCODE -eq 0 -and $common -and (Test-Path -LiteralPath $common)) { return (Split-Path (Split-Path ($common -replace '/', '\') -Parent) -Leaf) }
  (Split-Path -Leaf $Top)
}
$repoName = Resolve-RepoName $repoRoot
foreach ($p in @($runAll, $install)) { if (-not (Test-Path -LiteralPath $p)) { Write-Output "FAIL guard cannot run: $p is missing"; exit 1 } }

# --- parse run-all's suite table -----------------------------------------------------------------
# Comment lines are dropped BEFORE the scan: the table's comments name scripts too, and a comment must
# never be able to satisfy (or break) the wiring.
function Get-SuiteBlock([string]$Path) {
  $text = Get-Content -LiteralPath $Path -Raw
  $m = [regex]::Match($text, '(?ms)\$suites\s*=\s*\[ordered\]@\{.*?^\$names')
  if (-not $m.Success) { return '' }
  @($m.Value -split "`r?`n" | Where-Object { "$_".Trim() -notmatch '^#' }) -join "`n"
}
# $PSScriptRoot/$stage hold a copy of tests/, $stage also gets every file in bin/, $root is ps/ itself.
$prefixOf = @{ PSScriptRoot = @('tests'); stage = @('tests', 'bin'); bin = @('bin'); hooks = @('hooks'); root = @('') }
function Get-SuiteRefs([string]$Block) {
  $refs = @()
  # [$] is a literal dollar in BOTH languages (PowerShell would read `$(` as a subexpression there): a
  # bare `$` is a regex end-of-line anchor, so the pattern matched NOTHING - which is how this guard
  # passed its first run while four suite files were demonstrably absent from the map.
  foreach ($m in [regex]::Matches($Block, "Join-Path\s+[$](?<var>[A-Za-z_]\w*)\s+'(?<name>[^']+)'")) {
    $var = $m.Groups['var'].Value; $name = $m.Groups['name'].Value
    if (-not $prefixOf.ContainsKey($var)) { continue }
    $cand = @($prefixOf[$var] | ForEach-Object { if ($_) { "$_\$name" } else { $name } })
    $refs += , [pscustomobject]@{ Var = $var; Name = $name; Candidates = $cand }
  }
  $refs
}
function Get-MapKeys([string]$InstallPath) {
  $text = Get-Content -LiteralPath $InstallPath -Raw
  $m = [regex]::Match($text, '(?ms)\$map\s*=\s*\[ordered\]@\{.*?^\$dst')
  if (-not $m.Success) { return @() }
  $body = @($m.Value -split "`r?`n" | Where-Object { "$_".Trim() -notmatch '^#' }) -join "`n"
  $keys = @()
  foreach ($mm in [regex]::Matches($body, "'([^']+)'\s*=\s*'([^']+)'")) { $keys += $mm.Groups[1].Value }
  $keys
}
# A reference is satisfied when ANY of its candidate source paths is a map key.
function Get-MapDrift([string]$RunAllPath, [string]$InstallPath, [string[]]$Except = @()) {
  $block = Get-SuiteBlock $RunAllPath
  $keys = @(Get-MapKeys $InstallPath)
  $lower = @{}; foreach ($k in $keys) { $lower[$k.ToLowerInvariant()] = $k }
  $exceptLower = @{}; foreach ($e in $Except) { $exceptLower[$e.ToLowerInvariant()] = $true }
  $missing = @()
  foreach ($r in @(Get-SuiteRefs $block)) {
    $src = @($r.Candidates | Where-Object { $lower.ContainsKey($_.ToLowerInvariant()) -or $exceptLower.ContainsKey($_.ToLowerInvariant()) })
    if (-not $src.Count) { $missing += "$($r.Name) (from `$$($r.Var), expected map key $($r.Candidates -join ' or '))" }
  }
  @($missing | Select-Object -Unique)
}

$suiteBlock = Get-SuiteBlock $runAll
$mapKeys = @(Get-MapKeys $install)
Check 'the install map and the suite table are both parseable' ($suiteBlock.Length -gt 0 -and $mapKeys.Count -gt 0) "suite block $($suiteBlock.Length) chars, map keys $($mapKeys.Count)"
# Anti-vacuity: the drift check below can only fail if the references were actually extracted.
$refCount = @(Get-SuiteRefs $suiteBlock).Count
Check 'the suite references are readable (not an empty match)' ($refCount -ge 60) "extracted $refCount Join-Path references"

# 3 is written after the tracked set is known, so collect the except table first.
# An exception is not a hole: it is PRINTED on every run, and the guard says when it went stale.
$trackExcept = @{
  # reported 2026-11-22: the map entry is committed, the file is not - a fresh clone (CI) throws
  # "install: tests\test-release-phase-honesty.ps1 is in the map but not in this checkout".
  'tests\test-release-phase-honesty.ps1' = "untracked file of another agent; its owner must commit it"
}
function Get-TrackedSet([string]$RepoRoot) {
  $s = @{}
  # git answers repo-relative (`ps/tests/x.ps1`); the map keys are ps-relative (`tests\x.ps1`).
  foreach ($l in @(& git -C $RepoRoot ls-files -- ps/tests 2>$null)) {
    $n = "$l" -replace '/', '\'
    if ($n -match '(?i)^ps\\tests\\(.+)$') { $s["tests\$($Matches[1])".ToLowerInvariant()] = $true }
  }
  $s
}

# --- 1: every suite reference is installed -------------------------------------------------------
$drift = @(Get-MapDrift $runAll $install)
Check 'every file the suites reference is in the install map' ($drift.Count -eq 0) "$($drift.Count) missing: $($drift -join '; ')"
if ($drift.Count) { $drift | ForEach-Object { Note "not installed: $_" } }

# --- 2: every map key exists here -----------------------------------------------------------------
$absent = @($mapKeys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $psRoot $_)) })
Check 'every map key exists in this checkout' ($absent.Count -eq 0) "missing files: $($absent -join ', ')"

# --- 3: every mapped tests/ file is tracked (what CI checks out) ----------------------------------
$tracked = Get-TrackedSet $repoRoot
$untracked = @($mapKeys | Where-Object { "$_".ToLowerInvariant().StartsWith('tests\') -and -not $tracked.ContainsKey("$_".ToLowerInvariant()) })
$untrackedExcepted = @($untracked | Where-Object { $trackExcept.ContainsKey($_) })
$untrackedBare = @($untracked | Where-Object { -not $trackExcept.ContainsKey($_) })
Check 'every mapped tests/ file is tracked by git (or excepted, and printed)' ($untrackedBare.Count -eq 0) "untracked and not excepted: $($untrackedBare -join ', ')"
foreach ($u in $untrackedExcepted) { Note "EXCEPTED (tracking breaks CI): $u - $($trackExcept[$u])" }
foreach ($e in $trackExcept.Keys) {
  if ($tracked.ContainsKey($e.ToLowerInvariant())) { Note "the exception for $e is now STALE (the file is tracked) - drop it from the guard" }
  elseif ($mapKeys -notcontains $e) { Note "the exception for $e is STALE (no such map key) - drop it from the guard" }
}

# --- 4/5: the persisted gate list and the land gate -----------------------------------------------
# Resolved the same way run-all does, so the guard tests what runs: bin/agentq-config.json unless
# AGENTQ_CONFIG overrides it (the suites use that to isolate themselves).
function Get-ConfigPath([string]$PsRoot, [string]$EnvCfg) { if ($EnvCfg) { $EnvCfg } else { Join-Path $PsRoot 'bin\agentq-config.json' } }
function Read-Cfg([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } catch { return $null }
}
function Get-GateList([string]$CfgPath, [string]$Repo) {
  $c = Read-Cfg $CfgPath
  if (-not $c -or -not $c.ContainsKey('gateSuites')) { return @() }
  $gs = $c['gateSuites']
  if (-not ($gs -is [Collections.IDictionary]) -or -not $gs.ContainsKey($Repo)) { return @() }
  @($gs[$Repo])
}
function Get-GateFindings([string]$CfgPath, [string]$Repo, [string[]]$Names, [string[]]$MapKeys, [string]$RunAllPath) {
  $f = @()
  $list = @(Get-GateList $CfgPath $Repo)
  if (-not $list.Count) { return @("no gateSuites.$Repo in the config") }
  $known = @{}; foreach ($n in $Names) { $known[$n.ToLowerInvariant()] = $n }
  foreach ($n in $list) { if (-not $known.ContainsKey("$n".ToLowerInvariant())) { $f += "gateSuites.$Repo names '$n', which is not a suite in run-all.ps1" } }
  if (-not @($list | Where-Object { "$_".Trim().ToLowerInvariant() -eq 'status readonly' }).Count) { $f += "gateSuites.$Repo does not include 'status readonly'" }
  # a gated suite whose tool is not installed cannot run from the installed gate
  $missingRef = @(Get-MapDrift $RunAllPath (Join-Path (Split-Path -Parent $RunAllPath) '..\install.ps1'))
  if ($missingRef.Count) { $f += "the install map is missing $($missingRef -join '; ')" }
  $f
}
$suiteNames = @()
$sm = [regex]::Matches($suiteBlock, "(?m)^\s*'(?<n>[^']+)'\s*=")
foreach ($m in $sm) { $suiteNames += $m.Groups['n'].Value }
Check 'the suite names are readable for the gate list check' ($suiteNames.Count -ge 40) "found $($suiteNames.Count) suites"

$cfgPath = Get-ConfigPath $psRoot $env:AGENTQ_CONFIG
$cfg = Read-Cfg $cfgPath
Check "the config is readable ($cfgPath)" ($null -ne $cfg)
if ($cfg) {
  $gateFindings = @(Get-GateFindings $cfgPath $repoName $suiteNames $mapKeys $runAll)
  Check "gateSuites.$repoName is a valid, fully installed gate list (with 'status readonly')" ($gateFindings.Count -eq 0) "$($gateFindings -join '; ')"
  $lg = if ($cfg.ContainsKey('landGate')) { $cfg['landGate'] } else { $null }
  $lgCmd = if ($lg -and $lg.ContainsKey($repoName)) { "$($lg[$repoName])" } else { '' }
  Check "landGate.$repoName drives the persisted list (-RepoSuites), never a repeated literal" ($lgCmd -and $lgCmd -match '-RepoSuites' -and $lgCmd -notmatch '-Only\s') "landGate.$repoName = '$lgCmd'"
  $gl = @(Get-GateList $cfgPath $repoName)
  Note "gateSuites.$repoName ($($gl.Count)): $($gl -join ', ')"
}

# --- 6/7/8: run-all.ps1 -RepoSuites resolves, refuses nothing silently, and refuses a bad name -----
# No suite is executed: -List returns the RESOLVED names before the stage dir is even created.
function Invoke-RunAllList([string]$CfgPath, [string]$RunAllPath) {
  $prev = $env:AGENTQ_CONFIG; $env:AGENTQ_CONFIG = $CfgPath
  try { $out = @(& pwsh -NoProfile -File $RunAllPath -RepoSuites -List 2>&1 | ForEach-Object { "$_" }); [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out } }
  finally { if ($prev) { $env:AGENTQ_CONFIG = $prev } else { Remove-Item Env:AGENTQ_CONFIG -ErrorAction SilentlyContinue } }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aq-wiring-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  $persisted = @(Get-GateList $cfgPath $repoName | ForEach-Object { "$_".Trim() })
  $r = Invoke-RunAllList $cfgPath $runAll
  $got = @($r.Out | ForEach-Object { "$_".Trim() } | Where-Object { $_ -and $_ -notmatch '^(PASS|FAIL|note):' })
  Check 'run-all.ps1 -RepoSuites -List prints the persisted list, exit 0' ($r.Code -eq 0 -and $got.Count -eq $persisted.Count -and -not @(Compare-Object $persisted $got)) "exit=$($r.Code) got=$($got -join ',')"
  if ($got.Count -and ($persisted.Count -ne $got.Count -or (Compare-Object $persisted $got))) { Note "expected: $($persisted -join ',')" }

  # MUTATION 4: an unknown name in the persisted list must be refused, naming it.
  $mutCfg = Join-Path $tmp 'cfg-badname.json'
  $mc = Get-Content -LiteralPath $cfgPath -Raw
  $mc = $mc -replace '"gateSuites"', '"zzUnusedGateSuites"'
  $mc = '{ "gateSuites": { "' + $repoName + '": ["no such suite xyz"] },' + $mc.TrimStart('{')
  [IO.File]::WriteAllText($mutCfg, $mc, [Text.UTF8Encoding]::new($false))
  $r2 = Invoke-RunAllList $mutCfg $runAll
  Check 'MUTATION an unknown name in gateSuites is refused (exit 2, the name in the message)' ($r2.Code -eq 2 -and @($r2.Out | Where-Object { $_ -match 'no such suite xyz' }).Count -gt 0) "exit=$($r2.Code) out=$($r2.Out -join ' | ')"

  # No gateSuites key at all: refused, never a silent run-everything.
  $mutCfg2 = Join-Path $tmp 'cfg-nokey.json'
  [IO.File]::WriteAllText($mutCfg2, '{ "taskSlotsPerRepo": 10 }', [Text.UTF8Encoding]::new($false))
  $r3 = Invoke-RunAllList $mutCfg2 $runAll
  Check 'a config without gateSuites.<repo> is refused (exit 2), never a silent full run' ($r3.Code -eq 2 -and @($r3.Out | Where-Object { $_ -match 'gateSuites' }).Count -gt 0) "exit=$($r3.Code) out=$($r3.Out -join ' | ')"

  # MUTATION 9: a fake suite whose tool is not in the map must be DETECTED (check 1 is not vacuous).
  $tmpPs = Join-Path $tmp 'ps'
  New-Item -ItemType Directory -Force (Join-Path $tmpPs 'tests'), (Join-Path $tmpPs 'bin') | Out-Null
  $tRunAll = Join-Path $tmpPs 'tests\run-all.ps1'
  $tInstall = Join-Path $tmpPs 'install.ps1'
  Copy-Item $runAll $tRunAll; Copy-Item $install $tInstall; Copy-Item $cfgPath (Join-Path $tmpPs 'bin\agentq-config.json')
  $txt = Get-Content -LiteralPath $tRunAll -Raw
  $mutant = "  'mutant suite'   = @('-File', (Join-Path `$PSScriptRoot 'test-install-wiring.ps1'), '-Tool', (Join-Path `$bin 'no-such-tool.ps1'))"
  $txt = [regex]::Replace($txt, "(?m)^(\s*'help'\s*=.*)$", ("`$1" + "`n" + $mutant))
  [IO.File]::WriteAllText($tRunAll, $txt, [Text.UTF8Encoding]::new($false))
  $mutDrift = @(Get-MapDrift $tRunAll $tInstall)
  # The injection must be PROVEN to have happened, or the mutation proves nothing (first run: the 4-arg
  # [regex]::Replace overload does not exist, the text was unchanged, and the check passed vacuously).
  $injected = (Get-Content -LiteralPath $tRunAll -Raw).Contains('mutant suite')
  Check 'MUTATION a suite whose tool is not installed is detected' ($injected -and @($mutDrift | Where-Object { $_ -match 'no-such-tool' }).Count -gt 0) "injected=$injected drift=$($mutDrift -join '; ')"
} finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }

Write-Output "install wiring: pass=$pass fail=$fail"
if ($fail) { exit 1 }