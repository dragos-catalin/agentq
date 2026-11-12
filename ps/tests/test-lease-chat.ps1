# ADR 0009 stage 0 (OQ-001): a slot lease is kept alive by the tool calls of the CHAT that works in it.
# The per-tool-call hook (hooks/guard-tooluse.ps1) binds a chat to a lease when it works in the slot and
# touches <lease>.json.chat on every later call of that chat; agentq counts a recent touch like a live
# owner process. Guard calls run under Windows PowerShell 5.1 where available (that is what the editor
# starts) and under PowerShell 7 otherwise. Isolated in %TEMP%.
param(
  [string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'),
  [string]$Guard = (Join-Path $PSScriptRoot '..\hooks\guard-tooluse.ps1')
)
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path; $Guard = (Resolve-Path $Guard).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqlc-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:CODAI_GH_ROOT = Join-Path $tmp 'gh'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_PRUNE = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
# dead owner: stale after 60 min idle; any lease: stale after 600 min idle
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseDeadIdleMin":60,"leaseMaxIdleMin":600,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
$ps51 = if ($IsWindows) { (Get-Command powershell.exe -ErrorAction SilentlyContinue).Source } else { $null }
# One tool call through the guard, as chat $chat. -Seven forces PowerShell 7.
function Hook([string]$chat, [string]$tool, $ti, [switch]$Seven) {
  $p = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = $ti }
  if ($chat) { $p.session_id = $chat }
  $j = $p | ConvertTo-Json -Compress -Depth 5
  $exe = if ($ps51 -and -not $Seven) { $ps51 } else { 'pwsh' }
  $out = $j | & $exe -NoProfile -ExecutionPolicy Bypass -File $Guard 2>$null
  [pscustomobject]@{ code = $LASTEXITCODE; out = ($out -join "`n") }
}
function Edit([string]$chat, [string]$path) { Hook $chat 'replace_string_in_file' @{ filePath = $path; oldString = 'x'; newString = 'y' } }
function Cmd([string]$chat, [string]$command) { Hook $chat 'run_in_terminal' @{ command = $command } }
# Make the SLOT look idle for $min minutes with a dead owner (heartbeat, git index, lease record).
function Age($leaseJson, [int]$min) {
  [IO.File]::SetLastWriteTimeUtc("$leaseJson.hb", [DateTime]::UtcNow.AddMinutes(-$min))
  $l = Get-Content $leaseJson -Raw | ConvertFrom-Json; $l.created = [DateTime]::UtcNow.AddMinutes(-$min - 5).ToString('o'); $l.pid = 999999; $l.procStart = $null
  [IO.File]::WriteAllText($leaseJson, ($l | ConvertTo-Json -Compress))
  $gd = ((Get-Content (Join-Path $l.path '.git') -Raw) -replace '^gitdir:\s*', '').Trim()
  foreach ($n in 'index', 'HEAD', 'logs\HEAD') { $p = Join-Path $gd $n; if (Test-Path $p) { [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddMinutes(-$min)) } }
}
function ChatAge($leaseJson, [int]$min) { [IO.File]::SetLastWriteTimeUtc("$leaseJson.chat", [DateTime]::UtcNow.AddMinutes(-$min)) }
function Lease([string]$id) { $env:AGENTQ_SESSION = 'observer'; $st = AQ status -All -Json | ConvertFrom-Json; @($st.leases | Where-Object { $_.leaseId -eq $id }) | Select-Object -First 1 }
function Journal([string]$ev) { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq $ev) }
function Chats($leaseJson) { if (Test-Path "$leaseJson.chat") { @((Get-Content "$leaseJson.chat" -Raw | ConvertFrom-Json).chats) } else { @() } }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
$chatDir = Join-Path $env:AGENTQ_HOME 'chats'
Push-Location $repo
try {
  Write-Host "guard runs under: $(if ($ps51) { 'Windows PowerShell 5.1 (+ one PowerShell 7 case)' } else { 'PowerShell 7' })"
  $env:AGENTQ_SESSION = 'owner-A'
  $o = AQ lease -Purpose 'work A' -Json; $la = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  $lf = Join-Path $env:AGENTQ_HOME "leases\repo\$($la.slot).json"

  # 0 control: dead owner + idle slot, no chat -> stale (the state that cost 185 lease-break + 40 lease-expire)
  Age $lf 90
  $l = Lease $la.leaseId
  Check '0 control: dead owner, slot idle 90 min, no chat -> stale' ($l -and $l.stale -and $null -eq $l.chatIdleMin) ($l | ConvertTo-Json -Compress)

  # 1 an edit inside the slot binds the chat to the lease
  $r = Edit 'chat-1' (Join-Path $la.path 'a.txt')
  Check '1 the guard allows the edit' ($r.code -eq 0 -and $r.out -notmatch '"deny"') $r.out
  Check '1 chat bound: <lease>.json.chat names it' ((Chats $lf) -contains 'chat-1') ((Chats $lf) -join ',')
  Check '1 chat bound: chats/<chat>.json names the lease' ((Test-Path "$chatDir\chat-1.json") -and (Get-Content "$chatDir\chat-1.json" -Raw) -match $la.leaseId)

  # 2 a tool call of that chat that has NOTHING to do with the slot keeps the lease alive
  Age $lf 90; ChatAge $lf 90
  $l = Lease $la.leaseId
  Check '2 control: chat silent for 90 min -> stale again' ($l.stale -and $l.chatIdleMin -ge 89) ($l | ConvertTo-Json -Compress)
  $hbBefore = (Get-Item "$lf.hb").LastWriteTimeUtc
  $r = Cmd 'chat-1' 'git status'
  $l = Lease $la.leaseId
  Check '2 unrelated tool call of the bound chat -> NOT stale' ($l -and -not $l.stale) ($l | ConvertTo-Json -Compress)
  Check '2 idleMin still reports the idle slot, chatIdleMin the chat' ($l.idleMin -ge 89 -and $l.chatIdleMin -lt 3) "idle=$($l.idleMin) chat=$($l.chatIdleMin)"
  Check '2 the slot heartbeat was not faked' ((Get-Item "$lf.hb").LastWriteTimeUtc -eq $hbBefore)
  $env:AGENTQ_SESSION = 'sweeper'
  $o = AQ sweep
  Check '2 sweep does not expire a slot whose chat is active' ($o -match 'expired=0' -and (Test-Path $lf)) $o
  $o = AQ status -All
  Check '2 status shows the lease as kept by a chat' ($o -match "repo/$($la.slot)\s+task\s+chat\s") $o
  # the same through a read tool, and under PowerShell 7
  ChatAge $lf 90
  $r = Hook 'chat-1' 'read_file' @{ filePath = (Join-Path $repo 'a.txt'); startLine = 1; endLine = 2 } -Seven
  $l = Lease $la.leaseId
  Check '2 a read by the bound chat keeps it alive too (PowerShell 7 run)' (-not $l.stale -and $l.chatIdleMin -lt 3)

  # 3 another chat does not keep it alive, and reading or inspecting a slot does not bind
  ChatAge $lf 90
  $null = Cmd 'chat-2' 'git status'
  Check '3 a tool call of an UNBOUND chat does nothing' ((Lease $la.leaseId).stale)
  $null = Hook 'chat-2' 'read_file' @{ filePath = (Join-Path $la.path 'a.txt'); startLine = 1; endLine = 2 }
  Check '3 reading a file in the slot does not bind' (-not ((Chats $lf) -contains 'chat-2') -and -not (Test-Path "$chatDir\chat-2.json"))
  Age $lf 90
  $null = Cmd 'chat-2' "pwsh -NoProfile -File `"$Aq`" lease-check -Path `"$($la.path)`""
  $null = Cmd 'chat-2' "pwsh -NoProfile -File `"$Aq`" status -Repo `"$($la.path)`""
  Check '3 agentq inspection verbs naming the slot do not bind' (-not ((Chats $lf) -contains 'chat-2'))
  Age $lf 90
  $null = Edit 'chat-2' (Join-Path "$($la.path)0" 'a.txt')
  Check '3 a path in <slot>0 is not the slot (task-1 vs task-10)' (-not ((Chats $lf) -contains 'chat-2')) ((Chats $lf) -join ',')
  $null = Hook '' 'replace_string_in_file' @{ filePath = (Join-Path $la.path 'a.txt'); oldString = 'x'; newString = 'y' }
  Check '3 a call without a chat id binds nothing and does not fail' ((Chats $lf).Count -eq 1)
  $env:AGENTQ_NO_CHAT_KEEPALIVE = '1'
  $null = Edit 'chat-off' (Join-Path $la.path 'a.txt')
  Remove-Item Env:AGENTQ_NO_CHAT_KEEPALIVE
  Check '3 AGENTQ_NO_CHAT_KEEPALIVE=1 turns binding off' (-not ((Chats $lf) -contains 'chat-off'))

  # 4 other ways of working in the slot bind too: a command naming it, an apply_patch file header
  $null = Cmd 'chat-3' "git -C `"$($la.path)`" status --short"
  Check '4 a working command that names the slot binds' ((Chats $lf) -contains 'chat-3')
  $null = Hook 'chat-4' 'apply_patch' @{ input = "*** Begin Patch`n*** Update File: $($la.path)\a.txt`n@@`n-a`n+b`n*** End Patch"; explanation = 'x' }
  Check '4 an apply_patch into the slot binds' ((Chats $lf) -contains 'chat-4')

  # 5 the limit a live keeper has applies to a live chat too: slot idle past leaseMaxIdleMin -> stale
  Age $lf 700
  $null = Cmd 'chat-1' 'git status'
  $l = Lease $la.leaseId
  Check '5 slot idle 700 min (> max 600) is stale even with a live chat' ($l.stale -and $l.chatIdleMin -lt 3) ($l | ConvertTo-Json -Compress)

  # 6 the chat stops -> the lease expires as before; the journal carries the chat facts for the SLO
  Age $lf 90; ChatAge $lf 70
  $env:AGENTQ_SESSION = 'sweeper'
  $o = AQ sweep
  Check '6 chat silent 70 min (> 60) -> sweep expires the lease' ($o -match 'expired repo/' -and -not (Test-Path $lf)) $o
  $ex = Journal 'lease-expire' | Select-Object -Last 1
  Check '6 lease-expire journals chats + chatIdleMin (> 30 = not a live chat)' ($ex -and $ex.chats -eq 3 -and $ex.chatIdleMin -ge 69 -and $ex.byChat -eq $false) ($ex | ConvertTo-Json -Compress)
  Check '6 the chat file went with the lease' (-not (Test-Path "$lf.chat"))

  # 7 a NEW lease of the same slot is not kept alive by the old chat
  # A binding file the previous lease left behind (a crash between its release and the cleanup), touched a
  # moment ago: the new lease must start without it, or it would count as kept alive by a chat it never had.
  [IO.File]::WriteAllText("$lf.chat", ('{"leaseId":"' + $la.leaseId + '","chats":["chat-1"]}'))
  $env:AGENTQ_SESSION = 'owner-B'
  $o = AQ lease -Slot $la.slot -Purpose 'work B' -Json; $lb = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check '7 slot leased again' ($lb.leaseId -and $lb.leaseId -ne $la.leaseId -and $lb.slot -eq $la.slot) $o
  Check '7 a binding file left by the previous lease is removed by the new one' (-not (Test-Path "$lf.chat"))
  $null = Cmd 'chat-1' 'git status'
  Check '7 the old chat is not attached to the new lease' ((Chats $lf).Count -eq 0 -and -not (Test-Path "$chatDir\chat-1.json")) ((Chats $lf) -join ',')
  Age $lf 90
  Check '7 so the new lease goes stale on its own' ((Lease $lb.leaseId).stale)

  # 8 who released it: the worker's own chat (from another shell) vs somebody else while the chat is live
  $null = Edit 'chat-5' (Join-Path $lb.path 'a.txt')
  $null = Cmd 'chat-5' "pwsh -NoProfile -File `"$Aq`" unlease -Repo `"$($lb.path)`" -LeaseId $($lb.leaseId) -Reason 'done, landed'"
  Check '8 the hook records which chat runs unlease' ((Test-Path "$lf.release") -and (Get-Content "$lf.release" -Raw).Trim() -eq 'chat-5')
  $env:AGENTQ_SESSION = 'another-shell'
  $o = AQ unlease -Repo $lb.path -LeaseId $lb.leaseId -Reason 'done, landed'
  $br = Journal 'lease-break' | Select-Object -Last 1
  Check '8 released by its own chat from another shell -> lease-break with byChat=true' ($code -eq 0 -and $br -and $br.byChat -eq $true -and $br.chatIdleMin -lt 3) "$o | $($br | ConvertTo-Json -Compress)"
  $env:AGENTQ_SESSION = 'owner-C'
  $o = AQ lease -Slot $la.slot -Purpose 'work C' -Json; $lc = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  $null = Edit 'chat-6' (Join-Path $lc.path 'a.txt')
  $env:AGENTQ_SESSION = 'intruder'
  $o = AQ unlease -Repo $lc.path -LeaseId $lc.leaseId -Reason 'i need a slot'
  $br = Journal 'lease-break' | Select-Object -Last 1
  Check '8 broken by someone else while its chat is live -> byChat=false, chatIdleMin small (the SLO counts it)' ($br.ticket -eq $lc.leaseId -and $br.byChat -eq $false -and $br.chatIdleMin -lt 3 -and $br.chats -eq 1) ($br | ConvertTo-Json -Compress)
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'CODAI_GH_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_PRUNE', 'AGENTQ_NO_CHAT_KEEPALIVE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
