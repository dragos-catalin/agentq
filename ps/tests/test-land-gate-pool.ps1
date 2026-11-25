# 2026-11-25: the anti-regression ratchet for POOL-delegating land gates.
#
# agentq's own land gate ran `run-all.ps1 -RepoSuites -Parallel 4` on THIS workstation and was measured
# at 2160 s (36 min) of CPU for 26 suites (`TOTAL sec=2160 suites=26 failed=0`) - the last big local
# consumer in the land flow. It was moved to the devcloud pool. A ratchet is needed because a NEW repo
# can quietly acquire a land gate that runs an expensive local command, exactly as agentq's had, and
# nothing notices until the machine is busy again.
#
# Every `landGate.<repo>` in bin/agentq-config.json must therefore be either
#   (i)  present in tests/land-gate-pool.allow.json with a one-line reason, or
#   (ii) recognisably pool-delegating: its command names a wrapper under ps/devcloud/,
#        scripts/devcloud/ or infra/devcloud/, or a tool/*cloud* wrapper.
# Anything else FAILS. `_comment_*` keys are documentation and are skipped.
#
# Read-only and offline: it parses one JSON file and one allow-list and runs nothing. Non-vacuity is
# proven by two internal MUTATIONS - a bare local command injected into a temp copy of the config must
# be DETECTED, and the same command must pass once the repo is allow-listed (so (i) is consulted).
#
# Exit: 0 every landGate is accounted for, 1 at least one is not. Summary line `pass=N fail=N`.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$Ps = (Join-Path $PSScriptRoot '..'),
    [string]$Allow = (Join-Path $PSScriptRoot 'land-gate-pool.allow.json')
)
$ErrorActionPreference = 'Continue'
$pass = 0; $fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Output "PASS $Name" } else { $script:fail++; Write-Output "FAIL $Name$(if ($Detail) { ' - ' + $Detail })" }
}
function Note([string]$Text) { Write-Output "note: $Text" }

$psRoot = (Resolve-Path -LiteralPath $Ps).Path
$cfgPath = Join-Path $psRoot 'bin\agentq-config.json'

# A land gate is pool-delegating when its command names a wrapper in one of the pool directories, or a
# `tool/*cloud*` wrapper. Written as the RULE, not as a list of today's paths.
$poolRx = '(?i)(^|[\s\\/])(ps|scripts|infra)[\\/]devcloud[\\/]|[\s\\/]tool[\\/][^\s\\/]*cloud'
function Test-PoolDelegating([string]$Cmd) { [bool]($Cmd -and ($Cmd -match $poolRx)) }

function Read-Json([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable } catch { return $null }
}

# Evaluate one landGate map against one allow-list: one finding per repo the rule rejects.
function Get-LandGateFindings($LandGate, $AllowMap, [bool]$SkipAllow) {
    $f = @()
    if (-not ($LandGate -is [Collections.IDictionary])) { return @('landGate is not a map') }
    foreach ($k in @($LandGate.Keys | Sort-Object)) {
        if ("$k".StartsWith('_')) { continue }   # `_comment_*` keys document the block; they are not repos
        $cmd = "$($LandGate[$k])"
        if (-not $cmd.Trim()) { $f += "$k : the landGate entry is empty"; continue }
        if (Test-PoolDelegating $cmd) { continue }
        if (-not $SkipAllow -and $AllowMap -is [Collections.IDictionary] -and $AllowMap.ContainsKey($k) -and "$($AllowMap[$k])".Trim()) { continue }
        $f += "$k : not pool-delegating and not allow-listed ('$cmd')"
    }
    @($f)
}

# --- the config and the allow-list ----------------------------------------------------------------
$cfg = Read-Json $cfgPath
Check "the config is readable ($cfgPath)" ($null -ne $cfg)
if (-not $cfg) { Write-Output "land gate pool: pass=$pass fail=$fail"; exit 1 }

$landGate = if ($cfg -is [Collections.IDictionary] -and $cfg.ContainsKey('landGate')) { $cfg['landGate'] } else { $null }
Check 'landGate is a map in the config' ($landGate -is [Collections.IDictionary])
# Anti-vacuity: the rule below can only fail if there were entries to judge. Six is the 2026-11-25 count.
$repos = @(if ($landGate -is [Collections.IDictionary]) { $landGate.Keys | Where-Object { -not "$_".StartsWith('_') } })
Check 'the landGate repos are readable (not an empty match)' ($repos.Count -ge 6) "found $($repos.Count)"

$allowDoc = Read-Json $Allow
Check "the allow-list is readable ($Allow)" ($null -ne $allowDoc)
$allowMap = if ($allowDoc -is [Collections.IDictionary] -and $allowDoc.ContainsKey('allow')) { $allowDoc['allow'] } else { $null }
Check 'the allow-list has an allow map' ($allowMap -is [Collections.IDictionary])
if ($allowMap -is [Collections.IDictionary]) {
    # Every allow-listed repo must say WHY - an entry without a reason is not an exception, it is a habit.
    $empty = @($allowMap.Keys | Where-Object { -not "$($allowMap[$_])".Trim() })
    Check 'every allow-listed repo carries a one-line reason' ($empty.Count -eq 0) "$($empty -join ', ')"
}

# --- the rule, on the real config ------------------------------------------------------------------
$findings = @(Get-LandGateFindings $landGate $allowMap $false)
Check "every landGate.<repo> is pool-delegating or allow-listed ($($repos.Count) repos)" ($findings.Count -eq 0) ($findings -join '; ')
foreach ($f in $findings) { Note "unaccounted land gate: $f" }

# A stale allow-list entry (no such landGate key) is a smell, not a failure: the allow-list also carries
# the fifteen frontiers repos, which the canonical config does not name yet (the live config does).
if ($allowMap -is [Collections.IDictionary]) {
    $repoSet = @{}; foreach ($r in $repos) { $repoSet["$r"] = $true }
    $stale = @($allowMap.Keys | ForEach-Object { "$_" } | Where-Object { -not $repoSet.ContainsKey($_) } | Sort-Object)
    if ($stale.Count) { Note "$($stale.Count) allow-list entr$(if ($stale.Count -eq 1) { 'y' } else { 'ies' }) match no landGate key here (stale, or repos the canonical config does not name yet): $($stale -join ', ')" }
}

# --- the staged pool gate exists (the flip in landGate.agentq needs a target) ----------------------
foreach ($rel in 'devcloud\gate.ps1', 'devcloud\pool-suites.ps1') {
    Check "the staged pool gate file exists: ps\$rel" (Test-Path -LiteralPath (Join-Path $psRoot $rel))
}

# --- MUTATION: a bare local command must be DETECTED (the rule is not vacuous) ---------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aq-lgpool-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
    $raw = Get-Content -LiteralPath $cfgPath -Raw
    # A SENTINEL, not a plausible command: if the mutant were something a real config could already
    # contain (e.g. `pnpm lint`), the injected text would equal the original and the anti-vacuity check
    # below would fail for the wrong reason. `zz-mutation-bare-local` cannot appear in a real gate.
    $sentinel = 'zz-mutation-bare-local-command'
    $mutText = [regex]::Replace($raw, '"brivio"\s*:\s*"[^"]*"', ('"brivio": "' + $sentinel + '"'))
    $injected = $mutText -ne $raw -and $mutText.Contains('"brivio": "' + $sentinel + '"')
    $mutPath = Join-Path $tmp 'cfg-mut.json'
    [IO.File]::WriteAllText($mutPath, $mutText, [Text.UTF8Encoding]::new($false))
    $mutCfg = Read-Json $mutPath
    Check 'MUTATION injected (a bare local command replaced landGate.brivio)' ($injected -and $null -ne $mutCfg) "injected=$injected"
    $mutFind = @(Get-LandGateFindings $mutCfg['landGate'] $allowMap $false)
    Check 'MUTATION a bare local landGate is DETECTED (red)' (@($mutFind | Where-Object { $_ -match '^brivio ' }).Count -eq 1) "findings=$($mutFind -join '; ')"

    # And the allow-list is CONSULTED: the same bare command passes once the repo is excepted with a reason.
    $allowOne = @{ 'brivio' = 'mutation: proves branch (i) is consulted' }
    $mutFind2 = @(Get-LandGateFindings $mutCfg['landGate'] $allowOne $false)
    Check 'MUTATION the same bare landGate PASSES once allow-listed with a reason' (@($mutFind2 | Where-Object { $_ -match '^brivio ' }).Count -eq 0) "findings=$($mutFind2 -join '; ')"
    # ...and a reasonless exception is NOT an exception.
    $mutFind3 = @(Get-LandGateFindings $mutCfg['landGate'] @{ 'brivio' = '   ' } $false)
    Check 'MUTATION an allow-list entry with a blank reason does NOT except it' (@($mutFind3 | Where-Object { $_ -match '^brivio ' }).Count -eq 1) "findings=$($mutFind3 -join '; ')"
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "land gate pool: pass=$pass fail=$fail"
if ($fail) { exit 1 } else { Write-Output 'ALL PASS'; exit 0 }
