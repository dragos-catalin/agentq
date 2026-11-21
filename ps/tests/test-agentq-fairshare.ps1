# ADR 0014 D4: per-session fair share of a resource.
# Symptom that motivated it: one agent fanned out N parallel jobs, took EVERY slot of build:machine
# (cap 2-4) and every other session waited behind the whole block - the machine was busy while their
# 5 s job sat in queue. Rule now: while >= 2 sessions compete on a resource with cap >= 2, the rank
# order is round-robin over sessions and a session may hold at most ceil(cap / sessions) slots.
# Part A checks the helpers on their own (deterministic); part B proves it end to end on real tickets:
# a session that already holds its share is REFUSED even when it outranks the other session, and the
# refusal is journaled (`fair-share`); with the feature off the same setup admits it (the mutant check).
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$src = Get-Content -LiteralPath $Aq -Raw
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqfs-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }

# ---------------------------------------------------------------- part A: the helpers in isolation
$block = [regex]::Match($src, '(?s)function Get-FairShare \{.*?\r?\n\}').Value + "`n" +
         [regex]::Match($src, '(?s)function Sort-BySession\(.*?\r?\n\}').Value
Check '1 the helpers are in agentq.ps1' ($block -match 'function Get-FairShare' -and $block -match 'function Sort-BySession')
$cfgJson = '{}'
function Get-Config { $s = $cfgJson | ConvertFrom-Json -AsHashtable; if (-not $s) { $s = @{} }; $s }
function P($o, $k, $d = $null) { if ($o -is [hashtable] -and $o.ContainsKey($k)) { $o[$k] } else { $d } }
if ($block) { Invoke-Expression $block }
try {
  $fs = Get-FairShare
  Check '2 default: enabled with the share derived from the cap' ($fs.enabled -eq $true -and $fs.maxPerSession -eq 0) ($fs | ConvertTo-Json -Compress)
  $cfgJson = '{"fairShare":{"enabled":false}}'
  Check '2a config can turn it off' ((Get-FairShare).enabled -eq $false)
  $cfgJson = '{"fairShare":false}'
  Check '2b the shorthand false turns it off' ((Get-FairShare).enabled -eq $false)
  $cfgJson = '{"fairShare":true}'
  Check '2c the shorthand true keeps it on' ((Get-FairShare).enabled -eq $true)
  $cfgJson = '{"fairShare":{"maxPerSession":2}}'
  $fs = Get-FairShare
  Check '2d maxPerSession is honoured as a number' ($fs.enabled -eq $true -and $fs.maxPerSession -eq 2) ($fs | ConvertTo-Json -Compress)
  $cfgJson = '{"fairShare":{"enabled":true}}'; $env:AGENTQ_NO_FAIRSHARE = '1'
  Check '2e AGENTQ_NO_FAIRSHARE=1 disables it for one call' ((Get-FairShare).enabled -eq $false)
  Remove-Item Env:\AGENTQ_NO_FAIRSHARE -ErrorAction SilentlyContinue
  # the round-robin: session A's three waiters no longer sit as a block in front of B's single waiter
  $w = @(@{ id = 'a1'; session = 'A' }, @{ id = 'a2'; session = 'A' }, @{ id = 'a3'; session = 'A' }, @{ id = 'b1'; session = 'B' })
  $ord = @(Sort-BySession $w @('A', 'B') | ForEach-Object { $_.id })
  Check '3 a third-party waiter is pulled ahead of the block' (($ord -join ',') -eq 'a1,b1,a2,a3') ($ord -join ',')
  Check '3 one session keeps its own order' (($ord | Where-Object { $_ -like 'a*' }) -join ',' -eq 'a1,a2,a3') ($ord -join ',')
  Check '3 the round-robin never drops or duplicates a ticket' ($ord.Count -eq 4 -and (@($ord | Sort-Object -Unique).Count -eq 4))
  Check '4 the scheduler uses both (order + floor + refusal journal)' `
    ($src -match 'Sort-BySession \$waiting \$sess' -and $src -match 'fair share: my session holds' -and $src -match "event = 'fair-share'")
} catch { Check '2 the helpers run' $false "$_" }

# ---------------------------------------------------------------- part B: end to end on real tickets
$cfg = Join-Path $tmp 'cfg.json'
function Write-Cfg([bool]$fair) {
  $json = @{
    taskSlotsPerRepo = 3; taskSlotsMachine = 5; sharedCloneMode = 'off'
    machineCap = 2; quickBurst = 0; agingMin = 0; bumpMax = 20; minFreeCommitGB = 0; minFreeRamGB = 0
    idleCpuSec = 999999; idleYieldMin = 999999; fairShare = @{ enabled = $fair }
  } | ConvertTo-Json -Compress -Depth 5
  [IO.File]::WriteAllText($cfg, $json)
}
$env:AGENTQ_CONFIG = $cfg
$jf = Join-Path $env:AGENTQ_HOME 'journal.jsonl'
function Journal { if (-not (Test-Path -LiteralPath $jf)) { return @() }; @(Get-Content -LiteralPath $jf | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ }) }
function Start-Hold([string]$session, [string]$purpose, [int]$sec, [int]$prio = 0) {
  $a = @('-NoProfile', '-File', $Aq, 'run', '-Resource', 'build:machine', '-Purpose', $purpose, '-TimeoutMin', '3')
  if ($prio) { $a += @('-Priority', "$prio") }
  $a += @('--', 'pwsh', '-NoProfile', '-Command', "Start-Sleep $sec")
  $env:AGENTQ_SESSION = $session
  $p = Start-Process pwsh -ArgumentList $a -PassThru -WindowStyle Hidden
  $p
}
# A holds both slots, B waits, then A asks for a THIRD with a priority that outranks B. Without fair
# share the freed slot goes to A (it is first in rank); with it, A's session is at its share (1 of 2)
# and the refusal is journaled.
function Scenario([bool]$fair, [int]$holdSec) {
  Write-Cfg $fair
  Remove-Item -LiteralPath $jf -Force -ErrorAction SilentlyContinue
  $a1 = Start-Hold 'AAA' 'hold-1' $holdSec
  # The second holder outlives the first by 8 s on purpose: the window between the two releases is
  # exactly where the share must hand the freed slot to the other session instead of idling it.
  $a2 = Start-Hold 'AAA' 'hold-2' ($holdSec + 8)
  $q = Join-Path $env:AGENTQ_HOME 'queues\build_machine'
  $both = $false
  for ($i = 0; $i -lt 80 -and -not $both; $i++) { Start-Sleep -Milliseconds 250; if (@(Get-ChildItem -LiteralPath $q -Filter '*.json' -File -ErrorAction SilentlyContinue).Count -ge 2) { $both = $true } }
  $b = Start-Hold 'BBB' 'wait-b' 2
  Start-Sleep -Milliseconds 700
  $a3 = Start-Hold 'AAA' 'third-a' 2 30
  $done = $true
  foreach ($p in @($a1, $a2, $b, $a3)) { if (-not $p.WaitForExit(60000)) { $p.Kill(); $done = $false } }
  Get-ChildItem -LiteralPath $q -Filter '*.json' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
  $ev = @(Journal | Where-Object { $_.event -eq 'fair-share' })
  # WHO took the slot the first holder freed, decided by the journal order and not by wall-clock
  # timestamps: every argvq process spends 1-10 s in pwsh start + load probe, so comparing ExitTime
  # measured the process table, not the scheduler (it made a correct run look wrong).
  $win = @(Journal | Where-Object { $_.event -eq 'acquired' } | ForEach-Object { "$($_.purpose)" } |
      Where-Object { $_ -in 'wait-b', 'third-a' })
  [pscustomobject]@{
    both = $both; done = $done; events = $ev; window = $win
    firstWindow = if ($win.Count) { $win[0] } else { '' }
    exits = @($a1.ExitCode, $a2.ExitCode, $b.ExitCode, $a3.ExitCode)
    third = $a3.ExitCode
  }
}
$r1 = Scenario $true 8
Check '5 both slots were really held before the third request' ($r1.both) 'two holders never appeared'
Check '5b every process ended cleanly (no deadlock)' ($r1.done -and (@($r1.exits | Where-Object { $_ -ne 0 }).Count -eq 0)) ("exits: " + ($r1.exits -join ','))
Check '6 the outranking third request was REFUSED, once, and journaled' ($r1.events.Count -eq 1) ("events: " + $r1.events.Count)
if ($r1.events.Count) {
  $e = $r1.events[0]
  Check '6a the refusal names the session, the share and the cap' ($e.session -eq 'AAA' -and $e.cap -eq 2 -and $e.maxPerSession -eq 1 -and $e.held -ge 1) ($e | ConvertTo-Json -Compress)
  Check '6b no event is journaled for the other session' (@($r1.events | Where-Object { $_.session -ne 'AAA' }).Count -eq 0) ($r1.events | ConvertTo-Json -Compress)
}
Check '6c the other session took the freed slot (journal order)' ($r1.firstWindow -eq 'wait-b') ("window order: " + ($r1.window -join ' -> '))
Check '6d the refusal is journaled ONCE, not once per poll' ($r1.events.Count -le 1) ("events: " + $r1.events.Count)
Check '6e the refused request ran later anyway (nothing was lost)' ($r1.third -eq 0) ("exit: " + $r1.third)
# the mutant: with the feature off the SAME setup journals nothing (so check 6 cannot pass by accident)
$r2 = Scenario $false 5
Check '7 fairShare disabled: no refusal is journaled' ($r2.events.Count -eq 0) ("events: " + $r2.events.Count)
Check '7b fairShare disabled: the outranking request takes the window (old behaviour)' ($r2.firstWindow -eq 'third-a') ("window order: " + ($r2.window -join ' -> '))
Check '7c fairShare disabled: still no deadlock' ($r2.done -and (@($r2.exits | Where-Object { $_ -ne 0 }).Count -eq 0)) ("exits: " + ($r2.exits -join ','))
$env:AGENTQ_SESSION = 'OBS'
$o = @(& pwsh -NoProfile -File $Aq status 2>&1 | ForEach-Object { "$_" }) -join "`n"
Check '8 status still renders with the feature active' ($LASTEXITCODE -eq 0) $o

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "$(if ($fail) { "FAILED $fail" } else { 'ALL PASS' }) fair share ($(if ($fail) { '' }else { 'D4' }))"
exit $(if ($fail) { 1 } else { 0 })
