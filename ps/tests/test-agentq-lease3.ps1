# ADR 0003 W1-3: lease activity beyond the slot (live tickets, running jobs, session/-LeaseId calls)
# and lease-loss notices to the owning session. Isolated in %TEMP%.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aql3-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
# dead-owner idle 1 min, max idle 5 min -> easy to make stale by ageing the .hb
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Age($leaseJson, [int]$min) {
  $hb = "$leaseJson.hb"; [IO.File]::SetLastWriteTimeUtc($hb, [DateTime]::UtcNow.AddMinutes(-$min))
  $l = Get-Content $leaseJson -Raw | ConvertFrom-Json; $l.created = [DateTime]::UtcNow.AddMinutes(-$min - 5).ToString('o'); $l.pid = 999999; $l.procStart = $null
  [IO.File]::WriteAllText($leaseJson, ($l | ConvertTo-Json -Compress))
  # make the slot's git index look old too (Get-SlotGitActivity)
  $gd = ((Get-Content (Join-Path $l.path '.git') -Raw) -replace '^gitdir:\s*', '').Trim()
  foreach ($n in 'index', 'HEAD', 'logs\HEAD') { $p = Join-Path $gd $n; if (Test-Path $p) { [IO.File]::SetLastWriteTimeUtc($p, [DateTime]::UtcNow.AddMinutes(-$min)) } }
}

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  # 1 an idle lease with a dead owner is stale ...
  $env:AGENTQ_SESSION = 'owner-A'
  $o = AQ lease -Purpose 'work A' -Json; $la = $o | Select-Object -Last 1 | ConvertFrom-Json
  $lf = Join-Path $env:AGENTQ_HOME "leases\repo\$($la.slot).json"
  Age $lf 30
  $env:AGENTQ_SESSION = 'someone-else'
  $st = AQ status -Json | ConvertFrom-Json
  $mine = @($st.leases | Where-Object { $_.leaseId -eq $la.leaseId })
  Check '1 idle dead-owner lease is stale' ($mine.Count -eq 1 -and $mine[0].stale) ($st | ConvertTo-Json -Depth 4)

  # 2 ... but a RUNNING job whose cwd is inside the slot keeps it alive
  $jd = Join-Path $env:AGENTQ_HOME 'jobs'; New-Item -ItemType Directory -Force $jd | Out-Null
  $sleeper = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -WindowStyle Hidden -PassThru
  $jid = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss') + '-t001'
  $log = Join-Path $tmp 'job.log'; 'x' | Set-Content $log
  @{ id = $jid; state = 'running'; pid = $sleeper.Id; cwd = $la.path; command = 'pnpm test'; log = $log } | ConvertTo-Json | Set-Content (Join-Path $jd "$jid.json")
  $st = AQ status -Json | ConvertFrom-Json
  $mine = @($st.leases | Where-Object { $_.leaseId -eq $la.leaseId })
  Check '2 running job in slot -> not stale' ($mine.Count -eq 1 -and -not $mine[0].stale) ($mine | ConvertTo-Json)
  Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $jd "$jid.json")

  # 3 a running job that only MENTIONS the slot path in its command also counts
  $sleeper = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120' -WindowStyle Hidden -PassThru
  @{ id = $jid; state = 'running'; pid = $sleeper.Id; cwd = $tmp; command = "pwsh -File gate.ps1 -Root $($la.path)"; log = $log } | ConvertTo-Json | Set-Content (Join-Path $jd "$jid.json")
  $st = AQ status -Json | ConvertFrom-Json
  $mine = @($st.leases | Where-Object { $_.leaseId -eq $la.leaseId })
  Check '3 job naming the slot -> not stale' ($mine.Count -eq 1 -and -not $mine[0].stale)
  Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue
  Remove-Item (Join-Path $jd "$jid.json")

  # 4 any agentq call from the owner session (outside the slot) renews it
  Age $lf 30
  $env:AGENTQ_SESSION = 'owner-A'
  $null = AQ note -Message 'still working, from the main clone'
  $env:AGENTQ_SESSION = 'someone-else'
  $st = AQ status -Json | ConvertFrom-Json
  $mine = @($st.leases | Where-Object { $_.leaseId -eq $la.leaseId })
  Check '4 owner-session call renews' ($mine.Count -eq 1 -and -not $mine[0].stale -and $mine[0].idleMin -lt 2) ($mine | ConvertTo-Json)

  # 5 renew -LeaseId from anywhere
  Age $lf 30
  $o = AQ renew -LeaseId $la.leaseId
  Check '5 renew -LeaseId' ($o -match 'renewed') $o

  # 6 expiry writes a notice for the owner; the owner's next call prints it once; status lists the loss
  Age $lf 30
  $o = AQ sweep
  Check '6 swept' ($o -match 'expired repo/') $o
  $env:AGENTQ_SESSION = 'owner-A'
  $o = AQ note -Message 'hello'
  Check '6 owner sees NOTICE' ($o -match "NOTICE your lease $($la.leaseId)") $o
  $o = AQ note -Message 'again'
  Check '6 notice shown once' ($o -notmatch 'NOTICE') $o
  $o = AQ status
  Check '6 status lists the loss' ($o -match 'LEASES LOST') $o

  # 7 slot prep: repo hook scripts/slot-prep.ps1 runs on lease; result in .agentq-prep.json
  [IO.Directory]::CreateDirectory("$repo\scripts") | Out-Null
  [IO.File]::WriteAllText("$repo\scripts\slot-prep.ps1", 'param($Worktree, $Main) [IO.File]::WriteAllText((Join-Path $Worktree "prepped.txt"), $Main); exit 0')
  git -C $repo add -A; git -C $repo commit -qm prep; git -C $repo push -q origin main 2>$null
  $env:AGENTQ_SESSION = 'prep-B'
  $o = AQ lease -Purpose 'prep test' -Json; $lb = ($o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1) | ConvertFrom-Json
  Check '7 slot-prep hook ran' ((Test-Path (Join-Path $lb.path 'prepped.txt'))) $o
  $ps = Get-Content (Join-Path $env:AGENTQ_HOME "prep\repo--$($lb.slot).json") -Raw | ConvertFrom-Json
  Check '7 slot stays clean (no prep file in the tree)' (-not (git -C $lb.path status --porcelain | Where-Object { $_ -notmatch 'prepped.txt' }))
  Check '7 prep state ready' ($ps.ready -and ($ps.steps -join ' ') -match 'slot-prep.ps1 rc=0') ($ps | ConvertTo-Json)
  # 8 failing hook -> lease still granted, slot marked not ready, journal slot-prep-failed
  [IO.File]::WriteAllText("$repo\scripts\slot-prep.ps1", 'param($Worktree, $Main) "boom"; exit 7')
  git -C $repo add -A; git -C $repo commit -qm prep2; git -C $repo push -q origin main 2>$null
  $o = AQ unlease -Repo $lb.path -LeaseId $lb.leaseId
  $o = AQ lease -Purpose 'prep fail' -Json; $lc = ($o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1) | ConvertFrom-Json
  Check '8 lease granted despite prep failure' ($code -eq 0 -and $lc.leaseId) $o
  Check '8 warning printed' ($o -match 'not ready') $o
  Check '8 journal slot-prep-failed' ((Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -Raw) -match 'slot-prep-failed')
  # 9 stale index.lock in a reused slot is removed and the lease succeeds
  $null = AQ unlease -Repo $lc.path -LeaseId $lc.leaseId
  $gd = ((Get-Content (Join-Path $lc.path '.git') -Raw) -replace '^gitdir:\s*', '').Trim()
  $lock = Join-Path $gd 'index.lock'; [IO.File]::WriteAllText($lock, ''); [IO.File]::SetLastWriteTimeUtc($lock, [DateTime]::UtcNow.AddMinutes(-10))
  $o = AQ lease -Slot $lc.slot -Purpose 'after lock' -Json
  Check '9 stale index.lock cleared, lease ok' ($code -eq 0 -and -not (Test-Path $lock)) $o
} finally { Pop-Location; Get-Process pwsh -ErrorAction SilentlyContinue | Out-Null; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
