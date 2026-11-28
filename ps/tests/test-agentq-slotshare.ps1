# D5 (owner 2026-11-23): a per-session cap on SLOT LEASES + reuse before renting - the slot-side twin of
# the queue's fair share (D4, ADR 0014). Symptom that motivated it: ONE VS Code window is ONE agentq
# session, so every terminal AND every subagent shares one session id; that session held 4 slots at once
# (scratch-1, task-1, task-2, scratch-2) while other windows starved on the pool. Two behaviours:
#   (1) REUSE BEFORE RENTING - a session that already holds a CLEAN slot of the requested role in this repo
#       gets that slot back (journal `slot-reuse`) instead of renting a second one. "Subagents work in the
#       lead's slot" (ADR 0012) is now automatic. A DIRTY slot (unsaved work, the same `git status
#       --porcelain` test the pre-gate uses) is NOT handed back.
#   (2) PER-SESSION SHARE - a session may hold at most `fairShare.slotsPerSession` slots when > 0, else a
#       DERIVED share of the machine task-slot cap (ceil(cap / competing sessions), floor 1). It applies
#       ONLY while another live session holds a slot, so a lone session keeps every slot (no regression).
#       Over the share: a bounded wait, then a refusal naming the session, the held slots, the share and
#       the two recipes (journal `slot-fair-share`).
# D6 (owner 2026-11-28, proposals SHAREPERCHAT + LANDTICKETBEFORESLOT): the share KEY is the CHAT when it
# is known, not the session (one VS Code window). Measured 2026-11-28: ONE window ran several chats, the
# window held 14 -> 17 slots against a share of 6 while each chat's own work was 1-2 slots, so no chat of
# that window could lease a land slot - and every attempt paid for it: the refusal only surfaced INSIDE
# New-Lease, after the cap-1 `land:<repo>` ticket was taken, and New-Lease waits its own 10 min bound
# first (10 min 34 s of the whole repo's land queue burned to push nothing). Two changes, one suite:
#   (a) Get-SlotShare/Test-SlotShareRefusal/Show-SlotShare key by chat when the caller's chat id is known
#       AND some live lease carries a binding; unknown chat id or no bindings at all -> session, as before;
#   (b) the land path probes that verdict BEFORE New-Ticket takes the cap-1 land ticket (A16 pins the order).
# Part A pins the pure helpers (`Get-FairShare` + `Get-SlotShare`); part B drives the REAL lease path in an
# isolated %TEMP% fixture (AGENTQ_HOME / CODAI_WT_ROOT / AGENTQ_CONFIG), the same pattern as
# test-slot-budget.ps1 / test-agentq-fairshare.ps1.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqss-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'
$env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_AGENT_LIMIT = '1'; $env:AGENTQ_NO_PRUNE = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
Remove-Item Env:\AGENTQ_NO_FAIRSHARE -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
# 2026-11-26: the config literals below set scratchMinFreeGB/minFreeCommitGB to 0 on purpose. This
# suite is isolated in %TEMP% but the pool still consults the REAL volume: with the shipped values
# (25 / 12) a machine under pressure caps the scratch pool at its floor of 3, so B7's last lease can
# never be granted and the suite waits forever for a slot nobody releases. Measured 2026-11-26 with
# C: at 8 GB free: `scratch-alloc-denied`, three runs stuck at ~0 CPU. A fixture pins the resource
# knobs it depends on - it never inherits them from whatever else the machine is doing.
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Set-Cfg([string]$json) { [IO.File]::WriteAllText($cfg, $json) }
function LFile([string]$slot) { Join-Path $env:AGENTQ_HOME "leases\repo\$slot.json" }
function Clear-Leases { Get-ChildItem (Join-Path $env:AGENTQ_HOME 'leases\repo') -Filter '*.json*' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue }
function Journal { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ }) }
function Ev([string]$name) { @(Journal | Where-Object { $_.event -eq $name }) }
function Reset-Journal { Remove-Item -LiteralPath (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -Force -ErrorAction SilentlyContinue }

# ---------------------------------------------------------------- part A: the helpers in isolation
$src = Get-Content -LiteralPath $Aq -Raw
$blk = [regex]::Match($src, '(?s)function Get-FairShare \{.*?\r?\n\}').Value + "`n" +
       [regex]::Match($src, '(?s)function Get-SlotShare\(.*?\r?\n\}').Value
Check '0 the helpers are in agentq.ps1' ($blk -match 'function Get-FairShare' -and $blk -match 'function Get-SlotShare')
$cfgJson = '{}'
function Get-Config { $s = $cfgJson | ConvertFrom-Json -AsHashtable; if (-not $s) { $s = @{} }; $s }
function P($o, $k, $d = $null) {
  if ($null -eq $o) { return $d }
  if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($k) -and $null -ne $o[$k]) { return $o[$k] } ; return $d }
  if ($o.PSObject.Properties.Name -contains $k -and $null -ne $o.$k) { $o.$k } else { $d }
}
if ($blk) { Invoke-Expression $blk }
try {
  $fs = Get-FairShare
  Check 'A1 default: enabled, maxPerSession 0, slotsPerSession 0 (back-compat)' ($fs.enabled -eq $true -and $fs.maxPerSession -eq 0 -and $fs.slotsPerSession -eq 0) ($fs | ConvertTo-Json -Compress)
  $cfgJson = '{"fairShare":false}'
  Check 'A1a the shorthand false still turns it off (slotsPerSession is not a second switch)' ((Get-FairShare).enabled -eq $false -and (Get-FairShare).slotsPerSession -eq 0)
  $cfgJson = '{"fairShare":{"enabled":true,"maxPerSession":2}}'
  $fs = Get-FairShare
  Check 'A1b the existing shape (enabled+maxPerSession) is unchanged, slotsPerSession defaults to 0' ($fs.enabled -eq $true -and $fs.maxPerSession -eq 2 -and $fs.slotsPerSession -eq 0)
  $cfgJson = '{"fairShare":{"enabled":true,"slotsPerSession":3}}'
  $fs = Get-FairShare
  Check 'A2 slotsPerSession is read through the SAME Get-FairShare helper' ($fs.enabled -eq $true -and $fs.slotsPerSession -eq 3) ($fs | ConvertTo-Json -Compress)
  $cfgJson = '{}'
  $s = Get-SlotShare @(@{ session = 'A'; stale = $false }) 'A' 6
  Check 'A3 a lone session is never competing (never capped)' ($s.competing -eq $false -and $s.held -eq 1) ($s | ConvertTo-Json -Compress)
  $two = @(@{ session = 'A'; stale = $false }, @{ session = 'B'; stale = $false })
  $s = Get-SlotShare $two 'A' 6
  Check 'A4 two sessions: the share is ceil(cap / sessions)' ($s.competing -eq $true -and $s.share -eq 3 -and $s.held -eq 1) ($s | ConvertTo-Json -Compress)
  $s = Get-SlotShare @(@{ session = 'A'; stale = $false }, @{ session = 'A'; stale = $false }, @{ session = 'B'; stale = $false }) 'A' 6
  Check 'A5 the share follows the competing SESSION count, not the lease count' ($s.share -eq 3 -and $s.held -eq 2) ($s | ConvertTo-Json -Compress)
  $cfgJson = '{"fairShare":{"enabled":true,"slotsPerSession":1}}'
  $s = Get-SlotShare $two 'A' 12
  Check 'A6 slotsPerSession overrides the derived share' ($s.share -eq 1 -and $s.slotsPerSession -eq 1) ($s | ConvertTo-Json -Compress)
  $cfgJson = '{}'
  $s = Get-SlotShare @(@{ session = 'A'; stale = $false }, @{ session = 'B'; stale = $true }) 'A' 6
  Check 'A7 a stale lease is not a competitor (a dead chat does not cap me)' ($s.competing -eq $false) ($s | ConvertTo-Json -Compress)
  $s = Get-SlotShare $two 'A' 0
  Check 'A8 a zero/unknown task cap still floors the derived share at 1' ($s.share -eq 1) ($s | ConvertTo-Json -Compress)
  Check 'A9 the lease path and status both use the helper (one config shape, one store)' `
    ($src -match 'Get-SlotShare \$all \$Session \$cap \$chat' -and $src -match 'event = ''slot-reuse''' -and $src -match 'event = ''slot-fair-share''' -and $src -match 'SLOT SHARE')
  # Slot names repeat per repo (`codai\scratch-1` sits beside `marcai\scratch-1`), so a bare slot in the
  # status line made two sessions in DIFFERENT repos read as one duplicate lease - a 2026-11-27 report whose
  # only defect was the display. The line must name repo/slot.
  Check 'A10 the SLOT SHARE line names repo/slot, not a bare slot' ($src -match '\$\(\$_\.repo\)/\$\(\$_\.slot\)')

  # ---- D6: the share key is the CHAT (see the header). The measured case, as data: ONE session ('me') with
  # three chats, each 1 slot, beside another session's chat. Session-keyed this is "me holds 3 of a share of
  # 3" -> refused; chat-keyed it is "chatX holds 1 of a share of 2" -> allowed. That difference IS the fix.
  $chatLeases = @(
    @{ session = 'me'; stale = $false; chats = @('chatX') },
    @{ session = 'me'; stale = $false; chats = @('chatY') },
    @{ session = 'me'; stale = $false; chats = @('chatZ') },
    @{ session = 'other'; stale = $false; chats = @('chatW') }
  )
  $byChat = Get-SlotShare $chatLeases 'me' 6 'chatX'
  $bySess = Get-SlotShare $chatLeases 'me' 6 ''
  Check 'A11 with bindings the key is the CHAT: only my own chat is charged, every chat competes' `
    ($byChat.mode -eq 'chat' -and $byChat.held -eq 1 -and $byChat.sessions -eq 4 -and $byChat.share -eq 2 -and $byChat.competing -eq $true) ($byChat | ConvertTo-Json -Compress)
  Check 'A11a the SAME leases keyed by session refuse the chat the chat key lets through (the reported bug)' `
    ($bySess.mode -eq 'session' -and $bySess.held -eq 3 -and $bySess.held -ge $bySess.share -and $byChat.held -lt $byChat.share) ($bySess | ConvertTo-Json -Compress)
  $oldCall = Get-SlotShare $chatLeases 'me' 6
  Check 'A12 an unknown chat id is the OLD session behaviour (the 3-arg call and '' == one verdict)' `
    ($oldCall.mode -eq 'session' -and $oldCall.held -eq $bySess.held -and $oldCall.sessions -eq $bySess.sessions -and $oldCall.share -eq $bySess.share -and $oldCall.competing -eq $bySess.competing) ($oldCall | ConvertTo-Json -Compress)
  $mixedLeases = @(
    @{ session = 'me'; stale = $false; chats = @('chatX') },
    @{ session = 'me'; stale = $false },
    @{ session = 'other'; stale = $false }
  )
  $mx = Get-SlotShare $mixedLeases 'me' 6 'chatX'
  Check 'A13 a lease with NO chat binding is its own unit and is never charged to my chat' `
    ($mx.mode -eq 'chat' -and $mx.sessions -eq 3 -and $mx.held -eq 1 -and $mx.share -eq 2) ($mx | ConvertTo-Json -Compress)
  $unbound = Get-SlotShare @(@{ session = 'me'; stale = $false }, @{ session = 'other'; stale = $false }) 'me' 6 'chatX'
  Check 'A14 with no binding on ANY lease a known chat id still keys by session (never a guess)' ($unbound.mode -eq 'session') ($unbound | ConvertTo-Json -Compress)
  $staleOnly = Get-SlotShare @(@{ session = 'me'; stale = $false }, @{ session = 'other'; stale = $true; chats = @('chatW') }) 'me' 6 'chatX'
  Check 'A14a a STALE lease binding does not switch me into chat mode (its unit is gone anyway)' ($staleOnly.mode -eq 'session') ($staleOnly | ConvertTo-Json -Compress)
  # Mutation check: A11/A11a/A13 must die if the chat branch is removed. Without this, the whole part could
  # be green on a helper that never reads `chats` (the vacuous-suite trap: assert on the NEW field too).
  $mutBlk = $blk -replace '\$chatMode = \[bool\]\(\$chat -and \$bound -gt 0\)', '$chatMode = $false'
  Check 'A15 the mutation rewrote the chat branch (else the check below is vacuous)' ($mutBlk -ne $blk)
  Invoke-Expression $mutBlk
  $mut = Get-SlotShare $chatLeases 'me' 6 'chatX'
  Check 'A15 with chatMode forced off the chat-keyed verdict disappears (A11 is not vacuous)' `
    ($mut.mode -eq 'session' -and $mut.held -eq 3 -and $mut.held -ge $mut.share)
  Invoke-Expression $blk
  $restored = Get-SlotShare $chatLeases 'me' 6 'chatX'
  Check 'A15a the good helper is restored before part B' ($restored.mode -eq 'chat' -and $restored.held -eq 1)

  # ---- D6b: the land path must probe the share BEFORE it takes the cap-1 land ticket (owner proposal
  # LANDTICKETBEFORESLOT). Source ORDER is the invariant: after the ticket, a refusal costs the whole repo's
  # land queue the 10 min New-Lease waits. Index comparison, so moving the probe back down fails this check.
  $srcV2 = Get-Content -LiteralPath (Join-Path (Split-Path $Aq) 'agentq-v2.ps1') -Raw
  $iProbe = $srcV2.IndexOf('land-share-refused')
  $iTicket = $srcV2.IndexOf('$t = New-Ticket $res $why "land $Branch -> $Onto" $main')
  Check 'A16 the land probes the fair share BEFORE the cap-1 ticket, in the queued path' `
    ($iProbe -gt 0 -and $iTicket -gt 0 -and $iProbe -lt $iTicket -and $srcV2 -match 'swLand = Test-SlotShareRefusal \$repo\.Name ''land''') "probeAt=$iProbe ticketAt=$iTicket"

  # ---- D6c: which chat is MINE. `chats\.last.json` is written by the hook on EVERY tool call of EVERY
  # chat, so the hint it carries is usually a SIBLING chat (measured 2026-11-28 04:33Z: it named a chat that
  # held codai/task-2 while this chat held none). Keying the share on that hint would charge one chat's slots
  # to another - the same land allowed or refused depending on which sibling spoke last. Get-ShareChatId
  # CONFIRMS the hint against the per-chat registry and answers $null unless the hint is the ONE fresh chat
  # of MY session; $null means session keying (the pre-D6 behaviour). Get-CurrentChatId is stubbed here on
  # purpose: this check is about the confirmation rule, not about what the hook wrote.
  $shareBlk = [regex]::Match($srcV2, '(?s)function Get-ShareChatId\(.*?\r?\n\}').Value
  Check 'A17 Get-ShareChatId lives in agentq-v2.ps1 next to Get-CurrentChatId' ($shareBlk -match 'function Get-ShareChatId')
  Check 'A17 the share key at BOTH call sites is the confirmed chat, and the raw hint is gone' `
    ($src -match 'Get-ShareChatId \$all' -and $src -match 'Get-ShareChatId \$leases' -and $src -notmatch 'chat = "\$\(Get-CurrentChatId\)"')
  $chatDir = Join-Path $tmp 'chats'
  New-Item -ItemType Directory -Force $chatDir | Out-Null
  $Root = $tmp
  $Session = 'me'
  function Now { [datetime]::UtcNow }
  $script:cur = $null
  function Get-CurrentChatId { if ($script:cur) { return $script:cur }; return $null }
  function Touch-Chat([string]$id, [int]$ageSec = 0) {
    $f = Join-Path $chatDir "$id.json"
    [IO.File]::WriteAllText($f, '{}')
    if ($ageSec -gt 0) { [IO.File]::SetLastWriteTimeUtc($f, ([datetime]::UtcNow).AddSeconds(-$ageSec)) }
    $f
  }
  if ($shareBlk) { Invoke-Expression $shareBlk }
  Remove-Item Env:\AGENTQ_CHAT_ID -ErrorAction SilentlyContinue
  $mineLeases = @(
    @{ session = 'me'; stale = $false; chats = @('chatX', 'chatY') },
    @{ session = 'me'; stale = $false; chats = @('chatZ') },
    @{ session = 'other'; stale = $false; chats = @('chatW') }
  )
  $script:cur = 'chatX'; $null = Touch-Chat 'chatX'; $null = Touch-Chat 'chatZ'
  Check 'A18 two of my chats are fresh -> no chat key, session keying (a coin toss is not an identity)' `
    ($null -eq (Get-ShareChatId $mineLeases))
  $null = Touch-Chat 'chatZ' 3600
  Check 'A19 exactly one fresh chat of my session and it IS the hint -> the chat key' `
    ("$(Get-ShareChatId $mineLeases)" -eq 'chatX')
  $script:cur = 'chatW'; $null = Touch-Chat 'chatW'
  Check 'A20 the hint is fresh but belongs to ANOTHER session -> refused, session keying' `
    ($null -eq (Get-ShareChatId $mineLeases))
  $script:cur = 'chatGhost'; $null = Touch-Chat 'chatGhost'; $null = Touch-Chat 'chatZ' 3600
  Check 'A21 the hint is fresh but bound to NO live lease of mine -> session keying' `
    ($null -eq (Get-ShareChatId $mineLeases))
  $script:cur = 'chatX'; $null = Touch-Chat 'chatX' 3600
  Check 'A22 my only candidate is stale in the registry -> session keying (the window is the hook''s own)' `
    ($null -eq (Get-ShareChatId $mineLeases))
  $env:AGENTQ_CHAT_ID = 'chatX'; $null = Touch-Chat 'chatX'; $null = Touch-Chat 'chatZ'
  Check 'A23 an explicit AGENTQ_CHAT_ID is taken as given (the script/suite identity path)' `
    ("$(Get-ShareChatId $mineLeases)" -eq 'chatX')
  Remove-Item Env:\AGENTQ_CHAT_ID -ErrorAction SilentlyContinue
  $script:cur = 'chatX'; $null = Touch-Chat 'chatX'
  Check 'A24 a stale LEASE binding is not a candidate (its chat is only mine while the lease is live)' `
    ($null -eq (Get-ShareChatId @(@{ session = 'me'; stale = $true; chats = @('chatX') })))

  # ---- (e) owner 2026-11-28 "charge lands per REPO": WHAT IS CHARGED narrows, WHAT COMPETES does not. The
  # measured case as data: my session held 12 leases across agentq/brivio/marcai/codai against a share of 4,
  # so a codai LAND - which can only ever take a codai slot - was refused for other repos' work. Divider
  # unchanged (the machine task budget is not renegotiated by scope), numerator narrowed to the repo.
  $spread = @(
    @{ session = 'me'; repo = 'codai'; stale = $false }
    @{ session = 'me'; repo = 'agentq'; stale = $false }
    @{ session = 'me'; repo = 'agentq'; stale = $false }
    @{ session = 'me'; repo = 'brivio'; stale = $false }
    @{ session = 'me'; repo = 'marcai'; stale = $false }
    @{ session = 'me'; repo = 'marcai'; stale = $false }
    @{ session = 'o1'; repo = 'agentq'; stale = $false }
    @{ session = 'o2'; repo = 'brivio'; stale = $false }
    @{ session = 'o3'; repo = 'codai'; stale = $false }
  )
  $wide = Get-SlotShare $spread 'me' 8 ''
  $narrow = Get-SlotShare $spread 'me' 8 '' 'codai'
  Check 'A25 per-repo charging: the SAME leases, the same share, only the charge narrows (6 -> 1)' `
    ($wide.held -eq 6 -and $narrow.held -eq 1 -and $narrow.share -eq $wide.share -and $narrow.sessions -eq $wide.sessions) "wide=$($wide | ConvertTo-Json -Compress) narrow=$($narrow | ConvertTo-Json -Compress)"
  Check 'A25a the per-repo charge ADMITS what the machine-wide charge refuses (the measured refusal)' `
    ($wide.held -ge $wide.share -and $narrow.held -lt $narrow.share) "wide=$($wide.held)/$($wide.share) narrow=$($narrow.held)/$($narrow.share)"
  Check 'A25b the default scope is the old call, byte for byte (the lease/scratch path is untouched)' `
    ((Get-SlotShare $spread 'me' 8 '').held -eq $wide.held -and $wide.chargedIn -eq '' -and $wide.chargedCount -eq $spread.Count -and $narrow.chargedIn -eq 'codai' -and $narrow.chargedCount -eq 2) "wide=$($wide | ConvertTo-Json -Compress) narrow=$($narrow | ConvertTo-Json -Compress)"
  Check 'A25c the LAND is the caller that passes the scope (else the fix is dead code)' `
    ($srcV2 -match 'swLand = Test-SlotShareRefusal \$repo\.Name ''land'' -PerRepo' -and $src -match 'function Test-SlotShareRefusal\(\[string\]\$repoName, \[string\]\$role, \[switch\]\$PerRepo\)')

  # ---- D8 (owner 2026-11-28): the CHAT + its AGE per lease, for the SLOT SHARE line and `agentq who`.
  # The accounting is per chat (D6/D7), but the display keyed on the SESSION - so one window's 18 leases
  # under a single `term-<pid>` could not be told apart (which lease belongs to which chat was unreadable).
  # These cases pin the display helpers (id, age, key, fallback) and the SLOT SHARE wiring; the `who` side
  # is a PATCH (agentq-v2.ps1 is ACTIVE-OWNER -> not edited by this change), asserted against the patch.
  $chatBlk = ''
  foreach ($fn in 'Get-ChatAgeMin', 'Get-LeaseChatInfo', 'Format-LeaseChatTag', 'Format-LeaseChatCell') {
    $chatBlk += [regex]::Match($src, "(?s)function $fn\(.*?\r?\n\}").Value + "`n"
  }
  Check 'C0 the D8 chat-display helpers are in agentq.ps1' `
    ($chatBlk -match 'function Get-ChatAgeMin' -and $chatBlk -match 'function Get-LeaseChatInfo' -and $chatBlk -match 'function Format-LeaseChatTag' -and $chatBlk -match 'function Format-LeaseChatCell')
  if ($chatBlk) { Invoke-Expression $chatBlk }
  # a per-chat registry file with a chosen AGE (its CREATION time is the age source)
  function New-ChatFile([string]$id, [double]$ageMin) {
    $f = Join-Path $chatDir "$id.json"
    [IO.File]::WriteAllText($f, '{}')
    [IO.File]::SetCreationTimeUtc($f, ([datetime]::UtcNow).AddMinutes(-$ageMin))
    $f
  }
  # C1: a lease WITH a chat binding -> key chat, the id, the age from the registry file
  $null = New-ChatFile 'chatD8' 42
  $bound = @{ session = 'me'; chats = @('chatD8'); stale = $false }
  $info = Get-LeaseChatInfo $bound
  Check 'C1 a bound lease reports its CHAT id, not the session' ($info.key -eq 'chat' -and $info.id -eq 'chatD8') ($info | ConvertTo-Json -Compress)
  Check 'C1 the chat AGE comes from the registry file creation time (~42 min)' ($null -ne $info.ageMin -and $info.ageMin -ge 41 -and $info.ageMin -le 43) ($info | ConvertTo-Json -Compress)
  Check 'C1 the SLOT SHARE tag names the chat and its age' ((Format-LeaseChatTag $bound) -match 'chat chatD8 \(age 4[12]m') (Format-LeaseChatTag $bound)
  Check 'C1 the who cell carries the id and the age' ((Format-LeaseChatCell $bound) -match '^chatD8 \(age 4[12]m') (Format-LeaseChatCell $bound)
  # C2: no chat binding -> the SESSION, age unknown -> '-'
  $unbound = @{ session = 'term-9999'; stale = $false }
  $ui = Get-LeaseChatInfo $unbound
  Check 'C2 an unbound lease falls back to its SESSION (never a guess)' ($ui.key -eq 'session' -and $ui.id -eq 'term-9999' -and $null -eq $ui.ageMin) ($ui | ConvertTo-Json -Compress)
  Check 'C2 the who cell is empty (no chat) for an unbound lease' ((Format-LeaseChatCell $unbound) -eq '-') (Format-LeaseChatCell $unbound)
  # C3: a chat id whose registry file is gone -> age '-', never a throw
  $ghost = @{ session = 'me'; chats = @('chatGhostD8'); stale = $false }
  $gi = Get-LeaseChatInfo $ghost
  Check 'C3 a chat whose registry file is gone yields a null age (shown -)' ($gi.key -eq 'chat' -and $gi.id -eq 'chatGhostD8' -and $null -eq $gi.ageMin) ($gi | ConvertTo-Json -Compress)
  Check 'C3 the SLOT SHARE tag prints - for the unknown age' ((Format-LeaseChatTag $ghost) -match 'age -') (Format-LeaseChatTag $ghost)
  # C4: the SLOT SHARE line prints held/share ALWAYS + the competing count, and tags each held lease
  Check 'C4 the SLOT SHARE line prints my held vs my share ALWAYS (not only while competing)' ($src -match 'SLOT SHARE \{0\}/\{1\} held by \{2\}')
  Check 'C4 the SLOT SHARE line prints the number that compete' ($src -match '\$\(\$sh\.sessions\) \$unitTxt compete')
  Check 'C4 the SLOT SHARE held list uses the chat tag (id + age per lease)' ($src -match '\$\(Format-LeaseChatTag \$_\)')
  # C5: the `who` wiring lives in the PATCH (agentq-v2.ps1 is ACTIVE-OWNER -> patch, not edit here)
  $patchFile = 'E:\gh\.scratch\slot-share-clarity.patch'
  $pt = if (Test-Path -LiteralPath $patchFile) { Get-Content -LiteralPath $patchFile -Raw } else { '' }
  Check 'C5 the who patch adds a chat column and chatId/chatAgeMin to the row' `
    ($pt -match 'Format-LeaseChatCell' -and $pt -match 'chatId = \$chatId' -and $pt -match 'chatAgeMin = \$ci\.ageMin') "patch=$patchFile present=$([bool]$pt)"
} catch { Check 'A the helpers run' $false "$_" }

# ---------------------------------------------------------------- part B: end to end on the real lease path
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  $base = '{"taskSlotsPerRepo":12,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":true}}'

  # =============================== B1: a lone session is never capped
  Clear-Leases; Reset-Journal
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":2,"taskSlotsMachineFloor":0,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":true}}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'   # derived cap 1 - ONLY safe because a lone session is never capped
  $env:AGENTQ_SESSION = 'lone'
  foreach ($n in 1..3) { $null = AQ lease -Role scratch -Purpose "l$n" -Slot "scratch-$n" -Json }
  Check 'B1 a lone session is never capped: three slots granted' ((Test-Path (LFile 'scratch-1')) -and (Test-Path (LFile 'scratch-2')) -and (Test-Path (LFile 'scratch-3'))) "code=$($script:code)"
  Check 'B1 no slot-fair-share event for a lone session' (@(Ev 'slot-fair-share').Count -eq 0)

  # =============================== B2: reuse of a clean same-role slot
  Clear-Leases; Reset-Journal
  Set-Cfg $base
  Remove-Item Env:\AGENTQ_TEST_SLOT_BUDGET -ErrorAction SilentlyContinue
  $env:AGENTQ_SESSION = 'me'
  $o = AQ lease -Role scratch -Purpose 'lead work' -Json
  Check 'B2 the first scratch lease is granted' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-1'))) $o
  $slot1 = (Get-Content (LFile 'scratch-1') -Raw | ConvertFrom-Json).path
  git -C $slot1 checkout -q -- . 2>$null; git -C $slot1 clean -qfd 2>$null
  $o = AQ lease -Role scratch -Purpose 'a subagent asks too' -Json
  $reused = @(Ev 'slot-reuse')
  Check 'B2 a second lease of the same role REUSES the clean slot, it does not rent one' ($script:code -eq 0 -and $reused.Count -eq 1 -and -not (Test-Path (LFile 'scratch-2'))) $o
  Check 'B2 the reused answer names the slot this session already holds' ($o -match 'scratch-1') $o
  Check 'B2 the reuse is journaled with the session and the role' ($reused.Count -eq 1 -and $reused[0].session -eq 'me' -and $reused[0].role -eq 'scratch') ($reused[0] | ConvertTo-Json -Compress)

  # =============================== B3: a DIRTY slot is NOT reused
  Clear-Leases; Reset-Journal
  $env:AGENTQ_SESSION = 'me'
  $o = AQ lease -Role scratch -Purpose 'lead dirty' -Json
  Check 'B3 the first scratch lease is granted' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-1'))) $o
  $slot1 = (Get-Content (LFile 'scratch-1') -Raw | ConvertFrom-Json).path
  [IO.File]::WriteAllText((Join-Path $slot1 'unsaved.txt'), "wip`n")
  $o = AQ lease -Role scratch -Purpose 'needs a slot while the lead has unsaved work' -Json
  Check 'B3 a DIRTY same-role slot is NOT reused (a new slot is rented)' ($script:code -eq 0 -and @(Ev 'slot-reuse').Count -eq 0 -and (Test-Path (LFile 'scratch-2'))) $o

  # =============================== B4: derived share - a session at its share is REFUSED
  Clear-Leases; Reset-Journal
  # taskSlotsMachineFloor 0 -> floor+1 = 1; AGENTQ_TEST_SLOT_BUDGET '8,8' -> derived 0 -> cap 1 -> with
  # 2 competing sessions the derived share is ceil(1/2) = 1.
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":2,"taskSlotsMachineFloor":0,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":true}}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'mine-1' -Slot scratch-1 -Json
  Check 'B4 my session holds 1 scratch slot' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-1')))
  $env:AGENTQ_SESSION = 'other'
  $null = AQ lease -Role scratch -Purpose 'other-1' -Slot scratch-2 -Json
  Check 'B4 another session holds a slot (so we compete)' ($script:code -eq 0 -and (Test-Path (LFile 'scratch-2')))
  $env:AGENTQ_SESSION = 'me'
  $o = AQ lease -Role scratch -Purpose 'mine-2' -Slot scratch-3 -Wait -MaxMin 0 -Json
  Check 'B4 a session at its share is REFUSED (exit 3), no slot taken' ($script:code -eq 3 -and -not (Test-Path (LFile 'scratch-3'))) $o
  $ev = @(Ev 'slot-fair-share')
  Check 'B4 the refusal is journaled ONCE with session/held/cap' ($ev.Count -eq 1 -and $ev[0].session -eq 'me' -and [int]$ev[0].held -ge 1 -and [int]$ev[0].cap -eq 1) ($ev[0] | ConvertTo-Json -Compress)
  Check 'B4 the message names my session, the held count, the share, the held purpose and BOTH recipes' ($o -match 'me' -and $o -match 'holds 1' -and $o -match 'share of 1' -and $o -match 'mine-1' -and $o -match 'agentq unlease' -and $o -match 'reuse') $o
  Check 'B4 no event is journaled for the OTHER session' (@($ev | Where-Object { $_.session -ne 'me' }).Count -eq 0)

  # =============================== B5: slotsPerSession > 0 is honoured (overrides the derived share)
  Clear-Leases; Reset-Journal
  # With plenty of room the derived share would be ceil(20/2) = 10; the PIN of 1 must refuse a 2nd slot.
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":20,"taskSlotsMachineFloor":2,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":true,"slotsPerSession":1}}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '1000,1000'
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'p1' -Slot scratch-1 -Json
  $env:AGENTQ_SESSION = 'other'
  $null = AQ lease -Role scratch -Purpose 'o1' -Slot scratch-2 -Json
  $env:AGENTQ_SESSION = 'me'
  $o = AQ lease -Role scratch -Purpose 'p2' -Slot scratch-3 -Wait -MaxMin 0 -Json
  Check 'B5 slotsPerSession=1 refuses a 2nd slot the derived share would have allowed' ($script:code -eq 3 -and -not (Test-Path (LFile 'scratch-3'))) $o
  $ev = @(Ev 'slot-fair-share')[-1]
  Check 'B5 the journal records the PINNED slotsPerSession, not the derived share' ([int]$ev.slotsPerSession -eq 1 -and [int]$ev.cap -eq 1) ($ev | ConvertTo-Json -Compress)

  # =============================== B6: the status SLOT SHARE line
  $env:AGENTQ_SESSION = 'me'
  $o = AQ status -All
  Check 'B6 status -All prints a SLOT SHARE line' ($script:code -eq 0 -and $o -match 'SLOT SHARE') "code=$($script:code) :: $o"

  # =============================== B7: fairShare disabled -> no reuse, no cap (old behaviour)
  Clear-Leases; Reset-Journal
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":2,"taskSlotsMachineFloor":0,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2,"fairShare":{"enabled":false}}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'd1' -Slot scratch-1 -Json
  $env:AGENTQ_SESSION = 'other'
  $null = AQ lease -Role scratch -Purpose 'd2' -Slot scratch-2 -Json
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'd3' -Slot scratch-3 -Json
  Check 'B7 fairShare disabled: a 2nd slot of the same session is granted (no cap)' ((Test-Path (LFile 'scratch-3')) -and @(Ev 'slot-fair-share').Count -eq 0) "code=$($script:code)"
  $o = AQ lease -Role scratch -Purpose 'd4' -Wait -MaxMin 0 -Json
  Check 'B7 fairShare disabled: no reuse either (a new slot is rented)' (-not ($o -match 'reusing')) $o

  # =============================== B8: (a) the AGENTQ_NO_FAIRSHARE override leaves a trace when it MATTERED
  # Owner 2026-11-28. Without this the override is invisible: a fleet where every caller quietly opts out
  # looks exactly like a fleet with no contention, and the journal (the only fleet-wide record) cannot tell
  # the two apart. The line is written only when the override CHANGED the outcome - an override under the
  # share overrode nothing and must stay silent, or the record becomes noise nobody reads.
  Remove-Item Env:\AGENTQ_NO_FAIRSHARE -ErrorAction SilentlyContinue
  Clear-Leases; Reset-Journal
  Set-Cfg '{"taskSlotsPerRepo":12,"taskSlotsMachine":2,"taskSlotsMachineFloor":0,"scratchSlots":3,"scratchSlotsMax":6,"scratchMinFreeGB":0,"minFreeCommitGB":0,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":1440,"machineCap":2}'
  $env:AGENTQ_TEST_SLOT_BUDGET = '8,8'
  $env:AGENTQ_SESSION = 'other'
  $null = AQ lease -Role scratch -Purpose 'o1' -Slot scratch-1 -Json
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'm1' -Slot scratch-2 -Json
  $o = AQ lease -Role scratch -Purpose 'm2' -Slot scratch-3 -Wait -MaxMin 0 -Json
  Check 'B8 without the override the 2nd slot is refused and the refusal alone is journaled' `
    ((-not (Test-Path (LFile 'scratch-3'))) -and @(Ev 'slot-fair-share').Count -ge 1 -and @(Ev 'fair-share-override').Count -eq 0) "code=$($script:code) :: $o"
  Reset-Journal
  $env:AGENTQ_NO_FAIRSHARE = '1'
  $o = AQ lease -Role scratch -Purpose 'm3' -Slot scratch-4 -Json
  $ov = @(Ev 'fair-share-override')
  Check 'B8a the override admits the slot AND journals fair-share-override with the numbers it overrode' `
    ((Test-Path (LFile 'scratch-4')) -and $ov.Count -eq 1 -and $ov[0].held -eq 1 -and $ov[0].cap -eq 1) "code=$($script:code) :: $($ov | ConvertTo-Json -Compress) :: $o"
  Check 'B8b the override line is evidence, not a tally: resource, key, share numbers and scope' `
    ($ov[0].resource -match '^slot:.+:scratch$' -and $ov[0].keyBy -in 'chat', 'session' -and $ov[0].perRepo -eq $false -and $ov[0].sessions -eq 2 -and $ov[0].cap -eq [int][math]::Ceiling([double]$ov[0].taskCap / [double]$ov[0].sessions) -and "$($ov[0].reason)" -match 'AGENTQ_NO_FAIRSHARE') "$($ov[0] | ConvertTo-Json -Compress)"
  # the half that keeps the record trustworthy: no contention -> nothing was overridden -> no line
  Clear-Leases; Reset-Journal
  $env:AGENTQ_SESSION = 'me'
  $null = AQ lease -Role scratch -Purpose 'solo' -Slot scratch-5 -Json
  Check 'B8c an override UNDER the share journals nothing (it overrode nothing)' `
    (@(Ev 'fair-share-override').Count -eq 0 -and (Test-Path (LFile 'scratch-5'))) "code=$($script:code) :: $(@(Ev 'fair-share-override').Count)"
  Remove-Item Env:\AGENTQ_NO_FAIRSHARE -ErrorAction SilentlyContinue
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
Write-Host ''
if ($fail) { Write-Host "FAILED $fail" -ForegroundColor Red; exit 1 }
Write-Host 'ALL PASS slot share (D5)'
exit 0
