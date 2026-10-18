# agentq Job Object library (ADR 0003 W2-4). Dot-sourced by agentq.ps1 (`agentq run`) and by the
# standalone helper agentq-jobobject.ps1. The C# type is compiled once and cached as a dll under
# %LOCALAPPDATA%\agentq\jobobj (Add-Type costs ~700 ms; the cached load ~20 ms).
$src = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace AgentQ {
public static class JobObj {
  [StructLayout(LayoutKind.Sequential)] public struct BASIC_LIMIT {
    public long PerProcessUserTimeLimit; public long PerJobUserTimeLimit; public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize; public UIntPtr MaximumWorkingSetSize; public uint ActiveProcessLimit;
    public UIntPtr Affinity; public uint PriorityClass; public uint SchedulingClass; }
  [StructLayout(LayoutKind.Sequential)] public struct IO_COUNTERS {
    public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount; }
  [StructLayout(LayoutKind.Sequential)] public struct EXTENDED_LIMIT {
    public BASIC_LIMIT Basic; public IO_COUNTERS Io; public UIntPtr ProcessMemoryLimit; public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed; public UIntPtr PeakJobMemoryUsed; }
  [StructLayout(LayoutKind.Sequential)] public struct CPU_RATE { public uint ControlFlags; public uint Value; }
  [StructLayout(LayoutKind.Sequential)] public struct BASIC_ACCOUNTING {
    public long TotalUserTime, TotalKernelTime, ThisPeriodTotalUserTime, ThisPeriodTotalKernelTime;
    public uint TotalPageFaultCount, TotalProcesses, ActiveProcesses, TotalTerminatedProcesses; }
  [StructLayout(LayoutKind.Sequential)] public struct STARTUPINFO {
    public int cb; public IntPtr lpReserved, lpDesktop, lpTitle; public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    public short wShowWindow, cbReserved2; public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError; }
  [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION { public IntPtr hProcess, hThread; public int dwProcessId, dwThreadId; }

  public const int ClassBasicAccounting = 1, ClassExtendedLimit = 9, ClassCpuRate = 15;
  public const uint LIMIT_JOB_MEMORY = 0x200, LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
  public const uint CPU_ENABLE = 0x1, CPU_WEIGHT_BASED = 0x2;

  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern IntPtr CreateJobObjectW(IntPtr sa, string name);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetInformationJobObject(IntPtr job, int cls, IntPtr info, uint len);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool QueryInformationJobObject(IntPtr job, int cls, IntPtr info, uint len, IntPtr ret);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool AssignProcessToJobObject(IntPtr job, IntPtr proc);
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode, EntryPoint="CreateProcessW")]
  static extern bool CreateProcessW(string app, StringBuilder cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint ResumeThread(IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr p, uint code);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr p, out uint code);
  [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr h, uint mask, uint flags);

  public static bool Set<T>(IntPtr job, int cls, T value) where T : struct {
    int n = Marshal.SizeOf<T>(); IntPtr p = Marshal.AllocHGlobal(n);
    try { Marshal.StructureToPtr(value, p, false); return SetInformationJobObject(job, cls, p, (uint)n); }
    finally { Marshal.FreeHGlobal(p); } }
  public static T Query<T>(IntPtr job, int cls) where T : struct {
    int n = Marshal.SizeOf<T>(); IntPtr p = Marshal.AllocHGlobal(n);
    try { if (!QueryInformationJobObject(job, cls, p, (uint)n, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();
          return Marshal.PtrToStructure<T>(p); }
    finally { Marshal.FreeHGlobal(p); } }

  // Creates the child SUSPENDED with our std handles, so the caller can assign it to the job before it runs.
  public static PROCESS_INFORMATION StartSuspended(string cmdLine, string cwd) {
    var si = new STARTUPINFO(); si.cb = Marshal.SizeOf<STARTUPINFO>(); si.dwFlags = 0x100; // STARTF_USESTDHANDLES
    si.hStdInput = GetStdHandle(-10); si.hStdOutput = GetStdHandle(-11); si.hStdError = GetStdHandle(-12);
    foreach (var h in new[] { si.hStdInput, si.hStdOutput, si.hStdError })
      if (h != IntPtr.Zero && h != new IntPtr(-1)) SetHandleInformation(h, 1, 1); // HANDLE_FLAG_INHERIT
    PROCESS_INFORMATION pi;
    if (!CreateProcessW(null, new StringBuilder(cmdLine), IntPtr.Zero, IntPtr.Zero, true, 0x4 /*CREATE_SUSPENDED*/, IntPtr.Zero, cwd, ref si, out pi))
      throw new System.ComponentModel.Win32Exception();
    return pi; }
}
}
'@

function Import-JobObjType {
  if ('AgentQ.JobObj' -as [type]) { return }
  $sha = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($src))
  $hash = [Convert]::ToHexString($sha).Substring(0, 12).ToLowerInvariant()
  $dir = Join-Path $env:LOCALAPPDATA 'agentq\jobobj'
  $dll = Join-Path $dir "AgentQ.JobObj.$hash.dll"
  if (-not (Test-Path -LiteralPath $dll)) {
    try {
      New-Item -ItemType Directory -Force -Path $dir | Out-Null
      $tmp = Join-Path $dir ("tmp-{0}-{1}.dll" -f $PID, [guid]::NewGuid().ToString('N'))
      Add-Type -TypeDefinition $src -OutputAssembly $tmp -OutputType Library
      # Concurrent compilers race here; the first rename wins, the loser drops its copy.
      try { Move-Item -LiteralPath $tmp -Destination $dll -ErrorAction Stop } catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    } catch { Write-Verbose "jobobj: disk cache unavailable ($($_.Exception.Message)); compiling in memory" }
  }
  if (Test-Path -LiteralPath $dll) {
    try { Add-Type -Path $dll; return } catch { Write-Verbose "jobobj: cached dll failed to load ($($_.Exception.Message))" }
  }
  Add-Type -TypeDefinition $src
}


# Put the CURRENT process (and so every child it starts later) into a new job object:
#  - JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: when this process exits (or dies), leftover children die with it
#    (orphaned vitest/node/tsc trees kept CPU and file locks after a holder was killed);
#  - weight-based CPU rate (1..9): lane-weighted share when the machine is saturated (land gate highest).
# Returns @{ job; weightApplied; error } or $null when the OS refuses (never fatal for the caller).
function Enter-AgentqJob([int]$Weight) {
  try {
    Import-JobObjType
    $J = [AgentQ.JobObj]
    $job = $J::CreateJobObjectW([IntPtr]::Zero, $null)
    if ($job -eq [IntPtr]::Zero) { return @{ job = [IntPtr]::Zero; weightApplied = $false; error = "CreateJobObject win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" } }
    $ext = New-Object AgentQ.JobObj+EXTENDED_LIMIT
    $basic = $ext.Basic; $basic.LimitFlags = [uint32]$J::LIMIT_KILL_ON_JOB_CLOSE; $ext.Basic = $basic
    if (-not [AgentQ.JobObj]::Set[AgentQ.JobObj+EXTENDED_LIMIT]($job, $J::ClassExtendedLimit, $ext)) { $J::CloseHandle($job) | Out-Null; return @{ job = [IntPtr]::Zero; weightApplied = $false; error = "ExtendedLimit win32 $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" } }
    $rate = New-Object AgentQ.JobObj+CPU_RATE
    $rate.ControlFlags = $J::CPU_ENABLE -bor $J::CPU_WEIGHT_BASED; $rate.Value = [uint32][math]::Max(1, [math]::Min(9, $Weight))
    $w = [AgentQ.JobObj]::Set[AgentQ.JobObj+CPU_RATE]($job, $J::ClassCpuRate, $rate)
    if (-not $J::AssignProcessToJobObject($job, $J::GetCurrentProcess())) {
      $e = [Runtime.InteropServices.Marshal]::GetLastWin32Error(); $J::CloseHandle($job) | Out-Null
      return @{ job = [IntPtr]::Zero; weightApplied = $false; error = "AssignProcessToJobObject win32 $e" }
    }
    @{ job = $job; weightApplied = $w; error = '' }
  } catch { @{ job = [IntPtr]::Zero; weightApplied = $false; error = "$($_.Exception.Message)" } }
}
# CPU seconds (user+kernel) of every process that ever ran in the job, and the peak job commit (MB).
function Get-AgentqJobStats([IntPtr]$job) {
  try {
    $J = [AgentQ.JobObj]
    $acct = [AgentQ.JobObj]::Query[AgentQ.JobObj+BASIC_ACCOUNTING]($job, $J::ClassBasicAccounting)
    $ext = [AgentQ.JobObj]::Query[AgentQ.JobObj+EXTENDED_LIMIT]($job, $J::ClassExtendedLimit)
    @{ cpuSec = [math]::Round(($acct.TotalUserTime + $acct.TotalKernelTime) / 1e7, 1); peakMB = [math]::Round($ext.PeakJobMemoryUsed.ToUInt64() / 1MB, 0); procs = [int]$acct.TotalProcesses }
  } catch { $null }
}