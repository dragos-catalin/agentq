# resident-ensure.ps1 - make sure a resident hook server is listening; optionally REPLACE a running one.
#
# Why this file exists: the resident server hosts hook-pre.ps1 IN-PROCESS and reads the guard text ONCE
# at startup, so a change to hook-pre.ps1 or to the server itself does nothing until the server is
# replaced. That staleness is exactly how the `startMs` defect (the server recording its own uptime as
# the call's start, read by `agentq slo` as 318 162 h/day) outlived a first fix attempt. The launcher
# used to live only inside the installed session-start.ps1; it is here so it is version-controlled and
# so `install.ps1` can reuse it to restart the server after a code change.
#
# Silent by default (session-start.ps1 calls it and ANY stdout would corrupt the hook's JSON reply).
# Pass -Restart to stop the running server and start a fresh one; that mode prints one status line,
# which install.ps1 shows.
[CmdletBinding()]
param([switch]$Restart)
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$client = Join-Path $here 'hookc.exe'
$srv = Join-Path $here 'resident-server.ps1'
$pipe = 'codai-hookc'

# The client is a compiled artifact (build-client.ps1); without it the harness command is the classic
# `powershell.exe -File hook-pre.ps1`, which is exactly what ran before the resident path existed.
if (-not (Test-Path -LiteralPath $client)) {
    if ($Restart) { "resident: no client at $client - nothing to do" }
    return
}
if (-not (Test-Path -LiteralPath $srv)) {
    if ($Restart) { "resident: missing $srv" }
    return
}

# CIM, not Get-Process: Get-Process exposes NO CommandLine in pwsh 7, so such a filter matches nothing
# and would start a duplicate server (measured 2026-11-25). Match on the server path.
function Stop-ResidentServer {
    $needle = $srv.ToLowerInvariant()
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { "$($_.CommandLine)".ToLowerInvariant().Contains($needle) })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
# An existing pipe IS the condition: something is already listening on it.
function Test-HookPipe {
    @([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -like "*$pipe*" }).Count -gt 0
}

if ($Restart) {
    Stop-ResidentServer
    Start-Sleep -Milliseconds 300
} elseif (Test-HookPipe) {
    return
}

Start-Process pwsh -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $srv, '-GuardName', 'hook-pre.ps1', '-PipeName', $pipe, '-HostMode', 'subst') -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
if ($Restart) { "resident: started a fresh hook server on \\\\.\\pipe\\$pipe" }
