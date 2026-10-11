<#
job-start — launch a long command as a REGISTERED background job, isolated from the calling terminal,
then keep working. Wait only when blocked, with wait-job.ps1 (bounded, stall detection).

  job-start.ps1 -Label 'web typecheck' -Command 'pnpm --filter web typecheck' [-Cwd <dir>] [-ExpectedMin 8] [-Repo <name>]
  job-start.ps1 -Label gate -File .copilot-tmp\gate.ps1 [-Cwd <dir>] [-ExpectedMin 20] [script args...]
  (anything after the named parameters is passed to the -File script; in-process: -ArgList @('a','b c'))

Isolation: ShellExecute + Hidden = its OWN (hidden) console and no inherited handles, so a Ctrl+C typed
or sent into a shared VS Code terminal can never reach it (the "Terminate batch job (Y/N)?" hang) and a
caller capturing our output never waits for the job; the command gets an empty stdin (no prompt blocks).
Log: <cwd>\.copilot-tmp\jobs\<id>.log (combined output, then `EXIT=<code>` and `DONE`).
Registry: <AGENTQ_HOME or ~/.codai/coord>\jobs\<id>.json (mirrored to the hub by agentq-sync).
Prints: id, pid, log, and the wait-job / jobs command lines.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
  [Parameter(Mandatory)][string]$Label,
  [string]$Command, [string]$File,
  [Parameter(ValueFromRemainingArguments)][Alias('Args')][string[]]$ArgList = @(),
  [string]$Cwd, [double]$ExpectedMin = 10, [string]$Repo, [switch]$Json
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'agentq-jobs-lib.ps1')

if (-not $Command -and -not $File) { [Console]::Error.WriteLine('job-start: -Command "<pwsh command>" or -File <script.ps1> is required'); exit 2 }
if ($Command -and $File) { [Console]::Error.WriteLine('job-start: pass -Command OR -File, not both'); exit 2 }
$Cwd = if ($Cwd) { (Resolve-Path -LiteralPath $Cwd).Path } else { (Get-Location).Path }
if ($File) { $File = (Resolve-Path -LiteralPath $(if ([IO.Path]::IsPathRooted($File)) { $File } else { Join-Path $Cwd $File })).Path }
if (-not $Repo) {
  $common = (& git -C $Cwd rev-parse --path-format=absolute --git-common-dir 2>$null)
  if ($LASTEXITCODE -eq 0 -and $common) { $Repo = (Split-Path (Split-Path $common -Parent) -Leaf).ToLowerInvariant() } else { $Repo = '' }
}

$id = New-JobId
$logDir = Join-Path $Cwd '.copilot-tmp\jobs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir "$id.log"
[IO.File]::WriteAllText($log, '', [Text.UTF8Encoding]::new($false))

# Owner = the agent's shell (our parent pwsh), so `jobs orphans` can tell when the owner is gone.
$owner = $PID
try { $pp = (Get-Process -Id $PID).Parent; if ($pp -and $pp.ProcessName -match '^(pwsh|powershell)$') { $owner = $pp.Id } } catch { }

$display = if ($File) { (@("-File `"$File`"") + @($ArgList | ForEach-Object { "$_" })) -join ' ' } else { $Command }
Save-Job @{
  id = $id; label = $Label; command = $display; file = $(if ($File) { $File } else { $null }); args = @($ArgList)
  cwd = $Cwd; repo = $Repo; pid = 0; pidStart = $null; log = $log; expectedMin = $ExpectedMin
  startedAt = (Get-JobIso ([DateTime]::UtcNow)); state = 'running'; ownerPid = $owner; host = $env:COMPUTERNAME
  exitCode = $null; endedAt = $null
}
$runner = Join-Path $PSScriptRoot 'job-run.ps1'
# ShellExecute + Hidden: the runner gets its OWN hidden console and inherits NO handles. Inheriting our
# stdout (Start-Process with any -Redirect* uses CreateProcess with inheritance) made a caller that
# captures job-start's output block until the job ENDED (measured: 10 s job -> 10 s job-start). With
# no shared console a foreign Ctrl+C cannot reach it; job-run gives its child an empty stdin.
$psi = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
$psi.UseShellExecute = $true; $psi.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden; $psi.WorkingDirectory = $Cwd
foreach ($a in '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-Id', $id) { $psi.ArgumentList.Add($a) }
$p = [Diagnostics.Process]::Start($psi)
$ticks = try { $p.StartTime.ToUniversalTime().Ticks } catch { $null }
Update-Job $id @{ pid = $p.Id; pidStart = $ticks }

$wait = Join-Path $PSScriptRoot 'wait-job.ps1'
$jobs = Join-Path $PSScriptRoot 'jobs.ps1'
if ($Json) { [ordered]@{ id = $id; pid = $p.Id; log = $log } | ConvertTo-Json -Compress; exit 0 }
"job   $id  ($Label)"
"pid   $($p.Id)"
"log   $log"
"wait  pwsh -NoProfile -File `"$wait`" -JobId $id      # bounded (<=10 min); only when blocked"
"list  pwsh -NoProfile -File `"$jobs`" list"
'Keep working on independent items now; wait only when everything left depends on this job.'
