# Placement tests for `agentq run -Where local|cloud|auto` (devcloud F2, DC-037). Offline: the cloud
# tool is a stub (AGENTQ_CLOUD_TOOL) that records its args and exits with a chosen code.
param([string]$Aq)
$ErrorActionPreference = 'Stop'
if (-not $Aq) { $Aq = Join-Path (Split-Path $PSScriptRoot) 'bin\agentq.ps1' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agentq-cloud-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; $env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_SESSION = 'cloudtest'
Remove-Item Env:AGENTQ_WHERE -ErrorAction SilentlyContinue
$cfgFile = Join-Path $tmp 'agentq-config.json'
@{ machineCap = 1; quickBurst = 0; agingMin = 0; idleYieldMin = 0; minFreeCommitGB = 0; cloudWorkspaces = @{ repo = 'wsrepo' }; cloudAutoMinSec = 240 } | ConvertTo-Json | Set-Content $cfgFile
$env:AGENTQ_CONFIG = $cfgFile
$stub = Join-Path $tmp 'stub.ps1'; $rec = Join-Path $tmp 'stub.log'
@"
`$a = @(`$args); Add-Content -LiteralPath '$rec' -Value (`$a -join ' ')
exit ([int]`$(if (`$env:STUB_EXIT) { `$env:STUB_EXIT } else { 0 }))
"@ | Set-Content $stub
$env:AGENTQ_CLOUD_TOOL = $stub
$repo = Join-Path $tmp 'repo'; $other = Join-Path $tmp 'other'
foreach ($r in $repo, $other) {
  New-Item -ItemType Directory -Force $r | Out-Null
  git -C $r init -q -b main; git -C $r config user.email t@t; git -C $r config user.name t
  Set-Content (Join-Path $r 'a.txt') 'a'; git -C $r add a.txt; git -C $r commit -qm init
}
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }
$J = Join-Path $env:AGENTQ_HOME 'journal.jsonl'
function Journal { @(Get-Content $J -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json }) }
function Calls { @(Get-Content $rec -ErrorAction SilentlyContinue) }
function Run([string]$dir, [string[]]$extra, [string]$cmd = 'pnpm typecheck') {
  $a = @('-NoProfile', '-File', $Aq, 'run', '-Resource', 'build', '-Purpose', 'cloudtest', '-MinFreeGB', '0', '-TimeoutMin', '1', '-Repo', $dir) + $extra + @('--') + ($cmd -split ' ')
  & pwsh @a 2>$null | Out-Null; $LASTEXITCODE
}
$localCmd = 'pwsh -NoProfile -Command exit 0'

# 1. default (no -Where, no env) stays local: the stub is never called.
$rc = Run $repo @() $localCmd
Check 'default runs local' ($rc -eq 0 -and (Calls).Count -eq 0) "rc=$rc calls=$((Calls).Count)"

# 2. -Where cloud delegates to the tool with -Ws from config and the command after --; exit propagates.
$env:STUB_EXIT = '7'
$rc = Run $repo @('-Where', 'cloud', '-Lane', 'gate') 'pnpm --filter x typecheck'
Remove-Item Env:STUB_EXIT
$c = (Calls) | Select-Object -Last 1
Check 'cloud delegates with ws + command' ("$c" -match '-Ws wsrepo' -and "$c" -match '-- pnpm --filter x typecheck' -and "$c" -match '-Lane gate') "$c"
Check 'cloud exit code propagates' ($rc -eq 7) "rc=$rc"
Check 'cloud run takes no local ticket' (@(Journal | Where-Object { $_.event -eq 'start' -and $_.purpose -eq 'cloudtest' }).Count -eq 1) ''
Check 'placement journaled' (@(Journal | Where-Object { $_.event -eq 'placement' -and $_.where -eq 'cloud' -and $_.ws -eq 'wsrepo' }).Count -eq 1) ''

# 3. -Where cloud for a repo without a workspace is an error (no silent local fallback).
$n = (Calls).Count
$rc = Run $other @('-Where', 'cloud') 'pnpm typecheck'
Check 'cloud without workspace refuses' ($rc -ne 0 -and (Calls).Count -eq $n) "rc=$rc"

# 4. auto: machine free + no history -> local; repo without workspace -> local.
$rc = Run $repo @('-Where', 'auto') $localCmd
Check 'auto with free machine stays local' ($rc -eq 0 -and (Calls).Count -eq $n) "rc=$rc"
$rc = Run $other @('-Where', 'auto') $localCmd
Check 'auto without workspace stays local' ($rc -eq 0 -and (Calls).Count -eq $n) "rc=$rc"

# 5. auto: build:machine full (cap 1 held by a sleeper in the other repo) -> cloud.
$h = Start-Process pwsh -ArgumentList @('-NoProfile', '-File', $Aq, 'run', '-Resource', 'build', '-Purpose', 'holder', '-MinFreeGB', '0', '-Repo', $other, '--', 'pwsh', '-NoProfile', '-Command', 'Start-Sleep -Seconds 20') -PassThru -WindowStyle Hidden
$mq = Join-Path $env:AGENTQ_HOME 'queues\build_machine'
$t = 0; while ($t -lt 80 -and -not @(Get-ChildItem $mq -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.held }).Count) { Start-Sleep -Milliseconds 250; $t++ }
$rc = Run $repo @('-Where', 'auto') 'pnpm typecheck'
Check 'auto with full machine goes cloud' ($rc -eq 0 -and (Calls).Count -eq $n + 1) "rc=$rc calls=$((Calls).Count)"
Check 'auto reason names the full machine' (@(Journal | Where-Object { $_.event -eq 'placement' -and "$($_.reason)" -match 'build:machine full' }).Count -ge 1) ''

# 6. AGENTQ_WHERE=local opts out even while the machine is full (runs/queues locally -> no stub call).
$env:AGENTQ_WHERE = 'local'
$n = (Calls).Count
$rc = Run $repo @() $localCmd
Remove-Item Env:AGENTQ_WHERE
Check 'AGENTQ_WHERE=local opts out' ($rc -eq 0 -and (Calls).Count -eq $n) "rc=$rc"
Stop-Process -Id $h.Id -Force -ErrorAction SilentlyContinue

# 7. auto: a non-build kind (e2e) stays local even with history; long typecheck history -> cloud.
$now = [DateTime]::UtcNow.ToString('o')
1..3 | ForEach-Object { Add-Content $J (@{ ts = $now; event = 'done'; resource = 'build:repo,build:machine'; repo = 'repo'; kind = 'typecheck'; lane = 'gate'; holdSec = 600; waitSec = 1 } | ConvertTo-Json -Compress) }
Start-Sleep -Seconds 1
$n = (Calls).Count
$rc = Run $repo @('-Where', 'auto') 'pnpm typecheck'
Check 'auto with slow local history goes cloud' ($rc -eq 0 -and (Calls).Count -eq $n + 1) "rc=$rc"
$rc = Run $repo @('-Where', 'auto') 'pwsh -NoProfile -Command exit 0 # playwright'
Check 'auto keeps e2e local' ($rc -eq 0 -and (Calls).Count -eq $n + 1) "rc=$rc"

# 8. metrics count cloud-done rows and resume stats.
Add-Content $J (@{ ts = $now; event = 'cloud-done'; resource = 'cloud:wsrepo'; repo = 'repo'; kind = 'cloud'; lane = 'gate'; holdSec = 12.5; waitSec = 3; resumeSec = 9.5; exit = 0 } | ConvertTo-Json -Compress)
$m = (& pwsh -NoProfile -File $Aq metrics -Hours 1) -join "`n"
Check 'metrics show cloud row' ($m -match 'cloud:wsrepo') ''
Check 'metrics show resume p50' ($m -match 'resumes=1 resumeP50=9.5s') ($m -split "`n" | Select-Object -Last 1)

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-Item Env:AGENTQ_CONFIG, Env:AGENTQ_SESSION, Env:AGENTQ_CLOUD_TOOL -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
