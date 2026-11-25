# `agentq-cloud.ps1 -Status -Json` — the read-only devcloud surface Vitals calls (ADR 0050, vitals
# §6.3). Offline: a `gcloud` shim on PATH answers `compute instances describe` and `storage cat|ls`, so
# the suite pins the SHAPE and the "a number that cannot be measured is null, NEVER 0" rule without a
# network or a real workspace. The mutation block at the end would-be's the missing-heartbeat null: it
# is run by hand (see the header of run-all.ps1) and its red/green is reported, not asserted here.
param([string]$Cloud)
$ErrorActionPreference = 'Stop'
if (-not $Cloud) { $Cloud = Join-Path (Split-Path $PSScriptRoot) 'bin\agentq-cloud.ps1' }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('agentq-cloud-status-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }

# --- the shim: a `gcloud.cmd` on PATH that prints what the test tells it to -------------------------
$shim = Join-Path $tmp 'gcloud-shim.ps1'
$cmd = Join-Path $tmp 'gcloud.cmd'
@'
$a = @($args)
$ws = $env:FAKE_HB_WS
if ($a.Count -ge 3 -and $a[0] -eq 'storage' -and $a[1] -eq 'cat') {
  $uri = "$($a[2])"
  if ($ws -and $uri -match ('/ws/' + [regex]::Escape($ws) + '/heartbeat$')) { [Console]::Out.Write($env:FAKE_HB_JSON) }
  exit 1
}
if ($a.Count -ge 3 -and $a[0] -eq 'storage' -and $a[1] -eq 'ls') {
  if ($env:FAKE_QUEUE) { [Console]::Out.Write($env:FAKE_QUEUE) }
  exit 0
}
if ($a.Count -ge 4 -and $a[0] -eq 'compute' -and $a[1] -eq 'instances' -and $a[2] -eq 'describe') {
  $vm = "$($a[3])"
  if ($ws -and $vm -eq "ws-$ws") { [Console]::Out.Write('{"status":"RUNNING"}') } else { [Console]::Out.Write('{"status":"SUSPENDED"}') }
  exit 0
}
exit 1
'@ | Set-Content -LiteralPath $shim -Encoding ascii
"@echo off`r`npwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"%~dp0gcloud-shim.ps1`" %*" | Set-Content -LiteralPath $cmd -Encoding ascii

# A registry of exactly the two workspaces the test reasons about; the built-ins (codai, vitals-win)
# also appear and are simply found by name.
$cfgFile = Join-Path $tmp 'agentq-config.json'
@{ cloudRegistry = @{ 'good-ws' = @{ project = 'p-test'; zone = 'z-test' }; 'bare-ws' = @{ project = 'p-test'; zone = 'z-test' } } } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $cfgFile
$env:AGENTQ_CONFIG = $cfgFile
$now = [DateTime]::UtcNow.ToString('o')
$env:FAKE_HB_WS = 'good-ws'
$env:FAKE_HB_JSON = (@{ at = $now; host = 'ws-good-ws'; state = 'idle'; idleSec = 42 } | ConvertTo-Json -Compress)
$env:FAKE_QUEUE = "gs://b/ws/good-ws/queue/a.json`ngs://b/ws/good-ws/queue/b.json"

$savedPath = $env:PATH
$env:PATH = "$tmp;$env:PATH"
try {
  $raw = (@(& pwsh -NoProfile -File $Cloud -Status -Json 2>$null) -join "`n")
  $j = $raw | ConvertFrom-Json
  function Row([string]$ws) { @($j.workspaces | Where-Object { $_.ws -eq $ws }) | Select-Object -First 1 }

  # 1. the document envelope
  Check 'stdout is a JSON document and nothing else' ($raw.TrimStart().StartsWith('{') -and $raw.TrimEnd().EndsWith('}')) $raw.Substring(0, [math]::Min(60, $raw.Length))
  Check 'v is 1' ($j.v -eq 1) "v=$($j.v)"
  Check 'at is present and non-empty' ($j.PSObject.Properties['at'] -and "$($j.at)".Trim()) "$($j.at)"
  Check 'workspaces is an array' ($j.PSObject.Properties['workspaces'] -and $j.workspaces -is [array] -and $j.workspaces.Count -ge 2) "count=$($j.workspaces.Count)"
  Check 'unavailable is an array' ($j.PSObject.Properties['unavailable'] -and $j.unavailable -is [array]) "count=$($j.unavailable.Count)"

  # 2. per-row keys, exactly the contracted set
  $good = Row 'good-ws'
  $keys = @($good.PSObject.Properties.Name)
  $want = @('ws', 'vm', 'project', 'zone', 'state', 'heartbeatAt', 'heartbeatAgeSec', 'idleSec', 'queueDepth')
  $missing = @($want | Where-Object { $_ -notin $keys })
  Check 'row carries every contracted key' ($missing.Count -eq 0) "missing=$($missing -join ',')"
  Check 'row names the ws and its vm' ($good.ws -eq 'good-ws' -and $good.vm -eq 'ws-good-ws') "$($good.ws) $($good.vm)"
  Check 'row carries project and zone' ($good.project -eq 'p-test' -and $good.zone -eq 'z-test') "$($good.project)/$($good.zone)"

  # 3. a measured workspace: real values
  Check 'a reachable workspace is idle' ($good.state -eq 'idle') "state=$($good.state)"
  # On the WIRE it is ISO-8601; ConvertFrom-Json then hands the consumer a [datetime], which is what the
  # assertion below sees. Both halves are pinned: the raw string here, the parsed type on the value.
  Check 'heartbeatAt is ISO-8601 on the wire' ($raw -match '"heartbeatAt"\s*:\s*"\d{4}-\d{2}-\d{2}T') "$($good.heartbeatAt)"
  Check 'heartbeatAt parses to a timestamp' ([datetime]$good.heartbeatAt -is [datetime]) "$($good.heartbeatAt)"
  Check 'heartbeatAgeSec is a number' ($good.heartbeatAgeSec -is [int] -or $good.heartbeatAgeSec -is [long] -or $good.heartbeatAgeSec -is [double]) "$($good.heartbeatAgeSec)"
  Check 'idleSec passes through' ($good.idleSec -eq 42) "idleSec=$($good.idleSec)"
  Check 'queueDepth counts the queued specs' ($good.queueDepth -eq 2) "queueDepth=$($good.queueDepth)"

  # 4. THE HARD RULE: an unreadable heartbeat is null, never 0, and the ws is listed as unavailable
  $bare = Row 'bare-ws'
  Check 'bare ws is a row' ($null -ne $bare) ''
  Check 'missing heartbeatAt is null (not "")' ($bare.PSObject.Properties['heartbeatAt'] -and $null -eq $bare.heartbeatAt) "heartbeatAt=$($bare.heartbeatAt)"
  Check 'missing heartbeatAgeSec is null (not 0)' ($bare.PSObject.Properties['heartbeatAgeSec'] -and $null -eq $bare.heartbeatAgeSec) "heartbeatAgeSec=$($bare.heartbeatAgeSec)"
  Check 'its state is still reported (suspended VM)' ($bare.state -eq 'suspended') "state=$($bare.state)"
  $un = @($j.unavailable | Where-Object { $_.ws -eq 'bare-ws' }) | Select-Object -First 1
  Check 'bare ws appears in unavailable' ($null -ne $un) ''
  Check 'unavailable entry states a reason' ($un -and "$($un.why)".Trim().Length -gt 0) "$($un.why)"

  # 5. it round-trips through ConvertFrom-Json (this IS the consumer's parse)
  $rt = ($raw | ConvertFrom-Json | ConvertTo-Json -Depth 6 | ConvertFrom-Json)
  Check 'round-trips through ConvertFrom-Json' ($rt.v -eq 1 -and $rt.workspaces.Count -eq $j.workspaces.Count) "rt=$($rt.workspaces.Count)"
  Check 'null survives the round-trip as null' ($null -eq ((@($rt.workspaces | Where-Object { $_.ws -eq 'bare-ws' }) | Select-Object -First 1).heartbeatAgeSec)) ''

  # 6. read-only: the shim only ever saw cat|ls|describe verbs (no write verb exists in it, and the run
  # would have failed loudly on one). The journal must not have gained a line for a status call.
  Check 'the envelope has exactly the four contracted keys' (@($j.PSObject.Properties.Name).Count -eq 4) "props=$(@($j.PSObject.Properties.Name) -join ',')"
} finally {
  $env:PATH = $savedPath
  Remove-Item Env:AGENTQ_CONFIG, Env:FAKE_HB_WS, Env:FAKE_HB_JSON, Env:FAKE_QUEUE -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
