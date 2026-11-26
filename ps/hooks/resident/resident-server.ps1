<#
  server4.ps1 - resident hook server, v4 (2026-11-24). Same design as v3 (guard TEXT is the pipeline
  body + a PSHost records SetShouldExit, so a deny stays a deny), plus the BINARY reply the C client
  needs: a JSON reply would require an unescaper in C for no benefit.

  Framing: request = int32 header (NEGATIVE asks for the binary reply: -(len+1)) + payload bytes;
           reply   = int32 exit, int32 stdoutLen, int32 stderrLen, then stdout bytes, stderr bytes.
  A JSON reply is still produced for a positive header, so measure3.ps1 (which pipes into the exe)
  keeps working unchanged.

  -HostMode picks how the guard runs (see the param block): 'subst' is the only faithful mode, because
  the guard must behave exactly like `powershell.exe -File` - same automatic variables in every scope,
  and `exit N` still reaching PSHost.SetShouldExit.
#>
[CmdletBinding()]
param(
    [string]$PipeName = 'codai-hookc',
    [string]$GuardName = 'guard-tooluse.ps1',
    [int]$MaxRequests = 0,
    # How the guard is hosted. Every mode below was measured on 2026-11-25 with a deny payload; the two
    # wrong ones are kept so the defect stays reproducible instead of becoming folklore:
    #   subst (default)  guard TEXT runs as top-level script with $PSScriptRoot/$PSCommandPath
    #                    substituted by the literal values the engine would give this file - correct in
    #                    EVERY scope, and `exit N` still reaches PSHost.SetShouldExit, so the client can
    #                    report the CLI deny's exit 2;
    #   assign           the same, but patched by ASSIGNMENT at the body's own scope. Automatic variables
    #                    are per-scope, so inside the guard's FUNCTION $PSScriptRoot is its own EMPTY
    #                    value: Join-Path throws "...because it is an empty string." twice, both guards
    #                    are SKIPPED and the answer comes from the AXIOM block instead (this is exactly
    #                    how it behaved: resident denied via AXIOM where classic denied guard-command);
    #   file             guard run as a real file via AddCommand: scopes are right, but it is no longer a
    #                    top-level script, so a CLI `exit 2` was LOST (measured exit 0 where classic
    #                    exits 2 - a protection hole for the CLI harness).
    [ValidateSet('subst', 'assign', 'file')]
    [string]$HostMode = 'subst'
)
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$log = Join-Path $here 'server.log'
function Log([string]$m) { Add-Content -LiteralPath $log -Value ("{0}  {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $m) }

$cop = Join-Path $env:USERPROFILE '.copilot'
# The guard is normally the live one in ~\.copilot\hooks. An override lets this PoC be pointed at a
# SCRATCH guard, so the harness can be measured (does a spawned child see the payload?) without
# touching the trust surface. Set HOOKS_DIR_OVERRIDE, or pass an existing path as -GuardName.
$hooksDir = if ($env:HOOKS_DIR_OVERRIDE) { $env:HOOKS_DIR_OVERRIDE } else { Join-Path $cop 'hooks' }
$guard = if (Test-Path -LiteralPath $GuardName) { (Resolve-Path -LiteralPath $GuardName).Path } else { Join-Path $hooksDir $GuardName }
if (-not (Test-Path -LiteralPath $guard)) { Log "MISSING $guard"; exit 1 }

$src = @'
using System;
using System.Globalization;
using System.Management.Automation.Host;
// C#5 syntax on purpose: powershell.exe 5.1 runs Add-Type with a compiler that predates
// expression-bodied members and `{ get; } = value` - measured 2026-11-25, the C#6 form fails there
// with `; expected` and the server then never starts. Both engines compile THIS form.
public class HcHost : PSHost {
    public int? ExitCode;
    private Guid _id = Guid.NewGuid();
    public override string Name { get { return "hookc-host"; } }
    public override Version Version { get { return new Version(1, 0); } }
    public override Guid InstanceId { get { return _id; } }
    public override PSHostUserInterface UI { get { return null; } }
    public override CultureInfo CurrentCulture { get { return CultureInfo.InvariantCulture; } }
    public override CultureInfo CurrentUICulture { get { return CultureInfo.InvariantCulture; } }
    public override void SetShouldExit(int exitCode) { ExitCode = exitCode; }
    public override void EnterNestedPrompt() { }
    public override void ExitNestedPrompt() { }
    public override void NotifyBeginApplication() { }
    public override void NotifyEndApplication() { }
}
public static class HcNative {
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetStdHandle(int nStdHandle, IntPtr hHandle);
}
'@
Add-Type -TypeDefinition $src -ErrorAction Stop | Out-Null
$hcHost = New-Object HcHost
$rs = [RunspaceFactory]::CreateRunspace($hcHost)
$rs.Open()

$sw0 = [Diagnostics.Stopwatch]::StartNew()
$text = [IO.File]::ReadAllText($guard)
$block = $null
switch ($HostMode) {
    'subst' {
        # String.Replace, not -replace: a regex replacement gives $1/$& in the value special meaning.
        # The value substituted is exactly what the engine provides for a real file, so every scope sees
        # the truth (the guard only ever uses it as `Join-Path $PSScriptRoot $Name`).
        $hooksLit = "'" + ($hooksDir -replace "'", "''") + "'"
        $guardLit = "'" + ($guard -replace "'", "''") + "'"
        $block = [ScriptBlock]::Create($text.Replace('$PSScriptRoot', $hooksLit).Replace('$PSCommandPath', $guardLit))
    }
    'assign' {
        $body = "`$PSScriptRoot = '$($hooksDir -replace "'", "''")'; `$PSCommandPath = '$($guard -replace "'", "''")';`n" + $text
        $block = [ScriptBlock]::Create($body)
    }
}
$sw0.Stop()
$modeName = "v6-$HostMode"
# Tell the guard it runs INSIDE THIS PROCESS. The guard reads it to decide whether a process-start value
# is meaningful: here it is NOT (it would be this server's uptime, which is how `agentq slo` reached
# 318 162 h/day). Set once, before any request is served.
$env:CODAI_HOOK_RESIDENT = '1'
# Create the pipe BEFORE announcing it. The original order logged `listening on ...` and THEN constructed
# the stream, so a constructor failure left a log line claiming a listener that did not exist, with the
# error nowhere: the process is hidden, so an uncaught throw prints to a console nobody sees. Measured
# 2026-11-25 - a name still held by a session that was just torn down is released asynchronously, the
# constructor threw, and the log said `listening` while every client correctly fell back. So: retry the
# creation (bounded), and report a real failure instead of dying mute.
function New-Pipe {
    for ($i = 1; $i -le 20; $i++) {
        try {
            return [IO.Pipes.NamedPipeServerStream]::new($PipeName, [IO.Pipes.PipeDirection]::InOut, 1,
                [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::None)
        } catch {
            if ($i -ge 20) { throw }
            Start-Sleep -Milliseconds 250
        }
    }
}
try { $server = New-Pipe } catch { Log "pipe creation failed after retries: $($_.Exception.Message)"; exit 1 }
Set-Content -LiteralPath $log -Value ("{0}  listening on \\.\pipe\{1}  mode={2}  script={3} ({4} chars, parsed in {5:N0} ms)  pid={6}" -f `
    (Get-Date -Format 'HH:mm:ss.fff'), $PipeName, $modeName, $GuardName, $text.Length, $sw0.Elapsed.TotalMilliseconds, $PID)
$psHost = $null
$served = 0
$recreated = 0
while ($true) {
    # A lost client must NOT end the server. Observed 2026-11-25: a client whose watchdog expired closed
    # the handle mid-write, the server logged `write failed: ... Pipe is broken.` and then died on the
    # next WaitForConnection - so ONE slow tool call would take the resident path down for the rest of
    # the session and every later call silently paid the spawn again. Recreate the instance instead.
    try { $server.WaitForConnection() } catch {
        Log "wait failed: $($_.Exception.Message) - recreating the pipe"
        try { $server.Dispose() } catch { }
        Start-Sleep -Milliseconds 50
        try { $server = New-Pipe } catch { Log "recreate failed: $($_.Exception.Message)"; break }
        $recreated++; if ($recreated -ge 100) { Log "too many recreations ($recreated) - exiting"; break }
        continue
    }
    $recreated = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $hdr = New-Object byte[] 4; $got = 0
    while ($got -lt 4) { $n = $server.Read($hdr, $got, 4 - $got); if ($n -le 0) { break }; $got += $n }
    if ($got -lt 4) { Log 'short header - dropping connection'; continue }
    $raw = [BitConverter]::ToInt32($hdr, 0)
    $binary = $raw -lt 0
    $len = if ($binary) { -$raw - 1 } else { $raw }
    $buf = New-Object byte[] $len; $got = 0
    while ($got -lt $len) { $n = $server.Read($buf, $got, $len - $got); if ($n -le 0) { break }; $got += $n }
    $payload = [Text.Encoding]::UTF8.GetString($buf, 0, $got)
    $readMs = $sw.Elapsed.TotalMilliseconds
    # The request has fully arrived: this is the instant a per-call process would have been created.
    # The guard turns it into startMs, so the field measures THIS call, not this server's uptime.
    $recvMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

    $outW = [IO.StringWriter]::new(); $errW = [IO.StringWriter]::new()
    $oldIn = [Console]::In; $oldOut = [Console]::Out; $oldErr = [Console]::Error
    [Console]::SetIn([IO.StringReader]::new($payload))
    [Console]::SetOut($outW); [Console]::SetError($errW)
    # The payload must ALSO be visible at OS level: a guard that SHELLS OUT (the AXIOM gate ->
    # axiom.cmd -> node) inherits the PROCESS stdin, not [Console]::In, and would otherwise decide on
    # empty input. Measured 2026-11-25 without this: the same payload was denied by a different guard
    # in the resident path than in the classic one, and an allow case emitted "Cannot bind argument to
    # parameter 'Path' because it is an empty string." - i.e. the hosted path was NOT faithful.
    $inTmp = $null; $inStream = $null; $hStdOld = [IntPtr]::Zero
    try {
        $inTmp = [IO.Path]::GetTempFileName()
        [IO.File]::WriteAllBytes($inTmp, [Text.Encoding]::UTF8.GetBytes($payload))
        $inStream = [IO.File]::OpenRead($inTmp)
        $hStdOld = [HcNative]::GetStdHandle(-10)
        [void][HcNative]::SetStdHandle(-10, $inStream.SafeFileHandle.DangerousGetHandle())
    } catch { Log "stdin swap failed: $($_.Exception.Message)" }
    $hcHost.ExitCode = $null
    $result = @(); $exit = 0; $runMs = 0; $note = ''
    $env:CODAI_HOOK_REQUEST_MS = "$recvMs"
    try {
        if (-not $psHost) { $psHost = [PowerShell]::Create(); $psHost.Runspace = $rs }
        $psHost.Commands.Clear() | Out-Null
        # subst/assign add the finished script TEXT; 'file' adds the path. Only the text modes keep the
        # guard a TOP-LEVEL script, which is what makes `exit N` reach PSHost.SetShouldExit - AddCommand
        # measured exit 0 where the classic path exits 2 (the CLI deny lost its code). The mode is
        # chosen once, above; see the param block for what each one was measured to do.
        if ($block) { [void]$psHost.AddScript($block) } else { [void]$psHost.AddCommand($guard) }
        $t = [Diagnostics.Stopwatch]::StartNew()
        $result = @($psHost.Invoke())
        $t.Stop(); $runMs = $t.Elapsed.TotalMilliseconds
        if ($psHost.Streams.Error.Count) { $result += @($psHost.Streams.Error | ForEach-Object { "$_" }); $psHost.Streams.Error.Clear() }
        if ($hcHost.ExitCode -ne $null) { $exit = [int]$hcHost.ExitCode; $note = 'SetShouldExit' }
        elseif ($psHost.InvocationStateInfo.State -eq 'Failed') { $exit = 2; $note = 'failed state -> 2' }
        elseif ($psHost.InvocationStateInfo.State -ne 'Completed') { $note = "state $($psHost.InvocationStateInfo.State)" }
    } catch {
        $exit = 2; $note = "catch $($_.Exception.GetType().Name)"
        $result += "server: $($_.Exception.Message)"
        $psHost.Dispose(); $psHost = $null
    } finally {
        [Console]::SetIn($oldIn); [Console]::SetOut($oldOut); [Console]::SetError($oldErr)
        if ($inStream) { try { [void][HcNative]::SetStdHandle(-10, $hStdOld) } catch { }; $inStream.Dispose() }
        if ($inTmp) { Remove-Item -LiteralPath $inTmp -Force -ErrorAction SilentlyContinue }
        # One request at a time (single pipe) and the value must not linger into the next one.
        Remove-Item Env:CODAI_HOOK_REQUEST_MS -ErrorAction SilentlyContinue
    }

    $stdout = $outW.ToString() + ($result -join "`n")
    $stderr = $errW.ToString()
    try {
        if ($binary) {
            $ob = [Text.Encoding]::UTF8.GetBytes($stdout); $eb = [Text.Encoding]::UTF8.GetBytes($stderr)
            $head = New-Object byte[] 12
            [BitConverter]::GetBytes([int]$exit).CopyTo($head, 0)
            [BitConverter]::GetBytes([int]$ob.Length).CopyTo($head, 4)
            [BitConverter]::GetBytes([int]$eb.Length).CopyTo($head, 8)
            $server.Write($head, 0, 12)
            if ($ob.Length) { $server.Write($ob, 0, $ob.Length) }
            if ($eb.Length) { $server.Write($eb, 0, $eb.Length) }
        } else {
            $reply = [ordered]@{ stdout = $stdout.TrimEnd(); stderr = $stderr.TrimEnd(); exit = $exit; runMs = [math]::Round($runMs, 1); mode = $modeName } |
                ConvertTo-Json -Compress -Depth 4
            $bytes = [Text.Encoding]::UTF8.GetBytes($reply)
            $server.Write($bytes, 0, $bytes.Length)
        }
        $server.Flush(); $server.Disconnect()
    } catch { Log "write failed: $($_.Exception.Message)" }

    $sw.Stop(); $served++
    Log ("req $served  total {0:N0} ms (read {1:N0}, run {2:N0})  exit {3}{4}  bin={5}  stdout {6} B  stderr {7} B" -f `
            $sw.Elapsed.TotalMilliseconds, $readMs, $runMs, $exit, $(if ($note) { " ($note)" } else { '' }), $binary, $stdout.Length, $stderr.Length)
    if ($MaxRequests -gt 0 -and $served -ge $MaxRequests) { Log "served $served - exiting"; break }
}
if ($psHost) { $psHost.Dispose() }
$rs.Dispose(); $server.Dispose()
