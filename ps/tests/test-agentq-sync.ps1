# agentq-sync daemon-health collection: the payload's top-level `daemons` array and the persisted
# <coord>/daemons/<name>.json (history cap/newest-last, failStreak advance/reset). The default daemon
# (git-autosync) is a FAKE here, so nothing touches the real tool or the real coord dir. Isolated
# AGENTQ_HOME / AGENTQ_CONFIG / AGENTQ_GIT_AUTOSYNC under %TEMP%.
param([string]$Bin)
$ErrorActionPreference = 'Stop'
if (-not $Bin) { $Bin = Join-Path (Split-Path $PSScriptRoot) 'bin' }
$sync = Join-Path $Bin 'agentq-sync.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aq-sync-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:AGENTQ_SYNC_STATE = Join-Path $tmp 'sync-state.json'
$env:AGENTQ_SYNC_DUMP = Join-Path $tmp 'sync-body.json'
$env:AGENTQ_CONFIG = Join-Path $tmp 'cfg.json'
Remove-Item Env:AGENTQ_GIT_AUTOSYNC -ErrorAction SilentlyContinue
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }
# a fake daemon: ignores its args and prints one JSON record line (the frozen shape git-autosync -Json emits)
function FakeDaemon([string]$name, [string]$verdict) {
  $j = '{"name":"' + $name + '","at":"2026-01-01T00:00:00Z","verdict":"' + $verdict + '","okCount":2,"warnCount":1,"failCount":0,"lines":["x"],"failStreak":0,"history":[]}'
  $p = Join-Path $tmp ("fake-" + $name + ".ps1")
  [IO.File]::WriteAllText($p, "'" + $j.Replace("'", "''") + "'`n")
  $p
}
function RunSync { $o = @(& pwsh -NoProfile -File $sync -Once -DryRun 2>&1 | ForEach-Object { "$_" }); @{ code = $LASTEXITCODE; out = ($o -join "`n") } }
function Body { if (Test-Path $env:AGENTQ_SYNC_DUMP) { Get-Content $env:AGENTQ_SYNC_DUMP -Raw | ConvertFrom-Json } else { $null } }
$daemonFile = Join-Path $env:AGENTQ_HOME 'daemons\git-autosync.json'

# 1 default list: git-autosync, collected + merged into the record and the payload
$env:AGENTQ_GIT_AUTOSYNC = FakeDaemon 'git-autosync' 'warn'
$r = RunSync
Check '1 dry-run exits 0' ($r.code -eq 0) $r.out
Check '1 dry-run summary counts daemons' ($r.out -match 'daemons=1') $r.out
$b = Body
Check '1 payload has daemons[] with the record' (@($b.daemons).Count -eq 1 -and $b.daemons[0].name -eq 'git-autosync' -and $b.daemons[0].verdict -eq 'warn') (($b.daemons | ConvertTo-Json -Compress))
Check '1 daemon record written under coord/daemons' (Test-Path $daemonFile)
$rec = Get-Content $daemonFile -Raw | ConvertFrom-Json
Check '1 history has one entry, newest last' (@($rec.history).Count -eq 1 -and $rec.history[-1].verdict -eq 'warn')
Check '1 failStreak is 0 for warn' ($rec.failStreak -eq 0)
Check '1 record keeps the counts + lines' ($rec.okCount -eq 2 -and $rec.warnCount -eq 1 -and $rec.failCount -eq 0 -and @($rec.lines).Count -eq 1)
# 1b the pushed daemon object has EXACTLY the frozen keys/types the gateway + hub consume
$frozen = @('name', 'at', 'verdict', 'okCount', 'warnCount', 'failCount', 'lines', 'failStreak', 'history')
$got = @($b.daemons[0].PSObject.Properties.Name)
Check '1b daemons[] entry has exactly the frozen keys' (-not (Compare-Object $frozen $got)) ($got -join ', ')
Check '1b shapes: counts numeric, lines array, history entries {at,verdict}' (($b.daemons[0].okCount -ge 0) -and ($b.daemons[0].failStreak -ge 0) -and (@($b.daemons[0].lines).Count -ge 1) -and ((@($b.daemons[0].history)[0].PSObject.Properties.Name -join ',') -eq 'at,verdict')) (($b.daemons[0] | ConvertTo-Json -Compress))

# 2 history grows one per pass (cap 48, newest last)
$null = RunSync
$rec = Get-Content $daemonFile -Raw | ConvertFrom-Json
Check '2 history grows each pass' (@($rec.history).Count -eq 2)

# 3 a fail verdict advances failStreak; recovery resets it
$env:AGENTQ_GIT_AUTOSYNC = FakeDaemon 'git-autosync' 'fail'
$null = RunSync
$rec = Get-Content $daemonFile -Raw | ConvertFrom-Json
Check '3 failStreak increments on fail' ($rec.failStreak -eq 1)
$null = RunSync
$rec = Get-Content $daemonFile -Raw | ConvertFrom-Json
Check '3 failStreak counts consecutive fails' ($rec.failStreak -eq 2 -and @($rec.history).Count -eq 4)
$env:AGENTQ_GIT_AUTOSYNC = FakeDaemon 'git-autosync' 'ok'
$null = RunSync
$rec = Get-Content $daemonFile -Raw | ConvertFrom-Json
Check '3 failStreak resets on ok' ($rec.failStreak -eq 0)

# 4 a daemon that fails to run must NOT break the push: it is skipped, the pass still succeeds
$bad = Join-Path $tmp 'bad.ps1'; Set-Content -LiteralPath $bad -Value 'exit 1'
$env:AGENTQ_GIT_AUTOSYNC = $bad
$r = RunSync
Check '4 a broken daemon does not break the push' ($r.code -eq 0) $r.out
$b = Body
Check '4 broken daemon -> daemons[] empty, push still has tickets/marks' ($null -ne $b -and @($b.daemons).Count -eq 0 -and $null -ne $b.tickets -and $null -ne $b.marks) (($b.daemons | ConvertTo-Json -Compress))

# 5 agentq-config.json autosync.daemons overrides the default list (empty = disable collection)
[IO.File]::WriteAllText($env:AGENTQ_CONFIG, '{"autosync":{"daemons":[]}}')
$env:AGENTQ_GIT_AUTOSYNC = FakeDaemon 'git-autosync' 'ok'
$r = RunSync
Check '5 config autosync.daemons=[] disables collection' ($r.out -match 'daemons=0') $r.out

# 6 -Status prints the daemon list + the last verdict (config reset to the default list)
[IO.File]::WriteAllText($env:AGENTQ_CONFIG, '{}')
$st = (& pwsh -NoProfile -File $sync -Status 2>&1 | ForEach-Object { "$_" }) -join "`n"
Check '6 -Status lists the configured daemons' ($st -match 'daemons: 1 configured \(git-autosync\)') $st
Check '6 -Status shows the last daemon verdict' ($st -match 'git-autosync\s+ok\s+failStreak 0') $st

Remove-Item Env:AGENTQ_GIT_AUTOSYNC -ErrorAction SilentlyContinue
cmd /c rmdir /s /q "`"$tmp`"" 2>$null
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
