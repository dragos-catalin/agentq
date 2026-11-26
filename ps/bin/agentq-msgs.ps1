<#
  agentq-msgs.ps1 - a directed channel between the agents working on one machine (ask / reply / inbox).

  Why it exists (measured 2026-11-25, before writing it): the only way one agent could reach another was
  `note` - a journal line filed under a repo, with no addressee, no answer and no notification - plus
  `feedback`, which is the TOOL's inbox and faces the owner. Everything else an agent had was a resource
  verdict (`eval`). Two real coordination incidents had to be reported in prose AFTER the fact (a killed
  brivio pre-gate, 2026-11-24), because there was no way to ask before acting.

  Design, in the idiom of the rest of agentq:
    - one JSON file per message under $Root/msgs (<8 hex>.json); the journal carries `ask` and `reply`;
    - addressing is what an agent actually knows about its neighbour: repo:<name>, session:<term-id>,
      slot:<repo>:<slot>, `any`, `owner`. A bare word is read as a repo name;
    - `ask` prints how many LIVE agents the address reaches (from the agent registry), so "asked" and
      "asked nobody" are different outcomes and the sender can tell them apart;
    - a non-read-only agentq call prints the number of open messages addressed to this session, throttled
      to once per noticeMsgMin minutes, so nobody has to poll the journal.

  Read: `agentq help ask`. Acting verbs: ask, reply, inbox. State: $Root/msgs, $Root/agents (read-only here).
#>

# Per-process memo for the two identity helpers below. They are asked per MESSAGE (Test-MsgMine), and the
# answers cannot change inside one CLI invocation: without this, an `inbox` of 14 rows paid 14 git spawns
# plus 14 walks of the lease tree before printing anything, and Show-MessageNotices - which runs on EVERY
# non-read-only verb - paid the same 3.1 s on every call (measured 2026-11-26).
$script:MyRepoNamesCache = $null
$script:MySlotRefsCache = $null

function Get-MsgDir {
  $d = Join-Path $Root 'msgs'
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  $d
}
function Read-MsgJson([string]$f) {
  try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable) } catch { return $null }
}
function Get-MyRepoName {
  try { $r = Get-RepoInfo $Repo; if ($r) { "$($r.Name)" } else { $null } } catch { $null }
}
# Every repo name I am reachable UNDER: the one I am working in, and the one my own registry record names
# (the agent that asked me knows the name I had the last time I ran anything here).
function Get-MyRepoNames {
  # Computed once per process - see the cache declaration above.
  if ($null -ne $script:MyRepoNamesCache) { return $script:MyRepoNamesCache }
  $out = @()
  $r = Get-MyRepoName; if ($r) { $out += $r }
  try {
    $f = Join-Path (Join-Path $Root 'agents') ((Safe $Session) + '.json')
    if (Test-Path -LiteralPath $f) { $j = Read-MsgJson $f; if ($j -and $j['repo']) { $out += "$($j['repo'])" } }
  } catch {}
  $script:MyRepoNamesCache = @($out | Select-Object -Unique)
  $script:MyRepoNamesCache
}
# The addresses that belong to ME: my session, and every lease I hold (the slot's repo counts too - an
# agent working IN a repo is reachable by that repo's name even when its cwd is somewhere else).
function Get-MySlotRefs {
  # Computed once per process, and the walk pre-filters on the RAW text before parsing: a lease that does
  # not name my session in its bytes cannot be mine. Same shape as Get-SessionTickets in agentq.ps1.
  if ($null -ne $script:MySlotRefsCache) { return $script:MySlotRefsCache }
  $out = @()
  try {
    $ld = Join-Path $SysRoot 'leases'
    if (Test-Path -LiteralPath $ld) {
      $needle = '"' + "$Session" + '"'
      foreach ($f in @(Get-ChildItem -LiteralPath $ld -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try { if (-not ([IO.File]::ReadAllText($f.FullName).Contains($needle))) { continue } } catch { continue }
        $j = Read-MsgJson $f.FullName
        if (-not $j) { continue }
        if ("$($j['session'])" -eq "$Session" -and $j['repo'] -and $j['slot']) {
          $out += "slot:$($j['repo']):$($j['slot'])"
          $out += "repo:$($j['repo'])"
        }
      }
    }
  } catch {}
  $script:MySlotRefsCache = @($out | Select-Object -Unique)
  $script:MySlotRefsCache
}
function Get-LiveAgents([int]$Minutes = 30) {
  $out = @()
  try {
    $ad = Join-Path $Root 'agents'
    if (Test-Path -LiteralPath $ad) {
      $cut = (Now).AddMinutes(-1 * $Minutes)
      foreach ($f in @(Get-ChildItem -LiteralPath $ad -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $j = Read-MsgJson $f.FullName
        if (-not $j) { continue }
        $ls = $null; if ($j['lastSeen']) { try { $ls = ParseUtc $j['lastSeen'] } catch { $ls = $null } }
        if ($ls -and $ls -lt $cut) { continue }
        $out += $j
      }
    }
  } catch {}
  @($out)
}
function Resolve-MsgTarget([string]$t) {
  $u = 'agentq ask: -To must be repo:<name> | session:<term-id> | slot:<repo>:<slot> | any | owner'
  if (-not $t) { [Console]::Error.WriteLine($u); exit 2 }
  $v = "$t".Trim(); $l = $v.ToLowerInvariant()
  if ($l -in 'any', 'all', '*') { return 'any' }
  if ($l -eq 'owner') { return 'owner' }
  if ($l -like 'repo:*') { $n = $v.Substring(5).Trim(); if (-not $n) { [Console]::Error.WriteLine("agentq ask: -To repo: needs a repository name. $u"); exit 2 }; return "repo:$n" }
  if ($l -like 'session:*') { $n = $v.Substring(8).Trim(); if (-not $n) { [Console]::Error.WriteLine("agentq ask: -To session: needs a session id (agentq status prints one). $u"); exit 2 }; return "session:$n" }
  if ($l -like 'slot:*') { $p = $v -split ':'; if ($p.Count -lt 3 -or -not $p[1] -or -not $p[2]) { [Console]::Error.WriteLine("agentq ask: -To slot: needs slot:<repo>:<slot>. $u"); exit 2 }; return "slot:$($p[1]):$($p[2])" }
  if ($v -notmatch '[\s:]') { return "repo:$v" }
  [Console]::Error.WriteLine("agentq ask: cannot read -To '$t'. $u"); exit 2
}
# How many live agents (excluding me) this address reaches. The sender can then tell "asked" from "asked nobody".
function Get-MsgReachable([string]$to) {
  $me = "$Session"
  $agents = @(Get-LiveAgents 30 | Where-Object { "$($_['session'])" -ne $me })
  if ($to -eq 'any') { return @($agents).Count }
  if ($to -eq 'owner') { return 1 }
  if ($to -like 'repo:*') { $n = $to.Substring(5); return @($agents | Where-Object { "$($_['repo'])" -eq $n }).Count }
  if ($to -like 'session:*') { $n = $to.Substring(8); return @($agents | Where-Object { "$($_['session'])" -eq $n }).Count }
  @($agents).Count
}
function Test-MsgMine([hashtable]$m) {
  if (-not $m) { return $false }
  $fromS = if ($m['from']) { "$($m['from']['session'])" } else { '' }
  if ($fromS -eq "$Session") { return $false }
  $to = "$($m['to'])"
  if ($to -eq 'any') { return $true }
  if ($to -eq "session:$Session") { return $true }
  foreach ($rep in @(Get-MyRepoNames)) { if ($to -eq "repo:$rep") { return $true } }
  foreach ($s in @(Get-MySlotRefs)) { if ($to -eq $s) { return $true } }
  $false
}
function Get-AllMsgs {
  $dir = Get-MsgDir
  @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue |
    ForEach-Object { Read-MsgJson $_.FullName } | Where-Object { $_ -and $_['id'] })
}
function Resolve-MsgId([string]$id) {
  $dir = Get-MsgDir
  $f = Join-Path $dir "$id.json"
  if (Test-Path -LiteralPath $f) { return $f }
  $c = @(Get-ChildItem -LiteralPath $dir -Filter "$id*.json" -File -ErrorAction SilentlyContinue)
  if ($c.Count -eq 1) { return $c[0].FullName }
  $null
}
function Format-MsgAge([string]$ts) {
  try {
    $min = [int]((Now) - (ParseUtc $ts)).TotalMinutes
    if ($min -lt 60) { return "${min}m" }
    if ($min -lt 2880) { return "$([int]($min / 60))h" }
    "$([int]($min / 1440))d"
  } catch { '?' }
}
function Write-MsgFile([string]$f, [hashtable]$m) {
  $tmp = "$f.$PID.tmp"
  [IO.File]::WriteAllText($tmp, ($m | ConvertTo-Json -Depth 6 -Compress), [Text.UTF8Encoding]::new($false))
  Move-Item -Force -LiteralPath $tmp -Destination $f
}
function Invoke-Ask {
  $u = 'agentq ask -To <repo:<name>|session:<term-id>|slot:<repo>:<slot>|any|owner> -Message "..." [-Resource <r>] [-Repo <r>]'
  if (-not $Message) { [Console]::Error.WriteLine($u); exit 2 }
  if ($Message.Length -lt 8) { [Console]::Error.WriteLine('agentq ask: -Message is too short to be useful (min 8 chars) - say what you need decided'); exit 2 }
  $to = Resolve-MsgTarget $To
  $dir = Get-MsgDir
  $id = [guid]::NewGuid().ToString('n').Substring(0, 8)
  $f = Join-Path $dir "$id.json"
  $rep = Get-MyRepoName
  $rec = [ordered]@{
    v = 1; id = $id; to = $to
    resource = $(if ($Resource) { "$Resource" } else { $null })
    repo = $(if ($rep) { $rep } else { $null })
    message = $Message
    askedAt = (Iso (Now)); state = 'open'
    from = [ordered]@{
      session = $Session; repo = $rep; cwd = (Get-Location).Path
      user = [Environment]::UserName; host = [Environment]::MachineName; pid = $PID
    }
    answers = @()
  }
  Write-MsgFile $f $rec
  Write-Journal @{ event = 'ask'; resource = "msg:$id"; to = $to; repo = $(if ($rep) { $rep } else { '' }); about = $(if ($Resource) { "$Resource" } else { '' }); message = $Message }
  $reach = Get-MsgReachable $to
  Write-Output "asked $id to $to (reachable: $reach live agent$(if ($reach -ne 1) { 's' }))"
  if ($reach -eq 0) {
    [Console]::Error.WriteLine("agentq: nothing live at $to right now - the message is kept; a later agentq call from that address prints it (agentq inbox). For the OWNER use -To owner.")
  }
  # single-quoted pieces on purpose: a double-quoted string with an escaped inner quote is the exact
  # shape that printed a stray backslash instead of the quotes (seen live 2026-11-25).
  Write-Output ('  reply: agentq reply -Id ' + $id + ' -Message "..."   thread: agentq inbox -Id ' + $id)
}
function Invoke-Reply {
  if (-not $Id) { [Console]::Error.WriteLine('agentq reply -Id <message id> -Message "..."'); exit 2 }
  if (-not $Message) { [Console]::Error.WriteLine('agentq reply -Id <message id> -Message "..."'); exit 2 }
  $f = Resolve-MsgId $Id
  if (-not $f) { [Console]::Error.WriteLine("agentq reply: no message '$Id' (agentq inbox)"); exit 2 }
  $m = Read-MsgJson $f
  if (-not $m) { [Console]::Error.WriteLine("agentq reply: message '$Id' is unreadable"); exit 2 }
  $rep = Get-MyRepoName
  $ans = @($m['answers']) + @([ordered]@{ session = $Session; repo = $rep; user = [Environment]::UserName; at = (Iso (Now)); message = $Message })
  $fromS = if ($m['from']) { "$($m['from']['session'])" } else { '' }
  # A reply from the asker is a follow-up (the thread reopens); anyone else answers it.
  $m['state'] = $(if ($fromS -eq "$Session") { 'open' } else { 'answered' })
  $m['answers'] = $ans
  Write-MsgFile $f $m
  Write-Journal @{ event = 'reply'; resource = "msg:$($m['id'])"; to = "$($m['to'])"; repo = $(if ($rep) { $rep } else { '' }); state = "$($m['state'])"; message = $Message }
  Write-Output "replied to $($m['id']) (now $($m['state']) for $($m['to']))"
}
function Show-Inbox {
  if ($Id) {
    $f = Resolve-MsgId $Id
    if (-not $f) { [Console]::Error.WriteLine("agentq inbox: no message '$Id'"); exit 2 }
    $m = Read-MsgJson $f
    if ($Json) { ConvertTo-Json -InputObject $m -Depth 6; return }
    $fs = if ($m['from']) { "$($m['from']['session'])" } else { '?' }
    $fr = if ($m['from'] -and $m['from']['repo']) { " ($($m['from']['repo']))" } else { '' }
    Write-Output "$($m['id'])  [$($m['state'])]  $(Format-MsgAge $m['askedAt']) ago  to $($m['to'])  from $fs$fr"
    if ($m['resource']) { Write-Output "  about: $($m['resource'])" }
    Write-Output "  > $($m['message'])"
    foreach ($a in @($m['answers'])) {
      if (-not $a) { continue }
      Write-Output ''
      Write-Output "  <- $(if ($a['session']) { $a['session'] }) $(Format-MsgAge $a['at']) ago: $($a['message'])"
    }
    return
  }
  $rows = @(Get-AllMsgs | Where-Object { $All -or "$($_['state'])" -ne 'answered' } | Where-Object { Test-MsgMine $_ } |
    Sort-Object -Property @{ Expression = { ParseUtc $_['askedAt'] } } -Descending)
  if ($Json) { ConvertTo-Json -InputObject @($rows) -Depth 6; return }
  if (-not $rows) { Write-Output "inbox: no $(if ($All) { '' }else { 'open ' })message(s) addressed to $Session$(if (Get-MyRepoName) { " / repo:$(Get-MyRepoName)" })"; return }
  Write-Output "== INBOX for $Session$(if (Get-MyRepoName) { " / repo:$(Get-MyRepoName)" })  ($($rows.Count) $(if ($All) { 'total' } else { 'open' }))"
  foreach ($m in $rows) {
    $fs = if ($m['from']) { "$($m['from']['session'])" } else { '?' }
    $fr = if ($m['from'] -and $m['from']['repo']) { " ($($m['from']['repo']))" } else { '' }
    $line = "$($m['id'])  $(Format-MsgAge $m['askedAt'])  $fs$fr$(if ($m['resource']) { "  about $($m['resource'])" })"
    Write-Output $line
    Write-Output "  $([string]$m['message'] -replace "`r?`n", ' ' | ForEach-Object { if ($_.Length -gt 200) { $_.Substring(0, 200) + '...' } else { $_ } })"
  }
  Write-Output ''
  Write-Output '  agentq inbox -Id <id>                          the whole thread'
  Write-Output '  agentq reply -Id <id> -Message "..."           answer it'
}
# Delivery without polling: any non-read-only agentq call prints the count of open messages addressed to
# this session, at most once per noticeMsgMin minutes (the file remembers when it last showed them).
function Show-MessageNotices {
  try {
    $min = 10
    $cf = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $PSScriptRoot 'agentq-config.json' }
    # `$null -ne` and not truthiness: 0 is a valid setting ("show it on every call"), and PowerShell reads a
    # bare 0 as false, which silently turned the knob off (caught by test-agentq-msgs.ps1).
    try { $c = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json -AsHashtable; if ($c -and $null -ne $c['noticeMsgMin']) { $min = [int]$c['noticeMsgMin'] } } catch {}
    # Deliberately NOT Get-MsgDir: that one creates the store, so attaching a notice to every verb made a
    # read-only-looking call mutate the coord tree ("whatif changed nothing" in test-agentq-prune.ps1).
    # No directory means no message can be addressed to me, so there is nothing to announce.
    $dir = Join-Path $Root 'msgs'
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $stamp = Join-Path $dir ('.notice-' + (Safe $Session))
    if (Test-Path -LiteralPath $stamp) {
      try { if ((Now) - (ParseUtc ((Get-Content -LiteralPath $stamp -Raw).Trim())) -lt [TimeSpan]::FromMinutes($min)) { return } } catch {}
    }
    $open = @(Get-AllMsgs | Where-Object { "$($_['state'])" -ne 'answered' } | Where-Object { Test-MsgMine $_ })
    if (-not $open) { return }
    [IO.File]::WriteAllText($stamp, (Iso (Now)), [Text.UTF8Encoding]::new($false))
    $newest = @($open | Sort-Object -Property @{ Expression = { ParseUtc $_['askedAt'] } } -Descending)[0]
    [Console]::Error.WriteLine("agentq: INBOX $($open.Count) open message(s) for you - agentq inbox - $($newest['id']) from $($newest['from']['session']): $(([string]$newest['message'] -replace "`r?`n", ' '))")
  } catch { if ($env:AGENTQ_MSGS_DEBUG) { [Console]::Error.WriteLine("agentq: the message notice failed: $($_.Exception.Message)") } }
}
