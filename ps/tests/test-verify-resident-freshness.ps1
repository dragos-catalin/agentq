# 2026-11-28: anti-regression suite for verify-resident.ps1's FRESHNESS gate.
#
# Why this file exists: the gate makes verify-resident.ps1 REFUSE to measure when the live copy of itself
# is not byte-identical to the copy in the source root (see the gate block in that script). That refusal
# is the whole value of the check, and the failure mode it guards against is not "the script prints the
# wrong number" but "the script happily prints a number about a revision nobody has" - which looks exactly
# like a green run. Nothing else in the repo would notice if the refusal disappeared, so it gets its own
# suite.
#
# The suite drives the REAL script with -CheckSource: the gate runs, and the script exits before it spawns
# a host or kills a process. That makes it safe to run on any machine and needs no compiled hookc4.exe.
# The one thing -CheckSource cannot show - that the gate runs BEFORE the first kill and the first spawn -
# is asserted statically on the source with comment lines stripped, because the prose in that file names
# those calls too and a raw-text index would match a comment instead of the call. Case 8 uses the same
# comment-stripped text for the CLIENT NAME lookup (also unreachable under -CheckSource, it happens after
# the gate): the check must ask for the name an install leaves behind, not the builder's product name.
#
# Non-vacuity: point -Script at a MUTATED copy (neutralise the comparison) and this suite must report at
# least one FAIL and exit non-zero. Case 7 performs that mutation for you on a copy in %TEMP%, so the
# suite proves itself without editing anything in the repo.
[CmdletBinding()]
param(
    [string]$Script = (Join-Path $PSScriptRoot '..\hooks\resident\verify-resident.ps1'),
    [string]$Pwsh = 'pwsh'
)

$ErrorActionPreference = 'Continue'
$pass = 0
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Output "PASS $Name" }
    else { $script:fail++; Write-Output "FAIL $Name$(if ($Detail) { ' - ' + $Detail })" }
}
function Note([string]$Text) { Write-Output "note: $Text" }
function Sha([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    $h = [Security.Cryptography.SHA256]::HashData([IO.File]::ReadAllBytes($Path))
    ([BitConverter]::ToString($h) -replace '-', '').ToLowerInvariant()
}
# Run a script for real, from a chosen working directory, and capture its exit code and its output.
function Run-Verify([string]$Path, [string[]]$Extra, [string]$Cwd) {
    $lines = @()
    $code = -1
    Push-Location $Cwd
    try {
        $lines = @(& $Pwsh -NoProfile -ExecutionPolicy Bypass -File $Path @Extra 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { Pop-Location }
    [pscustomobject]@{ code = $code; lines = @($lines | Where-Object { "$_".Trim() }); text = ($lines -join "`n") }
}

$scriptPath = (Resolve-Path -LiteralPath $Script).ProviderPath
if (-not [IO.File]::Exists($scriptPath)) {
    Write-Output "FAIL 0 the script under test exists - $scriptPath"
    Write-Output 'verify-resident freshness: pass=0 fail=1'
    exit 1
}

$liveDir = [IO.Path]::GetDirectoryName($scriptPath)
$leaf = [IO.Path]::GetFileName($scriptPath)
$liveHash = Sha $scriptPath

$root = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'aqfresh-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$mutDir = [IO.Path]::Combine($root, 'mut')
$emptyDir = [IO.Path]::Combine($root, 'empty')
$savedRepoRoot = $env:AGENTQ_REPO_ROOT
try {
    [void][IO.Directory]::CreateDirectory($mutDir)
    [void][IO.Directory]::CreateDirectory($emptyDir)

    # 1. equal hashes -> the gate is a no-op, exactly as before the guard existed
    $r1 = Run-Verify $scriptPath @('-CheckSource', '-SourceRoot', $liveDir) $emptyDir
    Check '1 identical live and source copies are NOT refused' ($r1.code -eq 0 -and $r1.text -match 'matches its source') "exit=$($r1.code) | $($r1.text)"
    Check '1 that run claims neither staleness nor an unprovable source' ($r1.text -notmatch 'STALE|CANNOT PROVE') $r1.text

    # 2. different hashes -> refusal, non-zero, ONE line naming BOTH hashes
    $mutFile = [IO.Path]::Combine($mutDir, $leaf)
    [IO.File]::WriteAllText($mutFile, ((Get-Content -LiteralPath $scriptPath -Raw) + "`n# a stale source copy differs by exactly this line`n"), [Text.UTF8Encoding]::new($false))
    $mutHash = Sha $mutFile
    Check '2 the mutated source really differs from the live copy' ($mutHash -and $mutHash -ne $liveHash) "live=$liveHash mut=$mutHash"
    $r2 = Run-Verify $scriptPath @('-CheckSource', '-SourceRoot', $mutDir) $emptyDir
    Check '2 a DIFFERENT source hash is refused with a NON-ZERO exit' ($r2.code -ne 0) "exit=$($r2.code)"
    Check '2 the refusal is exactly ONE line' ($r2.lines.Count -eq 1) "lines=$($r2.lines.Count) | $($r2.text)"
    Check '2 that line names BOTH hashes' (($r2.text -match [regex]::Escape($liveHash)) -and ($r2.text -match [regex]::Escape($mutHash))) $r2.text
    Check '2 that line says the live copy is stale' ($r2.text -match 'STALE') $r2.text

    # 3. the gate runs before anything is killed or spawned (static: comments stripped first)
    $code = ((Get-Content -LiteralPath $scriptPath) | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n"
    $iGate = $code.IndexOf('$fresh = Test-ResidentFreshness')
    $iKill = $code.IndexOf('Stop-Matched ''')
    $iSpawn = $code.IndexOf('Start-Process ')
    Check '3 the freshness gate is called before the first process kill' ($iGate -ge 0 -and $iKill -gt $iGate) "gate@$iGate kill@$iKill"
    Check '3 the freshness gate is called before the first process spawn' ($iGate -ge 0 -and $iSpawn -gt $iGate) "gate@$iGate spawn@$iSpawn"
    Check '3 the refusal exits non-zero instead of writing a verdict' ($code.Contains('exit 9')) 'exit 9 not found'

    # 4 and 5. no source copy found anywhere -> refusal, unless the escape hatch is passed
    $env:AGENTQ_REPO_ROOT = $null
    Check '4 no .source-root marker sits beside the script (precondition for cases 4 and 5)' (-not [IO.File]::Exists([IO.Path]::Combine($liveDir, '.source-root')))
    $r4 = Run-Verify $scriptPath @('-CheckSource') $emptyDir
    Check '4 finding NO source copy is a refusal (fail closed, non-zero)' ($r4.code -ne 0 -and $r4.text -match 'CANNOT PROVE') "exit=$($r4.code) | $($r4.text)"
    $r5 = Run-Verify $scriptPath @('-CheckSource', '-AllowUnprovenSource') $emptyDir
    Check '5 -AllowUnprovenSource warns loudly and CONTINUES (exit 0)' ($r5.code -eq 0 -and $r5.text -match 'WARNING') "exit=$($r5.code) | $($r5.text)"
    Check '5 the escape-hatch path prints exactly ONE line' ($r5.lines.Count -eq 1) "lines=$($r5.lines.Count) | $($r5.text)"

    # 6. cost. The cold figure includes one-time type loading and the JIT of the gate's own functions in a
    #    fresh process; the warm figure is what the check itself costs, and that is the one that is budgeted.
    $w = [regex]::Match($r1.text, '(\d+)\s*ms\s+warm')
    $c = [regex]::Match($r1.text, '(\d+)\s*ms\s+cold')
    Check '6 the gate reports its own cost, cold and warm' ($w.Success -and $c.Success) $r1.text
    Check '6 the check itself costs under 50 ms warm' ($w.Success -and [int]$w.Groups[1].Value -lt 50) "warm=$($w.Groups[1].Value) ms cold=$($c.Groups[1].Value) ms"

    # 7. self-mutation: neutralise the comparison in a COPY and show that a stale copy then passes
    $raw = Get-Content -LiteralPath $scriptPath -Raw
    $neutralised = $raw.Replace('if ($liveHash -ne $srcHash) {', 'if ($false) {')
    $applied = $neutralised -cne $raw
    $detail7 = 'skipped - the script under test has no comparison left to neutralise (it is already the mutant)'
    $ok7 = -not $applied
    if ($applied) {
        $mutScript = [IO.Path]::Combine($root, 'verify-resident.mutant.ps1')
        [IO.File]::WriteAllText($mutScript, $neutralised, [Text.UTF8Encoding]::new($false))
        $rm = Run-Verify $mutScript @('-CheckSource', '-SourceRoot', $mutDir) $emptyDir
        $detail7 = "exit=$($rm.code) | $($rm.text)"
        $ok7 = ($rm.code -eq 0) -and ($rm.text -notmatch 'STALE')
    } else { Note $detail7 }
    Check '7 MUTATION: neutralising the comparison lets a stale copy pass, so case 2 is not vacuous' $ok7 $detail7

    # 8. the CLIENT is looked up by the name an install actually leaves behind. Regression guard for
    #    2026-11-28: the script asked for `hookc4.exe` (the BUILD product name) while install.ps1's map
    #    comment, README.md, hookc4.c's own header and resident-ensure.ps1 all call the installed client
    #    `hookc.exe` - so on a normally installed machine the check aborted with "missing ... hookc4.exe"
    #    and printed NO verdict (measured: exit 1, empty stdout, thrown before the first kill). Static
    #    assertions on comment-stripped source, because -CheckSource exits before the client is resolved.
    $iInstalled = $code.IndexOf("Join-Path `$here 'hookc.exe'")
    $iBuildName = $code.IndexOf("Join-Path `$here 'hookc4.exe'")
    Check '8 the client is resolved by the INSTALLED name hookc.exe' ($iInstalled -ge 0) "index=$iInstalled"
    Check '8 the installed name is tried BEFORE the build product name' ($iInstalled -ge 0 -and $iBuildName -gt $iInstalled) "installed@$iInstalled build@$iBuildName"
    Check '8 a missing client names BOTH candidates and the builder' ($code -match 'looked for hookc\.exe and hookc4\.exe' -and $code -match 'build-client\.ps1')
    Check '8 a client older than hookc4.c is a WARNING in the verdict, not a refusal' ($code -match 'predates hookc4\.c' -and $code -match 'WARNING')
    $m8 = $code.Replace("Join-Path `$here 'hookc.exe'", "Join-Path `$here 'hookc-nope.exe'")
    $iMutant = $m8.IndexOf("Join-Path `$here 'hookc.exe'")
    Check '8 MUTATION: dropping the installed name turns case 8 red, so it is not vacuous' (($m8 -cne $code) -and $iMutant -lt 0) "applied=$($m8 -cne $code) index=$iMutant"

    # 9. the SECOND RED. Twice a threshold in this file judged the MACHINE instead of the client: first a
    #    burst-relative count (demanded 5 of 6, red at 21.7 busy cores of 32), then a pool-anchored one
    #    (`served >= instances`, red at 2/6 on the same healthy copy twenty minutes after 5/6). The rule
    #    that survived is: the host must CLAIM a pool of >= 2, and >= 2 callers must be served without a
    #    spawn (measured: pool of one serves 1/6 and 2/6, so the claim is what catches the regression).
    #    Separately, a call that fell back used to count as a PARITY failure: the client's own 71-char
    #    notice is over the 40-char diff window, so one busy instance produced two reds and printed
    #    `classic ALLOW resident ALLOW same=False`. Both are text-level contracts, so they are asserted
    #    here rather than by running (a run cannot prove a threshold is absent).
    $iConc = $code.IndexOf('$concOk = ')
    $concLine = if ($iConc -ge 0) { (($code.Substring($iConc) -split "`n")[0]).Trim() } else { '' }
    Check '9 the concurrency rule anchors on the pool CLAIM and a served floor' ($concLine -match '\$poolN -ge 2' -and $concLine -match '\$concServed -ge 2') $concLine
    Check '9 the BURST width is not part of the rule (a burst-relative count tests the machine)' ($concLine.Length -gt 0 -and $concLine -notmatch '\$cc') $concLine
    Check '9 a fallback notice is excluded from the parity comparison' ($code -match 'hookc:\.\*falling back')
    $m9 = $concLine.Replace('($poolN -ge 2) -and ', '')
    Check '9 MUTATION: dropping the pool claim turns case 9 red, so it is not vacuous' (($m9 -cne $concLine) -and ($m9 -notmatch '\$poolN -ge 2')) $m9
}
finally {
    if ($null -ne $savedRepoRoot) { $env:AGENTQ_REPO_ROOT = $savedRepoRoot }
    else { Remove-Item Env:AGENTQ_REPO_ROOT -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output "verify-resident freshness: pass=$pass fail=$fail"
if ($fail) { exit 1 } else { Write-Output 'ALL PASS'; exit 0 }
