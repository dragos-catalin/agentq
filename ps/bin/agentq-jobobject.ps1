<#
.SYNOPSIS
  Run one command inside a Windows Job Object (agentq ADR 0003 W2-4).

.DESCRIPTION
  - CPU WEIGHT (JOBOBJECT_CPU_RATE_CONTROL_INFORMATION, ENABLE|WEIGHT_BASED, 1..9;
    Windows default for unweighted jobs is 5). Weight is relative between jobs that
    compete for CPU; it only bites under saturation, idle CPU is never withheld.
  - optional job-wide commit cap (JOB_OBJECT_LIMIT_JOB_MEMORY) when -MemoryMB > 0.
    .NET children see the cap and size their GC heap hard limit from it.
  - KILL_ON_JOB_CLOSE: the job handle is held ONLY by this process (created with
    a NULL security descriptor => not inheritable, so the child never gets a copy).
    When this process exits or is killed (TerminateProcess included) the kernel
    closes the handle and kills every process still in the job: cmd, its children,
    grandchildren, detached `start` leftovers.
  - Accounting: prints `JOBOBJ cpuSec=<user+kernel of all job processes> peakMB=<peak job commit>`
    and exits with the child's exit code.

  Race (child running outside the job): closed by construction. The child is
  created with CreateProcessW(CREATE_SUSPENDED), assigned with
  AssignProcessToJobObject while its only thread has not run a single
  instruction, then ResumeThread. Start-Process/Process.Start + assign-after-start
  would leave a window in which cmd could already spawn a grandchild that escapes.

  Cost: compiling the P/Invoke type with Add-Type costs ~0.5-1 s. The compiled
  assembly is cached on disk (%LOCALAPPDATA%\agentq\jobobj\AgentQ.JobObj.<srchash>.dll)
  and loaded with Add-Type -Path (tens of ms); inside one process the type is
  reused if already loaded.

.EXAMPLE
  pwsh -NoProfile -File agentq-jobobject.ps1 -Weight 9 -MemoryMB 8192 -Cwd E:\gh\codai -Command 'pnpm turbo run test'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Command,
  [ValidateRange(1, 9)][int]$Weight = 5,
  [ValidateRange(0, 1048576)][int]$MemoryMB = 0,
  [string]$Cwd = (Get-Location).ProviderPath,
  [ValidateSet('cmd', 'pwsh')][string]$Shell = 'cmd'
)
$ErrorActionPreference = 'Stop'
$inv = [cultureinfo]::InvariantCulture

. (Join-Path $PSScriptRoot 'agentq-jobobject-lib.ps1')

Import-JobObjType
$J = [AgentQ.JobObj]

$job = $J::CreateJobObjectW([IntPtr]::Zero, $null)
if ($job -eq [IntPtr]::Zero) {
  [Console]::Error.WriteLine("JOBOBJ-ERROR CreateJobObject failed (win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))")
  exit 125
}

$ext = New-Object AgentQ.JobObj+EXTENDED_LIMIT
$flags = [uint32]$J::LIMIT_KILL_ON_JOB_CLOSE
if ($MemoryMB -gt 0) {
  $flags = $flags -bor $J::LIMIT_JOB_MEMORY
  $ext.JobMemoryLimit = [UIntPtr]::new([uint64]$MemoryMB * 1MB)
}
$basic = $ext.Basic; $basic.LimitFlags = $flags; $ext.Basic = $basic
if (-not [AgentQ.JobObj]::Set[AgentQ.JobObj+EXTENDED_LIMIT]($job, $J::ClassExtendedLimit, $ext)) {
  [Console]::Error.WriteLine("JOBOBJ-ERROR SetInformationJobObject(ExtendedLimit) failed (win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))")
  exit 125
}

# CPU weight is best effort: a failure (e.g. parent job with a hard CPU cap) must not stop the gate.
$rate = New-Object AgentQ.JobObj+CPU_RATE
$rate.ControlFlags = $J::CPU_ENABLE -bor $J::CPU_WEIGHT_BASED
$rate.Value = [uint32]$Weight
$weightApplied = [AgentQ.JobObj]::Set[AgentQ.JobObj+CPU_RATE]($job, $J::ClassCpuRate, $rate)
$weightErr = if ($weightApplied) { 0 } else { [Runtime.InteropServices.Marshal]::GetLastWin32Error() }
$readback = 0
if ($weightApplied) { try { $readback = [AgentQ.JobObj]::Query[AgentQ.JobObj+CPU_RATE]($job, $J::ClassCpuRate).Value } catch { $readback = -1 } }

$cmdLine = if ($Shell -eq 'pwsh') {
  $pw = (Get-Process -Id $PID).Path
  '"{0}" -NoProfile -Command {1}' -f $pw, $Command
} else {
  $comspec = if ($env:ComSpec) { $env:ComSpec } else { "$env:SystemRoot\System32\cmd.exe" }
  # /d: no AutoRun; /s /c "...": cmd strips only the outer quotes, Command is passed verbatim.
  '"{0}" /d /s /c "{1}"' -f $comspec, $Command
}

try { $pi = $J::StartSuspended($cmdLine, $Cwd) }
catch { [Console]::Error.WriteLine("JOBOBJ-ERROR CreateProcess failed: $($_.Exception.Message)"); exit 126 }

if (-not $J::AssignProcessToJobObject($job, $pi.hProcess)) {
  $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  $J::TerminateProcess($pi.hProcess, 125) | Out-Null
  [Console]::Error.WriteLine("JOBOBJ-ERROR AssignProcessToJobObject failed (win32 $e); child killed before it ran")
  exit 125
}
[Console]::Out.WriteLine(('JOBOBJ start pid={0} weight={1} weightApplied={2} weightReadback={3} weightErr={4} memMB={5} killOnClose=true' -f `
      $pi.dwProcessId, $Weight, $weightApplied, $readback, $weightErr, $MemoryMB))
[Console]::Out.Flush()
$J::ResumeThread($pi.hThread) | Out-Null
$J::CloseHandle($pi.hThread) | Out-Null

# Poll so the PowerShell host stays responsive (Ctrl+C reaches the child via the shared console).
while ($J::WaitForSingleObject($pi.hProcess, 250) -eq 0x102) { }
[uint32]$code = 0
$J::GetExitCodeProcess($pi.hProcess, [ref]$code) | Out-Null
$J::CloseHandle($pi.hProcess) | Out-Null
$exitInt = [BitConverter]::ToInt32([BitConverter]::GetBytes($code), 0)

$acct = [AgentQ.JobObj]::Query[AgentQ.JobObj+BASIC_ACCOUNTING]($job, $J::ClassBasicAccounting)
$extOut = [AgentQ.JobObj]::Query[AgentQ.JobObj+EXTENDED_LIMIT]($job, $J::ClassExtendedLimit)
$cpuSec = ($acct.TotalUserTime + $acct.TotalKernelTime) / 1e7
$peakMB = $extOut.PeakJobMemoryUsed.ToUInt64() / 1MB
[Console]::Out.WriteLine(('JOBOBJ cpuSec={0} peakMB={1} userSec={2} kernelSec={3} procs={4} leftover={5} exit={6}' -f `
      $cpuSec.ToString('0.000', $inv), $peakMB.ToString('0.0', $inv), ($acct.TotalUserTime / 1e7).ToString('0.000', $inv),
    ($acct.TotalKernelTime / 1e7).ToString('0.000', $inv), $acct.TotalProcesses, $acct.ActiveProcesses, $exitInt))
[Console]::Out.Flush()

# Closing the handle kills leftovers (processes still alive after the main child exited).
$J::CloseHandle($job) | Out-Null
exit $exitInt
