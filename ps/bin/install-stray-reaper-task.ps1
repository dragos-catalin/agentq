<#
.SYNOPSIS
  (Re)register the codai-stray-reaper scheduled task.

.WHY THIS EXISTS
  stray-reaper.ps1 lives only in ~/.copilot/bin, which is NOT a git repo and is not backed up, so a
  lost task definition had no way back: the original registration was a hand-typed schtasks command
  and the task body (the hidden-run.vbs wrapper) is not recoverable from the script itself. This file
  is that missing half. Run it after restoring the script, or to change the schedule.

.NOTES
  The console EXE must be launched through wscript + hidden-run.vbs: a scheduled task whose action is
  pwsh.exe directly flashes a console window on every run under an Interactive logon, even with
  -WindowStyle Hidden and the task's own Hidden flag.
#>
[CmdletBinding()]
param(
  [string]$Time = '04:50',
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$reaper = Join-Path $env:USERPROFILE '.copilot\bin\stray-reaper.ps1'
$helper = Join-Path $env:USERPROFILE '.copilot\bin\scratch-dir.ps1'
$vbs = 'E:\gh\vmui\scripts\hidden-run.vbs'
$pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe' }

foreach ($p in @($reaper, $helper)) {
  if (-not (Test-Path -LiteralPath $p)) { throw "missing: $p" }
}
if (-not (Test-Path -LiteralPath $vbs)) { throw "missing launcher: $vbs (the console-flash wrapper)" }
if (-not (Test-Path -LiteralPath $pwsh)) { throw "missing pwsh: $pwsh" }

$tr = 'wscript.exe "{0}" "{1}" -NoProfile -ExecutionPolicy Bypass -File "{2}"' -f $vbs, $pwsh, $reaper
Write-Host "task to run:`n  $tr"

if ($WhatIf) { Write-Host '(WhatIf: not registering)'; return }

& schtasks.exe /Create /TN codai-stray-reaper /SC DAILY /ST $Time /RU $env:USERNAME /F /TR $tr | Out-String | Write-Host

# Read the definition back: /Create reporting SUCCESS says nothing about what was stored.
$back = (& schtasks.exe /query /tn codai-stray-reaper /v /fo list 2>&1) -join "`n"
foreach ($k in 'Task To Run', 'Schedule Type', 'Start Time', 'Run As User', 'Status') {
  $line = ($back -split "`r?`n" | Where-Object { $_ -match "^\s*$([regex]::Escape($k))" } | Select-Object -First 1)
  if ($line) { Write-Host $line.Trim() }
}
if ($back -notmatch [regex]::Escape($reaper)) { throw 'read-back does not name the reaper script - registration did not land' }
Write-Host 'OK: codai-stray-reaper registered and read back.'
