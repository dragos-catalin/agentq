# Behavioural tests for term-interrupt.ps1 with real processes: an interactive pwsh "terminal" (own
# console, -NoExit) runs a stuck command; the ladder must stop the command and leave the shell alive.
param([string]$Tool = (Join-Path (Split-Path $PSScriptRoot) 'bin\term-interrupt.ps1'))
$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('termi-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$started = [Collections.Generic.List[int]]::new()
function Alive([int]$id) { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
function Kids([int]$id) { @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$id" | Where-Object Name -notin 'conhost.exe', 'OpenConsole.exe') }
# a terminal: interactive pwsh in its own console, running $cmd as its first command
function Start-Term([string]$cmd) {
  $p = Start-Process pwsh -ArgumentList '-NoLogo', '-NoProfile', '-NoExit', '-Command', $cmd -WindowStyle Hidden -PassThru
  $started.Add($p.Id)
  for ($i = 0; $i -lt 40 -and -not (Kids $p.Id).Count; $i++) { Start-Sleep -Milliseconds 250 }
  $p
}
function Run([int]$id, [string[]]$extra = @()) { & pwsh -NoProfile -File $Tool -ShellPid $id -StepSec 4 -Json @extra 2>&1 | Select-Object -Last 1 | ConvertFrom-Json }
try {
  # 1. a child that honours Ctrl+C stops at step 1; the shell stays
  $t = Start-Term 'pwsh -NoProfile -Command Start-Sleep 600'
  $r = Run $t.Id
  Check 'ctrl+c stops an interruptible command and keeps the terminal' ($r.stillRunning -eq 0 -and (Alive $t.Id) -and $r.steps[-1].step -eq 'ctrl+c') ($r | ConvertTo-Json -Compress -Depth 4)

  # 2. cmd stuck at "Terminate batch job (Y/N)?" after Ctrl+C: step 2 answers it
  $bat = Join-Path $tmp 'loop.cmd'; Set-Content $bat "@echo off`r`n:a`r`nping -n 2 127.0.0.1 >nul`r`ngoto a"
  $t = Start-Term "cmd /c $bat"
  $r = Run $t.Id
  Check 'a batch file stuck at Terminate batch job is answered and stopped' ($r.stillRunning -eq 0 -and (Alive $t.Id) -and $r.steps[-1].step -in 'ctrl+c', 'answer prompt (Y)') ($r | ConvertTo-Json -Compress -Depth 4)

  # 3. a child that ignores Ctrl+C AND Ctrl+Break: children are killed, the shell stays
  $deaf = Join-Path $tmp 'deaf.ps1'
  Set-Content $deaf @'
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class Deaf {
  public delegate bool H(uint t);
  [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(H h, bool add);
  static readonly H Keep = t => true; // swallow CTRL_C and CTRL_BREAK
  public static void On() { SetConsoleCtrlHandler(Keep, true); }
}
"@
[Deaf]::On()
while ($true) { Start-Sleep -Milliseconds 200 }
'@
  $t = Start-Term "pwsh -NoProfile -File $deaf"
  Start-Sleep 4
  $r = Run $t.Id
  Check 'a command deaf to ctrl+c and ctrl+break is killed, the terminal survives' ($r.stillRunning -eq 0 -and (Alive $t.Id) -and $r.steps[-1].step -eq 'kill children') ($r | ConvertTo-Json -Compress -Depth 4)

  # 4. an idle terminal: nothing to do, no step taken
  $p = Start-Process pwsh -ArgumentList '-NoLogo', '-NoProfile', '-NoExit', '-Command', '$null' -WindowStyle Hidden -PassThru; $started.Add($p.Id); Start-Sleep 2
  $r = Run $p.Id
  Check 'an idle terminal is left alone' ($r.stillRunning -eq 0 -and (Alive $p.Id) -and @($r.steps).Count -eq 0) ($r | ConvertTo-Json -Compress -Depth 4)

  # 5. -KillShell closes the terminal itself, gracefully when it can
  $r = Run $p.Id @('-KillShell')
  Check '-KillShell closes an idle terminal by itself (exit), not by force' ((-not (Alive $p.Id)) -and $r.steps[-1].result -eq 'exited') ($r | ConvertTo-Json -Compress -Depth 4)

  # 6. -ChildPid finds the owning terminal
  $t = Start-Term 'pwsh -NoProfile -Command Start-Sleep 600'
  $child = (Kids $t.Id)[0].ProcessId
  $r = & pwsh -NoProfile -File $Tool -ChildPid $child -StepSec 4 -Json 2>&1 | Select-Object -Last 1 | ConvertFrom-Json
  Check '-ChildPid resolves the terminal shell' ($r.shellPid -eq $t.Id -and $r.stillRunning -eq 0) ($r | ConvertTo-Json -Compress -Depth 4)
} finally {
  foreach ($id in $started) { & taskkill.exe /T /F /PID $id 2>&1 | Out-Null }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
exit $fail
