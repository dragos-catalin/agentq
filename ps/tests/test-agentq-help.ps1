# Discoverability (2026-11-20). An agent that does not know a verb exists must learn it in ONE step.
# Before this there was no `help` verb: `agentq help` fell into `default`, dumped the 148-line comment
# header and exited 2 - which an agent reads as "the tool failed" - so an agent hunting for `land`
# burned 7 turns guessing names. This suite locks the three behaviours that fix that, plus the drift
# lock that keeps the help table and the dispatcher in step (the help table is the single source of
# truth for discovery, and a verb missing from it is a verb agents will not find).
#
# Pure output: no queue, no lease, no reap. Still runs on an isolated AGENTQ_HOME.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqhelp-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; $env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ADMISSION = '1'
$env:AGENTQ_SESSION = 'test-help'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AqRun([string[]]$a) {
  $o = @(& pwsh -NoProfile -File $Aq @a 2>&1) -join "`n"
  return [pscustomobject]@{ code = $LASTEXITCODE; out = $o }
}
try {
  # ---- the source of truth: help table vs dispatcher ------------------------------------------
  $lines = Get-Content -LiteralPath $Aq
  $hStart = ($lines | Select-String -SimpleMatch '$script:AqHelp = [ordered]@{' | Select-Object -First 1).LineNumber
  $sStart = ($lines | Select-String -SimpleMatch 'switch ($Verb.ToLowerInvariant()) {' | Select-Object -First 1).LineNumber
  Check '0 source layout found' ([bool]$hStart -and [bool]$sStart -and $hStart -lt $sStart) "h=$hStart s=$sStart"
  $hBlock = ($lines[($hStart - 1)..($sStart - 2)]) -join "`n"
  $sBlock = ($lines[($sStart - 1)..($lines.Count - 1)]) -join "`n"
  $helpKeys = @([regex]::Matches($hBlock, "(?m)^\s+'([a-z0-9-]+)' =") | ForEach-Object { $_.Groups[1].Value })
  $caseKeys = @([regex]::Matches($sBlock, "(?m)^\s+'([a-z0-9-]+)' \{") | ForEach-Object { $_.Groups[1].Value })
  Check '0a help table is non-empty' ($helpKeys.Count -ge 30) "n=$($helpKeys.Count)"
  Check '0b dispatcher parsed' ($caseKeys.Count -ge 30) "n=$($caseKeys.Count)"
  $noHelp = @($caseKeys | Where-Object { $_ -notin $helpKeys })
  $orphan = @($helpKeys | Where-Object { $_ -notin $caseKeys })
  Check '0c every verb has a help entry' ($noHelp.Count -eq 0) ("missing: " + ($noHelp -join ','))
  Check '0d every help entry is a real verb' ($orphan.Count -eq 0) ("orphan: " + ($orphan -join ','))

  # ---- 1: the index an agent reads in one step ------------------------------------------------
  $r = AqRun @('help')
  Check '1 index exits 0' ($r.code -eq 0) "exit=$($r.code)"
  $missing = @($caseKeys | Where-Object { $r.out -notmatch "(?m)^  $([regex]::Escape($_))\s" })
  Check '1b index lists every verb' ($missing.Count -eq 0) ("missing from index: " + ($missing -join ','))
  Check '1c index names the one verb to remember' ($r.out -match 'One verb to remember: run')
  Check '1d index says how to get detail' ($r.out -match 'agentq help <verb>')
  # The budget is DERIVED from the verb count. The regression this guards is the 148-line header dump,
  # not an absolute number that every new verb trips: it was a hard 72 while HEAD already rendered 76
  # lines (the scaffolding - title, group headers, blanks - is ~28 lines on its own), so adding any verb
  # failed the check for the wrong reason. entries + scaffolding + slack, so a new verb is free and a
  # reversion to the dump is still caught.
  $indexBudget = $caseKeys.Count + 30
  Check '1e index stays compact' (($r.out -split "`n").Count -le $indexBudget) "lines=$(($r.out -split "`n").Count) budget=$indexBudget (one line per verb + group headers; the old header dump was 148)"
  Check '1f index documents exit codes' ($r.out -match 'EXIT: 0 ok')

  # ---- 2: one verb's usage --------------------------------------------------------------------
  $r = AqRun @('help', 'land')
  Check '2 help land exits 0' ($r.code -eq 0) "exit=$($r.code)"
  Check '2a help land has usage+example' (($r.out -match '-Branch <topic> -Onto <dev\|main>') -and ($r.out -match 'example: agentq land'))
  $r = AqRun @('help', 'lease')
  Check '2b help lease has usage+example' (($r.out -match 'lease -Purpose') -and ($r.out -match 'example: agentq lease'))
  $r = AqRun @('help', 'run')
  Check '2c help run shows the -- split' (($r.code -eq 0) -and ($r.out -match '-- <cmd>'))

  # ---- 3/4: unknown input teaches instead of dumping ------------------------------------------
  $r = AqRun @('help', 'nosuchverb')
  Check '3 help <bogus> exits 2' ($r.code -eq 2) "exit=$($r.code)"
  Check '3a help <bogus> says no verb' ($r.out -match "no verb 'nosuchverb'")
  Check '3b help <bogus> still prints the index' ($r.out -match 'One verb to remember: run')
  $r = AqRun @('bogusverb')
  Check '4 bogus verb exits 2' ($r.code -eq 2) "exit=$($r.code)"
  Check '4a bogus verb names itself' ($r.out -match "unknown verb 'bogusverb'")
  Check '4b bogus verb points at help' ($r.out -match 'agentq help <verb>')
  Check '4c bogus verb prints the index, not the header' (($r.out -match 'One verb to remember: run') -and ($r.out -notmatch 'STAGE 0 OF THE ORCHESTRATOR') -and (($r.out -split "`n").Count -le ($indexBudget + 6))) "lines=$(($r.out -split "`n").Count) budget=$($indexBudget + 6)"

  # ---- 5: the flag spellings an agent will try ------------------------------------------------
  foreach ($f in '-h', '--help', '-?') {
    $r = AqRun @($f)
    Check "5 $f exits 0" ($r.code -eq 0) "exit=$($r.code)"
    Check "5a $f prints the index" ($r.out -match 'One verb to remember: run')
  }

  # ---- 6: a bad flag on a known verb points at its help ---------------------------------------
  $r = AqRun @('lease', '-Bogus', 'x')
  Check '6 bad flag exits 2' ($r.code -eq 2) "exit=$($r.code)"
  Check '6a bad flag points at help <verb>' ($r.out -match 'agentq help lease')

  # 7 an agent that only ever reads `status` must still learn where the rest of the tool is
  $r = AqRun @('status')
  Check '7 status ends with the help pointer' ($r.code -eq 0 -and $r.out -match '== HELP every verb \+ group: agentq help') "exit=$($r.code)"
  $r = AqRun @('status', '--json')
  Check '7a status --json stays parseable' ($r.code -eq 0 -and -not ($r.out -match '== HELP')) "exit=$($r.code)"
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
