# Runs every ps/ test suite against THIS checkout (not the installed copy). Exit 0 only if all pass.
$ErrorActionPreference = 'Continue'
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin'; $hooks = Join-Path $root 'hooks'
# test-agentq.ps1 resolves agentq.ps1 next to itself: run it from a temp copy beside bin/.
$stage = Join-Path ([IO.Path]::GetTempPath()) ('aq-runall-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory $stage | Out-Null
Copy-Item (Join-Path $bin '*') $stage
Copy-Item (Join-Path $PSScriptRoot 'test-agentq.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'test-agentq-v3.ps1') $stage
$suites = [ordered]@{
  'agentq v1'      = @('-File', (Join-Path $stage 'test-agentq.ps1'))
  'agentq v3'      = @('-File', (Join-Path $stage 'test-agentq-v3.ps1'))
  'agentq v2'      = @('-File', (Join-Path $PSScriptRoot 'test-agentq-v2.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land changelog' = @('-File', (Join-Path $PSScriptRoot 'test-land-changelog.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'worktree v2'    = @('-File', (Join-Path $PSScriptRoot 'test-worktree-v2.ps1'), '-Bin', $bin, '-Hooks', $hooks)
  'repo-migrate'   = @('-File', (Join-Path $PSScriptRoot 'test-repo-migrate.ps1'), '-Tool', (Join-Path $bin 'repo-migrate.ps1'))
  'guard'          = @('-File', (Join-Path $PSScriptRoot 'test-guard-v2.ps1'), '-Guard', (Join-Path $hooks 'guard-tooluse.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'jobs'           = @('-File', (Join-Path $PSScriptRoot 'test-jobs.ps1'), '-Bin', $bin, '-Hooks', $hooks)
  'cloud place'    = @('-File', (Join-Path $PSScriptRoot 'test-agentq-cloud.ps1'), '-Aq', (Join-Path $stage 'agentq.ps1'))
  'adaptive+reg'   = @('-File', (Join-Path $PSScriptRoot 'test-agentq-adaptive.ps1'))
  'reap terminals' = @('-File', (Join-Path $PSScriptRoot 'test-reap-terminals.ps1'), '-Tool', (Join-Path $bin 'reap-terminals.ps1'))
  'term interrupt' = @('-File', (Join-Path $PSScriptRoot 'test-term-interrupt.ps1'), '-Tool', (Join-Path $bin 'term-interrupt.ps1'))
  'git-autosync'   = @('-File', (Join-Path $PSScriptRoot 'test-git-autosync.ps1'), '-Tool', (Join-Path $bin 'git-autosync.ps1'))
  'guard shared'   = @('-File', (Join-Path $PSScriptRoot 'test-guard-shared.ps1'), '-Guard', (Join-Path $hooks 'guard-tooluse.ps1'))
  'guard cloud'    = @('-File', (Join-Path $PSScriptRoot 'test-guard-cloud.ps1'), '-Guard', (Join-Path $hooks 'guard-tooluse.ps1'))
  # ADR 0003 wave 1
  'publish'        = @('-File', (Join-Path $PSScriptRoot 'test-agentq-publish.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'lease3+prep'    = @('-File', (Join-Path $PSScriptRoot 'test-agentq-lease3.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'args'           = @('-File', (Join-Path $PSScriptRoot 'test-agentq-args.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  # ADR 0003 wave 2/4
  'land finalize'  = @('-File', (Join-Path $PSScriptRoot 'test-land-finalize.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land precheck'  = @('-File', (Join-Path $PSScriptRoot 'test-land-precheck.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land reclaim'   = @('-File', (Join-Path $PSScriptRoot 'test-land-reclaim.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'job object'     = @('-File', (Join-Path $PSScriptRoot 'test-jobobject.ps1'), '-Bin', $bin)
  'flakes'         = @('-Command', "node '$(Join-Path $PSScriptRoot 'test-flakes.mjs')'; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { 'PASS flakes selftest' }")
  'land batch'     = @('-File', (Join-Path $PSScriptRoot 'test-land-batch.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land default gate' = @('-File', (Join-Path $PSScriptRoot 'test-land-default-gate.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'claims'         = @('-File', (Join-Path $PSScriptRoot 'test-agentq-claims.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land flakes'    = @('-File', (Join-Path $PSScriptRoot 'test-land-flakes.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'store'          = @('-Command', "node '$(Join-Path $PSScriptRoot 'test-store.mjs')'; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { 'PASS store selftest' }")
  # ADR 0007: git-first + devbox teams
  'devbox tools'   = @('-File', (Join-Path $PSScriptRoot 'test-devbox-tools.ps1'), '-Bin', $bin)
  'devbox teams'   = @('-Command', "python '$(Join-Path $PSScriptRoot 'test-devbox-teams.py')' '$(Join-Path $bin 'devbox-teams.py')' 2>&1; if (`$LASTEXITCODE) { 'FAIL devbox-teams planner'; exit `$LASTEXITCODE } else { 'PASS devbox-teams planner (16)' }")
  'slo'            = @('-Command', "node '$(Join-Path $PSScriptRoot 'test-slo.mjs')'; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { 'PASS slo selftest' }")
}
$bad = @()
foreach ($k in $suites.Keys) {
  $a = $suites[$k]
  if ($a[0] -eq '-File' -and -not (Test-Path $a[1])) { Write-Host "SKIP $k (missing $($a[1]))"; continue }
  $out = @(& pwsh -NoProfile @a 2>&1 | ForEach-Object { "$_" })
  $code = $LASTEXITCODE
  $fails = @($out | Where-Object { $_ -match '^\s*(FAIL)\b' })
  Write-Host ("{0,-15} exit={1} pass={2} fail={3}" -f $k, $code, @($out | Where-Object { $_ -match '^\s*(PASS|ok)\b' }).Count, $fails.Count)
  $fails | ForEach-Object { Write-Host "   $_" }
  if ($code) { $bad += $k }
}
cmd /c rmdir /s /q "`"$stage`"" 2>$null
if ($bad) { Write-Host "FAILED: $($bad -join ', ')"; exit 1 } else { Write-Host 'ALL SUITES PASS'; exit 0 }
