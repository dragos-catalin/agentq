# CS-56 (2026-11-19): `agentq land` installs the merged lockfile in the LAND slot before the gate.
# Without it a land that changes a lockfile pushes a tree whose node_modules are stale; only the
# pre-push typecheck notices, with type errors that look like code errors (brivio 2026-11-18/19:
# stripe 23.0.0 in the land slot vs 23.1.0 in the branch -> TS2322 on the ApiVersion literal, while the
# land gate ran 103/103 green because it does not typecheck).
# Isolated in %TEMP%; a fake `pnpm` on PATH records the cwd and argv it is called with.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqli-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'
$env:AGENTQ_NO_ADMISSION = '1'; $env:AGENTQ_NO_FLAKES = '1'; $env:AGENTQ_NO_POSTLAND = '1'; $env:AGENTQ_LAND_BATCH = '0'
$env:AGENTQ_LAND_NO_PREGATE = '1'
$env:AGENTQ_SESSION = 'test-li'
$env:AGENTQ_RUN_BUILD = Join-Path $PSScriptRoot 'fake-gate.ps1'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null

# A fake pnpm earlier on PATH: records "<cwd> :: <argv>" per call. Exits 0, or 7 when FAKE_PNPM_FAIL=1.
$fakebin = Join-Path $tmp 'fakebin'; New-Item -ItemType Directory -Force $fakebin | Out-Null
$env:FAKE_PNPM_LOG = Join-Path $tmp 'pnpm.log'
$cmd = @('@echo off', 'echo %CD% :: %*>>"%FAKE_PNPM_LOG%"', 'if "%FAKE_PNPM_FAIL%"=="1" exit /b 7', 'exit /b 0')
[IO.File]::WriteAllLines((Join-Path $fakebin 'pnpm.cmd'), $cmd)
$env:PATH = "$fakebin;$env:PATH"
Remove-Item Env:FAKE_PNPM_FAIL -ErrorAction SilentlyContinue

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name  $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function Journal { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json }) }
function Ev([string]$name) { @(Journal | Where-Object { $_.event -eq $name }) }
function PnpmCalls { if (Test-Path $env:FAKE_PNPM_LOG) { @(Get-Content $env:FAKE_PNPM_LOG | Where-Object { $_ -match 'install' }) } else { @() } }
function Remote([string]$f) { git -C $repo fetch -q origin 2>$null; (git -C $repo show "origin/dev:$f" 2>$null) -join '' }
function Tip { (git -C $repo ls-remote origin refs/heads/dev).Split("`t")[0] }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'pnpm-lock.yaml') 'lockfileVersion: 9'
Set-Content (Join-Path $repo 'a.txt') 'a'
git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$repoName = Split-Path -Leaf $repo
$cfg = Join-Path $tmp 'cfg.json'
"{`"taskSlotsPerRepo`":12,`"taskSlotsMachine`":14,`"minFreeCommitGB`":0,`"landGate`":{`"$repoName`":`"pnpm land:gate`"}}" | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg

function Slot([string]$branch) {
  Push-Location $repo
  try { $o = AQ lease -Purpose "work $branch" -Branch $branch -Ref origin/dev -Json } finally { Pop-Location }
  $l = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  git -C $l.path config core.autocrlf false
  $l
}
function Commit($l, [hashtable]$files, [string]$branch) {
  foreach ($k in $files.Keys) { Set-Content (Join-Path $l.path $k) $files[$k] }
  git -C $l.path add -A; git -C $l.path commit -qm "topic $branch"
  git -C $l.path push -q origin $branch 2>$null
}
function LandFrom([string]$dir, [string[]]$more) { Push-Location $dir; try { AQ @(@('land', '-Onto', 'dev', '-TimeoutMin', '5') + $more) } finally { Pop-Location } }

try {
  # 1. a topic that changes pnpm-lock.yaml: the land installs the merged lockfile IN THE LAND SLOT
  $l1 = Slot 'i1'; Commit $l1 @{ 'i1.txt' = 'i1'; 'pnpm-lock.yaml' = "lockfileVersion: 9`n# bumped" } 'i1'
  $o = LandFrom $l1.path @('-Branch', 'i1', '-Purpose', 'land i1')
  Check '1 land exits 0 and lands' ($code -eq 0 -and (Remote 'i1.txt') -eq 'i1') $o
  $calls = PnpmCalls
  Check '1 pnpm install --frozen-lockfile --prefer-offline was run' (@($calls | Where-Object { $_ -match 'install --frozen-lockfile --prefer-offline' }).Count -ge 1) ($calls -join ' ~ ')
  Check '1 it ran in the LAND slot, not the task slot' (@($calls | Where-Object { $_ -match '\\land :: install' }).Count -ge 1) ($calls -join ' ~ ')
  Check '1 journal land-install + land-install-ok' (@(Ev 'land-install').Count -eq 1 -and @(Ev 'land-install-ok').Count -eq 1)
  Check '1 the slot is back on its branch' ((git -C $l1.path symbolic-ref --short HEAD) -eq 'i1')

  # 2. a topic that changes no lockfile: no install at all (zero cost)
  $calls0 = @(PnpmCalls).Count
  $l2 = Slot 'i2'; Commit $l2 @{ 'i2.txt' = 'i2' } 'i2'
  $o = LandFrom $l2.path @('-Branch', 'i2', '-Purpose', 'land i2')
  Check '2 lands' ($code -eq 0 -and (Remote 'i2.txt') -eq 'i2') $o
  Check '2 no install when the lockfile did not change' (@(PnpmCalls).Count -eq $calls0 -and @(Ev 'land-install').Count -eq 1) ("$(@(PnpmCalls).Count) vs $calls0")

  # 3. an install that FAILS aborts the land (exit 10) and pushes nothing
  $before = Tip
  $l3 = Slot 'i3'; Commit $l3 @{ 'i3.txt' = 'i3'; 'pnpm-lock.yaml' = "lockfileVersion: 9`n# fail" } 'i3'
  $env:FAKE_PNPM_FAIL = '1'
  $o = LandFrom $l3.path @('-Branch', 'i3', '-Purpose', 'land i3')
  Check '3 a failing install -> exit 10' ($code -eq 10) "$code :: $o"
  Check '3 nothing pushed' ((Tip) -eq $before)
  Check '3 journal land-install-failed, no land-install-ok' (@(Ev 'land-install-failed').Count -ge 1 -and @(Ev 'land-install-ok').Count -eq 1)
  Remove-Item Env:FAKE_PNPM_FAIL -ErrorAction SilentlyContinue

  # 4. AGENTQ_NO_LAND_INSTALL=1 opts out (and the land still works)
  $env:AGENTQ_NO_LAND_INSTALL = '1'
  $l4 = Slot 'i4'; Commit $l4 @{ 'i4.txt' = 'i4'; 'pnpm-lock.yaml' = "lockfileVersion: 9`n# optout" } 'i4'
  $n = @(PnpmCalls).Count
  $ni = @(Ev 'land-install').Count
  $o = LandFrom $l4.path @('-Branch', 'i4', '-Purpose', 'land i4')
  Check '4 lands with the escape hatch' ($code -eq 0 -and (Remote 'i4.txt') -eq 'i4') $o
  Check '4 no install with AGENTQ_NO_LAND_INSTALL=1' (@(PnpmCalls).Count -eq $n -and @(Ev 'land-install').Count -eq $ni) "$(@(PnpmCalls).Count)/$n installs, $(@(Ev 'land-install').Count)/$ni journal"
  Remove-Item Env:AGENTQ_NO_LAND_INSTALL -ErrorAction SilentlyContinue

  if ($fail) { Write-Host "FAIL land install suite ($fail)" -ForegroundColor Red; exit 1 }
  Write-Host "PASS land install suite"
  exit 0
} finally {
  Remove-Item Env:FAKE_PNPM_FAIL, Env:AGENTQ_NO_LAND_INSTALL -ErrorAction SilentlyContinue
  if (-not $env:AGENTQ_KEEP_TMP) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
