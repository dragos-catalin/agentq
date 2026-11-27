# The heal policy of `agentq-cloud.ps1` when a queued job is never claimed. Three properties each fail
# silently in production if a later edit regresses them, so they are pinned here:
#   (i)   a heal is ATTEMPTED AGAIN after the doubling backoff when the workspace is still stale - the old
#         one-shot $healedAt guard healed once and then died at the deadline (38 "no result before
#         deadline" in the journal);
#   (ii)  the reset is SKIPPED while ANOTHER job is in flight on the workspace - the old heal only asked
#         whether the CALLER's own job had been claimed, so a reset rebooted the VM out from under a peer's
#         build (ws-codai, 2026-11-26);
#   (iii) the attempt cap is respected - after 3 heals the workspace is never reset again.
#
# The policy helpers live in bin\agentq-cloud.ps1 and are extracted from it by AST: the suite drives the
# PRODUCTION definitions (a rename or a reference to the caller's script scope fails here), not a copy. A
# final block pins the WIRING in the script itself (the functions are actually called, the busy object is
# actually read, the old $healedAt guard is actually gone), so the policy cannot be left orphaned.
param([string]$Source = (Join-Path (Split-Path $PSScriptRoot) 'bin\agentq-cloud.ps1'))
$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { Write-Host "PASS $Name" } else { Write-Host "FAIL $Name - $Detail"; $script:fail++ }
}

# ---- the policy helpers, straight out of the production file --------------------------------------
$tok = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Source, [ref]$tok, [ref]$errs)
$fns = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match '(?i)CloudHeal|HealBackoff|HealFirstInterval|CloudPeerBusy' }, $true))
Check 'the heal-policy helpers are defined in agentq-cloud.ps1' ($fns.Count -ge 3) "found $($fns.Count) in $Source"
if ($fns.Count) { . ([scriptblock]::Create((($fns | ForEach-Object { $_.Extent.Text }) -join "`n"))) }
if (-not (Get-Command Get-CloudHealDecision -ErrorAction SilentlyContinue)) {
  Write-Host "$([math]::Max($fail, 1)) FAILED (Get-CloudHealDecision is not in $Source - nothing to drive)"
  exit 1
}

$now = [DateTime]::UtcNow

# ---- Get-HealBackoffMin: the doubling, and the -StaleClaimMin floor it is built on -----------------
Check 'backoff #1 is the first interval' ((Get-HealBackoffMin -HealsDone 0 -FirstMin 3) -eq 3) "got $(Get-HealBackoffMin -HealsDone 0 -FirstMin 3)"
Check 'backoff doubles each attempt' (((Get-HealBackoffMin -HealsDone 1 -FirstMin 3) -eq 6) -and ((Get-HealBackoffMin -HealsDone 2 -FirstMin 3) -eq 12)) "got $(Get-HealBackoffMin -HealsDone 1 -FirstMin 3)/$(Get-HealBackoffMin -HealsDone 2 -FirstMin 3)"
Check 'backoff follows a custom first interval' ((Get-HealBackoffMin -HealsDone 2 -FirstMin 5) -eq 20) "got $(Get-HealBackoffMin -HealsDone 2 -FirstMin 5)"
Check 'a zero first interval means no pacing' ((Get-HealBackoffMin -HealsDone 3 -FirstMin 0) -eq 0) ''

# ---- Test-CloudPeerBusy: the marker that decides "is a peer run alive here?" ------------------------
$future = $now.AddMinutes(30).ToString('o'); $past = $now.AddMinutes(-30).ToString('o')
Check '(ii) no marker = no peer' ((Test-CloudPeerBusy -Marker $null -SelfJobId 'me' -Now $now) -eq $false) ''
Check '(ii) a live peer marker = busy' ((Test-CloudPeerBusy -Marker @{ job = 'peer'; until = $future } -SelfJobId 'me' -Now $now) -eq $true) ''
Check '(ii) a marker that names MY job is not a peer' ((Test-CloudPeerBusy -Marker @{ job = 'me'; until = $future } -SelfJobId 'me' -Now $now) -eq $false) ''
Check '(ii) an EXPIRED peer marker is not a live peer (a wedge, not a peer)' ((Test-CloudPeerBusy -Marker @{ job = 'peer'; until = $past } -SelfJobId 'me' -Now $now) -eq $false) ''
Check '(ii) a marker without until falls back to at+timeoutSec (live)' ((Test-CloudPeerBusy -Marker @{ job = 'peer'; at = $now.AddMinutes(-5).ToString('o'); timeoutSec = 3600 } -SelfJobId 'me' -Now $now) -eq $true) ''
Check '(ii) at+timeoutSec in the past is not a live peer' ((Test-CloudPeerBusy -Marker @{ job = 'peer'; at = $now.AddMinutes(-90).ToString('o'); timeoutSec = 3600 } -SelfJobId 'me' -Now $now) -eq $false) ''
Check '(ii) a JSON STRING marker is parsed, not treated as opaque' ((Test-CloudPeerBusy -Marker ('{"job":"peer","until":"' + $future + '"}') -SelfJobId 'me' -Now $now) -eq $true) ''
Check '(ii) an unparseable marker never blocks a heal' ((Test-CloudPeerBusy -Marker 'not json' -SelfJobId 'me' -Now $now) -eq $false) ''

# ---- Get-CloudHealDecision: the whole policy --------------------------------------------------------
function Dec([hashtable]$Over) {
  $p = @{ NoHeal = $false; Claimed = $false; HealCount = 0; HealMax = 3; SinceCursorMin = 3.1; FirstIntervalMin = 3
    HeartbeatAgeSec = 600; HeartbeatOlderThanQueue = $false; PeerBusy = $false }
  foreach ($k in $Over.Keys) { $p[$k] = $Over[$k] }
  Get-CloudHealDecision @p
}
Check '(iii) the first attempt is due after the first interval' ((Dec @{ HealCount = 0; SinceCursorMin = 3.1 }).action -eq 'act') ''
Check 'a not-yet-due attempt waits' ((Dec @{ HealCount = 0; SinceCursorMin = 2.9 }).action -eq 'wait') ''
# (i) THE REGRESSION: a SECOND failure must be healed too, after the doubled backoff.
Check '(i) a second heal is ATTEMPTED after the 2x backoff (the one-shot bug)' ((Dec @{ HealCount = 1; SinceCursorMin = 6.5 }).action -eq 'act') "action=$((Dec @{ HealCount = 1; SinceCursorMin = 6.5 }).action)"
Check '(i) the second heal is not attempted BEFORE the backoff' ((Dec @{ HealCount = 1; SinceCursorMin = 5.9 }).action -eq 'wait') ''
Check '(i) a third heal is attempted after the 4x backoff' ((Dec @{ HealCount = 2; SinceCursorMin = 12.5 }).action -eq 'act') ''
# (ii) THE PEER GUARD: stale + due, but a peer is running -> never reset.
Check '(ii) a peer in flight SKIPS the reset (never reset a busy workspace)' ((Dec @{ HealCount = 0; SinceCursorMin = 3.1; PeerBusy = $true }).action -eq 'skip-peer') ''
Check '(ii) the peer guard wins even when the heartbeat is stale and the attempt is due' ((Dec @{ HealCount = 2; SinceCursorMin = 20; PeerBusy = $true }).action -eq 'skip-peer') ''
Check '(ii) with no peer the same inputs WOULD reset (the guard is what changes the answer)' ((Dec @{ HealCount = 2; SinceCursorMin = 20; PeerBusy = $false }).action -eq 'act') ''
# (iii) THE CAP.
Check '(iii) the cap is respected at exactly HealMax' ((Dec @{ HealCount = 3; SinceCursorMin = 999; PeerBusy = $false }).action -eq 'cap') ''
Check '(iii) the cap is respected beyond HealMax' ((Dec @{ HealCount = 5; SinceCursorMin = 999 }).action -eq 'cap') ''
Check '(iii) the cap wins even while a peer is running' ((Dec @{ HealCount = 3; PeerBusy = $true }).action -eq 'cap') ''
# parity: -NoHeal and an already-claimed job never heal, and a live heartbeat is left alone.
Check '-NoHeal never heals' ((Dec @{ NoHeal = $true; SinceCursorMin = 999 }).action -eq 'none') ''
Check 'a claimed job never heals' ((Dec @{ Claimed = $true; SinceCursorMin = 999 }).action -eq 'none') ''
Check 'a live heartbeat is left alone' ((Dec @{ HeartbeatAgeSec = 10; HeartbeatOlderThanQueue = $false; HealCount = 0 }).action -eq 'none') ''
Check 'a heartbeat older than the submission is stale even when short' ((Dec @{ HeartbeatAgeSec = 5; HeartbeatOlderThanQueue = $true; HealCount = 0 }).action -eq 'act') ''

# ---- wiring: the policy is actually used by the script, and the old guard is actually gone ---------
$src = [IO.File]::ReadAllText($Source)
Check 'the script CALLS Get-CloudHealDecision' ($src.Contains('Get-CloudHealDecision -NoHeal')) ''
Check 'the script CALLS Test-CloudPeerBusy' ($src.Contains('Test-CloudPeerBusy -Marker')) ''
Check 'the script READS the workspace busy marker' ($src.Contains('"$Bucket/ws/$Ws/busy"')) ''
Check 'the script journals a skipped heal' ($src.Contains("'cloud-heal-skipped'")) ''
Check 'the script caps the heal count at 3' ($src.Contains('$HealMax = 3')) ''
Check 'the script journals a heal attempt index' ($src.Contains('attempt = $healCount')) ''
Check 'the one-shot $healedAt guard is GONE (assignment and gate both removed)' ((-not $src.Contains('$healedAt = [DateTime]::UtcNow')) -and (-not $src.Contains('-not $healedAt'))) 'still present'
Check 'the runner publishes and clears ws/<ws>/busy' ((Test-Path (Join-Path (Split-Path (Split-Path $PSScriptRoot) -Parent) 'cloud\runner-agent.mjs')) -and ([IO.File]::ReadAllText((Join-Path (Split-Path (Split-Path $PSScriptRoot) -Parent) 'cloud\runner-agent.mjs')).Contains('ws/${cfg.ws}/busy'))) 'runner marker absent'
# ---- the wake-shortened FIRST wait (2026-11-27): 180 s of dead wait per landing after a resume -----
# The pre-filter's first interval is the base of the doubling, so the checks below pin (a) the POLICY of
# the helper itself, driven from the production definition, (b) that the helper is WIRED into the
# pre-filter rather than declared and forgotten, and (c) that the short value is configurable and
# defaults to 30 s. Delete (a) and the three-minute window is back for every first job after a suspend
# while the text-style dispatch checks still pass - which is exactly what the previous, text-only pins
# could not see.
Check '(a) a wake in THIS run shortens the first interval to the wake value' ((Get-HealFirstIntervalMin -Resumed $true -WakeFirstHealMin 0.5 -StaleClaimMin 3) -eq 0.5) "got $(Get-HealFirstIntervalMin -Resumed $true -WakeFirstHealMin 0.5 -StaleClaimMin 3)"
Check '(a) a VM this run did NOT wake keeps StaleClaimMin as the base' ((Get-HealFirstIntervalMin -Resumed $false -WakeFirstHealMin 0.5 -StaleClaimMin 3) -eq 3) "got $(Get-HealFirstIntervalMin -Resumed $false -WakeFirstHealMin 0.5 -StaleClaimMin 3)"
Check '(a) the defaults are 30 s for the wake case and 3 min for the rest' (((Get-HealFirstIntervalMin -Resumed $true) -eq 0.5) -and ((Get-HealFirstIntervalMin -Resumed $false) -eq 3)) "got $(Get-HealFirstIntervalMin -Resumed $true)/$(Get-HealFirstIntervalMin -Resumed $false)"
Check '(a) the shortened base still feeds the doubling (6 s->30 s then 1, 2 min)' (((Get-HealBackoffMin -HealsDone 0 -FirstMin (Get-HealFirstIntervalMin -Resumed $true)) -eq 0.5) -and ((Get-HealBackoffMin -HealsDone 1 -FirstMin (Get-HealFirstIntervalMin -Resumed $true)) -eq 1)) ''
Check '(b) the pre-filter derives $healFirstMin from the helper (wired, not just declared)' ($src.Contains('$healFirstMin = Get-HealFirstIntervalMin')) ''
Check '(b) the pre-filter actually uses $healFirstMin' ($src.Contains('-FirstMin $healFirstMin')) ''
Check '(c) the wake-shortened first interval defaults to 0.5 min and is configurable' (($src.Contains('$WakeFirstHealMin = 0.5')) -and ($src.Contains("'wakefirsthealmin'")) -and ($src.Contains('cloudWakeFirstHealMin'))) ''

if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
