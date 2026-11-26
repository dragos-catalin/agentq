#requires -Version 5.1
<#
.SYNOPSIS
  Ask the OWNER to approve an edit ticket (a GUI window), then mint it. The agent-side half of
  remote/local consent.

.DESCRIPTION
  WHY THIS EXISTS
    An agent that touches a trust surface (hooks, rules, instructions, agents, skills, AGENTS.md,
    .github/**) needs a user-issued edit ticket. `rules-ticket.ps1 -Issue` REFUSES to run with a
    redirected console - by design, the mint is a human gesture - so an agent can never mint one
    itself, and asking the owner to type a command breaks the flow entirely.
    This tool moves the gesture into a window: the agent asks, the window states EXACTLY which paths
    would become editable, for how long and why, the owner clicks Approve, and the ticket is minted
    from a process that owns a real console. Two clicks, no command to type.

  THE FLOW
    agentq approve -Paths 'a','b' -Purpose "why" [-Hours 2] [-MaxMin 10]
      1. writes <home>\approvals\<id>.json      - the request: scope, purpose, session, host, expiry
      2. starts agentq-approve-gui.ps1 -STA in its own process (the window; nothing else is shown)
      3. polls <id>.verdict.json for up to -MaxMin minutes
      4. approved + mint ok  -> exit 0   (the ticket exists and is valid for <Hours>)
         denied              -> exit 3   (nothing was minted)
         approved, mint failed -> exit 5 (the ticket script's own exit code is in the verdict)
         no answer in -MaxMin  -> exit 7 (the request STAYS OPEN for the remote surface)
         -MaxMin 0             -> exit 4 (record only: never start a window, never wait)

  THE SECOND SURFACE (remote)
    -MaxMin 0 records the request and returns at once. The hub `/ops/agentq` page and the Codwen
    phone app can answer it with a biometric proof. The ticket itself can only be minted on THIS
    machine - its HMAC key is a DPAPI blob in ~/.copilot/rules/ticket.key - so a remote approval is
    CONSENT, never the mint.

  SAFETY
    The request record carries NO secret. Nothing is minted before a verdict exists. A window the
    owner merely closes answers `denied`: silence is never consent. The scope string is passed to the
    ticket script as ONE comma-joined value, which is the form that script documents and splits
    itself (a real array handed to Start-Process is joined with spaces and would bind only the first
    element).

  Exit: 0 approved, 3 denied, 4 recorded (not answered), 5 mint failed, 7 timed out, 2 bad arguments.

  Examples:
    pwsh -NoProfile -File ps/bin/agentq-approve.ps1 -Paths 'packages/x/**' -Purpose "fix the guard"
    pwsh -NoProfile -File ps/bin/agentq-approve.ps1 -Paths 'a,b' -Purpose "batch" -Hours 1 -MaxMin 5
    pwsh -NoProfile -File ps/bin/agentq-approve.ps1 -Paths 'a' -Purpose "answer on the phone" -MaxMin 0
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # The paths the ticket must authorise - the exact globs, as `rules-ticket.ps1 -Scope` takes them.
    # ACCEPTED FORMS: `-Paths a,b` (ONE comma-joined value - the CLI form, split below) and the array an
    # in-process caller passes (`agentq approve` passes @($Paths -join ',')). The SPACE form `-Paths a b`
    # is refused by PowerShell's own binder before this script runs, so commas are NOT optional on the
    # CLI: `ValueFromRemainingArguments` is inert under CmdletBinding and would not have collected it.
    [string[]]$Paths,
    [string]$Purpose = '',
    # Ticket lifetime in hours (the mint caps at 2; a larger value is clamped and reported).
    [double]$Hours = 2,
    # How long to wait for the owner's answer. 0 = record only, never start a window (exit 4).
    [double]$MaxMin = 10,
    [switch]$Json,
    # Overrides for tests / a non-standard install root. Defaults: the hooks dir, and the GUI beside
    # this script - so an override is only ever needed to replace the HUMAN with a stub.
    [string]$TicketScript,
    [string]$GuiScript,
    [switch]$Help
)

$ErrorActionPreference = 'Continue'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

if ($Help) {
    Get-Help $PSCommandPath -Detailed
    exit 0
}

function Write-AqApproveErr([string]$m) { [Console]::Error.WriteLine("agentq approve: $m") }

# <home>\approvals, honouring AGENTQ_HOME so a fixture never touches the real coordination state.
function Get-AqApprovalDir {
    if ($env:AGENTQ_HOME) { return (Join-Path $env:AGENTQ_HOME 'approvals') }
    $coord = if ($env:CODAI_COORD) { $env:CODAI_COORD } else { Join-Path $env:USERPROFILE '.codai\coord' }
    Join-Path $coord 'approvals'
}

# A real array out of any of: -Paths a,b / -Paths 'a,b' / -Paths a b (an in-process caller passes an
# array; `pwsh -File -Paths a,b` binds ONE string - the repo's documented trap).
function Normalize-AqGlob([string[]]$raw) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($s in @($raw)) {
        if (-not $s) { continue }
        foreach ($p in ([string]$s -split ',')) { $t = $p.Trim(); if ($t) { $out.Add($t) } }
    }
    return , $out.ToArray()
}

function Write-AqAtomic([string]$Path, [string]$Text) {
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, $Text, [Text.UTF8Encoding]::new($false))
    Move-Item -Force -LiteralPath $tmp -Destination $Path
}

# Poll for the window's answer. Returns $null when the bound expires (the request stays open).
function Wait-AqVerdict([string]$Path, [double]$MaxMin, [int]$PollMs = 750) {
    $deadline = (Get-Date).AddMinutes($MaxMin)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            try {
                $v = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -DateKind String
                if ($v.verdict) { return $v }
            } catch { }
        }
        Start-Sleep -Milliseconds $PollMs
    }
    return $null
}

$globs = Normalize-AqGlob $Paths
# A glob that begins with '-' is a typo, not a path: refuse it rather than mint a ticket for a scope
# nobody wrote (the binder refuses most of these first, this is the belt to its braces).
foreach ($g in @($globs)) {
    if ($g.StartsWith('-')) {
        Write-AqApproveErr "unexpected argument '$g' - scope globs are comma-separated (-Paths 'a,b')"
        exit 2
    }
}
if (-not $globs -or $globs.Count -eq 0) {
    Write-AqApproveErr '-Paths is required: the exact paths the ticket must authorise (a,b or an array)'
    exit 2
}
if ($Hours -le 0) { $Hours = 2 }
if ($Hours -gt 2) {
    Write-AqApproveErr "a ticket lives at most 2 h on this machine; -Hours $Hours clamped to 2"
    $Hours = 2
}
if (-not $TicketScript) { $TicketScript = Join-Path $env:USERPROFILE '.copilot\hooks\rules-ticket.ps1' }
if (-not $GuiScript) { $GuiScript = Join-Path $PSScriptRoot 'agentq-approve-gui.ps1' }

$dir = Get-AqApprovalDir
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$id = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
$reqPath = Join-Path $dir "$id.json"
$verPath = Join-Path $dir "$id.verdict.json"

$session = if ($env:AGENTQ_SESSION) { $env:AGENTQ_SESSION } else { "term-$PID" }
$repoLeaf = ''
try { $repoLeaf = Split-Path -Leaf (Get-Location).Path } catch { }
$rec = [ordered]@{
    id         = $id
    at         = (Get-Date).ToUniversalTime().ToString('o')
    scope      = @($globs)
    purpose    = $Purpose
    hours      = $Hours
    session    = $session
    host       = $env:COMPUTERNAME
    repo       = $repoLeaf
    expires_at = (Get-Date).ToUniversalTime().AddMinutes(15).ToString('o')
}
Write-AqAtomic $reqPath ($rec | ConvertTo-Json -Depth 4)
if (Get-Command Write-Journal -ErrorAction SilentlyContinue) {
    Write-Journal @{ event = 'approval-request'; resource = "approval:$id"; id = $id; scope = @($globs); purpose = $Purpose; hours = $Hours; session = $session }
}

if ($MaxMin -le 0) {
    if ($Json) { [ordered]@{ id = $id; status = 'pending'; request = $reqPath } | ConvertTo-Json -Compress }
    else {
        Write-Output "approval requested: $id"
        Write-Output "  scope   : $($globs -join ', ')"
        Write-Output "  purpose : $(if ($Purpose) { $Purpose } else { '(not stated)' })"
        Write-Output "  valid   : up to $Hours h once approved"
        Write-Output "  answer  : hub /ops/agentq, or the Codwen phone app (no window was started)"
        Write-Output "  request : $reqPath"
    }
    exit 4
}

if (-not (Test-Path -LiteralPath $GuiScript)) {
    Write-AqApproveErr "the window script is missing: $GuiScript"
    exit 2
}

# -STA: WPF needs a single-threaded apartment, and pwsh 7's default is not one.
$gui = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-STA', '-File', $GuiScript, '-Request', $reqPath, '-TicketScript', $TicketScript) -PassThru
$v = Wait-AqVerdict $verPath $MaxMin

if (-not $v) {
    Write-Output "approval pending: $id (no answer within $MaxMin min; pid $($gui.Id) may still be showing the window)"
    Write-Output "  the request is still open - hub /ops/agentq, or the Codwen phone app"
    Write-Output "  request: $reqPath"
    exit 7
}

$verdict = "$($v.verdict)"
$mintExit = -1
if ($v.PSObject.Properties['ticket_exit'] -and $null -ne $v.ticket_exit) { $mintExit = [int]$v.ticket_exit }

if ($verdict -ceq 'approved' -and $mintExit -eq 0) {
    if ($Json) { [ordered]@{ id = $id; status = 'approved'; hours = $Hours; scope = @($globs); verdict = $verPath } | ConvertTo-Json -Compress }
    else {
        Write-Output "approved: the ticket is valid for $Hours h (id $id)"
        Write-Output "  scope: $($globs -join ', ')"
    }
    exit 0
}
if ($verdict -ceq 'approved') {
    Write-AqApproveErr "the owner approved, but the mint failed (rules-ticket exit $mintExit) - no ticket is valid"
    Write-Output "  verdict: $verPath"
    exit 5
}

Write-Output "denied: nothing was minted (id $id)"
Write-Output "  verdict: $verPath"
exit 3
