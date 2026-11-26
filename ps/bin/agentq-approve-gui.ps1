#requires -Version 5.1
<#
.SYNOPSIS
  The WINDOW behind `agentq approve`: shows exactly which paths an edit ticket would unlock, and
  mints it when the owner clicks Approve.

.DESCRIPTION
  Started by agentq-approve.ps1 (pwsh -STA -File ... -Request <path>) once per request. It reads the
  request record, shows a small WPF window, and on Approve runs the ticket script in a NEW console -
  the only place a ticket can be minted, because the mint needs a real interactive console and the
  caller's is redirected.

  Reads the request   :  <home>\approvals\<id>.json      (written by agentq-approve.ps1)
  Writes the verdict  :  <home>\approvals\<id>.verdict.json
                         { verdict: approved|denied, at, by, ticket_exit, mint_ms, why? }

  -AutoApprove / -AutoDeny answer without a window: they exist so the whole decision + mint path is
  testable (and usable from a script), never to replace the owner's click. Closing the window is a
  denial - silence is never consent.

  Exit: 0 approved and minted, 3 denied, 5 approved but the mint failed, 2 the request is unreadable.
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)][string]$Request,
    [switch]$AutoApprove,
    [switch]$AutoDeny,
    # Overrides for tests / a non-standard install root.
    [string]$TicketScript,
    [switch]$Help
)

$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

if ($Help) { Get-Help $PSCommandPath -Detailed; exit 0 }

function Write-AqGuiErr([string]$m) { [Console]::Error.WriteLine("agentq approve (window): $m") }

function Write-AqGuiAtomic([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -Force -LiteralPath $tmp -Destination $Path
}

# Runs the ONE command that can mint the ticket, in its own console (a real one: Start-Process with
# no -NoNewWindow creates it), and returns its exit code. The scope goes as ONE comma-joined value,
# which is the form the ticket script documents and splits itself.
function Invoke-AqGuiMint([string[]]$globs, [double]$hours, [string]$ticket) {
    if (-not (Test-Path -LiteralPath $ticket)) {
        Write-AqGuiErr "the ticket script is missing: $ticket"
        return 127
    }
    $argv = @('-NoProfile', '-File', $ticket, '-Issue', '-Hours', "$hours", '-Scope', ($globs -join ','))
    $p = Start-Process -FilePath 'pwsh' -ArgumentList $argv -Wait -PassThru
    return [int]$p.ExitCode
}

function Write-AqGuiVerdict([string]$verdictPath, [string]$verdict, [int]$mintExit, [long]$mintMs, [string]$why) {
    $rec = [ordered]@{
        verdict     = $verdict
        at          = (Get-Date).ToUniversalTime().ToString('o')
        by          = 'owner'
        ticket_exit = $mintExit
        mint_ms     = $mintMs
    }
    if ($why) { $rec.why = $why }
    Write-AqGuiAtomic $verdictPath ($rec | ConvertTo-Json -Compress)
}

if (-not (Test-Path -LiteralPath $Request)) { Write-AqGuiErr "request not readable: $Request"; exit 2 }
try { $r = Get-Content -LiteralPath $Request -Raw | ConvertFrom-Json -DateKind String }
catch { Write-AqGuiErr "request is not valid JSON: $Request"; exit 2 }

$dir = Split-Path -Parent $Request
$id = if ($r.PSObject.Properties['id'] -and $r.id) { "$($r.id)" } else { [IO.Path]::GetFileNameWithoutExtension($Request) }
$verdictPath = Join-Path $dir "$id.verdict.json"
$globs = @($r.scope | ForEach-Object { ([string]$_ -split ',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$hours = if ($r.PSObject.Properties['hours'] -and $r.hours) { [double]$r.hours } else { 2 }
$purpose = if ($r.PSObject.Properties['purpose']) { "$($r.purpose)" } else { '' }
$session = if ($r.PSObject.Properties['session']) { "$($r.session)" } else { '?' }
$repo = if ($r.PSObject.Properties['repo']) { "$($r.repo)" } else { '?' }
$hostName = if ($r.PSObject.Properties['host']) { "$($r.host)" } else { $env:COMPUTERNAME }
if (-not $TicketScript) { $TicketScript = Join-Path $env:USERPROFILE '.copilot\hooks\rules-ticket.ps1' }

if ($AutoDeny) {
    Write-AqGuiVerdict $verdictPath 'denied' -1 0 'answered by -AutoDeny'
    exit 3
}

if ($AutoApprove) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-AqGuiMint $globs $hours $TicketScript
    $sw.Stop()
    Write-AqGuiVerdict $verdictPath 'approved' $code $sw.ElapsedMilliseconds ''
    Write-Output "approved (mint exit $code)"
    if ($code -eq 0) { exit 0 }
    exit 5
}

# ---- the window ---------------------------------------------------------------------------------
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Codwen - approve an edit ticket" Width="580" SizeToContent="Height"
        WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
  <StackPanel Margin="16">
    <TextBlock FontSize="15" FontWeight="SemiBold" Text="An agent asks for an edit ticket"/>
    <TextBlock Margin="0,10,0,4" TextWrapping="Wrap"
               Text="Approving makes exactly these paths editable, on this machine, until the ticket expires:"/>
    <TextBox Name="scope" IsReadOnly="True" AcceptsReturn="True" Height="96" TextWrapping="Wrap"
             VerticalScrollBarVisibility="Auto" FontFamily="Consolas" Background="WhiteSmoke"/>
    <TextBlock Name="why" Margin="0,10,0,0" TextWrapping="Wrap"/>
    <TextBlock Name="who" Margin="0,10,0,0" Foreground="DimGray" TextWrapping="Wrap"/>
    <TextBlock Margin="0,12,0,0" Foreground="DimGray" TextWrapping="Wrap"
               Text="Approve asks Windows Hello (a typed YES if Hello is unavailable) and mints the ticket here. Nothing is editable before that. Cancel, or closing this window, denies the request."/>
    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,14,0,0">
      <Button Name="ok" Content="Approve" Width="112" Height="32" IsDefault="True"/>
      <Button Name="no" Content="Cancel" Width="112" Height="32" Margin="8,0,0,0" IsCancel="True"/>
    </StackPanel>
  </StackPanel>
</Window>
'@

try {
    $w = [Windows.Markup.XamlReader]::Parse($xaml)
} catch {
    # No desktop / no WPF: fail CLOSED, and say why so the remote surface can answer instead.
    Write-AqGuiErr "cannot show the window ($($_.Exception.Message)) - denying; answer on the hub or the phone"
    Write-AqGuiVerdict $verdictPath 'denied' -1 0 'window-unavailable'
    exit 3
}

$w.FindName('scope').Text = ($globs -join "`r`n")
$w.FindName('why').Text = 'Why: ' + $(if ($purpose) { $purpose } else { '(not stated)' })
$w.FindName('who').Text = "Requested by $session on $hostName in $repo; valid up to $hours h once approved. Ticket id $id."

$script:aqAnswer = $null
$w.FindName('ok').Add_Click({ $script:aqAnswer = 'approved' })
$w.FindName('no').Add_Click({ $script:aqAnswer = 'denied' })
$w.Add_Closed({ if (-not $script:aqAnswer) { $script:aqAnswer = 'denied' } })

[void]$w.ShowDialog()

if ($script:aqAnswer -ceq 'approved') {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $code = Invoke-AqGuiMint $globs $hours $TicketScript
    $sw.Stop()
    Write-AqGuiVerdict $verdictPath 'approved' $code $sw.ElapsedMilliseconds ''
    if ($code -eq 0) { exit 0 }
    exit 5
}

Write-AqGuiVerdict $verdictPath 'denied' -1 0 ''
exit 3
