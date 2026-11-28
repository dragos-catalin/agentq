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

# 9. circuit breaker: tool exit 4 (nothing submitted) -> the command runs locally, rc 0.
$env:STUB_EXIT = '4'
$n = (Calls).Count
$rc = Run $repo @('-Where', 'cloud') $localCmd
Check 'exit 4 falls back to local' ($rc -eq 0 -and (Calls).Count -eq $n + 1) "rc=$rc"
Check 'fallback journaled' (@(Journal | Where-Object { $_.event -eq 'placement' -and $_.resource -eq 'cloud-fallback' }).Count -eq 1) ''
# 9b. AGENTQ_CLOUD_STRICT=1 keeps the failure visible.
$env:AGENTQ_CLOUD_STRICT = '1'
$rc = Run $repo @('-Where', 'cloud') $localCmd
Remove-Item Env:AGENTQ_CLOUD_STRICT
Check 'strict mode propagates exit 4' ($rc -eq 4) "rc=$rc"
Remove-Item Env:STUB_EXIT
# 9c. an unexpired cloud-down record places locally without calling the tool; an expired one is ignored.
$dd = Join-Path $env:AGENTQ_HOME 'cloud-down'; New-Item -ItemType Directory -Force $dd | Out-Null
@{ ws = 'wsrepo'; since = [DateTime]::UtcNow.ToString('o'); until = [DateTime]::UtcNow.AddMinutes(10).ToString('o'); reason = 'test' } | ConvertTo-Json | Set-Content (Join-Path $dd 'wsrepo.json')
$n = (Calls).Count
$rc = Run $repo @('-Where', 'cloud') $localCmd
Check 'cloud-down skips the tool' ($rc -eq 0 -and (Calls).Count -eq $n) "rc=$rc calls=$((Calls).Count)"
@{ ws = 'wsrepo'; since = [DateTime]::UtcNow.AddMinutes(-30).ToString('o'); until = [DateTime]::UtcNow.AddMinutes(-1).ToString('o'); reason = 'old' } | ConvertTo-Json | Set-Content (Join-Path $dd 'wsrepo.json')
$rc = Run $repo @('-Where', 'cloud') $localCmd
Check 'expired cloud-down is ignored' ((Calls).Count -eq $n + 1 -and -not (Test-Path (Join-Path $dd 'wsrepo.json'))) "calls=$((Calls).Count)"

# 10. DC-063: explicit -Ws overrides the repo mapping; agentq-cloud reads cloudRegistry from config
# (an unknown workspace is exit 2 = usage, a registered one reaches the network step).
$rc = Run $repo @('-Where', 'cloud', '-Ws', 'vitals-win') 'cargo test -p vitals-core'
Check 'explicit -Ws wins over mapping' ("$((Calls) | Select-Object -Last 1)" -match '-Ws vitals-win .*-- cargo test -p vitals-core') "$((Calls) | Select-Object -Last 1)"
$real = Join-Path (Split-Path $PSScriptRoot) 'bin\agentq-cloud.ps1'
$cfg2 = Join-Path ([IO.Path]::GetTempPath()) "aq-reg-$PID.json"
@{ cloudRegistry = @{ 'zz-ws' = @{ project = 'p-none'; zone = 'z-none' } } } | ConvertTo-Json -Depth 4 | Set-Content $cfg2
$env:AGENTQ_CONFIG = $cfg2
$o = (& pwsh -NoProfile -File $real -Ws 'unknown-ws' -Purpose regtest -- echo 2>&1) -join ' '
Check 'unknown workspace is usage error' ($LASTEXITCODE -eq 2 -and $o -match 'zz-ws' -and $o -match 'vitals-win') $o
Remove-Item $cfg2 -ErrorAction SilentlyContinue

# 11. AGENTQPARALLELLANES20261125: a repo may map to SEVERAL workspaces, so two lanes that must
# not share a machine stop serialising behind one VM. The lane comes from the command line, then
# from the cloudLaneWorkspaces pin, then round-robin by session; a workspace with no
# cloudRegistry entry is never a candidate, and a STRING mapping keeps behaving exactly as before.
function RunOut([string]$dir, [string[]]$extra, [string]$cmd) {
  $a = @('-NoProfile', '-File', $Aq, 'run', '-Resource', 'build', '-Purpose', 'cloudtest', '-MinFreeGB', '0', '-TimeoutMin', '1', '-Repo', $dir) + $extra + @('--') + ($cmd -split ' ')
  ((& pwsh @a 2>&1) -join "`n")
}
# The hash is re-stated here on purpose: the guarantee is "the same session and lane always pick
# the same workspace, and two lanes of one session diverge when their keys do". A test that only
# demanded "not always equal" would pass or fail with the parity of whatever names it happened to
# use, which is how a flaky test gets written.
function Expected-Ws([string]$session, [string]$lane, [string[]]$pool) {
  $key = "$session|$lane"; $h = 0
  foreach ($ch in $key.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 1000003 }
  $pool[$h % $pool.Count]
}
$cfg3 = Join-Path ([IO.Path]::GetTempPath()) "aq-multi-$PID.json"
@{
  machineCap = 1; quickBurst = 0; agingMin = 0; idleYieldMin = 0; minFreeCommitGB = 0
  cloudWorkspaces     = @{ repo = @('pair-a', 'pair-b'); other = 'solo-ws' }
  cloudLaneWorkspaces = @{ repo = @{ rust = 'pair-a'; android = 'pair-b' } }
  cloudRegistry       = @{ 'pair-a' = @{ project = 'p'; zone = 'z' }; 'pair-b' = @{ project = 'p'; zone = 'z2' } }
} | ConvertTo-Json -Depth 6 | Set-Content $cfg3
$env:AGENTQ_CONFIG = $cfg3

$rc = Run $repo @('-Where', 'cloud') 'pwsh -NoProfile -File scripts/verify.ps1 -Lane rust -Where local'
Check 'array + a rust pin picks the pinned workspace' ("$((Calls) | Select-Object -Last 1)" -match '-Ws pair-a ') "$((Calls) | Select-Object -Last 1)"
$rc = Run $repo @('-Where', 'cloud') 'pwsh -NoProfile -File scripts/verify.ps1 -Lane android -Where local'
Check 'array + an android pin picks the other workspace' ("$((Calls) | Select-Object -Last 1)" -match '-Ws pair-b ') "$((Calls) | Select-Object -Last 1)"

# Two lanes with no pin must still diverge. The lanes are chosen by the test so that their keys do
# differ, rather than hoping two plausible names happen to land on different workspaces.
$lanes = 1..8 | ForEach-Object { "probe$_" }
$probeA = $null; $probeB = $null
foreach ($l in $lanes) {
  foreach ($m in $lanes) {
    if ($m -eq $l) { continue }
    if ((Expected-Ws 'cloudtest' $m @('pair-a', 'pair-b')) -ne (Expected-Ws 'cloudtest' $l @('pair-a', 'pair-b'))) { $probeA = $l; $probeB = $m; break }
  }
  if ($probeA) { break }
}
$wantA = Expected-Ws 'cloudtest' $probeA @('pair-a', 'pair-b')
$gotA = RunOut $repo @('-Where', 'cloud') "pwsh -NoProfile -File scripts/verify.ps1 -Lane $probeA -Where local"
$gotB = RunOut $repo @('-Where', 'cloud') "pwsh -NoProfile -File scripts/verify.ps1 -Lane $probeB -Where local"
$wsA = if ($gotA -match 'placement cloud:(pair-[ab])') { $Matches[1] } else { '' }
$wsB = if ($gotB -match 'placement cloud:(pair-[ab])') { $Matches[1] } else { '' }
Check 'an unpinned lane uses the workspace the documented hash predicts' ($wsA -eq $wantA) "lane=$probeA got=$wsA want=$wantA"
# The placement line stringifies, so an array would still read as its first element there. What the
# tool receives is the contract that matters, and `-Ws X Y` is not a workspace.
$lastA = "$((Calls) | Select-Object -Last 1)"
Check 'an unpinned lane passes exactly one workspace to the tool' ($lastA -match '-Ws pair-[ab] -Purpose') $lastA
Check 'two unpinned lanes of one session diverge' ($wsA -and $wsB -and $wsA -ne $wsB) "a=${probeA}:$wsA b=${probeB}:$wsB"

# A string mapping is untouched by all of this, and an unregistered sibling is not a candidate.
$rc = Run $other @('-Where', 'cloud') 'pnpm typecheck'
Check 'a string mapping still picks that one workspace' ("$((Calls) | Select-Object -Last 1)" -match '-Ws solo-ws ') "$((Calls) | Select-Object -Last 1)"
@{ machineCap = 1; minFreeCommitGB = 0; cloudWorkspaces = @{ repo = @('ghost-ws', 'pair-a') }; cloudRegistry = @{ 'pair-a' = @{ project = 'p'; zone = 'z' } } } | ConvertTo-Json -Depth 6 | Set-Content $cfg3
$env:AGENTQ_CONFIG = $cfg3
$rc = Run $repo @('-Where', 'cloud') 'pnpm typecheck'
Check 'an unregistered workspace is never picked' ("$((Calls) | Select-Object -Last 1)" -match '-Ws pair-a ') "$((Calls) | Select-Object -Last 1)"
Remove-Item $cfg3 -ErrorAction SilentlyContinue

# 12. Warm pool (TASK A) + shard count (TASK B): the PURE decision helpers, driven from the production
# file by AST (a rename or a reference to the caller's scope fails here), plus the config defaults and
# the wiring in the script text. Offline - no VM, no bucket, no git.
$cloudSrc = Join-Path (Split-Path $PSScriptRoot) 'bin\agentq-cloud.ps1'
$tok2 = $null; $err2 = $null
$ast2 = [System.Management.Automation.Language.Parser]::ParseFile($cloudSrc, [ref]$tok2, [ref]$err2)
Check 'the cloud script parses with 0 errors' ($err2.Count -eq 0) "$($err2.Count) parse error(s)"
$wfns = @($ast2.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -match '(?i)WarmPool|ShardWorkspaces' }, $true))
Check 'the warm/shard helpers are defined in agentq-cloud.ps1' ($wfns.Count -ge 2) "found $($wfns.Count)"
if ($wfns.Count) { . ([scriptblock]::Create((($wfns | ForEach-Object { $_.Extent.Text }) -join "`n"))) }

# Get-WarmPoolChoice: an explicit flag beats the config either way; the config beats the OFF default.
$wa = Get-WarmPoolChoice -Flag $true -CfgPresent $false
Check 'warm: -Warm beats an absent config' ($wa.on -and $wa.source -eq 'flag') "$($wa.on)/$($wa.source)"
$wb = Get-WarmPoolChoice -Flag $false -CfgPresent $true -CfgOn $true
Check 'warm: -NoWarm beats a true config' ((-not $wb.on) -and $wb.source -eq 'flag') "$($wb.on)/$($wb.source)"
$wc = Get-WarmPoolChoice -Flag $null -CfgPresent $true -CfgOn $true
Check 'warm: the config turns it on when no flag is given' ($wc.on -and $wc.source -eq 'config') "$($wc.on)/$($wc.source)"
$wd = Get-WarmPoolChoice -Flag $null -CfgPresent $true -CfgOn $false
Check 'warm: a present-but-false config stays off, source config' ((-not $wd.on) -and $wd.source -eq 'config') "$($wd.on)/$($wd.source)"
$we = Get-WarmPoolChoice -Flag $null -CfgPresent $false
Check 'warm: the default is OFF (nothing spends without the switch)' ((-not $we.on) -and $we.source -eq 'default') "$($we.on)/$($we.source)"

# Get-ShardWorkspaces: count 1 names only the base (today, no merge); a count whose sibling is not
# registered is reported as missing, so the caller can refuse instead of starting a partial run.
$reg = @{ agentq = @{}; 'agentq-s2' = @{} }
$s1 = Get-ShardWorkspaces -Ws agentq -Count 1 -Registry $reg
Check 'shard: count 1 names only the base workspace' (($s1.names.Count -eq 1) -and ($s1.names[0] -eq 'agentq') -and ($s1.missing.Count -eq 0)) "$($s1.names -join ',')"
$s2 = Get-ShardWorkspaces -Ws agentq -Count 2 -Registry $reg
Check 'shard: count 2 adds the sibling and finds it registered' (($s2.names.Count -eq 2) -and ($s2.names[1] -eq 'agentq-s2') -and ($s2.missing.Count -eq 0)) "$($s2.names -join ',')"
$s3 = Get-ShardWorkspaces -Ws agentq -Count 3 -Registry $reg
Check 'shard: a count whose sibling is UNREGISTERED is reported missing' (($s3.missing.Count -eq 1) -and ($s3.missing[0] -eq 'agentq-s3')) "$($s3.missing -join ',')"
$s0 = Get-ShardWorkspaces -Ws agentq -Count 0 -Registry $reg
Check 'shard: a count below 1 clamps to 1 (never a zero-shard run)' ($s0.names.Count -eq 1) "$($s0.names -join ',')"

# The config the repo ships: the three knobs exist with the safe defaults.
$cfgReal = Join-Path (Split-Path $PSScriptRoot) 'bin\agentq-config.json'
$cfgJ = Get-Content -LiteralPath $cfgReal -Raw | ConvertFrom-Json
Check 'config: cloudWarmPool defaults false' ($cfgJ.cloudWarmPool -eq $false) "$($cfgJ.cloudWarmPool)"
Check 'config: cloudWarmIdleMin defaults 30' ($cfgJ.cloudWarmIdleMin -eq 30) "$($cfgJ.cloudWarmIdleMin)"
Check 'config: cloudShardCount defaults 1' ($cfgJ.cloudShardCount -eq 1) "$($cfgJ.cloudShardCount)"

# Wiring: the switch is honoured by the suspend path, the choice is journaled, the flags are parsed and
# a shard count that names an unregistered workspace is refused.
$cloudText = [IO.File]::ReadAllText($cloudSrc)
Check 'wiring: the suspend path honours the warm pool' ($cloudText.Contains('warm-pool on - $Vm is NOT suspended'))
Check 'wiring: the effective choice is journaled' ($cloudText.Contains("'cloud-warm-pool'") -and $cloudText.Contains('warm-pool {0} (source: {1})'))
Check 'wiring: -Warm/-NoWarm are parsed' ($cloudText.Contains("'nowarm' { `$WarmFlag = `$false }") -and $cloudText.Contains("'warm' { `$WarmFlag = `$true }"))
Check 'wiring: an unregistered shard workspace is refused, not run partially' ($cloudText.Contains('cloudShardCount') -and $cloudText.Contains('unregistered shard workspace'))
Check 'wiring: the warm idle window is stamped via the metadata lever' ($cloudText.Contains('Set-VmIdleMetadata'))

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-Item Env:AGENTQ_CONFIG, Env:AGENTQ_SESSION, Env:AGENTQ_CLOUD_TOOL -ErrorAction SilentlyContinue
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
