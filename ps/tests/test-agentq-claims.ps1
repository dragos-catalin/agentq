# ADR 0005 (W4-2): advisory path claims. lease -Claims stores them; an overlapping live lease is printed and
# journaled (claim-overlap), a sibling prefix is not; `claim` replaces; among waiting land tickets an
# overlapping YOUNGER lease ranks after the older one even with a higher priority. Isolated in %TEMP%.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqclm-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"leaseDeadIdleMin":60,"leaseMaxIdleMin":600,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Events([string]$e) { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq $e) }
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$repoName = Split-Path -Leaf $repo
# Keep lease owners alive: a long-lived pwsh per lease.
$owners = @()
function Owner { $p = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 300' -PassThru -WindowStyle Hidden; $script:owners += $p; $p.Id }
Push-Location $repo
try {
  $env:AGENTQ_SESSION = 'S1'
  $o = AQ lease -Purpose 'hub work' -Claims 'apps/hub/**,packages/ui/**' -Json -OwnerPid (Owner)
  $l1 = $o | Select-String '^\{' | ForEach-Object { $_.Line | ConvertFrom-Json } | Select-Object -First 1
  Check '1 lease with claims' ($code -eq 0 -and $l1.leaseId) $o
  $lf = Get-Content (Join-Path $env:AGENTQ_HOME "leases\$repoName\$($l1.slot).json") -Raw | ConvertFrom-Json
  Check '1 claims stored on the lease' ((@($lf.claims) -join ',') -eq 'apps/hub/**,packages/ui/**') ($lf | ConvertTo-Json -Compress)

  $env:AGENTQ_SESSION = 'S2'
  $o = AQ lease -Purpose 'hubx work' -Claims 'apps/hubx/**' -Json -OwnerPid (Owner)
  $l2 = $o | Select-String '^\{' | ForEach-Object { $_.Line | ConvertFrom-Json } | Select-Object -First 1
  Check '2 sibling prefix (apps/hubx) does not overlap apps/hub' ($code -eq 0 -and $o -notmatch 'claim overlap' -and -not (Events 'claim-overlap').Count) $o

  $env:AGENTQ_SESSION = 'S3'
  $o = AQ lease -Purpose 'ui tweak' -Claims 'packages/ui/src/button.tsx' -Json -OwnerPid (Owner)
  $l3 = $o | Select-String '^\{' | ForEach-Object { $_.Line | ConvertFrom-Json } | Select-Object -First 1
  Check '3 overlap printed (file under a claimed glob)' ($code -eq 0 -and $o -match 'claim overlap' -and $o -match 'hub work') $o
  $ov = Events 'claim-overlap'
  Check '3 claim-overlap journaled' ($ov.Count -eq 1 -and "$($ov[0].paths)" -match 'packages/ui') ($ov | ConvertTo-Json -Compress)

  $env:AGENTQ_SESSION = 'S2'
  $o = AQ claim -LeaseId $l2.leaseId -Claims 'apps/hub/src/**'
  Check '4 claim replaces + reports the new overlap' ($code -eq 0 -and $o -match 'claims on' -and $o -match 'claim overlap') $o
  $lf2 = Get-Content (Join-Path $env:AGENTQ_HOME "leases\$repoName\$($l2.slot).json") -Raw | ConvertFrom-Json
  Check '4 claims replaced on disk' ((@($lf2.claims) -join ',') -eq 'apps/hub/src/**')
  $o = AQ claim -LeaseId 'nope0000' -Claims 'x/**'
  Check '4 unknown lease refused' ($code -ne 0) $o

  # 5. land ordering. Hold land:<repo> with a ticket, queue S2's land (younger lease, priority 40)
  #    before S1's land (older lease, priority 0); both claim apps/hub. S1 must rank first.
  $q = Join-Path (Join-Path $env:AGENTQ_HOME 'queues') "land_$repoName"
  $res = "land:$repoName"
  $hp = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', "`$env:AGENTQ_SESSION='H'; Set-Location '$repo'; & pwsh -NoProfile -File '$Aq' run -Resource '$res' -Purpose holder '--' pwsh -NoProfile -Command 'Start-Sleep 120'" -PassThru -WindowStyle Hidden
  $owners += $hp
  $held = $false; for ($i = 0; $i -lt 40 -and -not $held; $i++) { Start-Sleep -Milliseconds 500; $held = [bool]((AQ status) -match "(?m)$([regex]::Escape($res)).*HOLD.*holder") }
  Check '5 holder acquired' $held
  foreach ($b in 'b2', 'b1') { git -C $repo checkout -q -B $b origin/dev; Set-Content (Join-Path $repo "$b.txt") $b; git -C $repo add "$b.txt"; git -C $repo commit -qm $b; git -C $repo push -q origin $b 2>$null }
  git -C $repo checkout -q dev
  $env:AGENTQ_LAND_NO_PRECHECK = '1'
  $p2 = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', "`$env:AGENTQ_SESSION='S2'; Set-Location '$($l2.path)'; & pwsh -NoProfile -File '$Aq' land -Branch b2 -Onto dev -Purpose 'land b2' -Priority 40 -TimeoutMin 4 *> '$tmp\b2.out'" -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 4
  $p1 = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', "`$env:AGENTQ_SESSION='S1'; Set-Location '$($l1.path)'; & pwsh -NoProfile -File '$Aq' land -Branch b1 -Onto dev -Purpose 'land b1' -TimeoutMin 4 *> '$tmp\b1.out'" -PassThru -WindowStyle Hidden
  $owners += $p1, $p2
  $deadline = (Get-Date).AddSeconds(60); $st = ''
  while ((Get-Date) -lt $deadline) {
    $st = AQ status
    if ($st -match "(?s)$([regex]::Escape($res)).*land b1.*land b2" -or $st -match "(?s)land b2.*land b1") { break }
    Start-Sleep -Seconds 2
  }
  # Rank: read the 'waiting' line each land prints (rank N by priority).
  Start-Sleep -Seconds 40
  $o1 = Get-Content "$tmp\b1.out" -Raw -ErrorAction SilentlyContinue; $o2 = Get-Content "$tmp\b2.out" -Raw -ErrorAction SilentlyContinue
  Check '5 older overlapping lease ranks first despite lower priority' ($o1 -match 'rank 1 by priority' -and $o1 -notmatch 'rank 2 by priority' -and $o2 -match 'rank 2 by priority') "b1: $o1`nb2: $o2"
  $t1 = Get-ChildItem $q -Filter '*.json' | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.purpose -eq 'land b1' }
  Check '5 land ticket carries the lease claims' ((@($t1.claims) -join ',') -eq 'apps/hub/**,packages/ui/**' -and $t1.leaseCreated) ($t1 | ConvertTo-Json -Compress)
} finally {
  Pop-Location
  foreach ($p in $owners) { try { $p.Kill($true) } catch {} }
  Start-Sleep -Milliseconds 500
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS claims'; exit 0 }
