<#
.SYNOPSIS
  Run agentq's gate suites ON a devcloud pool workspace, by repo key - never by directory name.

.DESCRIPTION
  The remote half of `ps/devcloud/gate.ps1` (agentq's land gate). agentq ships a workspace a bundle of
  the commits plus a patch of the working tree, and the runner builds the checkout with `git init` +
  `git fetch <bundle> HEAD:refs/devcloud/in/<job>` + `git checkout --detach <sha>`. Such a checkout
  has no `origin` remote and no tags, and its git COMMON dir is `<checkout>/.git`, so `run-all.ps1
  -RepoSuites` derives the repo key from that common dir as the leaf of its parent - the CHECKOUT
  DIRECTORY's name, not `agentq` - and exits 2 with `no gateSuites.<name>`.

  This script takes the repo key EXPLICITLY (`-RepoKey agentq`), reads `gateSuites.<RepoKey>` from
  THIS checkout's own `ps/bin/agentq-config.json` (the tree under test), and fails LOUDLY (non-zero)
  when the key is missing or empty, so a wrong key can never be mistaken for a green gate. It then
  runs those suites through `run-all.ps1 -Only <list>` and returns run-all's exit code.

  Examples (on the workspace, cwd = the checkout):
    pwsh -NoProfile -File ps/devcloud/pool-suites.ps1 -RepoKey agentq
    pwsh -NoProfile -File ps/devcloud/pool-suites.ps1 -RepoKey agentq -List
    pwsh -NoProfile -File ps/devcloud/pool-suites.ps1 -RepoKey agentq -Parallel 8

.PARAMETER RepoKey
  The `gateSuites.<RepoKey>` key to run. Required - the whole point is that it is named, not derived.

.PARAMETER Parallel
  Suites to run at once, passed to run-all.ps1 (1..16). Default 4.

.PARAMETER List
  Print the resolved suite names and exit 0 without running anything.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RepoKey,
    [int]$Parallel = 4,
    [switch]$List
)
$ErrorActionPreference = 'Continue'

# ps/devcloud/pool-suites.ps1 -> the repo root is two levels up: this IS the checkout under test.
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cfgPath = Join-Path $root 'ps/bin/agentq-config.json'
if (-not (Test-Path -LiteralPath $cfgPath)) {
    "AGENTQ-POOL-SUITES: no config at $cfgPath - refusing (this checkout is not agentq's tree)."
    exit 2
}
$cfg = $null
try { $cfg = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json -AsHashtable }
catch { "AGENTQ-POOL-SUITES: cannot parse $cfgPath ('$($_.Exception.Message)') - refusing."; exit 2 }
$gs = if ($cfg -is [Collections.IDictionary] -and $cfg.ContainsKey('gateSuites')) { $cfg['gateSuites'] } else { $null }
$gateList = @()
if ($gs -is [Collections.IDictionary] -and $gs.ContainsKey($RepoKey)) {
    $gateList = @($gs[$RepoKey] | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}
if (-not $gateList.Count) {
    "AGENTQ-POOL-SUITES: no gateSuites.$RepoKey in $cfgPath - refusing to run a gate with no suites. (This is the loud failure the checkout directory name would otherwise hide.)"
    exit 2
}
"AGENTQ-POOL-SUITES: gateSuites.$RepoKey = $($gateList.Count) suites: $($gateList -join ', ')"
if ($List) { exit 0 }

$runAll = Join-Path $root 'ps/tests/run-all.ps1'
if (-not (Test-Path -LiteralPath $runAll)) { "AGENTQ-POOL-SUITES: no $runAll - refusing."; exit 2 }
# -LogDir: run-all.ps1 writes one FULL log per suite under this dir. Without it they go to a
# per-run %TEMP% stage dir that run-all.ps1:484 deletes at the end, so a flaky suite could not
# be diagnosed from jobs/<id>/log (2026-11-27: `guard format` failed ~40% of pool runs, reason
# unreadable). We keep the logs, and echo a suite's log into STDOUT when it FAILED or when its
# capture is EMPTY - stdout IS streamed to jobs/<id>/log, so the evidence outlives the VM. The
# EMPTY case is the field signature that an exit-code-only check cannot see: `guard format` came
# back with a blank log one run in 54, so neither a FAIL line nor a failed-suite tail existed to
# echo - only the suite NAME survived. No devcloud-side change needed.
$poolLogDir = Join-Path ([IO.Path]::GetTempPath()) ('aq-pool-logs-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
# -TimeoutMin: a WEDGED suite must not hold a pool slot until the infrastructure timeout. Measured
# 2026-11-27 (per-suite table of a full pool run): apart from the 900 s lease-reuse wait that agentq
# itself now fixes, the slowest suite is 60 s and the whole 16-suite run finishes in < 2 min, so 20 min
# is ~10x the honest worst case and only fires on a real wedge. Bounded, so it is a report and not a
# silent hold; a suite that hits it is reported as failed with its log (the -LogDir block below).
# run-all's own stdout is TEE'd (the lines still reach stdout live, one at a time) so the per-suite
# verdicts are readable afterwards: it prints one `<name> exit=N pass=N fail=N sec=N` line per suite
# and a final `FAILED: <names>`. That names the suites that FAILED, which is what lets a failure whose
# .log carries no `FAIL` token still be echoed below. $rc remains run-all's exit code, unchanged.
$runLines = [System.Collections.Generic.List[string]]::new()
& pwsh -NoProfile -File $runAll -Only ($gateList -join ',') -Parallel $Parallel -TimeoutMin 20 -LogDir $poolLogDir |
  ForEach-Object { $runLines.Add("$_"); $_ }
$rc = $LASTEXITCODE
# A log file per suite that RAN, named by run-all's own Get-SuiteLog sanitisation ([^A-Za-z0-9._-]+ -> '-'),
# so run-all's suite KEY maps onto the file name exactly. Collect the FAILED ones by name (with exit code
# when run-all printed it) so the echo decision does not depend on the .log happening to hold a FAIL line.
function Get-PoolLogName([string]$Name) { (($Name.Trim() -replace '[^A-Za-z0-9._-]+', '-') + '.log') }
$failed = @{}
foreach ($ln in @($runLines)) {
  $s = "$ln"
  $m = [regex]::Match($s, '^\s*(.+?)\s+exit=(-?\d+)\s+pass=\d+\s+fail=(\d+)\s+sec=\d+\s*$')
  if ($m.Success -and ([int]$m.Groups[2].Value -ne 0 -or [int]$m.Groups[3].Value -gt 0)) {
    $failed[(Get-PoolLogName $m.Groups[1].Value)] = [int]$m.Groups[2].Value
  }
  $f = [regex]::Match($s, '^FAILED:\s*(.+?)\s*$')
  if ($f.Success) {
    foreach ($n in @($f.Groups[1].Value -split ',')) {
      if ("$n".Trim()) { $k = (Get-PoolLogName $n); if (-not $failed.ContainsKey($k)) { $failed[$k] = $null } }
    }
  }
}
$echoed = @{}
if (Test-Path -LiteralPath $poolLogDir) {
  foreach ($lf in @(Get-ChildItem -LiteralPath $poolLogDir -Filter *.log -ErrorAction SilentlyContinue | Sort-Object Name)) {
    if ($echoed.ContainsKey($lf.Name)) { continue }   # a suite is echoed at most once
    $body = @(Get-Content -LiteralPath $lf.FullName -ErrorAction SilentlyContinue)
    $nf = @($body | Where-Object { $_ -match '^\s*FAIL\b' }).Count
    $isEmpty = -not @($body | Where-Object { "$_".Trim() }).Count
    $isFailed = $failed.ContainsKey($lf.Name) -or $nf -gt 0
    if (-not $isFailed -and -not $isEmpty) { continue }   # a green suite with output is never dumped
    $echoed[$lf.Name] = $true
    $code = $failed[$lf.Name]
    $tag = if ($nf) { "FAIL=$nf" }
         elseif ($isEmpty) { "FAIL=0, EMPTY capture" }
         elseif ($null -ne $code) { "FAIL=0, exit=$code" }
         else { "FAIL=0" }
    "AGENTQ-POOL-SUITES: ---- $($lf.Name) ($tag) ----"
    if ($isEmpty) {
      "AGENTQ-POOL-SUITES: <the suite produced NOTHING on stdout or stderr; $($lf.Name) is empty - this is the silent-failure signature that leaves no other trace in jobs/<id>/log>"
    } else {
      @($body) | Select-Object -Last 200 | ForEach-Object { $_ }
    }
    "AGENTQ-POOL-SUITES: ---- end $($lf.Name) ----"
  }
  Remove-Item -LiteralPath $poolLogDir -Recurse -Force -ErrorAction SilentlyContinue
}
exit $rc
exit $LASTEXITCODE
