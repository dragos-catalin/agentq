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
    [string]$Allow = (Join-Path $PSScriptRoot 'land-gate-pool.allow.json'),
    [string]$V2 = (Join-Path $PSScriptRoot '..\bin\agentq-v2.ps1')
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

# --- the pool gate KEEPS the per-suite logs (2026-11-27) -------------------------------------------
# run-all.ps1 writes one FULL log per suite under -LogDir, or - when -LogDir is absent - under a
# %TEMP%\aq-runall-<6hex> stage dir that run-all.ps1:484 deletes at the end. So WITHOUT -LogDir the
# per-suite logs never leave the pool and only the summary lines Report-Suite prints reach
# jobs/<id>/log. That is exactly why `guard format` could fail ~40% of pool runs on 2026-11-27
# (`FAIL warn cargo fmt (no rustfmt.toml)`) and still not be diagnosable: the guard's own output
# lived in a file deleted with the job. The wrapper must therefore pass -LogDir AND echo the FAILED
# suites' logs into STDOUT (stdout is what streams to jobs/<id>/log). Written as the RULE, not as a
# copy of today's code.
$poolPath = Join-Path $psRoot 'devcloud\pool-suites.ps1'
$poolText = if (Test-Path -LiteralPath $poolPath) { Get-Content -LiteralPath $poolPath -Raw } else { '' }
Check 'pool-suites passes a -LogDir to run-all (the per-suite logs outlive the job)' ($poolText -match '(?m)-LogDir\s+\$\w+')
Check 'pool-suites echoes the FAILED suites own logs into stdout (the streaming channel)' (($poolText -match '(?m)-Filter\s+\*\.log') -and ($poolText -match 'AGENTQ-POOL-SUITES: ----'))

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

# --- WHERE THE WRAPPER RUNS, not just where the work runs (class #3, 2026-11-26) -------------------
# The rule above answers "does this gate delegate its WORK to the pool". This one answers a second,
# independent question: does the WRAPPER itself run on a host that can execute it. Getting the first
# right and the second wrong is what held land:codai for hours on 2026-11-26: agentq forced
# AGENTQ_WHERE=auto, run-build.ps1 (which carries no platform knowledge of the workspace) shipped the
# PowerShell wrapper to ws-codai, Linux answered `exit 64` in 0.1 s, and agentq - reading 64 as a
# PRE-gate failure - quarantined every topic before a land ticket existed. Invoke-GateRun now asks
# Get-GateRunWhere; this ratchet keeps that honest for a repo that acquires a PowerShell gate later.
# The host set is written HERE as an independent literal, so removing a host from the helper (or
# classifying it as `auto`) turns this suite red instead of silently reopening the hole.
$winHosts = @('pwsh', 'powershell', 'powershell_ise', 'cmd')
Check 'the Windows-only host set is non-trivial (4 hosts)' ($winHosts.Count -ge 4) "count=$($winHosts.Count)"

# One finding per landGate whose classification disagrees with its first token. `$Classify` is injected
# so the rule can be mutated in-process (a checker that cannot fail is not a check).
function Get-GatePlacementFindings($LandGate, $Classify) {
    $f = @()
    if (-not ($LandGate -is [Collections.IDictionary])) { return @('landGate is not a map') }
    foreach ($k in @($LandGate.Keys | Sort-Object)) {
        if ("$k".StartsWith('_')) { continue }
        $cmd = "$($LandGate[$k])".Trim()
        if (-not $cmd) { continue }   # an empty entry is the other rule's finding, not this one's
        $first = @($cmd -split '\s+' | Where-Object { $_ })[0]
        $leaf = @(($first -replace '(?i)\.(exe|cmd|bat|ps1)$', '').ToLowerInvariant() -split '[\\/]' | Where-Object { $_ })[-1]
        $want = if ($winHosts -contains $leaf) { 'local' } else { 'auto' }
        $got = "$(& $Classify $cmd)"
        if ($got -ne $want) { $f += "$k : first token '$leaf' is placed '$got' but must be '$want'" }
    }
    @($f)
}

# The rule is taken as TEXT out of the real file and evaluated in a sandbox scriptblock. Dot-sourcing
# agentq-v2.ps1 is not an option in an offline suite: the file runs top-level statements that need the
# CLI's own state and die with "Cannot bind argument to parameter 'Path' because it is null" (measured
# 2026-11-26). Extracting the function keeps this suite read-only and still tests the REAL text - if the
# function is renamed or deleted the extraction below fails closed.
$helperLoaded = $false
$probe = $null
Check "the placement helper is readable ($V2)" (Test-Path -LiteralPath $V2)
if (Test-Path -LiteralPath $V2) {
    $v2Text = Get-Content -LiteralPath $V2 -Raw
    $m = [regex]::Match($v2Text, '(?ms)^function\s+Get-GateRunWhere\b.*?^}')
    if ($m.Success) {
        try {
            # `$args[0]` is the scriptblock's own argument list, so the call needs no quoting of the
            # gate command (tokens contain spaces and backslashes).
            $probe = [ScriptBlock]::Create($m.Value + "`nGet-GateRunWhere `$args[0]")
            $helperLoaded = "$(& $probe 'pwsh -File x.ps1')" -eq 'local'
        } catch {
            Note "evaluating the extracted rule failed: $($_.Exception.Message)"
        }
    }
    else { Note "no 'function Get-GateRunWhere' in $V2 - the rule was renamed or removed" }
}
Check 'the placement rule extracted from agentq-v2.ps1 works (a pwsh gate is local)' $helperLoaded

if ($helperLoaded) {
    function Invoke-GateRunWhere([string]$Command) { "$(& $probe $Command)" }
    # The table: both sides of the rule, in the forms a gate is actually written in.
    foreach ($h in @('pwsh', 'powershell', 'PWSh.EXE', 'cmd', 'cmd.exe', 'C:\Windows\System32\cmd.exe')) {
        $dec = Invoke-GateRunWhere "$h -NoProfile -File scripts/devcloud/gate.ps1"
        Check "Get-GateRunWhere places '$h' as local" ($dec -eq 'local') "got '$dec'"
    }
    foreach ($p in @('bash', 'sh', 'pnpm', 'node')) {
        $dec = Invoke-GateRunWhere "$p scripts/devcloud/gate.sh"
        Check "Get-GateRunWhere leaves '$p' as auto (the pool may take it)" ($dec -eq 'auto') "got '$dec'"
    }
    Check "Get-GateRunWhere leaves an empty gate as auto" ((Invoke-GateRunWhere '') -eq 'auto')

    # ...and the real config must AGREE. A new repo with a `cmd /c` or a fully-qualified pwsh gate lands here.
    $place = @(Get-GatePlacementFindings $landGate { param($c) Invoke-GateRunWhere $c })
    Check "every landGate wrapper is placed for its own host ($($repos.Count) repos)" ($place.Count -eq 0) ($place -join '; ')
    foreach ($p in $place) { Note "misplaced land gate: $p" }

    # MUTATION: the checker itself must reject a wrapper placed for the wrong host, both ways round.
    $synthWin = @{ 'poolrepo' = 'pwsh -NoProfile -File scripts/devcloud/gate.ps1' }
    $m1 = @(Get-GatePlacementFindings $synthWin { param($c) 'auto' })
    Check 'MUTATION a pwsh wrapper placed auto is DETECTED (red)' (@($m1 | Where-Object { $_ -match '^poolrepo ' }).Count -eq 1) "findings=$($m1 -join '; ')"
    $m2 = @(Get-GatePlacementFindings $synthWin { param($c) 'local' })
    Check 'MUTATION the same wrapper PASSES once placed local' (@($m2 | Where-Object { $_ -match '^poolrepo ' }).Count -eq 0) "findings=$($m2 -join '; ')"
    $synthPosix = @{ 'poolrepo2' = 'bash scripts/devcloud/gate.sh' }
    $m3 = @(Get-GatePlacementFindings $synthPosix { param($c) 'local' })
    Check 'MUTATION a POSIX gate forced local is DETECTED (the rule is two-sided)' (@($m3 | Where-Object { $_ -match '^poolrepo2 ' }).Count -eq 1) "findings=$($m3 -join '; ')"
}
else {
    # Fail closed: without the helper loaded, the checks above are the ones that matter and they did not run.
    Check 'the placement rule could be evaluated (helper loaded)' $false 'agentq-v2.ps1 did not define Get-GateRunWhere'
}

# --- WHERE THE GATE QUEUES, and what a runner crash may NOT do (2026-11-26, owner) -----------------
# Two independent regressions, both measured on 2026-11-26:
#  (A) the gate queued on `build:<repo>` (cap 1) - the land lane and that repo's ordinary build lane
#      serialised against each other (one pre-gate measured 7242 s in the queue). It must queue on
#      `verify:<repo>` while STILL executing through run-build.ps1 (lock, log, wedge watch): the
#      AGENTQ_HELD pre-seed is what stops run-build from taking a second ticket.
#  (B) `exit 64` in 0.1 s - a PowerShell wrapper shipped to a Linux pool - quarantined four different
#      topics in one morning, because the exit code of the RUNNER was read as a verdict on the TREE.
#      It must journal land-pregate-infra-64, retry once with the wrapper forced LOCAL, and only the
#      second verdict may reach Set-LandQuarantine.
# Both are checked as TEXT of the real file and both carry a mutation, so flipping either back turns
# this suite red instead of silently reopening the hole.
if (-not $v2Text) { $v2Text = '' }

function Get-GateQueueFindings([string]$Text) {
    $f = @()
    $m = [regex]::Match($Text, '(?ms)^function\s+Invoke-GateRun\b.*?^}')
    if (-not $m.Success) { return @('Invoke-GateRun is gone from agentq-v2.ps1') }
    $g = $m.Value
    if ($g -notmatch '-Resource\s+"verify:\$repoName"') { $f += 'the gate does not queue on verify:<repo> (a land gate serialises against that repo''s builds again)' }
    if ($g -notmatch '"-File",|pwsh -NoProfile -File \$rb -Root \$dir') { $f += 'the gate no longer executes through run-build.ps1 (the lock, the log and the wedge watch are lost)' }
    if ($g -notmatch '"build:\$repoName"') { $f += 'AGENTQ_HELD is not pre-seeded with build:<repo>, so run-build takes a SECOND ticket in the build queue' }
    if ($g -notmatch '(?s)\$prevWhere = \$env:AGENTQ_WHERE.*?if \(-not \$prevWhere\)') { $f += 'AGENTQ_WHERE is filled unconditionally - the forced-local retry would stop working' }
    @($f)
}

$qFind = @(Get-GateQueueFindings $v2Text)
Check 'the land gate queues on verify:<repo> and still runs through run-build (no build-lane serialisation)' ($qFind.Count -eq 0) ($qFind -join '; ')
foreach ($p in $qFind) { Note "gate placement regression: $p" }

# MUTATION: put it back on build:<repo> and the same checker must go red.
$qMut = $v2Text -replace [regex]::Escape('-Resource "verify:$repoName"'), '-Resource "build:$repoName"'
$qMutFind = @(Get-GateQueueFindings $qMut)
Check 'MUTATION a build:<repo> placement is DETECTED (red)' ($qMutFind.Count -ge 1) "findings=$($qMutFind -join '; ')"
# MUTATION: a run-build invocation that no longer pre-seeds AGENTQ_HELD must also be caught.
$qMut2 = $v2Text -replace [regex]::Escape('$env:AGENTQ_HELD = (@($prevHeld, "build:$repoName")'), '$env:AGENTQ_HELD = (@($prevHeld, "x:$repoName")'
Check 'MUTATION dropping the AGENTQ_HELD pre-seed is DETECTED (red)' (@(Get-GateQueueFindings $qMut2).Count -ge 1) ''

# The exit-64 escape hatch: the retry must sit BETWEEN the 64 verdict and the quarantine block, and the
# quarantine call itself must still exist after it (otherwise `-notmatch` would pass vacuously).
$i64 = $v2Text.IndexOf('land-pregate-infra-64')
$iQ = $v2Text.IndexOf('land-pregate-quarantined')
Check 'the exit-64 escape hatch exists in the pre-gate' ($i64 -gt 0) 'no land-pregate-infra-64 journal event'
Check 'the escape hatch sits BEFORE the quarantine event (the order is what makes it an escape)' ($i64 -gt 0 -and $iQ -gt $i64) "i64=$i64 iQ=$iQ"
$win64 = if ($i64 -gt 0 -and $iQ -gt $i64) { $v2Text.Substring($i64, $iQ - $i64) } else { '' }
Check 'exit 64 in <=5 s forces AGENTQ_WHERE=local for the retry' ($win64 -match "AGENTQ_WHERE = 'local'")
# NOTE: these patterns must stay SINGLE-quoted. In a double-quoted string `\$sp` does NOT escape the
# dollar - PowerShell interpolates `$sp`/`$repo` (empty here) and the regex silently matches nothing.
Check 'exit 64 retries the pre-gate once, with the repo name' ($win64 -match 'Invoke-GateRun \$sp .*\$repo\.Name')
$iRetry = $win64.IndexOf("(retry after exit 64)")
$iSetQ = $win64.IndexOf('Set-LandQuarantine $repo.Name $Branch')
Check 'exit 64 does not fail the topic before the retry (no PregateResult = failed in the 64 block)' ($iRetry -gt 0 -and ($win64.Substring(0, $iRetry) -notmatch "PregateResult = 'failed'"))
Check 'MUTATION guard: the quarantine call exists AFTER the retry in the same window (the check above is not vacuous)' ($iSetQ -gt $iRetry -and $iRetry -gt 0) "retry@$iRetry setQ@$iSetQ"
# ...and the failure journal must NAME the member, not just the command.
Check 'a failed pre-gate journals the failing member(s) and the log path' ($v2Text -match '(?s)land-pregate-failed.{0,400}members = @\(\$script:GateFailedMembers\)')

Write-Output "land gate pool: pass=$pass fail=$fail"
if ($fail) { exit 1 } else { Write-Output 'ALL PASS'; exit 0 }
