<#
job-run — the runner job-start.ps1 launches (hidden, own console, no inherited handles). Not for
direct use. Reads the registry entry, runs its command in a child pwsh with an EMPTY stdin (EOF at
once, so no prompt can block it), appends combined
stdout+stderr to the job log line by line (open/close per line, so readers never hit a lock), then
appends `EXIT=<code>` and `DONE` and records state done|failed, exitCode, endedAt.
#>
param([Parameter(Mandatory)][string]$Id)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'agentq-jobs-lib.ps1')

$job = Read-Job $Id
if (-not $job) { exit 2 }
$log = "$($job['log'])"
$utf8 = [Text.UTF8Encoding]::new($false)
function Out-Log([string]$s) {
  for ($i = 0; $i -lt 20; $i++) { try { [IO.File]::AppendAllText($log, $s + "`n", $utf8); return } catch { Start-Sleep -Milliseconds 25 } }
}
Out-Log "=== job $Id ($($job['label'])) started $(Get-JobIso ([DateTime]::UtcNow)) pid $PID"
Out-Log "=== cwd $($job['cwd'])"
# Children inherit the creator's priority class, so lowering ours lowers the whole job tree.
$prio = if ($job['priority']) { "$($job['priority'])" } else { 'BelowNormal' }
try { (Get-Process -Id $PID).PriorityClass = [Diagnostics.ProcessPriorityClass]$prio } catch { Out-Log "job-run: priority $prio not applied: $($_.Exception.Message)" }
$code = 1
try {
  if ($job['cwd']) { Set-Location -LiteralPath "$($job['cwd'])" }
  if ($job['file']) {
    $jobArgs = @($job['args'] | Where-Object { $null -ne $_ } | ForEach-Object { "$_" })
    @() | & pwsh -NoProfile -ExecutionPolicy Bypass -File "$($job['file'])" @jobArgs 2>&1 | ForEach-Object { Out-Log "$_" }
  } else {
    # -EncodedCommand: no quoting layer between the registry string and the child parser.
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$($job['command'])"))
    @() | & pwsh -NoProfile -ExecutionPolicy Bypass -EncodedCommand $enc 2>&1 | ForEach-Object { Out-Log "$_" }
  }
  $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
} catch {
  Out-Log "job-run: $($_.Exception.Message)"
  $code = 1
}
Out-Log "EXIT=$code"
Out-Log 'DONE'
Update-Job $Id @{ state = $(if ($code -eq 0) { 'done' } else { 'failed' }); exitCode = $code; endedAt = (Get-JobIso ([DateTime]::UtcNow)) }
exit $code
