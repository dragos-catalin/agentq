# 2026-11-23: `bump` had no target selector, and its bare form matched tickets by SESSION silently. A
# waiter ran `agentq bump -By 20` and raised TWO OTHER sessions' tickets (a land + a perf(gate) land)
# ahead of its own - and `status` never showed the id of its own ticket, so it could not target one.
# This suite pins the fixed surface:
#   (a) -Session <id> bumps ONLY that session's ticket;
#   (b) the bare form REPORTS which ticket it bumped (id + session);
#   (c) a session (or id) with no waiting ticket bumps nothing and exits 2;
#   (d) -Id targets ONE ticket, and -Id with -Session is refused;
#   (e) `status` prints the caller's own waiting ticket ids (the == MINE line).
# Isolated AGENTQ_HOME + AGENTQ_CONFIG. Tickets are crafted directly (pid = this process, so they look
# alive) instead of spawning real `run`s, so the suite is fast and does not depend on machine load.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqbump-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_NO_REGISTRY = '1'
$env:AGENTQ_NO_ADMISSION = '1'
New-Item -ItemType Directory -Force $env:AGENTQ_HOME | Out-Null
# overridesPerHour 0 = unlimited, so the suite's several bumps never hit the hourly override budget.
$cfg = Join-Path $tmp 'agentq-config.json'
@{ machineCap = 1; quickBurst = 1; agingMin = 0; idleYieldMin = 0; idleCpuSec = 10; bumpMax = 50; burstMax = 2; burstMaxMin = 60; overridesPerHour = 0; minFreeCommitGB = 0 } | ConvertTo-Json | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
# a temp git repo: the top-level renewal path (Renew-ForCwd) runs for `bump` and wants a cwd we own.
$repo = Join-Path $tmp 'repo'; New-Item -ItemType Directory -Force $repo | Out-Null
git -C $repo init -q -b main; git -C $repo config user.email t@t; git -C $repo config user.name t
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }
# Run agentq in a child pwsh and return its exit code, with stdout+stderr captured into $lastOut. The
# args are splatted as an ARRAY (each element stays one argv - a -Reason with spaces must not split),
# and $ErrorActionPreference is relaxed for the call: a native command that writes to stderr becomes an
# error record under 'Stop' and would abort the whole suite instead of being captured as text.
$script:lastOut = ''
function RunAq([string[]]$a) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  Push-Location $repo
  try { $script:lastOut = (@(& pwsh -NoProfile -File $Aq @a 2>&1) -join "`n"); $code = $LASTEXITCODE }
  finally { Pop-Location; $ErrorActionPreference = $prev }
  $code
}

# Two WAITING tickets owned by different sessions on the same queue. `pid` = this process (alive) and
# procStart = its start time, so Get-Live keeps them; held = $false, so they are waiters.
$qdir = Join-Path $env:AGENTQ_HOME (Join-Path 'queues' 'build_demo')
New-Item -ItemType Directory -Force $qdir | Out-Null
$meStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
function New-TicketFile([string]$seq, [string]$id, [string]$sess, [string]$purpose) {
  $f = Join-Path $qdir ("{0}-{1}.json" -f $seq, $id)
  $obj = [ordered]@{ id = $id; seq = [long]$seq; resource = 'build:demo'; pid = $PID; procStart = $meStart; session = $sess; purpose = $purpose; cmd = ''; repo = 'repo'; host = 'h'; user = 'u'; created = [DateTime]::UtcNow.ToString('o'); v = 3; lane = 'gate'; prio = 0; bump = 0; held = $false; ready = $true }
  [IO.File]::WriteAllText($f, ($obj | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText("$f.hb", '', [Text.UTF8Encoding]::new($false))
  $f
}
$idA = 'aaa11111'; $idB = 'bbb22222'
$fA = New-TicketFile '00000001' $idA 'sessA' 'wait-A'
$fB = New-TicketFile '00000002' $idB 'sessB' 'wait-B'
function BumpOf([string]$f) { ([IO.File]::ReadAllText($f) | ConvertFrom-Json).bump }

# The caller's own session is sessA: that is "my ticket".
$env:AGENTQ_SESSION = 'sessA'
$lastOut = ''

# (a) -Session <mine> bumps ONLY my ticket.
$rc = RunAq @('bump', '-Session', 'sessA', '-By', '20', '-Reason', 'test: session selector picks mine')
Check 'a1 -Session exits 0' ($rc -eq 0) "exit $rc :: $lastOut"
Check 'a2 -Session bumped my ticket to 20' ((BumpOf $fA) -eq 20) "A.bump=$(BumpOf $fA)"
Check 'a3 -Session left the other ticket at 0' ((BumpOf $fB) -eq 0) "B.bump=$(BumpOf $fB)"
Check 'a4 -Session output names the bumped ticket + session' ($lastOut -match [regex]::Escape($idA) -and $lastOut -match 'sessA') $lastOut

# (b) the bare form reports WHICH ticket it bumped (id + session), and bumps mine.
$rc = RunAq @('bump', '-By', '5', '-Reason', 'test: bare form reports target')
Check 'b1 bare bump exits 0' ($rc -eq 0) "exit $rc :: $lastOut"
Check 'b2 bare bump reports the ticket id it bumped' ($lastOut -match [regex]::Escape($idA)) $lastOut
Check 'b3 bare bump reports the session it bumped' ($lastOut -match 'sessA') $lastOut
Check 'b4 bare bump raised my ticket to 25' ((BumpOf $fA) -eq 25) "A.bump=$(BumpOf $fA)"
Check 'b5 bare bump did not touch the other ticket' ((BumpOf $fB) -eq 0) "B.bump=$(BumpOf $fB)"

# (c) a non-existent session selects nothing: exit 2, no ticket changed.
$beforeA = BumpOf $fA; $beforeB = BumpOf $fB
$rc = RunAq @('bump', '-Session', 'no-such-session', '-By', '20', '-Reason', 'test: unknown session bumps nothing')
Check 'c1 unknown session exits 2' ($rc -eq 2) "exit $rc :: $lastOut"
Check 'c2 unknown session changed nothing' ((BumpOf $fA) -eq $beforeA -and (BumpOf $fB) -eq $beforeB) "A=$(BumpOf $fA) B=$(BumpOf $fB)"
Check 'c3 unknown session output names the selector' ($lastOut -match 'no-such-session') $lastOut

# (d) -Id targets ONE ticket; -Id with -Session is refused (mutually exclusive).
$rc = RunAq @('bump', '-Id', $idB, '-By', '7', '-Reason', 'test: -Id targets one ticket')
Check 'd1 -Id exits 0' ($rc -eq 0) "exit $rc :: $lastOut"
Check 'd2 -Id bumped only B' ((BumpOf $fB) -eq 7 -and (BumpOf $fA) -eq $beforeA) "A=$(BumpOf $fA) B=$(BumpOf $fB)"
$rc = RunAq @('bump', '-Id', $idB, '-Session', 'sessA', '-By', '7', '-Reason', 'test: mutually exclusive')
Check 'd3 -Id with -Session is refused (exit 2)' ($rc -eq 2) "exit $rc :: $lastOut"

# (e) `status` shows MY waiting ticket id (the == MINE line), so a waiter can find the hash to target.
$null = RunAq @('status', '-All')
$o = $lastOut
Check 'e1 status prints == MINE with my ticket id' ($o -match '== MINE session sessA' -and $o -match [regex]::Escape($idA)) (($o -split "`n" | Where-Object { $_ -match 'MINE' }) -join ' | ')

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }