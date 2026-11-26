# Build the resident hook client. Reproducible on purpose: the exe was first made with a one-off
# command line, so nobody could say what produced it.
#   pwsh -NoProfile -File build-client.ps1 [-Check]
# -Check compiles to a temp name and compares bytes, so drift between hookc4.c and hookc4.exe is
# detectable instead of assumed (the same class of mistake as trusting a stale binary in the installer).
[CmdletBinding()]
param([switch]$Check, [string]$Out)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$src = Join-Path $here 'hookc4.c'
$exe = if ($Out) { $Out } else { Join-Path $here 'hookc4.exe' }
$gcc = (Get-Command gcc -EA SilentlyContinue).Source
if (-not $gcc) { throw 'gcc not found on PATH (mingw-w64)' }
$target = if ($Check) { Join-Path $here ("hookc4.check.{0}.exe" -f (Get-Date -Format 'HHmmss')) } else { $exe }
# -municode: wmain(); -O2; no console window is not needed (the harness owns the console).
& $gcc -O2 -municode -Wall -Wextra -o $target $src
if ($LASTEXITCODE -ne 0) { throw "gcc failed with $LASTEXITCODE" }
if ($Check) {
    $a = (Get-FileHash $target -Algorithm SHA256).Hash
    $b = (Get-FileHash $exe -Algorithm SHA256).Hash
    Remove-Item $target -Force
    Write-Host ("source {0}  {1}" -f (Get-Item $src).LastWriteTime, (Get-Item $src).Length)
    Write-Host ("built  sha256 $a")
    Write-Host ("on disk sha256 $b")
    Write-Host ("VERDICT: {0}" -f $(if ($a -eq $b) { 'in sync' } else { 'STALE - rebuild without -Check' }))
} else {
    $i = Get-Item $target
    Write-Host ("built {0}  {1} B  {2}" -f $i.Name, $i.Length, $i.LastWriteTime)
    Write-Host ("sha256 {0}" -f (Get-FileHash $target -Algorithm SHA256).Hash)
}
