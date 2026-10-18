<#
term-interrupt — stop what is running in a terminal WITHOUT killing the terminal, escalating only as
far as needed (2026-10-18). The terminal (and the agent chat that owns it) survives; only the stuck
command goes. Use it on a VS Code terminal whose command hangs, instead of closing the terminal.

Ladder, each step only if the previous one left the command running (-StepSec between steps):
  1. Ctrl+C          CTRL_C_EVENT on the console (what the keyboard does).
  2. answer prompts  types `Y` + Enter: cmd's "Terminate batch job (Y/N)?" swallows Ctrl+C and waits
                     forever for exactly this (the hang seen in run-build/gradle .cmd wrappers).
  3. Ctrl+Break      CTRL_BREAK_EVENT: reaches processes that ignore Ctrl+C.
  4. kill children   taskkill /T /F on each child of the shell - the shell itself is never killed.
-KillShell adds step 5 (Ctrl+C + `exit`, then force) for a terminal that should go entirely.

Target by -ShellPid (the terminal's pwsh), or by -ChildPid (any process in it: the shell is found by
walking up to the first INTERACTIVE shell - VS Code shell integration or -NoExit on its command line -
never further, so a nested `pwsh -File` is never mistaken for the terminal and the walk can never climb
into the caller's own terminal).

  term-interrupt.ps1 -ShellPid 1234 [-StepSec 5] [-KillShell] [-WhatIf] [-Json]
Prints each step and the result; EXIT 0 = nothing left running under the shell, 1 = still running,
2 = usage / shell not found.
#>
[CmdletBinding()]
param([int]$ShellPid, [int]$ChildPid, [double]$StepSec = 5, [switch]$KillShell, [switch]$WhatIf, [switch]$Json,
  [string]$SignalTool = (Join-Path $PSScriptRoot 'console-signal.ps1'))
$ErrorActionPreference = 'Stop'
$shells = 'pwsh.exe', 'powershell.exe', 'cmd.exe', 'bash.exe'
function Get-Procs { $m = @{}; foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate) { $m[[int]$p.ProcessId] = $p }; $m }
$procs = Get-Procs
if (-not $ShellPid -and $ChildPid) {
  $cur = $procs[[int]$procs[$ChildPid].ParentProcessId]
  while ($cur) {
    if ($cur.Name -in $shells -and "$($cur.CommandLine)" -match 'shellIntegration\.ps1|-NoExit') { $ShellPid = [int]$cur.ProcessId; break }
    $cur = $procs[[int]$cur.ParentProcessId]
  }
}
if (-not $ShellPid -or -not $procs.ContainsKey($ShellPid)) { [Console]::Error.WriteLine('term-interrupt: -ShellPid (or -ChildPid inside a terminal) not found'); exit 2 }
$shellStart = $procs[$ShellPid].CreationDate

# descendants of the shell, excluding console hosts (conhost/OpenConsole are not work)
function Get-Work([hashtable]$m) {
  $kids = @{}; foreach ($p in $m.Values) { $pp = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($pp)) { $kids[$pp] = @() }; $kids[$pp] += $p }
  $out = @(); $q = [Collections.Generic.Queue[int]]::new(); $q.Enqueue($ShellPid)
  # WerFault is Windows Error Reporting attaching to a crashing child: not work, and it exits by itself
  while ($q.Count) { $id = $q.Dequeue(); foreach ($c in @($kids[$id])) { if (-not $c) { continue }; if ([int]$c.ProcessId -eq $ShellPid) { continue }; if ($c.CreationDate -lt $shellStart) { continue }; if ($c.Name -notin 'conhost.exe', 'OpenConsole.exe', 'WerFault.exe') { $out += $c }; $q.Enqueue([int]$c.ProcessId) } }
  $out
}
function Alive([int]$id) { try { $null = Get-Process -Id $id -ErrorAction Stop; $true } catch { $false } }
$log = [Collections.Generic.List[object]]::new()
function Step([string]$name, [scriptblock]$act) {
  $before = @(Get-Work (Get-Procs))
  if (-not $before.Count -and $name -ne 'close shell') { return $true }
  $r = if ($WhatIf) { 'whatif' } else { (& $act) -join ' ' }
  if (-not $WhatIf) {
    $deadline = (Get-Date).AddSeconds($StepSec)
    do { Start-Sleep -Milliseconds 300; $left = @(Get-Work (Get-Procs)) } while ($left.Count -and (Get-Date) -lt $deadline)
  } else { $left = $before }
  $log.Add([pscustomobject]@{ step = $name; before = $before.Count; after = $left.Count; result = $r; running = (($left | ForEach-Object Name) -join ',') })
  return (-not $left.Count)
}
$sig = { param($s, $t) $a = @('-NoProfile', '-File', $SignalTool, '-Pids', "$ShellPid", '-Signal', $s); if ($t) { $a += @('-Type', $t) } else { $a += '-NoExit' }; & pwsh @a 2>&1 }
$done = (Step 'ctrl+c' { & $sig 'CtrlC' $null }) -or
        (Step 'answer prompt (Y)' { & $sig 'None' 'Y' }) -or
        (Step 'ctrl+break' { & $sig 'CtrlBreak' $null }) -or
        (Step 'kill children' { foreach ($c in @(Get-Work (Get-Procs)) | Where-Object { [int]$_.ParentProcessId -eq $ShellPid }) { & taskkill.exe /T /F /PID ([int]$c.ProcessId) 2>&1 | Out-Null; "killed $($c.ProcessId):$($c.Name)" } })
if ($KillShell -and -not $WhatIf) {
  & $sig 'CtrlC' 'exit' | Out-Null
  $deadline = (Get-Date).AddSeconds($StepSec); while ((Alive $ShellPid) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
  $how = if (Alive $ShellPid) { Stop-Process -Id $ShellPid -Force -ErrorAction SilentlyContinue; 'forced' } else { 'exited' }
  $log.Add([pscustomobject]@{ step = 'close shell'; before = 1; after = [int](Alive $ShellPid); result = $how; running = '' })
}
$still = @(Get-Work (Get-Procs))
if ($Json) { [ordered]@{ shellPid = $ShellPid; steps = $log; stillRunning = $still.Count; shellAlive = (Alive $ShellPid) } | ConvertTo-Json -Compress -Depth 4 }
else { $log | Format-Table -AutoSize | Out-String -Width 200; "shell $ShellPid alive=$(Alive $ShellPid) stillRunning=$($still.Count)" }
exit $(if ($still.Count) { 1 } else { 0 })
