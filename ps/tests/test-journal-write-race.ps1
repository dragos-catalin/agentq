# Two journal/priority behaviours, both from the 2026-11-25 land failures:
#  (1) a journal write that loses a race must NOT abort the operation. A sharing violation on
#      journal.jsonl threw out of Write-Journal and killed a land pre-gate before its gate ran
#      ("land: gate failed (1) ... nothing queued, nothing pushed") while several chats held tickets.
#  (2) the land PRE-gate runs at Normal priority, like the queued land gate. Only '^land gate' was
#      matched, so 'land pregate ...' fell through to the lane default (BelowNormal) and starved.
# Prints PASS/FAIL per case, then ALL OK (exit 0) or FAILED (exit 1).
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$script:fails = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { "PASS $name $detail" } else { "FAIL $name $detail"; $script:fails++ }
}
$pwsh = (Get-Process -Id $PID).Path

# Everything this suite writes lands in a throwaway store, never the machine's own journal/queues.
$store = Join-Path ([IO.Path]::GetTempPath()) ('aq-journal-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $store | Out-Null
$journal = Join-Path $store 'journal.jsonl'
$env:AGENTQ_HOME = $store
$env:AGENTQ_NO_JOBOBJ = '1'
$repoTop = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# One `agentq run` of a trivial command, optionally while this process holds the journal EXCLUSIVELY
# for $holdMs, exactly like a second writer does in the wild. Returns the exit code.
function Invoke-AqRun([string]$purpose, [int]$holdMs) {
  $lock = $null
  if ($holdMs -gt 0) { $lock = [IO.File]::Open($journal, 'OpenOrCreate', 'ReadWrite', 'None') }
  # A failing run must SAY why: an opaque rc tells nobody anything.
  $tag = [guid]::NewGuid().ToString('N').Substring(0, 6)
  $outFile = Join-Path $store "out-$tag.txt"
  $errFile = Join-Path $store "err-$tag.txt"
  try {
    # One pre-quoted string: Start-Process -ArgumentList @(...) joins with spaces and does NOT quote,
    # so '-Purpose smoke: plain run' would arrive as three arguments (agentq then exits 2).
    $argLine = '-NoProfile -File "{0}" run -Resource smoke:journal -Purpose "{1}" -TimeoutMin 2 -- pwsh -NoProfile -Command "exit 0"' -f $Aq, $purpose
    $psi = Start-Process -FilePath $pwsh -PassThru -WindowStyle Hidden -WorkingDirectory $repoTop `
      -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ArgumentList $argLine
    if ($holdMs -gt 0) { Start-Sleep -Milliseconds $holdMs; $lock.Dispose(); $lock = $null }
  } finally { if ($lock) { $lock.Dispose() } }
  if (-not $psi.WaitForExit(90000)) { try { $psi.Kill() } catch {} ; return 99 }
  if ($psi.ExitCode -ne 0) {
    # stderr, never the pipeline: this function's return value must stay the exit code alone.
    [Console]::Error.WriteLine("--- agentq run '$purpose' rc=$($psi.ExitCode) ---")
    @(Get-Content -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue) |
      Select-Object -Last 12 | ForEach-Object { [Console]::Error.WriteLine('  | ' + $_) }
  } else {
    Remove-Item -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue
  }
  $psi.ExitCode
}
function Get-JournalRows([string]$event) {
  if (-not (Test-Path -LiteralPath $journal)) { return @() }
  $needle = '"event":"' + $event + '"'
  @(Get-Content -LiteralPath $journal | Where-Object { $_.Contains($needle) } | ForEach-Object { $_ | ConvertFrom-Json })
}

# 0) parse check on the script under test
$t = $null; $e = $null
[System.Management.Automation.Language.Parser]::ParseFile($Aq, [ref] $t, [ref] $e) | Out-Null
Check 'parse agentq.ps1' ($e.Count -eq 0) "errors=$($e.Count)"

# 1) control run: no lock, ordinary purpose. This is also the control for case 2 - the recorded
#    priority here must NOT be Normal, otherwise 'Normal' below would prove nothing.
$rc1 = Invoke-AqRun 'smoke: plain run' 0
$done1 = @(Get-JournalRows 'done')
Check 'plain run exits 0' ($rc1 -eq 0) "rc=$rc1"
Check 'plain run recorded its done line' ($done1.Count -ge 1) "rows=$($done1.Count)"
Check 'control: a non-land run is not Normal priority' (@($done1 | Where-Object { $_.priority -eq 'Normal' }).Count -eq 0) "priority=$(@($done1 | ForEach-Object { $_.priority }) -join ',')"

# 2) the same run while the journal is held exclusively: the writer must retry and the operation must
#    survive (the old code let the sharing violation out of Write-Journal and the run exited 1).
#    2500 ms is deliberate: the child's first journal write lands ~0.6-1.2 s after launch, so the
#    collision is guaranteed, while the ~4.3 s retry budget means the fixed writer loses no line.
$rc2 = Invoke-AqRun 'smoke: plain run under lock' 2500
$done2 = @(Get-JournalRows 'done')
Check 'run under a locked journal exits 0' ($rc2 -eq 0) "rc=$rc2"
Check 'run under a locked journal still recorded a done line' ($done2.Count -ge 2) "rows=$($done2.Count)"

# 3) the land pre-gate gets Normal (the queued land gate's own class)
$rc3 = Invoke-AqRun 'land pregate work/probe' 0
$done3 = @(Get-JournalRows 'done' | Where-Object { $_.purpose -eq 'land pregate work/probe' })
Check 'land pregate run exits 0' ($rc3 -eq 0) "rc=$rc3"
Check 'land pregate runs at Normal priority' (@($done3 | Where-Object { $_.priority -eq 'Normal' }).Count -eq 1) "priority=$(@($done3 | ForEach-Object { $_.priority }) -join ',')"

Remove-Item -Recurse -Force $store -ErrorAction SilentlyContinue
if ($script:fails) { "FAILED ($($script:fails))"; exit 1 }
'ALL OK'
exit 0
