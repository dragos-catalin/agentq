# agentq prune (ADR 0009 stage 0, OQ-006): removes dead agent/job/notice/release records, idle ticket-less
# queue folders, orphan prep/batch/day/chat files - and nothing else. Synthetic state in %TEMP% with aged
# file times; -WhatIf must change nothing; a second run must remove 0 and journal nothing.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$PruneFile = Join-Path (Split-Path -Parent $Aq) 'agentq-prune.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqprune-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_SESSION = 'prunetest'
$cfg = Join-Path $tmp 'cfg.json'
'{"machineCap":2,"quickBurst":0,"agingMin":0,"idleYieldMin":0,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }

$H = $env:AGENTQ_HOME
$NowU = [DateTime]::UtcNow
function Iso([datetime]$d) { $d.ToUniversalTime().ToString('o') }
function Put([string]$rel, $obj, [double]$ageHours) {
  $p = Join-Path $H $rel
  $dir = Split-Path -Parent $p; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $text = if ($obj -is [string]) { $obj } else { $obj | ConvertTo-Json -Compress -Depth 5 }
  [IO.File]::WriteAllText($p, $text, [Text.UTF8Encoding]::new($false))
  [IO.File]::SetLastWriteTimeUtc($p, $NowU.AddHours(-$ageHours))
  $p
}
function AgeDir([string]$rel, [double]$ageHours) { [IO.Directory]::SetLastWriteTimeUtc((Join-Path $H $rel), $NowU.AddHours(-$ageHours)) }
function Has([string]$rel) { Test-Path -LiteralPath (Join-Path $H $rel) }
function Snapshot {
  @(Get-ChildItem -LiteralPath $H -Recurse -Force | ForEach-Object { "$($_.FullName.Substring($H.Length))|$(if ($_.PSIsContainer) { 'd' } else { "$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" })" } | Sort-Object) -join "`n"
}
function SnapDiff([string]$a, [string]$b) { (@(Compare-Object @($a -split "`n") @($b -split "`n") | Select-Object -First 8 | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ' ; ') }
# report line: "   <class> <removed> <kept> <skipped>"
function Row([string]$report, [string]$class) {
  foreach ($ln in @($report -split "`n")) {
    if ($ln -match "^\s+$class\s+(\d+)\s+(\d+)\s+(\d+)") { return @{ removed = [int]$Matches[1]; kept = [int]$Matches[2]; skipped = [int]$Matches[3] } }
  }
  $null
}

$me = Get-Process -Id $PID
$myStart = Iso $me.StartTime
$sleeper = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 180' -WindowStyle Hidden -PassThru
$sleeperStart = (Get-Process -Id $sleeper.Id).StartTime.ToUniversalTime()
$old = 24 * 10; $dead = 999999
$ticketJson = @{ id = 'abcd1234'; seq = 2; resource = 'build:repo'; pid = $dead; procStart = $null; session = 's'; purpose = 'p'; created = (Iso $NowU) }
try {
  # ---- synthetic state --------------------------------------------------------------------
  # agents
  $null = Put 'agents\old-dead.json' @{ v = 1; session = 'a'; shellPid = $dead; shellStart = (Iso $NowU.AddDays(-20)); lastSeen = (Iso $NowU.AddDays(-10)) } $old
  $null = Put 'agents\old-alive.json' @{ v = 1; session = 'b'; shellPid = $PID; shellStart = $myStart; lastSeen = (Iso $NowU.AddDays(-10)) } $old
  $null = Put 'agents\old-wrongstart.json' @{ v = 1; session = 'c'; shellPid = $PID; shellStart = (Iso $me.StartTime.AddHours(-1)); lastSeen = (Iso $NowU.AddDays(-10)) } $old
  $null = Put 'agents\recent.json' @{ v = 1; session = 'd'; shellPid = $dead; shellStart = (Iso $NowU); lastSeen = (Iso $NowU) } 0
  $null = Put 'agents\old-bad.json' 'not json {' $old
  $null = Put 'agents\x.json.123.tmp' '{' 5
  # jobs
  $null = Put 'jobs\old-done.json' @{ id = 'j1'; state = 'done'; pid = $dead; pidStart = $null; startedAt = (Iso $NowU.AddDays(-11)); endedAt = (Iso $NowU.AddDays(-10)) } $old
  $null = Put 'jobs\old-running-live.json' @{ id = 'j2'; state = 'running'; pid = $sleeper.Id; pidStart = $sleeperStart.Ticks; startedAt = (Iso $NowU.AddDays(-10)); endedAt = $null } $old
  $null = Put 'jobs\old-running-dead.json' @{ id = 'j3'; state = 'running'; pid = $dead; pidStart = $null; startedAt = (Iso $NowU.AddDays(-10)); endedAt = $null } $old
  $null = Put 'jobs\recent-done.json' @{ id = 'j4'; state = 'done'; pid = $dead; pidStart = $null; startedAt = (Iso $NowU); endedAt = (Iso $NowU) } 0
  $null = Put 'jobs\old-file-recent-end.json' @{ id = 'j5'; state = 'done'; pid = $dead; pidStart = $null; startedAt = (Iso $NowU.AddDays(-10)); endedAt = (Iso $NowU.AddHours(-1)) } $old
  # finished long ago, its pid number now belongs to another live process (this test), no start recorded
  $null = Put 'jobs\old-done-recycled-pid.json' @{ id = 'j7'; state = 'done'; pid = $PID; pidStart = $null; startedAt = (Iso $NowU.AddDays(-11)); endedAt = (Iso $NowU.AddDays(-10)) } $old
  $null = Put 'jobs\leftover.json.tmp' '{' 5
  $null = Put 'jobs\fresh.json.tmp' '{' 0
  # notices
  $null = Put 'notices\old.jsonl' '{"event":"x"}' $old
  $null = Put 'notices\new.jsonl' '{"event":"x"}' 1
  # releases
  $null = Put 'releases\repo__a.json' @{ runId = 'r1'; repo = 'repo'; target = 'a'; state = 'done'; pid = $dead; procStart = $null; phaseAt = (Iso $NowU.AddDays(-10)) } $old
  $null = Put 'releases\repo__b.json' @{ runId = 'r2'; repo = 'repo'; target = 'b'; state = 'running'; pid = $sleeper.Id; procStart = (Iso $sleeperStart); phaseAt = (Iso $NowU.AddDays(-10)) } $old
  $null = Put 'releases\repo__c.json' @{ runId = 'r3'; repo = 'repo'; target = 'c'; state = 'running'; pid = $dead; procStart = $null; phaseAt = (Iso $NowU.AddDays(-10)) } $old
  $null = Put 'releases\repo__d.json' @{ runId = 'r4'; repo = 'repo'; target = 'd'; state = 'done'; pid = $dead; procStart = $null; phaseAt = (Iso $NowU.AddHours(-2)) } $old
  # died long ago, record rewritten just now (sweep marks a dead run failed without moving phaseAt)
  $null = Put 'releases\repo__f.json' @{ runId = 'r6'; repo = 'repo'; target = 'f'; state = 'failed'; pid = $dead; procStart = $null; phaseAt = (Iso $NowU.AddDays(-10)) } 0
  # queues
  $null = Put 'queues\x_repo_y\capacity' '1' 72; $null = Put 'queues\x_repo_y\seq' '7' 72; AgeDir 'queues\x_repo_y' 72
  $null = Put 'queues\build_repo\capacity' '1' 72; $null = Put 'queues\build_repo\seq' '2' 72
  $null = Put 'queues\build_repo\00000002-abcd1234.json' $ticketJson 72
  $null = Put 'queues\build_repo\00000002-abcd1234.json.hb' '' 72          # heartbeat of a ticket that exists: stays
  $null = Put 'queues\build_repo\00000001-deadbeef.json.hb' '' 72          # orphan: its ticket is gone
  $null = Put 'queues\build_repo\00000001-deadbeef.json.wedged' '' 72
  $null = Put 'queues\build_repo\00000003-ffffffff.json.hb' '' 0           # orphan but fresh: stays (ticket may be mid-publish)
  $null = Put 'queues\build_repo\00000003-ffffffff.json.tmp' '{' 72
  AgeDir 'queues\build_repo' 72
  # capacity 1 on purpose: only the name rule protects build_machine here, not the sticky-capacity rule
  $null = Put 'queues\build_machine\capacity' '1' 72; $null = Put 'queues\build_machine\adaptive.json' @{ at = (Iso $NowU); cap = 2 } 72; AgeDir 'queues\build_machine' 72
  # everything old, but it holds a ticket: only the "has a ticket" rule protects it
  $null = Put 'queues\old_ticket\capacity' '1' 72; $null = Put 'queues\old_ticket\seq' '5' 72
  $null = Put 'queues\old_ticket\00000005-0123abcd.json' $ticketJson 72; $null = Put 'queues\old_ticket\00000005-0123abcd.json.hb' '' 72
  AgeDir 'queues\old_ticket' 72
  $null = Put 'queues\recent_empty\capacity' '1' 72; $null = Put 'queues\recent_empty\seq' '1' 0; AgeDir 'queues\recent_empty' 0
  $null = Put 'queues\young_dir\capacity' '1' 72; AgeDir 'queues\young_dir' 1   # files old, folder touched 1 h ago (ticket just removed)
  $null = Put 'queues\fresh_file\capacity' '1' 72; $null = Put 'queues\fresh_file\seq' '3' 0; AgeDir 'queues\fresh_file' 72   # folder old, one file fresh
  # prep (slot dirs under CODAI_WT_ROOT)
  New-Item -ItemType Directory -Force (Join-Path $env:CODAI_WT_ROOT 'repo\task-1') | Out-Null
  $null = Put 'prep\repo--task-1.json' @{ ready = $true } $old
  $null = Put 'prep\repo--task-2.json' @{ ready = $true } $old
  $null = Put 'prep\repo--task-3.json' @{ ready = $true } 1
  # batches
  $null = Put 'batches\repo\old.json' @{ exit = 0 } 48
  $null = Put 'batches\repo\new.json' @{ exit = 0 } 1
  $null = Put 'batches\other\old.json' @{ exit = 1 } 48; AgeDir 'batches\other' 48
  $null = Put 'batches\busy\old.json' @{ exit = 1 } 48; AgeDir 'batches\busy' 0   # a land wrote here just now
  # day files
  $today = $NowU.ToString('yyyyMMdd')
  $null = Put 'hooks\cost-20250101.jsonl' '{}' 0
  $null = Put "hooks\cost-$today.jsonl" '{}' 0
  $null = Put 'load\probe-20250101.jsonl' '{}' 0
  $null = Put "load\probe-$today.jsonl" '{}' 0
  $null = Put 'load\other-20250101.jsonl' '{}' $old   # not a probe file: never touched
  # chats
  $null = Put 'chats\old.json' @{ id = 1 } $old
  $null = Put 'chats\new.json' @{ id = 2 } 1
  # never touched
  $null = Put 'leases\repo\task-1.json' @{ leaseId = 'l1'; repo = 'repo'; slot = 'task-1'; pid = $dead; created = (Iso $NowU.AddDays(-30)) } (24 * 30)
  $null = Put 'leases\repo\task-1.json.hb' '' (24 * 30)
  $null = Put 'marks\build_repo.json' @{ resource = 'build:repo'; state = 'frozen'; reason = 'r'; session = 's'; at = (Iso $NowU.AddDays(-30)) } (24 * 30)
  $null = Put 'flakes\repo.json' @{ } (24 * 30)
  $null = Put 'journal-archive\journal-20250101-000000.jsonl' '{}' (24 * 30)
  $null = Put 'agentq.db' 'x' (24 * 30)
  $null = Put 'quarantine\x.json' '{}' (24 * 30)
  $jl = '{"ts":"2025-01-01T00:00:00.0000000Z","event":"note","resource":"note","message":"seed"}'
  $J = Put 'journal.jsonl' ($jl + "`n") (24 * 30)
  $untouched = @('leases\repo\task-1.json', 'leases\repo\task-1.json.hb', 'marks\build_repo.json', 'flakes\repo.json', 'journal-archive\journal-20250101-000000.jsonl', 'agentq.db', 'quarantine\x.json', 'load\other-20250101.jsonl')

  # ---- 1 -WhatIf changes nothing and reports the right counts ----------------------------
  $before = Snapshot
  $o = AQ prune -WhatIf
  Check '1 whatif exit 0' ($code -eq 0) $o
  $after = Snapshot
  Check '1 whatif changed nothing' ($after -eq $before) (SnapDiff $before $after)
  Check '1 whatif says so' ($o -match 'nothing deleted') ''
  Check '1 whatif lists items' ($o -match 'would remove agents .*old-dead\.json' -and $o -match 'would remove queueFolders .*x_repo_y') ''
  $r = Row $o 'agents'; Check '1 whatif agents 3/2' ($r -and $r.removed -eq 3 -and $r.kept -eq 2) ($o -split "`n" | Where-Object { $_ -match 'agents' } | Out-String)
  $r = Row $o 'jobs'; Check '1 whatif jobs 3/3' ($r -and $r.removed -eq 3 -and $r.kept -eq 3) ''
  $r = Row $o 'releases'; Check '1 whatif releases 3/2' ($r -and $r.removed -eq 3 -and $r.kept -eq 2) ''
  $r = Row $o 'queueFolders'; Check '1 whatif queueFolders 1/6' ($r -and $r.removed -eq 1 -and $r.kept -eq 6) ''
  $r = Row $o 'queueFiles'; Check '1 whatif queueFiles 3/3' ($r -and $r.removed -eq 3 -and $r.kept -eq 3) ''
  $r = Row $o 'tmp'; Check '1 whatif tmp 2/1' ($r -and $r.removed -eq 2 -and $r.kept -eq 1) ''
  $r = Row $o 'total'; Check '1 whatif total 23' ($r -and $r.removed -eq 23) ($o -split "`n" | Select-Object -Last 14 | Out-String)
  Check '1 whatif no journal event' (-not ((Get-Content $J -Raw) -match '"event":"prune"')) ''
  Check '1 no hashtable leaked into output' ($o -notmatch '(?m)^\s*Name\s+Value' -and $o -notmatch 'System\.Collections') ''

  # ---- 2 real run -----------------------------------------------------------------------------
  $o = AQ prune
  Check '2 prune exit 0' ($code -eq 0) $o
  Check '2 agents: old dead removed, unparseable removed, wrong start removed' (-not (Has 'agents\old-dead.json') -and -not (Has 'agents\old-bad.json') -and -not (Has 'agents\old-wrongstart.json')) ''
  Check '2 agents: alive shell kept, recent kept' ((Has 'agents\old-alive.json') -and (Has 'agents\recent.json')) ''
  Check '2 agents: old tmp removed' (-not (Has 'agents\x.json.123.tmp')) ''
  Check '2 jobs: old finished removed, running+dead pid removed' (-not (Has 'jobs\old-done.json') -and -not (Has 'jobs\old-running-dead.json')) ''
  Check '2 jobs: finished job whose pid number was recycled removed' (-not (Has 'jobs\old-done-recycled-pid.json')) ''
  Check '2 jobs: live pid kept, recent kept, recent endedAt kept' ((Has 'jobs\old-running-live.json') -and (Has 'jobs\recent-done.json') -and (Has 'jobs\old-file-recent-end.json')) ''
  Check '2 jobs: old tmp removed, fresh tmp kept' (-not (Has 'jobs\leftover.json.tmp') -and (Has 'jobs\fresh.json.tmp')) ''
  Check '2 notices: old removed, recent kept' (-not (Has 'notices\old.jsonl') -and (Has 'notices\new.jsonl')) ''
  Check '2 releases: done+old removed, running+dead removed' (-not (Has 'releases\repo__a.json') -and -not (Has 'releases\repo__c.json')) ''
  Check '2 releases: old phaseAt wins over a fresh file time' (-not (Has 'releases\repo__f.json')) ''
  Check '2 releases: running+alive kept, recent phaseAt kept' ((Has 'releases\repo__b.json') -and (Has 'releases\repo__d.json')) ''
  Check '2 queues: old empty folder removed' (-not (Has 'queues\x_repo_y')) ''
  Check '2 queues: ticket folder kept, ticket + its hb intact' ((Has 'queues\build_repo\00000002-abcd1234.json') -and (Has 'queues\build_repo\00000002-abcd1234.json.hb') -and (Has 'queues\build_repo\seq')) ''
  Check '2 queues: orphan old hb/wedged/tmp removed' (-not (Has 'queues\build_repo\00000001-deadbeef.json.hb') -and -not (Has 'queues\build_repo\00000001-deadbeef.json.wedged') -and -not (Has 'queues\build_repo\00000003-ffffffff.json.tmp')) ''
  Check '2 queues: fresh orphan hb kept' (Has 'queues\build_repo\00000003-ffffffff.json.hb') ''
  Check '2 queues: build_machine kept with adaptive.json' ((Has 'queues\build_machine\adaptive.json') -and (Has 'queues\build_machine\capacity')) ''
  Check '2 queues: old folder that holds a ticket kept whole' ((Has 'queues\old_ticket\00000005-0123abcd.json') -and (Has 'queues\old_ticket\00000005-0123abcd.json.hb') -and (Has 'queues\old_ticket\seq')) ''
  Check '2 queues: recent empty folder kept' (Has 'queues\recent_empty\seq') ''
  Check '2 queues: old files in a recently touched folder kept' (Has 'queues\young_dir\capacity') ''
  Check '2 queues: old folder with one fresh file kept' (Has 'queues\fresh_file\seq') ''
  Check '2 prep: missing slot removed, existing slot kept, recent kept' (-not (Has 'prep\repo--task-2.json') -and (Has 'prep\repo--task-1.json') -and (Has 'prep\repo--task-3.json')) ''
  Check '2 batches: old removed, new kept, idle empty subfolder removed' (-not (Has 'batches\repo\old.json') -and (Has 'batches\repo\new.json') -and -not (Has 'batches\other')) ''
  Check '2 batches: a subfolder written to recently stays (its old file goes)' ((Has 'batches\busy') -and -not (Has 'batches\busy\old.json')) ''
  Check '2 day files: old removed by name date, today kept' (-not (Has 'hooks\cost-20250101.jsonl') -and (Has "hooks\cost-$today.jsonl") -and -not (Has 'load\probe-20250101.jsonl') -and (Has "load\probe-$today.jsonl")) ''
  Check '2 chats: old removed, new kept' (-not (Has 'chats\old.json') -and (Has 'chats\new.json')) ''
  $still = @($untouched | Where-Object { -not (Has $_) })
  Check '2 leases, marks, journal archive, db, flakes, quarantine untouched' ($still.Count -eq 0) ($still -join ', ')
  $jlines = @(Get-Content $J | Where-Object { $_ })
  Check '2 journal: seed line intact' ($jlines[0] -eq $jl) ''
  $pe = @($jlines | Where-Object { $_ -match '"event":"prune"' } | ForEach-Object { $_ | ConvertFrom-Json })
  Check '2 journal: exactly one prune event with total 23' ($pe.Count -eq 1 -and [int]$pe[0].removed -eq 23 -and "$($pe[0].reason)" -match 'agents=3' -and "$($pe[0].reason)" -match 'queueFolders=1') ($pe | ConvertTo-Json -Compress)
  $r = Row $o 'total'; Check '2 report total 23' ($r -and $r.removed -eq 23 -and $r.skipped -eq 0) ($o -split "`n" | Select-Object -Last 14 | Out-String)

  # ---- 3 stable: a second run removes 0 and journals nothing ---------------------------------
  $snap2 = Snapshot
  $o = AQ prune
  $r = Row $o 'total'
  Check '3 second run removes 0' ($code -eq 0 -and $r -and $r.removed -eq 0) $o
  $snap3 = Snapshot
  Check '3 second run changed nothing' ($snap3 -eq $snap2) (SnapDiff $snap2 $snap3)
  Check '3 no second journal event' (@(Get-Content $J | Where-Object { $_ -match '"event":"prune"' }).Count -eq 1) ''

  # ---- 4 -Json parses --------------------------------------------------------------------------
  $o = AQ prune -Json
  $js = try { $o | ConvertFrom-Json } catch { $null }
  Check '4 -Json parses with the documented shape' ($null -ne $js -and $js.PSObject.Properties.Name -contains 'removed' -and $js.removed.PSObject.Properties.Name -contains 'queueFolders' -and $js.PSObject.Properties.Name -contains 'tookMs' -and $js.whatIf -eq $false) $o

  # ---- 5 -Days overrides the four record classes --------------------------------------------
  $null = Put 'agents\hour-dead.json' @{ v = 1; session = 'e'; shellPid = $dead; shellStart = (Iso $NowU) } 1
  $null = Put 'jobs\hour-done.json' @{ id = 'j6'; state = 'done'; pid = $dead; pidStart = $null; startedAt = (Iso $NowU.AddHours(-2)); endedAt = (Iso $NowU.AddHours(-1)) } 1
  $null = Put 'notices\hour.jsonl' '{}' 1
  $null = Put 'releases\repo__e.json' @{ runId = 'r5'; repo = 'repo'; target = 'e'; state = 'done'; pid = $dead; procStart = $null; phaseAt = (Iso $NowU.AddHours(-1)) } 1
  $null = Put 'chats\hour.json' @{ id = 3 } 1
  $o = AQ prune -Days '0.01'
  Check '5 -Days 0.01 removes hour-old agent/job/notice/release' ($code -eq 0 -and -not (Has 'agents\hour-dead.json') -and -not (Has 'jobs\hour-done.json') -and -not (Has 'notices\hour.jsonl') -and -not (Has 'releases\repo__e.json')) $o
  Check '5 -Days leaves other classes on their defaults' ((Has 'chats\hour.json') -and (Has 'queues\recent_empty\seq')) ''
  Check '5 -Days never removes a live job' (Has 'jobs\old-running-live.json') ''

  # ---- 6 a new ticket on the pruned resource works ------------------------------------------
  $repo = Join-Path $tmp 'repo'; New-Item -ItemType Directory -Force $repo | Out-Null
  & git -C $repo init -q -b main 2>$null; & git -C $repo config user.email t@t; & git -C $repo config user.name t
  [IO.File]::WriteAllText("$repo\a.txt", "a`n"); & git -C $repo add a.txt 2>$null; & git -C $repo commit -qm init 2>$null
  $o = AQ run -Resource x:repo:y -Purpose t -Repo $repo -TimeoutMin 1 '--' pwsh -NoProfile -Command exit
  Check '6 agentq run on the pruned resource exits 0' ($code -eq 0) $o
  Check '6 queue folder recreated with seq' (Has 'queues\x_repo_y\seq') ''

  # ---- 7 in-process -Quiet form (what sweep calls): returns counts, prints nothing, journals --
  $harness = Join-Path $tmp 'quiet.ps1'
  $null = Put 'notices\old2.jsonl' '{}' $old
  $n0 = @(Get-Content $J | Where-Object { $_ -match '"event":"prune"' }).Count
  @"
. '$Aq' log -Last 1 *> `$null
. '$PruneFile'
`$r = Invoke-Prune -Quiet
"QUIET type=`$(`$r.GetType().Name) notices=`$(`$r.removed.notices) total=`$(`$r.total) hasKey=`$(`$r.ContainsKey('removed') -and `$r.removed.ContainsKey('queueFolders') -and `$r.kept.ContainsKey('jobs')) whatIf=`$(`$r.whatIf)"
"@ | Set-Content $harness
  $lines = @(& pwsh -NoProfile -File $harness 2>&1 | ForEach-Object { "$_" })
  Check '7 quiet form prints only the caller line' ($lines.Count -eq 1 -and $lines[0] -eq 'QUIET type=Hashtable notices=1 total=1 hasKey=True whatIf=False') ($lines -join ' | ')
  Check '7 quiet form deleted and journaled' (-not (Has 'notices\old2.jsonl') -and @(Get-Content $J | Where-Object { $_ -match '"event":"prune"' }).Count -eq $n0 + 1) ''

  # ---- 9 config key `prune` overrides one number ------------------------------------------
  $cfg2 = Join-Path $tmp 'cfg2.json'
  '{"machineCap":2,"quickBurst":0,"agingMin":0,"idleYieldMin":0,"minFreeCommitGB":0,"prune":{"chatsDays":0.01,"queueIdleHours":0.5}}' | Set-Content $cfg2
  $null = Put 'queues\cfg_idle\capacity' '1' 2; AgeDir 'queues\cfg_idle' 2
  $null = Put 'queues\cap_three\capacity' '3' 72; AgeDir 'queues\cap_three' 72
  $env:AGENTQ_CONFIG = $cfg2
  try { $o = AQ prune } finally { $env:AGENTQ_CONFIG = $cfg }
  Check '9 config prune.chatsDays removes the hour-old chats' ($code -eq 0 -and -not (Has 'chats\hour.json') -and -not (Has 'chats\new.json')) $o
  Check '9 config prune.queueIdleHours removes a 2 h idle folder' (-not (Has 'queues\cfg_idle')) ''
  Check '9 a folder with a sticky capacity other than 1 stays' (Has 'queues\cap_three\capacity') ''

  # ---- 8 a folder whose ticket mutex is held is skipped, not deleted -------------------------
  $null = Put 'queues\held_one\capacity' '1' 72; AgeDir 'queues\held_one' 72
  $mname = "Global\agentq-held_one-" + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_')
  $mx = [Threading.Mutex]::new($false, $mname); [void]$mx.WaitOne(0)
  try { $o = AQ prune } finally { $mx.ReleaseMutex(); $mx.Dispose() }
  $r = Row $o 'queueFolders'
  Check '8 held mutex -> folder skipped' ((Has 'queues\held_one\capacity') -and $r -and $r.skipped -eq 1) $o
  $o = AQ prune
  Check '8 released mutex -> folder removed' (-not (Has 'queues\held_one')) $o

  # ---- 10 a ticket published while prune waits for the folder's mutex is never lost ---------
  # (Covers a creator that HOLDS the mutex. A New-Ticket that is past its folder check but not yet
  # holding the mutex is not covered by prune - see the note at the delete in agentq-prune.ps1.)
  # The test holds the ticket mutex of race_one. prune deletes a_first (sorts first), then blocks on
  # race_one; the ticket is written (aged, so only the re-check for tickets can save the folder) and the
  # mutex released inside prune's 2 s wait. Up to 3 attempts in case a loaded machine misses the window
  # (then prune reports the folder as skipped, which is safe but does not exercise the re-check).
  $raceName = "Global\agentq-race_one-" + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_')
  $raceTicket = 'queues\race_one\00000002-0badf00d.json'
  $exercised = $false; $lost = $false; $tries = 0; $rep = ''
  while (-not $exercised -and -not $lost -and $tries -lt 3) {
    $tries++
    if (Has $raceTicket) { Remove-Item -LiteralPath (Join-Path $H $raceTicket) -Force }
    $null = Put 'queues\a_first\capacity' '1' 72; AgeDir 'queues\a_first' 72
    $null = Put 'queues\race_one\capacity' '1' 72; $null = Put 'queues\race_one\seq' '1' 72; AgeDir 'queues\race_one' 72
    $mx = [Threading.Mutex]::new($false, $raceName); [void]$mx.WaitOne(0); $freed = $false
    try {
      $job = Start-ThreadJob -ArgumentList $Aq -ScriptBlock { param($tool) @(& pwsh -NoProfile -File $tool prune 2>&1 | ForEach-Object { "$_" }) -join "`n" }
      $until = [DateTime]::UtcNow.AddSeconds(120)
      while ((Has 'queues\a_first') -and $job.State -in 'NotStarted', 'Running' -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 20 }
      Start-Sleep -Milliseconds 300
      $null = Put $raceTicket $ticketJson 72; AgeDir 'queues\race_one' 72
      $mx.ReleaseMutex(); $freed = $true
      $rep = "$(Receive-Job $job -Wait -AutoRemoveJob)"
    } finally { if (-not $freed) { try { $mx.ReleaseMutex() } catch {} }; $mx.Dispose() }
    if (-not (Has $raceTicket)) { $lost = $true }
    $r = Row $rep 'queueFolders'
    if ($r -and $r.skipped -eq 0) { $exercised = $true }
  }
  Check '10 ticket created during the mutex wait survives' (-not $lost -and (Has $raceTicket) -and (Has 'queues\race_one\seq')) $rep
  Check '10 the re-check under the mutex ran (not a timeout skip)' ($exercised) "tries=$tries"
} finally {
  Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  Remove-Item Env:AGENTQ_HOME, Env:CODAI_WT_ROOT, Env:AGENTQ_NO_SIGNAL, Env:AGENTQ_NO_REGISTRY, Env:AGENTQ_SESSION, Env:AGENTQ_CONFIG -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
