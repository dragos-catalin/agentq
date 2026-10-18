<#
console-signal — ask console processes to stop, politely, before anyone kills them (2026-10-18).

For each pid: attach to that process's console, raise CTRL+C on it (GenerateConsoleCtrlEvent, the
same thing a keyboard Ctrl+C does - it reaches the shell AND anything running in it), then type
`exit` + Enter into its input buffer so an idle shell at its prompt closes itself with exit code 0.
A VS Code terminal that exits 0 raises no "terminated with exit code" alert, and whoever was using
it sees a normal interrupt/exit instead of a process vanishing mid-read.

Runs as its own process on purpose: attaching to another console means detaching from ours first
(a process has at most one console), which would break the caller's own output.

  console-signal.ps1 -Pids 123,456 [-NoExit]
Prints one line per pid: "<pid> ok" or "<pid> fail <reason>". EXIT 0 always (per-pid result).
#>
param([Parameter(Mandatory)][string]$Pids, [switch]$NoExit)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ConSig {
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool SetConsoleCtrlHandler(IntPtr h, bool add);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool GenerateConsoleCtrlEvent(uint ev, uint group);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError = true)] public static extern bool CloseHandle(IntPtr h);
  [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
  public struct KEY_EVENT_RECORD {
    [FieldOffset(0)] public int bKeyDown; [FieldOffset(4)] public ushort wRepeatCount;
    [FieldOffset(6)] public ushort wVirtualKeyCode; [FieldOffset(8)] public ushort wVirtualScanCode;
    [FieldOffset(10)] public char UnicodeChar; [FieldOffset(12)] public uint dwControlKeyState;
  }
  [StructLayout(LayoutKind.Explicit)]
  public struct INPUT_RECORD { [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY_EVENT_RECORD Key; }
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  public static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);

  static INPUT_RECORD Key(char c, ushort vk, bool down) {
    var r = new INPUT_RECORD(); r.EventType = 1;
    r.Key.bKeyDown = down ? 1 : 0; r.Key.wRepeatCount = 1; r.Key.wVirtualKeyCode = vk; r.Key.UnicodeChar = c;
    return r;
  }
  // "" on success, else the failing step + Win32 error
  public static string Signal(uint pid, bool typeExit) {
    FreeConsole();
    if (!AttachConsole(pid)) return "attach " + Marshal.GetLastWin32Error();
    try {
      SetConsoleCtrlHandler(IntPtr.Zero, true); // this helper ignores the Ctrl+C it raises
      if (!GenerateConsoleCtrlEvent(0, 0)) return "ctrl-c " + Marshal.GetLastWin32Error();
      if (!typeExit) return "";
      System.Threading.Thread.Sleep(300); // let the shell abandon whatever it was reading
      IntPtr h = CreateFileW("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
      if (h == new IntPtr(-1)) return "conin " + Marshal.GetLastWin32Error();
      try {
        string text = "exit";
        var recs = new System.Collections.Generic.List<INPUT_RECORD>();
        foreach (char c in text) { ushort vk = (ushort)char.ToUpperInvariant(c); recs.Add(Key(c, vk, true)); recs.Add(Key(c, vk, false)); }
        recs.Add(Key('\r', 0x0D, true)); recs.Add(Key('\r', 0x0D, false));
        uint n; if (!WriteConsoleInputW(h, recs.ToArray(), (uint)recs.Count, out n)) return "input " + Marshal.GetLastWin32Error();
      } finally { CloseHandle(h); }
      return "";
    } finally { FreeConsole(); SetConsoleCtrlHandler(IntPtr.Zero, false); }
  }
}
'@
foreach ($p in @($Pids -split ',' | Where-Object { $_ -match '^\d+$' })) {
  $err = [ConSig]::Signal([uint32]$p, -not $NoExit)
  # stdout is gone while attached elsewhere; write through a file-backed stream is not needed
  # because Signal() detaches before returning and Write-Output goes to our original handle.
  if ($err) { Write-Output "$p fail $err" } else { Write-Output "$p ok" }
}
exit 0
