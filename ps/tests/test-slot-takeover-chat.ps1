# TASK 2 (2026-11-26): a slot take-over is announced per CHAT, not per session.
# The bug: `Publish-SlotTakeover` suppressed its note whenever `$holder -eq $Session`, even though
# `Backup-Slot` had really run. So a SIBLING chat of the same session could re-lease a slot over another
# chat's unsaved work - the work was saved to refs/backup/... and nobody was told - because the two chats
# share one session id. The evidence for "provably the same worker" is the chat list the previous lease
# left in <lease>.json.chat: the suppression may only fire when the CURRENT chat is one of those chats.
#   A. a sibling chat (same session, different chat id) IS told, and the note NAMES the displaced chat;
#   B. the same chat re-leasing its own slot is NOT told (that is the noise the suppression is for);
#   C. an unknown current chat NEVER suppresses (the note is cheap, a silent clobber is not);
#   D. a cross-session take-over keeps the wording the recover suite pins ("another session", the holder).
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqtk-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; $env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'
# The suite leases a `task` slot, and a task lease is held back while the machine's start probe says it is
# saturated (admission, ADR 0009). On a box running several agents that turns 'PASS 0 slot leased' into a
# minutes-long silent wait, so the suite opts out of admission exactly as the help text documents
# (AGENTQ_NO_ADMISSION=1 opts ONE call out) - the lease mechanics under test are unrelated to load.
$env:AGENTQ_NO_ADMISSION = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
Remove-Item Env:AGENTQ_CHAT_ID -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0,"scratchIdleMin":900}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
# The session stays the SAME one the note logic compares against (`-eq`/`-ne`): only its CASE varies,
# and it is alternated so the spelling stored in the lease never matches the caller's. Why that matters:
# `Renew-ForSession` looks the session up inside the lease JSON with the case-SENSITIVE `String.Contains`,
# and a renewal touches the lease's `.hb` - the aged slot then looks live and `lease` WAITS FOR A FREE SLOT
# instead of taking the slot over (measured 2026-11-27: the take-over never happened and the suite hung).
# Every identity decision the note logic makes uses PowerShell's case-INSENSITIVE `-eq`, so a case variant
# is still "the same session" to the code under test - which is exactly a sibling chat of one window.
$same = 'OWNER-A'   # A/C: the sibling chat case
$same2 = 'owner-a'  # B/D: the same chat again, spelled as the lease stored it before
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
# The lease must look abandoned to whoever takes it over: dead pid, an old heartbeat, old slot git files
# AND an old chat binding - `Get-LeaseChatFacts` counts a chat touched within 30 min as LIVE, which is the
# whole point of the chat clock (a session-wide takeover must not look like the holder is still working).
function Age($leaseJson, [int]$min) {
  $hb = "$leaseJson.hb"; [IO.File]::SetLastWriteTimeUtc($hb, [DateTime]::UtcNow.AddMinutes(-$min))
  if (Test-Path -LiteralPath "$leaseJson.chat") { [IO.File]::SetLastWriteTimeUtc("$leaseJson.chat", [DateTime]::UtcNow.AddMinutes(-($min + 10))) }
  $l = Get-Content $leaseJson -Raw | ConvertFrom-Json; $l.created = [DateTime]::UtcNow.AddMinutes(-$min - 5).ToString('o'); $l.pid = 999999; $l.procStart = $null
  [IO.File]::WriteAllText($leaseJson, ($l | ConvertTo-Json -Compress))
  $gd = ((Get-Content (Join-Path $l.path '.git') -Raw) -replace '^gitdir:\s*', '').Trim()
  foreach ($n in 'index', 'HEAD', 'logs\HEAD') { $p = Join-Path $gd $n; if (Test-Path $p) { [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddMinutes(-$min)) } }
}
# The guard hook's side of the contract: <lease>.json.chat = { leaseId, chats:[...] }.
function BindChat($leaseJson, [string]$leaseId, [string[]]$chats) {
  [IO.File]::WriteAllText("$leaseJson.chat", (@{ leaseId = $leaseId; chats = @($chats) } | ConvertTo-Json -Compress))
}
function Takeovers { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.event -eq 'lease-takeover' }) }
function LastTakeover { @(Takeovers | Select-Object -Last 1) }
function ReadLease($f) { Get-Content $f -Raw | ConvertFrom-Json }
# A fresh unsaved file in the slot, so the next lease really backs something up and `$prevRef` is non-empty
# (without unsaved work the note is not produced at all, and the assertion would be vacuous).
function Wip($path, [string]$what) { [IO.File]::WriteAllText((Join-Path $path "wip-$what.txt"), "unsaved $what`n") }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  # ---- 0. the first holder (session owner-A) leaves unsaved work in task-1
  $env:AGENTQ_SESSION = 'owner-A'
  $la = (AQ lease -Purpose 'work A' -Json | Select-Object -Last 1 | ConvertFrom-Json)
  Check '0 slot leased' ($la.slot -eq 'task-1' -and (Test-Path $la.path)) ($la | ConvertTo-Json -Compress)
  $lf = Join-Path $env:AGENTQ_HOME "leases\repo\$($la.slot).json"

  # ---- A. a SIBLING chat of the same session takes the slot over: it IS told, and told who it displaced
  $env:AGENTQ_SESSION = $same
  Wip $la.path 'A'
  BindChat $lf $la.leaseId @('chat-1')
  Age $lf 30
  $env:AGENTQ_CHAT_ID = 'chat-2'
  $out = AQ lease -Purpose 'work A sibling' -Slot task-1
  Check 'A1 sibling chat gets the take-over note' ($out -match 'still held another chat') $out
  Check 'A2 the note names the displaced chat' ($out -match 'chats displaced: chat-1') $out
  Check 'A3 the note still names the holder and the ref' ($out -match 'last holder: owner-A' -and $out -match 'refs/backup/wt/repo/task-1/') $out
  $tk = LastTakeover
  Check 'A4 journalled: holderChats + byChat + sameChat=false' ($tk.Count -eq 1 -and (($tk[0].holderChats -join ',') -match 'chat-1') -and "$($tk[0].byChat)" -eq 'chat-2' -and $tk[0].sameChat -eq $false) ($tk | ConvertTo-Json -Compress)
  Check 'A5 holderSession is still recorded (the SLO and the recover suite read it)' ("$($tk[0].holderSession)" -eq 'owner-A') ($tk | ConvertTo-Json -Compress)

  # ---- B. the SAME chat re-leasing its own slot is NOT told (the noise the suppression exists for)
  $env:AGENTQ_SESSION = $same2
  $lb = ReadLease $lf
  Wip $la.path 'B'
  BindChat $lf $lb.leaseId @('chat-1')
  Age $lf 30
  $env:AGENTQ_CHAT_ID = 'chat-1'
  $out = AQ lease -Purpose 'work A same chat' -Slot task-1
  Check 'B1 the same chat is NOT told' (-not ($out -match 'still held')) $out
  Check 'B2 the take-over is still journalled with sameChat=true' ((LastTakeover)[0].sameChat -eq $true) ((LastTakeover) | ConvertTo-Json -Compress)

  # ---- C. an unknown current chat NEVER suppresses
  $env:AGENTQ_SESSION = $same
  $lc = ReadLease $lf
  Wip $la.path 'C'
  BindChat $lf $lc.leaseId @('chat-1')
  Age $lf 30
  Remove-Item Env:AGENTQ_CHAT_ID -ErrorAction SilentlyContinue
  if (Test-Path (Join-Path $env:AGENTQ_HOME 'chats\.last.json')) { Remove-Item -Force (Join-Path $env:AGENTQ_HOME 'chats\.last.json') }
  $out = AQ lease -Purpose 'work A unknown chat' -Slot task-1
  Check 'C1 an unknown chat is told anyway' ($out -match 'still held another chat') $out
  Check 'C2 journalled with sameChat=false and byChat empty' ((LastTakeover)[0].sameChat -eq $false -and -not "$((LastTakeover)[0].byChat)") ((LastTakeover) | ConvertTo-Json -Compress)

  # ---- D. the hook's marker IS the fallback (no explicit AGENTQ_CHAT_ID): a fresh .last.json names the chat
  $env:AGENTQ_SESSION = $same2
  $ld = ReadLease $lf
  Wip $la.path 'D'
  BindChat $lf $ld.leaseId @('chat-1')
  Age $lf 30
  $cd = Join-Path $env:AGENTQ_HOME 'chats'; New-Item -ItemType Directory -Force $cd | Out-Null
  [IO.File]::WriteAllText((Join-Path $cd '.last.json'), (@{ chatId = 'chat-1'; at = [DateTime]::UtcNow.ToString('o') } | ConvertTo-Json -Compress))
  $out = AQ lease -Purpose 'work A hook marker' -Slot task-1
  Check 'D1 a fresh hook marker identifies the chat, so the same chat is NOT told' (-not ($out -match 'still held')) $out
  [IO.File]::WriteAllText((Join-Path $cd '.last.json'), (@{ chatId = 'chat-1'; at = [DateTime]::UtcNow.AddHours(-2).ToString('o') } | ConvertTo-Json -Compress))

  # ---- E. cross-session behaviour is unchanged (the recover suite pins this wording)
  $le = ReadLease $lf
  Wip $la.path 'E'
  BindChat $lf $le.leaseId @('chat-1')
  Age $lf 30
  Remove-Item Env:AGENTQ_CHAT_ID -ErrorAction SilentlyContinue
  $env:AGENTQ_SESSION = 'owner-B'
  $out = AQ lease -Purpose 'work B' -Slot task-1
  Check 'E1 cross-session still says "another session"' ($out -match 'still held another session') $out
  Check 'E2 and still names the previous holder' ($out -match 'last holder: owner-A') $out

  # ---- F. the previous holder is notified on its next call (the notice channel, unchanged)
  $env:AGENTQ_SESSION = 'owner-A'
  $st = AQ note -Message 'holder A is back'
  Check 'F1 the displaced holder is notified' ($st -match 'NOTICE your lease' -and $st -match 'lease-takeover') $st
} finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
