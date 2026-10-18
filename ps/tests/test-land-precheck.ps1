# ADR 0003 W2-6: `agentq land` refuses BEFORE queueing (exit 5, no ticket, no land slot) when the topic
# conflicts with origin/<onto> on a real file; a conflict only in CHANGELOG.md still proceeds (the land
# resolver handles it). Isolated in %TEMP%; bare repo = origin.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqpre-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_SESSION = 'test-P'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Tip { "$((git -C $repo ls-remote origin refs/heads/dev) -split "`t" | Select-Object -First 1)".Trim() }
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'; Set-Content (Join-Path $repo 'CHANGELOG.md') "# Changelog`n`n- base"
git -C $repo add a.txt CHANGELOG.md; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
Push-Location $repo
try {
  # 1. real conflict on a.txt -> exit 5 before queueing
  git -C $tw checkout -q -B clash origin/dev
  Set-Content (Join-Path $tw 'a.txt') 'topic edit'; git -C $tw commit -qam 'topic a'; git -C $tw push -q origin clash 2>$null
  Set-Content (Join-Path $repo 'a.txt') 'dev edit'; git -C $repo commit -qam 'dev a'; git -C $repo push -q origin dev 2>$null
  $t0 = Tip
  $o = AQ land -Branch clash -Onto dev -Purpose 'clash'
  Check 'precheck conflict -> exit 5' ($code -eq 5) $o
  Check 'precheck names the file' ($o -match 'a\.txt' -and $o -match 'Nothing queued') $o
  Check 'nothing pushed' ((Tip) -eq $t0)
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  Check 'journaled land-precheck-conflict' (@($j | Where-Object event -eq 'land-precheck-conflict').Count -eq 1)
  Check 'never queued (no land ticket, no land lease)' (-not @($j | Where-Object { $_.event -eq 'queued' -and "$($_.resource)" -like 'land:*' }).Count -and -not (Test-Path (Join-Path $env:AGENTQ_HOME 'leases\repo\land.json')))
  # 2. AGENTQ_LAND_NO_PRECHECK=1 skips it -> the classic in-slot conflict path (still exit 5)
  $env:AGENTQ_LAND_NO_PRECHECK = '1'
  $o = AQ land -Branch clash -Onto dev -Purpose 'clash no precheck'
  Remove-Item Env:AGENTQ_LAND_NO_PRECHECK
  Check 'opt-out: in-slot conflict path, exit 5' ($code -eq 5 -and $o -match 'CONFLICT picking') $o
  # 3. conflict ONLY in CHANGELOG.md -> not refused, lands via the union resolver
  git -C $repo pull -q --no-rebase origin dev 2>$null
  git -C $tw fetch -q origin; git -C $tw checkout -q -B cl origin/dev
  [IO.File]::WriteAllText((Join-Path $tw 'CHANGELOG.md'), "# Changelog`n`n- topic entry`n- base`n")
  Set-Content (Join-Path $tw 'b.txt') 'b'; git -C $tw add CHANGELOG.md b.txt; git -C $tw commit -qm 'topic b'; git -C $tw push -q origin cl 2>$null
  [IO.File]::WriteAllText((Join-Path $repo 'CHANGELOG.md'), "# Changelog`n`n- dev entry`n- base`n")
  git -C $repo commit -qam 'dev cl'; git -C $repo push -q origin dev 2>$null
  $o = AQ land -Branch cl -Onto dev -Purpose 'changelog only'
  Check 'CHANGELOG-only conflict is not refused, lands' ($code -eq 0 -and $o -match 'landed cl') $o
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_LAND_NO_PRECHECK') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
