# TASK 3 (2026-11-26): a `[string[]]`-style parameter that reached agentq through `pwsh -File` as ONE
# comma-containing element must be REFUSED, not silently matched against.
# `pwsh -NoProfile -File agentq.ps1 -Repo a,b` does not build an array: PowerShell's `-File` binder hands
# the whole `a,b` token to the parameter as one string, so the verb looks up a repo literally named "a,b"
# and prints nothing - which reads as "no such work" rather than "your value is nonsense". Two documented
# round trips died on exactly this (codai scripts/ops/forensics/README.md: `dead-leases.ps1 -Repo a,b`
# printed `0 lease(s), 0 DEAD`). The suite pins BOTH directions:
#   A. the guard refuses every single-value identity parameter, names the flag and the fix, exit 2;
#   B. it does NOT refuse the flags where a comma is legitimate - the list flags (-Paths/-Claims/-Also/-Only)
#      and the free-text ones (-Purpose/-Message/-Reason) - so the guard can never cost a real run.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqcomma-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; $env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_SESSION = 'test-comma'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
# The REFUSAL is about the PARSE, so it must be observed as a real `pwsh -File` call (`-Command`/in-process
# calls expand a comma list into a real array and never hit the trap).
function AqFile {
  param([string[]]$A)
  $o = @(& pwsh -NoProfile -File $Aq @A 2>&1 | ForEach-Object { "$_" })
  $script:code = $LASTEXITCODE
  $o -join "`n"
}
$commaMsg = 'got ONE value containing a comma'

try {
  # ---- A. refused: the identity parameters -Repo and -Slot are the two the readers actually use
  $o = AqFile @('status', '-Repo', 'a,b')
  Check 'A1 -Repo a,b is refused (exit 2)' ($code -eq 2) "$code | $o"
  Check 'A2 the refusal names the flag' ($o -match $commaMsg -and $o -match '-Repo') $o
  Check 'A3 the refusal says the value can never match' ($o -match 'can never match anything') $o
  Check 'A4 the refusal gives the fix' ($o -match 'once per value' -and $o -match '-Paths/-Claims/-Also/-Only') $o

  $o = AqFile @('status', '-Slot', 'task-1,task-2')
  Check 'A5 -Slot a,b is refused and named' ($code -eq 2 -and $o -match $commaMsg -and $o -match '-Slot') "$code | $o"

  $o = AqFile @('who', '-Branch', 'x,y')
  Check 'A6 -Branch a,b is refused and named' ($code -eq 2 -and $o -match $commaMsg -and $o -match '-Branch') "$code | $o"

  # ---- B. NOT refused: the form the message tells you to use (one value per occurrence)
  $o = AqFile @('status', '-Repo', 'a', '-Repo', 'b')
  Check 'B1 the sanctioned per-value form is not refused' (-not ($o -match $commaMsg)) "$code | $o"

  # ---- B. NOT refused: free text, where a comma is legitimate
  $o = AqFile @('status', '-Purpose', 'a,b')
  Check 'B2 free text (-Purpose) with a comma is not refused' (-not ($o -match $commaMsg)) "$code | $o"
  $o = AqFile @('feedback', '-Kind', 'note', '-Message', 'a,b')
  Check 'B3 -Message with a comma is not refused' (-not ($o -match $commaMsg)) "$code | $o"

  # ---- B. NOT refused: the list flags still split a comma list (the -File path that -Paths documents)
  $repo = Join-Path $tmp 'repo'
  git init -q -b main $repo
  foreach ($n in 'a', 'b') { [IO.File]::WriteAllText("$repo\$n.txt", "$n`n") }
  git -C $repo add -A; git -C $repo commit -qm init
  Push-Location $repo
  try {
    [IO.File]::AppendAllText("$repo\a.txt", "x`n"); [IO.File]::AppendAllText("$repo\b.txt", "x`n")
    $o = AqFile @('commit', '-Purpose', 'comma list', '-Message', 'chore: comma list', '-Paths', 'a.txt,b.txt', '-NoPush')
    $committed = @(git -C $repo show --name-only --format= HEAD | Where-Object { $_ })
    Check 'B4 -Paths a,b still commits BOTH paths (not refused, still splitting)' (($committed -join ',') -eq 'a.txt,b.txt') "$code | $committed | $o"
  } finally { Pop-Location }

  # ---- B. NOT refused: -Only (doctor) is a list flag too, and must never be reported as the comma trap
  $o = AqFile @('doctor', '-Only', 'nosuch-a,nosuch-b', '-Quiet')
  Check 'B5 -Only a,b is not reported as the comma trap (it is a list flag)' (-not ($o -match $commaMsg)) "$code | $o"
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
