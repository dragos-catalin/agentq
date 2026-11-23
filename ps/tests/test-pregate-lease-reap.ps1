# 2026-11-23 leak (docs/ops/2026-11-23-pregate-scratch-slot-leak.md): a scratch slot rented by a land
# pre-gate inherited its SESSION heartbeat, so when the land process was killed mid-gate the lease never
# went stale and the pool saturated. Get-PregateScratchSlot now stamps pregatePid/pregateProcStart/
# pregateUntil; the lease is stale as soon as that process is gone or the deadline passed - even with a
# fresh heartbeat and a dirty tree - and a stamp-less lease keeps today's behaviour.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqpg-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:CODAI_GH_ROOT = Join-Path $tmp 'gh'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_PRUNE = '1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseIdleMin":45,"leaseOwnerIdleMin":90,"leaseScratchIdleMin":15,"leaseChatGraceMin":20,"leaseMaxIdleMin":600,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Lease([string]$id) { $env:AGENTQ_SESSION = 'observer'; $st = AQ status -All -Json | ConvertFrom-Json; @($st.leases | Where-Object { $_.leaseId -eq $id }) | Select-Object -First 1 }
function Stamp($lf, [int]$procId, $procStart, [datetime]$until) {
  $l = Get-Content $lf -Raw | ConvertFrom-Json -AsHashtable
  $l['pregatePid'] = $procId; $l['pregateProcStart'] = $procStart; $l['pregateUntil'] = $until.ToUniversalTime().ToString('o')
  [IO.File]::WriteAllText($lf, ($l | ConvertTo-Json -Compress))
  [IO.File]::SetLastWriteTimeUtc("$lf.hb", [DateTime]::UtcNow)   # the session heartbeat stays fresh
}

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  $env:AGENTQ_SESSION = 'lander'
  $o = AQ lease -Role scratch -Purpose 'land pre-gate for t' -Json
  $la = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Check 'setup: scratch lease taken' ($la -and $la.leaseId) $o
  $lf = Join-Path $env:AGENTQ_HOME "leases\repo\$($la.slot).json"
  $me = Get-Process -Id $PID; $meStart = $me.StartTime.ToUniversalTime().ToString('o')

  Check '0 a stamp-less fresh scratch lease is not stale' (-not (Lease $la.leaseId).stale)
  Stamp $lf $PID $meStart ([DateTime]::UtcNow.AddMinutes(30))
  Check '1 live pre-gate pid, deadline ahead -> not stale' (-not (Lease $la.leaseId).stale)
  Stamp $lf 999999 $null ([DateTime]::UtcNow.AddMinutes(30))
  [IO.File]::WriteAllText((Join-Path $la.path 'dirty.txt'), 'x')
  Check '2 dead pre-gate pid -> stale despite a fresh heartbeat and a dirty tree' ((Lease $la.leaseId).stale)
  Stamp $lf $PID $meStart ([DateTime]::UtcNow.AddMinutes(-1))
  Check '3 live pid but deadline passed -> stale' ((Lease $la.leaseId).stale)
  Stamp $lf 999999 $null ([DateTime]::UtcNow.AddMinutes(30))
  $env:AGENTQ_SESSION = 'sweeper'
  $o = AQ sweep
  Check '4 sweep frees the leaked pre-gate slot (backed up)' ($o -match "expired repo/$($la.slot)" -and -not (Test-Path $lf)) $o
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'CODAI_GH_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_ADMISSION', 'AGENTQ_NO_PRUNE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
