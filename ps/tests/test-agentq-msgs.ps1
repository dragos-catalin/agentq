# agentq ask/reply/inbox (agentq-msgs.ps1): a directed channel between live agents. Synthetic state in
# %TEMP%; asserts addressing (session / slot / repo / any), that "asked nobody" is reported as such, the
# thread lifecycle (open -> answered -> reopened by the asker), the throttled delivery notice, and that an
# unreadable -To fails with a message an agent can act on instead of silently writing a dead message.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqmsg-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'
$env:AGENTQ_SESSION = 'asker'
$cfg = Join-Path $tmp 'cfg.json'
'{"machineCap":2,"quickBurst":0,"agingMin":0,"idleYieldMin":0,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
$H = $env:AGENTQ_HOME
function Put([string]$rel, $obj) {
  $p = Join-Path $H $rel
  New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null
  $text = if ($obj -is [string]) { $obj } else { $obj | ConvertTo-Json -Compress -Depth 6 }
  [IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($false))
  $p
}
$jf = Join-Path $H 'journal.jsonl'
function JournalHas([string]$pat) { (Test-Path -LiteralPath $jf) -and (@(Get-Content -LiteralPath $jf) -join "`n") -match [regex]::Escape($pat) }
function InboxOf([string]$session, [string[]]$extra) {
  $env:AGENTQ_SESSION = $session
  $out = AQ inbox @extra
  $env:AGENTQ_SESSION = 'asker'
  $out
}

try {
  # ---- 1. ask to a session that is NOT live: kept, and the sender is told it reached nobody -----------
  $out = AQ ask -To session:nobody-here -Message 'are you editing the shared file?'
  $id1 = if ($out -match 'asked ([0-9a-f]{8}) to') { $Matches[1] } else { '' }
  Check 'ask prints a message id' ($id1.Length -eq 8) $out
  Check 'ask says reachable: 0 live agent' ($out -match 'reachable: 0 live agents') $out
  Check 'ask warns that nothing is live' ($out -match 'nothing live at session:nobody-here') $out
  Check 'ask is journaled' (JournalHas '"event":"ask"') ''
  Check 'the message file exists' (Test-Path -LiteralPath (Join-Path $H "msgs\$id1.json"))
  Check 'ask exit 0' ($script:code -eq 0) "exit=$($script:code)"

  # ---- 2. a live agent in the registry makes the count honest ----------------------------------------
  $null = Put 'agents\term-1.json' @{ v = 1; session = 'term-1'; repo = 'vitals'; lastSeen = ([DateTime]::UtcNow.ToString('o')) }
  $out = AQ ask -To repo:vitals -Message 'plumbing question about the runner-agent'
  $id2 = if ($out -match 'asked ([0-9a-f]{8}) to') { $Matches[1] } else { '' }
  Check 'repo address counts the live agent' ($out -match 'reachable: 1 live agent\b') $out
  Check 'repo message is addressed as repo:vitals' (Select-String -Path (Join-Path $H "msgs\$id2.json") -Pattern '"to":"repo:vitals"' -Quiet) ''

  # ---- 3. the addressee sees it and nobody else does -------------------------------------------------
  Check 'the session addressee sees it' ((InboxOf 'nobody-here') -match $id1) ''
  Check 'an unrelated session sees nothing' ((InboxOf 'term-1') -notmatch $id1) ''
  Check 'the repo agent sees the repo message' ((InboxOf 'term-1') -match $id2) ''
  Check 'the asker does not see its own ask' ((InboxOf 'asker') -notmatch $id1) ''

  # ---- 4. a lease address (slot:<repo>:<slot>) reaches the holder ------------------------------------
  $null = Put 'leases\graph-existence\task-1.json' @{ leaseId = 'aa11bb22'; repo = 'graph-existence'; slot = 'task-1'; role = 'task'; session = 'holder1'; pid = 1; procStart = ([DateTime]::UtcNow.ToString('o')) }
  $out = AQ ask -To slot:graph-existence:task-1 -Message 'may I rebase your branch before landing?'
  $id3 = if ($out -match 'asked ([0-9a-f]{8}) to') { $Matches[1] } else { '' }
  Check 'slot address accepted' ($id3.Length -eq 8) $out
  Check 'the lease holder sees it' ((InboxOf 'holder1') -match $id3) ''
  Check 'the lease repo is also an address' ((InboxOf 'holder1' @('-Id', $id3)) -match 'to slot:graph-existence:task-1') ''

  # ---- 5. -To any reaches every live agent except the asker -----------------------------------------
  $out = AQ ask -To any -Message 'freezing deploy:brivio:release for 10 minutes, speak now'
  Check 'any is counted across the registry' ($out -match 'reachable: 1 live agent') $out
  Check 'any is seen by another session' ((InboxOf 'term-1') -match 'freezing deploy') ''

  # ---- 6. thread lifecycle -------------------------------------------------------------------------
  $env:AGENTQ_SESSION = 'nobody-here'
  $out = AQ reply -Id $id1 -Message 'yes, but I will be done in 5 minutes'
  Check 'reply accepted' ($out -match "replied to $id1") $out
  $env:AGENTQ_SESSION = 'asker'
  Check 'reply is journaled' (JournalHas '"event":"reply"') ''
  Check 'the thread shows both messages' ((AQ inbox -Id $id1) -match 'yes, but I will be done in 5 minutes') ''
  Check 'answered is out of the default inbox' ((InboxOf 'nobody-here') -notmatch $id1) ''
  Check '-All still shows it' ((InboxOf 'nobody-here' @('-All')) -match $id1) ''
  # the asker replying reopens the thread (it is a follow-up, not an answer)
  $out = AQ reply -Id $id1 -Message 'thanks - one more: does that touch the tracker csv?'
  Check 'the asker replying reopens the thread' ($out -match 'now open for session:nobody-here') $out
  Check 'the reopened thread is back in the inbox' ((InboxOf 'nobody-here') -match $id1) ''

  # ---- 7. delivery notice, throttled ---------------------------------------------------------------
  # noticeMsgMin 0 = show on every call; 30 = the window that must suppress the repeat.
  $env:AGENTQ_SESSION = 'nobody-here'
  '{"machineCap":2,"quickBurst":0,"agingMin":0,"idleYieldMin":0,"minFreeCommitGB":0,"noticeMsgMin":0}' | Set-Content $cfg
  $o1 = AQ note -Message 'a working verb as the addressee'
  Check 'a working verb prints the inbox notice' ($o1 -match 'INBOX \d+ open message\(s\) for you') $o1
  '{"machineCap":2,"quickBurst":0,"agingMin":0,"idleYieldMin":0,"minFreeCommitGB":0,"noticeMsgMin":30}' | Set-Content $cfg
  $o2 = AQ note -Message 'again, inside the throttle window'
  Check 'the notice is throttled' ($o2 -notmatch 'INBOX \d+ open message\(s\)') $o2
  $env:AGENTQ_SESSION = 'asker'
  $o3 = AQ note -Message 'the asker has no open messages'
  Check 'no notice when nothing is addressed to me' ($o3 -notmatch 'INBOX \d+ open message\(s\)') $o3
  # an explicit inbox is never throttled and never consumed by the notice
  Check 'inbox is never throttled' ((InboxOf 'nobody-here') -match $id1) ''

  # ---- 8. unreadable input fails loudly ------------------------------------------------------------
  $out = AQ ask -To 'session one two' -Message 'a message that cannot be addressed'
  Check 'a malformed -To exits 2' ($script:code -eq 2) "exit=$($script:code) $out"
  Check 'a malformed -To is explained' ($out -match 'must be repo:<name> \| session:<term-id>') $out
  $out = AQ ask -To repo:vitals -Message 'short'
  Check 'a too-short message exits 2' ($script:code -eq 2) "exit=$($script:code) $out"
  $out = AQ reply -Id deadbeef -Message 'answering nothing'
  Check 'replying to an unknown id exits 2' ($script:code -eq 2) "exit=$($script:code) $out"
  $out = AQ inbox -Id deadbeef
  Check 'reading an unknown thread exits 2' ($script:code -eq 2) "exit=$($script:code) $out"
  $out = AQ ask -To repo:vitals
  Check 'ask without a message exits 2' ($script:code -eq 2) "exit=$($script:code) $out"

  # ---- 9. machine-readable -------------------------------------------------------------------------
  $env:AGENTQ_SESSION = 'nobody-here'
  $js = AQ inbox -Json
  $env:AGENTQ_SESSION = 'asker'
  $ok = $false; try { $arr = $js | ConvertFrom-Json; $ok = @($arr).Count -ge 1 -and $arr[0].id } catch {}
  Check 'inbox -Json parses and carries ids' $ok $js
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail -gt 0) { Write-Host "`n$fail FAILED" -ForegroundColor Red; exit 1 }
Write-Host "`nall asks delivered, answered and throttled correctly"
