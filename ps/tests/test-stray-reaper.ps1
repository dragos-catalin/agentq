# Liveness/drift tests for ps/bin/stray-reaper.ps1 - the machine-local litter sweeper, now a tracked
# artefact of this repo so a reinstall can restore it and a gate can reach it. The file it guards is a
# COPY of the live ~/.copilot/bin/stray-reaper.ps1 (the caller copied it byte-exact); nothing here
# executes the sweeper, because running the real thing deletes files on this machine.
#
# What must hold, and why each check is not decorative:
#   (1) the whole file PARSES (zero syntax errors) - a rules array cannot be trusted from a file that
#       does not parse;
#   (2) the $tempDirRules array LITERAL evaluates to a non-empty list of {P;H[;B]} rules and every P
#       compiles as a regex - so a hand-edit that breaks the array fails here, not at 04:50;
#   (3) each of the family patterns added by hand on 2026-11-26/27 matches a synthetic name it should
#       match AND does NOT match a legitimate sibling - the anchors are what stop `agentq-cloud-prod`
#       being reaped, so a loosened pattern must go red;
#   (4) the task name and log path the file declares are CONSISTENT with the live copy it was taken
#       from - a drift between the two is how a reinstall restores a sweeper that logs somewhere else.
# The tool path is a parameter so run-all.ps1 can point at the staged copy; the default is this checkout.
[CmdletBinding()]
param([string]$Tool = (Join-Path $PSScriptRoot '..\bin\stray-reaper.ps1'))
$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:Pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:Fail++; Write-Host "  FAIL  $name$(if ($detail) { " -- $detail" })" -ForegroundColor Red }
}

if (-not (Test-Path -LiteralPath $Tool)) { Write-Host "stray-reaper.ps1 not found at $Tool" -ForegroundColor Red; exit 2 }
$Tool = (Resolve-Path -LiteralPath $Tool).Path
$raw = Get-Content -LiteralPath $Tool -Raw

# --- (1) the file parses ---------------------------------------------------------------------------
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Tool, [ref]$tokens, [ref]$errors)
Check 'the tool parses with zero syntax errors' ($errors.Count -eq 0) "$($errors.Count) error(s): $((@($errors | ForEach-Object { $_.Message })) -join '; ')"

# --- (2) $tempDirRules evaluates to a real array of rules ------------------------------------------
# Eval with STUB time variables so the pure-data array literal {P;H[;B]} is built exactly as the
# sweeper builds it - this is what proves the array "parses", not just that the text exists.
$assign = @($ast.FindAll({ param($n)
      $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$tempDirRules'
    }, $true)) | Select-Object -First 1
Check '$tempDirRules is assigned (found in the AST)' ($null -ne $assign)
$rules = @()
if ($assign) {
  $arrayText = $assign.Right.Extent.Text
  $now = Get-Date; $cutFast = $now.AddHours(-12); $cutMin = $now.AddHours(-24)
  try { $rules = @(& ([ScriptBlock]::Create($arrayText))) }
  catch { Check 'the $tempDirRules array literal evaluates' $false $_.Exception.Message }
}
Check 'the $tempDirRules array evaluates to a non-empty rule list' ($rules.Count -ge 10) "got $($rules.Count) rule(s)"
Check 'every rule carries a non-empty P pattern string' ((@($rules | Where-Object { -not ($_.P -is [string] -and $_.P) })).Count -eq 0)
$badRx = @($rules | ForEach-Object { try { [void][regex]::new("$($_.P)"); $null } catch { "$($_.P)" } } | Where-Object { $_ })
Check 'every rule P compiles as a regex' ($badRx.Count -eq 0) "uncompilable: $($badRx -join ', ')"
$patterns = @($rules | ForEach-Object { "$($_.P)" })

# --- (3) the hand-added family patterns match their intended names, and only those -----------------
# Each entry: P is the EXACT pattern string the file must still carry; Match/NoMatch are synthetic
# %TEMP% names. A NoMatch named like a plausible real folder is the point: it proves the anchors bite.
$cases = @(
  @{ Name = 'agentq-cloud'; Key = '^agentq-cloud-'; P = '^agentq-cloud-([0-9a-f]{6}|\d{8}-\d{6}-[0-9a-f]{6})$'
    Match   = @('agentq-cloud-a1b2c3', 'agentq-cloud-20261127-120000-abcdef')
    NoMatch = @('agentq-cloud-prod', 'agentq-cloud-v2-build', 'agentq-cloud-a1b2c', 'agentq-cloud-20261127-120000-abcde') }
  @{ Name = 'stop-mutations'; Key = '^stop-mutations-'; P = '^stop-mutations-[0-9a-f]{8}$'
    Match   = @('stop-mutations-deadbeef')
    NoMatch = @('stop-mutations-notahex', 'stop-mutations-deadbeef0', 'stop-mutations-deadbee') }
  @{ Name = 'stop-rules-mutant'; Key = '^stop-rules-mutant-'; P = '^stop-rules-mutant-'
    Match   = @('stop-rules-mutant-abc123', 'stop-rules-mutant-')
    NoMatch = @('stop-rules-mutants', 'stop-rule-mutant-x') }
  @{ Name = 'codai-stop-state-test'; Key = '^codai-stop-state-test-'; P = '^codai-stop-state-test-\d+$'
    Match   = @('codai-stop-state-test-4242')
    NoMatch = @('codai-stop-state-test-4x', 'codai-stop-state-test-', 'codai-stop-state-tests-1') }
  @{ Name = 'stoptest'; Key = '^stoptest-'; P = '^stoptest-\d+$'
    Match   = @('stoptest-7')
    NoMatch = @('stoptest-7x', 'stoptest-') }
  @{ Name = 'prewarm-verb-test'; Key = '^prewarm-verb-test-'; P = '^prewarm-verb-test-'
    Match   = @('prewarm-verb-test-abc')
    NoMatch = @('prewarm-verb-testing') }
)
foreach ($c in $cases) {
  Check "the file still carries an exact '$($c.Name)' rule pattern" ($patterns -contains $c.P)
  # Test the FILE's own pattern for this family (selected by its literal prefix), not the literal in
  # this suite: a pattern loosened in the file must fail the sibling check, not just a missing one.
  $filePat = @($patterns | Where-Object { "$_".StartsWith($c.Key) }) | Select-Object -First 1
  if (-not $filePat) { Check "the file declares a '$($c.Name)' rule pattern at all" $false "no pattern starts with '$($c.Key)'"; continue }
  $rx = [regex]::new("$filePat")
  $missed = @($c.Match | Where-Object { -not $rx.IsMatch($_) })
  $wrong = @($c.NoMatch | Where-Object { $rx.IsMatch($_) })
  Check "the file's '$($c.Name)' pattern matches its intended names" ($missed.Count -eq 0) "pattern '$filePat' missed: $($missed -join ', ')"
  Check "the file's '$($c.Name)' pattern does NOT match a legitimate sibling" ($wrong.Count -eq 0) "pattern '$filePat' wrongly matched: $($wrong -join ', ')"
}

# --- (4) task name + log path are consistent with the live copy ------------------------------------
# Tokens the file declares: the scheduled-task name in its header, the log file in its -Log default.
$declared = [pscustomobject]@{
  Task = ([regex]::Match($raw, 'codai-stray-reaper')).Value
  Log  = ([regex]::Match($raw, '\.codai\\coord\\stray-reaper\.log')).Value
}
Check 'the tool declares its scheduled-task name (codai-stray-reaper)' ($declared.Task -eq 'codai-stray-reaper') "got '$($declared.Task)'"
Check 'the tool declares its log path (.codai\coord\stray-reaper.log)' ($declared.Log -eq '.codai\coord\stray-reaper.log') "got '$($declared.Log)'"

$live = Join-Path $HOME '.copilot\bin\stray-reaper.ps1'
if (Test-Path -LiteralPath $live) {
  $liveRaw = Get-Content -LiteralPath $live -Raw
  $liveDeclared = [pscustomobject]@{
    Task = ([regex]::Match($liveRaw, 'codai-stray-reaper')).Value
    Log  = ([regex]::Match($liveRaw, '\.codai\\coord\\stray-reaper\.log')).Value
  }
  Check 'the live copy declares the same task name' ($liveDeclared.Task -ceq $declared.Task) "repo '$($declared.Task)' vs live '$($liveDeclared.Task)'"
  Check 'the live copy declares the same log path' ($liveDeclared.Log -ceq $declared.Log) "repo '$($declared.Log)' vs live '$($liveDeclared.Log)'"
  # Byte-equality is the strongest form of "consistently with the live copy": the repo file IS the
  # artefact a reinstall writes back. A divergence here is exactly the drift this suite exists for.
  $hRepo = (Get-FileHash -LiteralPath $Tool -Algorithm SHA256).Hash
  $hLive = (Get-FileHash -LiteralPath $live -Algorithm SHA256).Hash
  Check 'the tracked copy is byte-identical to the live copy' ($hRepo -ceq $hLive) "repo $hRepo vs live $hLive"
} else {
  Write-Host "  note  live copy absent ($live) - only the repo copy's own declaration was checked" -ForegroundColor DarkGray
}

Write-Host "stray-reaper: $script:Pass passed, $script:Fail failed" -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
exit $(if ($script:Fail) { 1 } else { 0 })
