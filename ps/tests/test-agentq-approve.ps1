#requires -Version 5.1
<#
  Test: agentq-approve.ps1 + agentq-approve-gui.ps1 - the edit-ticket approval path.

  Hermetic: every run points AGENTQ_HOME at a temp dir and replaces the HUMAN (a stub window script)
  and the TICKET MINT (a stub ticket script that records the argv it received). No window is ever
  shown, no real ticket is ever minted, and the real coordination state is never touched.

  The load-bearing assertions:
    - nothing is minted before a verdict exists (denied and timed-out paths must not run the mint)
    - the scope reaches the ticket script as ONE comma-joined value (the form it splits itself)
    - an approved-but-failed mint is NOT reported as success
    - a mutation of the verdict comparison is DETECTED (the suite is not vacuously green)
#>
param()

$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) { $PSNativeCommandUseErrorActionPreference = $false }

$bin = (Resolve-Path (Join-Path $PSScriptRoot '..\bin')).Path
$cli = Join-Path $bin 'agentq-approve.ps1'
$gui = Join-Path $bin 'agentq-approve-gui.ps1'

$pass = 0; $fail = 0
function Ok([string]$name) { $script:pass++; Write-Output "PASS $name" }
function Bad([string]$name, [string]$why) { $script:fail++; Write-Output "FAIL $name - $why" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aqapprove-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
New-Item -ItemType Directory -Force -Path $env:AGENTQ_HOME | Out-Null
$approvals = Join-Path $env:AGENTQ_HOME 'approvals'
$argvFile = Join-Path $env:AGENTQ_HOME 'ticket-args.txt'

# --- fixtures ------------------------------------------------------------------------------------
# The mint stub: records what it was called with, then exits with $env:FAKE_TICKET_EXIT (0 by default).
$fakeTicket = Join-Path $tmp 'fake-ticket.ps1'
@'
param([string[]]$Scope, [double]$Hours)
$f = Join-Path $env:AGENTQ_HOME 'ticket-args.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
$flat = @($Scope | ForEach-Object { ([string]$_ -split ',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
"scope=$($flat -join '|') hours=$Hours" | Set-Content -LiteralPath $f
if ($env:FAKE_TICKET_EXIT) { exit [int]$env:FAKE_TICKET_EXIT }
exit 0
'@ | Set-Content -LiteralPath $fakeTicket -Encoding UTF8

# A stub WINDOW that answers immediately: the CLI launches it with -Request only, so the answer is
# keyed off the request's purpose ("DENY"/"MINTFAIL"), which keeps the stub version-proof.
function New-FakeGui([string]$path, [string]$verdict, [int]$ticketExit) {
    @"
param([string]`$Request, [string]`$TicketScript)
`$v = Join-Path (Split-Path -Parent `$Request) ((Split-Path -Leaf `$Request) -replace '\.json$','.verdict.json')
'{"verdict":"$verdict","ticket_exit":$ticketExit}' | Set-Content -LiteralPath `$v
"@ | Set-Content -LiteralPath $path -Encoding UTF8
}
$guiDeny = Join-Path $tmp 'fgui-deny.ps1'; New-FakeGui $guiDeny 'denied' 0
$guiOk = Join-Path $tmp 'fgui-ok.ps1'; New-FakeGui $guiOk 'approved' 0
$guiMintFail = Join-Path $tmp 'fgui-mintfail.ps1'; New-FakeGui $guiMintFail 'approved' 9

function Run([string[]]$argv) {
    $o = & pwsh -NoProfile @argv 2>&1
    return @{ code = $LASTEXITCODE; out = ($o -join "`n") }
}
function LastRequest([string]$id) { Join-Path $approvals "$id.json" }
function NewestRequest {
    if (-not (Test-Path -LiteralPath $approvals)) { return $null }
    return (Get-ChildItem -LiteralPath $approvals -Filter '*.json' | Where-Object { $_.Name -notlike '*.verdict.json' } |
        Sort-Object LastWriteTime | Select-Object -Last 1)
}

try {
    # --- 1. -Paths is required -------------------------------------------------------------------
    $r = Run @('-File', $cli, '-Purpose', 'no scope', '-MaxMin', '0')
    if ($r.code -eq 2) { Ok 'no -Paths is refused with exit 2' } else { Bad 'no -Paths is refused with exit 2' "exit $($r.code)" }

    # --- 2. -MaxMin 0 records the request and never waits ----------------------------------------
    $r = Run @('-File', $cli, '-Paths', 'packages/x/**,packages/y/**', '-Purpose', 'record only', '-MaxMin', '0')
    $reqFile = NewestRequest
    $recOk = $false; $why = 'no request file'
    if ($reqFile) {
        try {
            $rec = Get-Content -LiteralPath $reqFile.FullName -Raw | ConvertFrom-Json -DateKind String
            $scopeOk = (@($rec.scope).Count -eq 2 -and $rec.scope[0] -eq 'packages/x/**' -and $rec.scope[1] -eq 'packages/y/**')
            $secretFields = @($rec.PSObject.Properties.Name | Where-Object { $_ -match 'token|secret|key$|password' })
            # The two clocks must both be real and separately named: -Hours is the TICKET's life after
            # approval, the REQUEST must stay decidable for -RequestTtlMin. A missing parameter made
            # expires_at == at (instantly stale) and a magic 15 min made a remote answer impossible;
            # both are caught here.
            $ttlMin = $null
            if ($rec.at -and $rec.expires_at) { $ttlMin = ([datetime]$rec.expires_at - [datetime]$rec.at).TotalMinutes }
            $clockOk = ($null -ne $ttlMin -and $ttlMin -ge 59 -and $ttlMin -le 61 -and $rec.hours -eq 2)
            $recOk = $scopeOk -and $rec.purpose -eq 'record only' -and $secretFields.Count -eq 0 -and -not $rec.ticket_exit -and $clockOk
            if (-not $recOk) { $why = "scope=$($rec.scope -join ',') secretFields=$($secretFields -join ',') ttlMin=$ttlMin hours=$($rec.hours)" }
        } catch { $why = "unparseable request: $($_.Exception.Message)" }
    }
    if ($r.code -eq 4 -and $recOk) { Ok '-MaxMin 0 records the request (scope + purpose, no secret) and exits 4' }
    else { Bad '-MaxMin 0 records the request and exits 4' ("exit $($r.code); $why; out=" + ((@($r.out -split "`n") | Where-Object { $_ } | Select-Object -First 2) -join ' ~ ')) }

    # --- 2a. the request window is the OVERRIDE, not a hardcoded number --------------------------
    $rTtl = Run @('-File', $cli, '-Paths', 'a', '-MaxMin', '0', '-RequestTtlMin', '5')
    $reqTtl = NewestRequest
    $ttl2 = $null
    if ($reqTtl) {
        $rec2 = Get-Content -LiteralPath $reqTtl.FullName -Raw | ConvertFrom-Json -DateKind String
        $ttl2 = ([datetime]$rec2.expires_at - [datetime]$rec2.at).TotalMinutes
    }
    if ($rTtl.code -eq 4 -and $null -ne $ttl2 -and $ttl2 -ge 4.9 -and $ttl2 -le 5.1) { Ok '-RequestTtlMin is honoured (the window is not hardcoded)' }
    else { Bad '-RequestTtlMin is honoured' "exit $($rTtl.code) ttlMin=$ttl2" }

    # --- 2b. a typo can never record a request ----------------------------------------------------
    # Two shapes PowerShell's own binder refuses: a stray flag, and the space-separated form
    # (`-Paths a b` - the trap the -Paths contract documents; commas are the CLI form). Both must leave
    # the approvals dir untouched: a scope nobody wrote must never be able to become a ticket.
    $before = @(Get-ChildItem -LiteralPath $approvals -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.verdict.json' }).Count
    $rFlag = Run @('-File', $cli, '-Paths', 'a', '-Bogus', '1', '-MaxMin', '0')
    $rSpace = Run @('-File', $cli, '-Paths', 'a', 'b', '-MaxMin', '0')
    $after = @(Get-ChildItem -LiteralPath $approvals -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike '*.verdict.json' }).Count
    if ($rFlag.code -ne 0 -and $rSpace.code -ne 0 -and $after -eq $before) { Ok 'a stray flag and the space form are both refused and record nothing' }
    else { Bad 'a stray flag and the space form are both refused and record nothing' "flag=$($rFlag.code) space=$($rSpace.code) requests $before->$after" }

    # --- 3. denied: exit 3 and the mint NEVER runs -----------------------------------------------
    Remove-Item -Force -LiteralPath $argvFile -ErrorAction SilentlyContinue
    $r = Run @('-File', $cli, '-Paths', 'a,b', '-Purpose', 'DENY', '-MaxMin', '1', '-GuiScript', $guiDeny)
    if ($r.code -eq 3 -and -not (Test-Path -LiteralPath $argvFile)) { Ok 'denied exits 3 and mints nothing' }
    else { Bad 'denied exits 3 and mints nothing' "exit $($r.code), mint-ran=$(Test-Path -LiteralPath $argvFile)" }

    # --- 4. approved + mint ok: exit 0 -----------------------------------------------------------
    $r = Run @('-File', $cli, '-Paths', 'a,b', '-Purpose', 'fine', '-MaxMin', '1', '-GuiScript', $guiOk)
    if ($r.code -eq 0) { Ok 'approved with a successful mint exits 0' } else { Bad 'approved with a successful mint exits 0' "exit $($r.code): $($r.out)" }

    # --- 5. approved but the mint failed: NOT success --------------------------------------------
    $r = Run @('-File', $cli, '-Paths', 'a', '-Purpose', 'MINTFAIL', '-MaxMin', '1', '-GuiScript', $guiMintFail)
    if ($r.code -eq 5) { Ok 'approved but mint-failed exits 5 (never reported as approved)' }
    else { Bad 'approved but mint-failed exits 5' "exit $($r.code)" }

    # --- 6. no answer inside the bound: exit 7, request stays open --------------------------------
    $guiNever = Join-Path $tmp 'fgui-never.ps1'
    'param([string]$Request, [string]$TicketScript)' | Set-Content -LiteralPath $guiNever -Encoding UTF8
    Remove-Item -Force -LiteralPath $argvFile -ErrorAction SilentlyContinue
    $r = Run @('-File', $cli, '-Paths', 'a', '-Purpose', 'silence', '-MaxMin', '0.05', '-GuiScript', $guiNever)
    if ($r.code -eq 7 -and -not (Test-Path -LiteralPath $argvFile)) { Ok 'no answer inside the bound exits 7 and mints nothing' }
    else { Bad 'no answer inside the bound exits 7' "exit $($r.code), mint-ran=$(Test-Path -LiteralPath $argvFile)" }

    # --- 7. the WINDOW script itself: -AutoApprove mints with the scope as ONE comma-joined value -
    Remove-Item -Force -LiteralPath $argvFile -ErrorAction SilentlyContinue
    $idOk = '20260101-000000-testok'
    $reqOk = Join-Path $approvals "$idOk.json"
    @{ id = $idOk; scope = @('a,b'); purpose = 'auto'; hours = 2; session = 's'; host = 'h'; repo = 'r' } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $reqOk -Encoding UTF8
    $r = Run @('-File', $gui, '-Request', $reqOk, '-AutoApprove', '-TicketScript', $fakeTicket)
    $verdictOk = Get-Content -LiteralPath (Join-Path $approvals "$idOk.verdict.json") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -DateKind String
    $argsLine = Get-Content -LiteralPath $argvFile -Raw -ErrorAction SilentlyContinue
    $mintOk = ($r.code -eq 0 -and "$($verdictOk.verdict)" -ceq 'approved' -and [int]$verdictOk.ticket_exit -eq 0)
    if ($mintOk -and $argsLine -match 'scope=a\|b hours=2') { Ok 'the window mints with the scope split to a,b and the requested hours' }
    elseif ($mintOk) { Bad 'the window mints with the scope split to a,b and the requested hours' "argv='$argsLine'" }
    else { Bad 'the window mints' "exit $($r.code) verdict=$($verdictOk.verdict) ticket_exit=$($verdictOk.ticket_exit)" }

    # --- 8. the window: -AutoDeny denies and mints nothing ---------------------------------------
    Remove-Item -Force -LiteralPath $argvFile -ErrorAction SilentlyContinue
    $idNo = '20260101-000000-testno'
    $reqNo = Join-Path $approvals "$idNo.json"
    @{ id = $idNo; scope = @('a'); purpose = 'auto no'; hours = 2 } | ConvertTo-Json -Compress |
        Set-Content -LiteralPath $reqNo -Encoding UTF8
    $r = Run @('-File', $gui, '-Request', $reqNo, '-AutoDeny', '-TicketScript', $fakeTicket)
    $verdictNo = Get-Content -LiteralPath (Join-Path $approvals "$idNo.verdict.json") -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -DateKind String
    if ($r.code -eq 3 -and $verdictNo.verdict -eq 'denied' -and -not (Test-Path -LiteralPath $argvFile)) { Ok '-AutoDeny answers denied and mints nothing' }
    else { Bad '-AutoDeny answers denied and mints nothing' "exit $($r.code) verdict=$($verdictNo.verdict)" }

    # --- 9. the window: a missing ticket script is a FAILED mint, not an approval -----------------
    $r = Run @('-File', $gui, '-Request', $reqNo, '-AutoApprove', '-TicketScript', (Join-Path $tmp 'nope.ps1'))
    if ($r.code -eq 5) { Ok 'a missing ticket script exits 5 (failed mint, never success)' }
    else { Bad 'a missing ticket script exits 5' "exit $($r.code)" }

    # --- 10. MUTATION: flipping the verdict comparison must be DETECTED ---------------------------
    $mutant = Join-Path $tmp 'agentq-approve-mutant.ps1'
    $text = Get-Content -LiteralPath $cli -Raw
    $mtext = $text -creplace "\(\`$verdict -ceq 'approved' -and \`$mintExit -eq 0\)", "(`$verdict -ceq 'approved' -and `$mintExit -ne 0)"
    if ($mtext -cne $text) {
        Set-Content -LiteralPath $mutant -Value $mtext -Encoding UTF8 -NoNewline
        $r = Run @('-File', $mutant, '-Paths', 'a,b', '-Purpose', 'fine', '-MaxMin', '1', '-GuiScript', $guiOk)
        if ($r.code -ne 0) { Ok 'mutation detected: an approved verdict with a good mint must exit 0' }
        else { Bad 'mutation detected' 'the mutant also exited 0 - the assertion is vacuous' }
    }
    else { Bad 'mutation applied' 'the verdict comparison anchor was not found in the CLI (rename it?)' }
}
finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
    Remove-Item Env:AGENTQ_HOME -ErrorAction SilentlyContinue
}

Write-Output "agentq-approve: pass=$pass fail=$fail"
if ($fail -gt 0) { Write-Output 'SOME FAILED'; exit 1 }
Write-Output 'ALL PASS'
exit 0
