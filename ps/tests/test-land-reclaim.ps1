# A land lease whose owner (the agentq land process) is dead is stale after 3 min, not after
# leaseDeadIdleMin (120): 2026-10-18 a land killed by a reboot held codai's land slot 80+ min and every
# later land waited for it. A task lease with a dead owner keeps the long grace. Isolated in %TEMP%.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqlr-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_SESSION = 'test-R'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":120,"leaseMaxIdleMin":1440,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
Push-Location $repo
try {
  # A task lease and a land lease, both owned by a dead pid, both idle 5 min.
  $o = AQ lease -Purpose 'task work' -Json; $t = $o | Select-Object -Last 1 | ConvertFrom-Json
  Check 'task lease granted' ($code -eq 0 -and $t.slot -eq 'task-1') $o
  $o = AQ lease -Slot land -Purpose 'land x -> dev' -Json; $l = $o | Select-Object -Last 1 | ConvertFrom-Json
  Check 'land lease granted' ($code -eq 0 -and $l.slot -eq 'land') $o
  foreach ($s in 'task-1', 'land') {
    $f = Join-Path $env:AGENTQ_HOME "leases\repo\$s.json"
    $j = Get-Content $f -Raw | ConvertFrom-Json; $j.pid = 999999; $j.created = [DateTime]::UtcNow.AddMinutes(-10).ToString('o'); $j | ConvertTo-Json | Set-Content $f
    [IO.File]::SetLastWriteTimeUtc("$f.hb", [DateTime]::UtcNow.AddMinutes(-5))
    # Slot git index writes count as activity (DC-021): age them like the heartbeat.
    $sp = Join-Path $env:CODAI_WT_ROOT "repo\$s"
    $gd = "$(git -C $sp rev-parse --absolute-git-dir)".Trim()
    Get-ChildItem $gd -File -Recurse | ForEach-Object { [IO.File]::SetLastWriteTimeUtc($_.FullName, [DateTime]::UtcNow.AddMinutes(-5)) }
  }
  # Every agentq call renews the CALLER's own leases: observe/land as another session.
  $env:AGENTQ_SESSION = 'test-S'
  $st = AQ status -Json | ConvertFrom-Json
  $sl = @($st.leases) | Where-Object slot -eq 'land'; $stt = @($st.leases) | Where-Object slot -eq 'task-1'
  Check 'dead land lease idle 5 min -> STALE' ($sl.stale -eq $true) ($sl | ConvertTo-Json -Compress)
  Check 'dead task lease idle 5 min -> NOT stale (120 min grace)' ($stt.stale -eq $false) ($stt | ConvertTo-Json -Compress)
  # A fresh dead land lease (idle 1 min) is not stale yet.
  $f = Join-Path $env:AGENTQ_HOME 'leases\repo\land.json'
  [IO.File]::SetLastWriteTimeUtc("$f.hb", [DateTime]::UtcNow.AddMinutes(-1))
  $st = AQ status -Json | ConvertFrom-Json
  Check 'dead land lease idle 1 min -> not stale yet' ((@($st.leases) | Where-Object slot -eq 'land').stale -eq $false)
  # The next land takes the slot over (backup + expire) instead of waiting.
  [IO.File]::SetLastWriteTimeUtc("$f.hb", [DateTime]::UtcNow.AddMinutes(-5))
  git -C $repo checkout -q -b topic; Set-Content (Join-Path $repo 'b.txt') 'b'; git -C $repo add b.txt; git -C $repo commit -qm 'topic b'; git -C $repo push -q origin topic 2>$null; git -C $repo checkout -q dev
  $o = AQ land -Branch topic -Onto dev -Purpose 'land after dead land' -TimeoutMin 2
  Check 'land reclaims the dead land slot and lands' ($code -eq 0 -and $o -match 'landed topic') $o
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'lease-expire' -and $_.resource -match 'land' })
  Check 'reclaim journaled as lease-expire' ($j.Count -ge 1) ''
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
