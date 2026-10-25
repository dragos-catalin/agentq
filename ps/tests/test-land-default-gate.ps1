# ADR-0303 A (brivio): config `landGate: { <repo>: <cmd> }` makes every `agentq land` run that gate
# without -Gate; an explicit -Gate wins; `-Gate none` skips it (journaled). Isolated in %TEMP%.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqlg-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_SESSION = 'test-lg'
$env:AGENTQ_RUN_BUILD = Join-Path $PSScriptRoot 'fake-gate.ps1'
$env:FAKE_GATE_LOG = Join-Path $tmp 'gates.log'
Remove-Item Env:FAKE_GATE_HOLD -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Remote([string]$f) { (git -C $repo show "origin/dev:$f" 2>$null) -join '' }
function Gates { if (Test-Path $env:FAKE_GATE_LOG) { @(Get-Content $env:FAKE_GATE_LOG) } else { @() } }
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$repoName = Split-Path -Leaf $repo
$cfg = Join-Path $tmp 'cfg.json'
"{`"taskSlotsPerRepo`":2,`"taskSlotsMachine`":3,`"minFreeCommitGB`":0,`"landGate`":{`"$repoName`":`"pnpm land:gate`"}}" | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
function Topic([string]$name, [string]$file) {
  git -C $tw fetch -q origin 2>$null
  git -C $tw checkout -q -B $name origin/dev
  Set-Content (Join-Path $tw $file) $name; git -C $tw add $file; git -C $tw commit -qm "topic $name"
  git -C $tw push -q origin $name 2>$null
  git -C $repo fetch -q origin 2>$null
}
Push-Location $repo
try {
  # 1. no -Gate -> config default runs
  Topic 'g1' 'g1.txt'
  $o = AQ land -Branch g1 -Onto dev -Purpose 'land g1'
  git -C $repo fetch -q origin
  Check '1 land exits 0' ($code -eq 0) $o
  Check '1 announces the default gate' ($o -match 'default gate for .*pnpm land:gate') $o
  Check '1 gate ran once for g1' (@(Gates | Where-Object { $_ -match 'land gate g1' }).Count -eq 1) ((Gates) -join ' | ')
  Check '1 landed' ((Remote 'g1.txt') -eq 'g1')
  # 2. default gate failing -> exit 6, nothing pushed
  Topic 'g2' 'bad.txt'
  $before = (git -C $repo ls-remote origin refs/heads/dev).Split("`t")[0]
  $o = AQ land -Branch g2 -Onto dev -Purpose 'land g2'
  $after = (git -C $repo ls-remote origin refs/heads/dev).Split("`t")[0]
  Check '2 failing default gate -> exit 6' ($code -eq 6) $o
  Check '2 nothing pushed' ($before -eq $after)
  # 3. -Gate none -> no gate, journaled skip, lands
  Topic 'g3' 'g3.txt'
  $o = AQ land -Branch g3 -Onto dev -Gate none -Purpose 'land g3'
  git -C $repo fetch -q origin
  Check '3 -Gate none lands' ($code -eq 0 -and (Remote 'g3.txt') -eq 'g3') $o
  Check '3 no gate ran for g3' (@(Gates | Where-Object { $_ -match 'land gate g3' }).Count -eq 0) ((Gates) -join ' | ')
  $sk = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object event -eq 'land-gate-skipped')
  Check '3 skip journaled' ($sk.Count -eq 1 -and $sk[0].branch -eq 'g3')
  # 4. repo without a configured gate -> no gate
  "{`"taskSlotsPerRepo`":2,`"taskSlotsMachine`":3,`"minFreeCommitGB`":0,`"landGate`":{`"other`":`"x`"}}" | Set-Content $cfg
  Topic 'g4' 'g4.txt'
  $o = AQ land -Branch g4 -Onto dev -Purpose 'land g4'
  Check '4 unconfigured repo: no gate' ($code -eq 0 -and @(Gates | Where-Object { $_ -match 'land gate g4' }).Count -eq 0) $o
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_RUN_BUILD', 'FAKE_GATE_LOG', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
