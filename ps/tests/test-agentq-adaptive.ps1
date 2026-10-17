# Adaptive build:machine cap (S18-08): steps up when CPU is low, down when memory is low, stays inside
# [min,max], one step per refresh, and journals every change. Isolated AGENTQ_HOME + AGENTQ_CONFIG.
$ErrorActionPreference = 'Stop'
$aq = Join-Path (Split-Path $PSScriptRoot) 'bin\agentq.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("agentq-adapt-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; $env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_SESSION = 'adapttest'
$cfgFile = Join-Path $tmp 'agentq-config.json'; $env:AGENTQ_CONFIG = $cfgFile
$repo = Join-Path $tmp 'repo'
New-Item -ItemType Directory -Force $repo | Out-Null
git -C $repo init -q -b main; git -C $repo config user.email t@t; git -C $repo config user.name t
Set-Content (Join-Path $repo 'a.txt') 'a'; git -C $repo add a.txt; git -C $repo commit -qm init
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }
$J = Join-Path $env:AGENTQ_HOME 'journal.jsonl'
$af = Join-Path $env:AGENTQ_HOME 'queues\build_machine\adaptive.json'
$capf = Join-Path $env:AGENTQ_HOME 'queues\build_machine\capacity'
function Cfg($adaptive) { @{ machineCap = 2; quickBurst = 0; agingMin = 0; idleYieldMin = 0; minFreeCommitGB = 0; machineCapAdaptive = $adaptive } | ConvertTo-Json -Depth 4 | Set-Content $cfgFile }
function Tick { & pwsh -NoProfile -File $aq run -Resource build -Purpose 'adapt' -MinFreeGB 0 -TimeoutMin 1 -Repo $repo -- pwsh -NoProfile -Command 'exit 0' 2>$null | Out-Null; $LASTEXITCODE }
function Cap { if (Test-Path $af) { [int](Get-Content $af -Raw | ConvertFrom-Json).cap } else { -1 } }

# 1. no machineCapAdaptive -> the fixed cap, no adaptive.json.
@{ machineCap = 2; quickBurst = 0; agingMin = 0; idleYieldMin = 0; minFreeCommitGB = 0 } | ConvertTo-Json | Set-Content $cfgFile
$rc = Tick
Check 'fixed cap without adaptive config' ($rc -eq 0 -and -not (Test-Path $af) -and [int](Get-Content $capf -Raw) -eq 2) "rc=$rc"

# 2. cpuLow 101 = always "idle" -> +1 per refresh, clamped at max 4; starts at min.
Cfg @{ min = 2; max = 4; cpuLow = 101; cpuHigh = 200; minFreeRamGB = 0; minFreeCommitGB = 0; everySec = 0 }
$null = Tick; $c1 = Cap      # first sample has no CPU delta -> holds at min
$null = Tick; $c2 = Cap
$null = Tick; $c3 = Cap
$null = Tick; $c4 = Cap
Check 'first refresh holds at min' ($c1 -eq 2) "c1=$c1"
Check 'steps up one per refresh' ($c2 -eq 3 -and $c3 -eq 4) "c2=$c2 c3=$c3"
Check 'clamped at max' ($c4 -eq 4) "c4=$c4"
Check 'capacity file shows effective cap' ([int](Get-Content $capf -Raw) -eq 4) ''
Check 'cap change journaled with reason' (@(Get-Content $J | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'cap' -and $_.to -eq 4 -and "$($_.reason)" -match 'cpu' }).Count -eq 1) ''

# 3. memory gate below free RAM -> steps down, clamped at min.
Cfg @{ min = 2; max = 4; cpuLow = 101; cpuHigh = 200; minFreeRamGB = 100000; minFreeCommitGB = 0; everySec = 0 }
$null = Tick; $d1 = Cap
$null = Tick; $null = Tick; $d3 = Cap
Check 'low memory steps down' ($d1 -eq 3) "d1=$d1"
Check 'clamped at min' ($d3 -eq 2) "d3=$d3"

# 4. everySec caches the decision: no new sample inside the window.
Cfg @{ min = 2; max = 4; cpuLow = 101; cpuHigh = 200; minFreeRamGB = 0; minFreeCommitGB = 0; everySec = 600 }
$at = (Get-Content $af -Raw | ConvertFrom-Json).at
$null = Tick
Check 'refresh window reuses the decision' ((Get-Content $af -Raw | ConvertFrom-Json).at -eq $at) ''

# 5. agent registry: every run records the caller under agents/<session>.json, counting calls.
$rf = Join-Path $env:AGENTQ_HOME 'agents\adapttest.json'
$r = if (Test-Path $rf) { Get-Content $rf -Raw | ConvertFrom-Json } else { $null }
Check 'registry written for the session' ($null -ne $r -and $r.session -eq 'adapttest' -and $r.lastPurpose -eq 'adapt' -and $r.lastVerb -eq 'run') "$r"
# 1 + 4 + 3 + 1 Tick() runs before this point
Check 'registry counts calls' ($r -and [int]$r.calls -eq 9) "calls=$($r.calls)"
Check 'registry records the repo' ($r -and $r.repo -eq 'repo') "repo=$($r.repo)"
$env:AGENTQ_CLIENT = 'test-client'; $null = Tick; Remove-Item Env:AGENTQ_CLIENT
Check 'registry takes AGENTQ_CLIENT' ((Get-Content $rf -Raw | ConvertFrom-Json).client -eq 'test-client') ''
$env:AGENTQ_NO_REGISTRY = '1'; $c0 = [int](Get-Content $rf -Raw | ConvertFrom-Json).calls; $null = Tick; Remove-Item Env:AGENTQ_NO_REGISTRY
Check 'AGENTQ_NO_REGISTRY opts out' ([int](Get-Content $rf -Raw | ConvertFrom-Json).calls -eq $c0) ''

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-Item Env:AGENTQ_CONFIG, Env:AGENTQ_SESSION -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
