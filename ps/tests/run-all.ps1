# Runs every ps/ test suite against THIS checkout (not the installed copy). Exit 0 only if all pass.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin'; $hooks = Join-Path $root 'hooks'
# test-agentq.ps1 resolves agentq.ps1 next to itself: run it from a temp copy beside bin/.
$stage = Join-Path ([IO.Path]::GetTempPath()) ('aq-runall-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory $stage | Out-Null
Copy-Item (Join-Path $bin '*') $stage
Copy-Item (Join-Path $PSScriptRoot 'test-agentq.ps1') $stage
$suites = [ordered]@{
  'agentq v1'      = @('-File', (Join-Path $stage 'test-agentq.ps1'))
  'agentq v2'      = @('-File', (Join-Path $PSScriptRoot 'test-agentq-v2.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'worktree v2'    = @('-File', (Join-Path $PSScriptRoot 'test-worktree-v2.ps1'), '-Bin', $bin, '-Hooks', $hooks)
  'repo-migrate'   = @('-File', (Join-Path $PSScriptRoot 'test-repo-migrate.ps1'), '-Tool', (Join-Path $bin 'repo-migrate.ps1'))
  'guard'          = @('-File', (Join-Path $PSScriptRoot 'test-guard-v2.ps1'), '-Guard', (Join-Path $hooks 'guard-tooluse.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
}
$bad = @()
foreach ($k in $suites.Keys) {
  $a = $suites[$k]
  if (-not (Test-Path $a[1])) { Write-Host "SKIP $k (missing $($a[1]))"; continue }
  $out = @(& pwsh -NoProfile @a 2>&1 | ForEach-Object { "$_" })
  $code = $LASTEXITCODE
  $fails = @($out | Where-Object { $_ -match '^\s*(FAIL)\b' })
  Write-Host ("{0,-15} exit={1} pass={2} fail={3}" -f $k, $code, @($out | Where-Object { $_ -match '^\s*(PASS|ok)\b' }).Count, $fails.Count)
  $fails | ForEach-Object { Write-Host "   $_" }
  if ($code) { $bad += $k }
}
cmd /c rmdir /s /q "`"$stage`"" 2>$null
if ($bad) { Write-Host "FAILED: $($bad -join ', ')"; exit 1 } else { Write-Host 'ALL SUITES PASS'; exit 0 }
