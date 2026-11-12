# ADR 0009 stage 0 (OQ-010): ps/install.ps1 installs every mapped file byte for byte (hook-pre.ps1 and
# its suite included), MERGES agentq-config.json instead of replacing it, records what it installed, and
# reports drift. Runs against a throwaway destination (AGENTQ_INSTALL_DIR); the live folder is never
# written. -SkipTests on every call: this suite tests the installer, not the suites it would gate on.
param([string]$Src = (Join-Path $PSScriptRoot '..'))
$ErrorActionPreference = 'Stop'
$Src = (Resolve-Path $Src).Path
$installer = Join-Path $Src 'install.ps1'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aqin-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$dst = Join-Path $tmp 'dst'
New-Item -ItemType Directory -Force $dst | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function Install([string]$from, [string[]]$more) {
  $env:AGENTQ_INSTALL_DIR = $dst
  try { $o = @(& pwsh -NoProfile -File (Join-Path $from 'install.ps1') @more 2>&1 | ForEach-Object { "$_" }) } finally { Remove-Item Env:AGENTQ_INSTALL_DIR -ErrorAction SilentlyContinue }
  $script:code = $LASTEXITCODE
  $o -join "`n"
}
function Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
# The map, read from the installer text: 'source' = 'destination' pairs inside the $map block.
$text = [IO.File]::ReadAllText($installer)
$block = [regex]::Match($text, '(?s)\$map = \[ordered\]@\{(.*?)\r?\n\}').Groups[1].Value
$map = [ordered]@{}
foreach ($m in [regex]::Matches($block, "'([^']+)'\s*=\s*'([^']+)'")) { $map[$m.Groups[1].Value] = $m.Groups[2].Value }
$cfgKey = 'bin\agentq-config.json'
$live = Join-Path $env:USERPROFILE '.copilot\bin\agentq-config.json'
$liveStamp = if (Test-Path -LiteralPath $live) { (Get-Item -LiteralPath $live).LastWriteTimeUtc.Ticks } else { 0 }
try {
  Check '0 the map was read from the installer' ($map.Count -ge 60 -and $map.Contains($cfgKey)) "pairs=$($map.Count)"
  Check '0 hook-pre.ps1 and its suite are in the map (they lived only in the installed folder before)' ($map['hooks\hook-pre.ps1'] -eq 'hooks\hook-pre.ps1' -and $map['tests\test-hook-pre.ps1'] -eq 'hooks\test-hook-pre.ps1')
  $missing = @($map.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Src $_)) })
  Check '0 every mapped source file exists in this checkout' ($missing.Count -eq 0) ($missing -join ', ')

  # 1. fresh destination: everything lands, byte for byte
  $o = Install $Src @('-SkipTests')
  Check '1 install into an empty folder exits 0' ($code -eq 0) $o
  $diff = @($map.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $dst $map[$_])) -or (Sha (Join-Path $Src $_)) -ne (Sha (Join-Path $dst $map[$_])) })
  Check '1 every installed copy is byte-equal to the repository copy' ($diff.Count -eq 0) ($diff -join ', ')
  Check '1 hook-pre.ps1 installed byte-equal' ((Sha (Join-Path $Src 'hooks\hook-pre.ps1')) -eq (Sha (Join-Path $dst 'hooks\hook-pre.ps1')))
  $o = Install $Src @('-Check')
  Check '1 -Check right after: in sync, exit 0' ($code -eq 0 -and $o -match 'in sync') $o
  $o = Install $Src @('-SkipTests')
  Check '1 a second install changes nothing (0 files)' ($code -eq 0 -and $o -match 'install: 0 file') $o

  # 2. the record of what was installed
  $mf = Get-Content -LiteralPath (Join-Path $dst 'bin\agentq-install.json') -Raw | ConvertFrom-Json
  $bad = @($mf.files.PSObject.Properties | Where-Object { (Sha (Join-Path $dst $_.Name)) -ne $_.Value })
  Check '2 manifest: source folder, time, and a SHA-256 per installed file that matches the file' ($mf.src -eq $Src -and $mf.at -and @($mf.files.PSObject.Properties).Count -eq ($map.Count - 1) -and $bad.Count -eq 0) "files=$(@($mf.files.PSObject.Properties).Count) bad=$($bad.Count)"
  Check '2 manifest leaves the config out (a local override is not drift)' (-not $mf.files.PSObject.Properties['bin\agentq-config.json'])

  # 3. the config is merged: local values stay, missing keys are added, nothing is dropped
  $cfgDst = Join-Path $dst 'bin\agentq-config.json'
  $c = Get-Content -LiteralPath $cfgDst -Raw | ConvertFrom-Json -AsHashtable
  $srcCfg = Get-Content -LiteralPath (Join-Path $Src $cfgKey) -Raw | ConvertFrom-Json -AsHashtable
  $dropKey = @($srcCfg.Keys | Where-Object { $_ -ne 'taskSlotsMachine' })[-1]
  $c['taskSlotsMachine'] = 99; $c['localOnly'] = @{ kept = $true }; $c.Remove($dropKey)
  [IO.File]::WriteAllText($cfgDst, ($c | ConvertTo-Json -Depth 8))
  $o = Install $Src @('-Check')
  Check '3 a key missing from the installed config is reported as drift (config only)' ($code -eq 1 -and $o -match 'DRIFT: bin\\agentq-config\.json\s*$') $o
  $o = Install $Src @('-SkipTests')
  $c2 = Get-Content -LiteralPath $cfgDst -Raw | ConvertFrom-Json -AsHashtable
  Check '3 install adds the missing key from the checkout' ($code -eq 0 -and $c2.ContainsKey($dropKey) -and (($c2[$dropKey] | ConvertTo-Json -Depth 8 -Compress) -eq ($srcCfg[$dropKey] | ConvertTo-Json -Depth 8 -Compress)) -and $o -match "merged .*added $([regex]::Escape($dropKey))") $o
  Check '3 a local value is kept (slot caps were silently shrunk by an install twice)' ($c2['taskSlotsMachine'] -eq 99)
  Check '3 a key only the installed copy has is kept' ($c2.ContainsKey('localOnly') -and $c2['localOnly']['kept'] -eq $true)
  $bk = @(Get-ChildItem -LiteralPath (Join-Path $dst '.backup') -Directory | Sort-Object Name)[-1]
  Check '3 the previous config is in the backup folder' ((Test-Path -LiteralPath (Join-Path $bk.FullName 'bin\agentq-config.json')) -and (Get-Content -LiteralPath (Join-Path $bk.FullName 'bin\agentq-config.json') -Raw) -match '"taskSlotsMachine":\s*99')
  $o = Install $Src @('-Check')
  Check '3 a config that only differs in local values is in sync' ($code -eq 0 -and $o -match 'in sync') $o

  # 4. a hand-edited installed file: reported, restored, the edit kept in the backup
  Start-Sleep -Milliseconds 1100   # backup folders are named to the second
  $victim = Join-Path $dst 'hooks\hook-pre.ps1'
  Add-Content -LiteralPath $victim -Value '# edited by hand'
  $o = Install $Src @('-Check')
  Check '4 a hand edit of an installed file is reported as drift' ($code -eq 1 -and $o -match 'hooks\\hook-pre\.ps1') $o
  $o = Install $Src @('-SkipTests')
  Check '4 install restores it byte-equal' ($code -eq 0 -and (Sha $victim) -eq (Sha (Join-Path $Src 'hooks\hook-pre.ps1')) -and $o -match 'installed hooks\\hook-pre\.ps1') $o
  $bk = @(Get-ChildItem -LiteralPath (Join-Path $dst '.backup') -Directory | Sort-Object Name)[-1]
  Check '4 the edited copy is in the backup folder' ((Test-Path -LiteralPath (Join-Path $bk.FullName 'hooks\hook-pre.ps1')) -and (Get-Content -LiteralPath (Join-Path $bk.FullName 'hooks\hook-pre.ps1') -Raw) -match 'edited by hand')
  Check '4 no half-written file is left behind' (@(Get-ChildItem -LiteralPath $dst -Recurse -File -Filter '*.new').Count -eq 0)

  # 4b. upgrade order: a file the destination lacks is copied before any existing file is replaced
  Start-Sleep -Milliseconds 1100
  Remove-Item -LiteralPath (Join-Path $dst 'bin\agentq-probe.ps1')
  Add-Content -LiteralPath (Join-Path $dst 'bin\agentq.ps1') -Value '# older copy'
  $o = Install $Src @('-SkipTests')
  $iNew = $o.IndexOf('installed bin\agentq-probe.ps1'); $iOld = $o.IndexOf('installed bin\agentq.ps1')
  Check '4b a missing companion file is installed before agentq.ps1 is replaced' ($code -eq 0 -and $iNew -ge 0 -and $iOld -gt $iNew) $o

  # 5. a checkout that lacks a mapped file refuses before copying anything
  $copy = Join-Path $tmp 'ps'
  Copy-Item -LiteralPath $Src -Destination $copy -Recurse
  Remove-Item -LiteralPath (Join-Path $copy 'bin\wait-job.ps1')
  $dst2 = Join-Path $tmp 'dst2'; New-Item -ItemType Directory -Force $dst2 | Out-Null
  $keep = $dst; $dst = $dst2
  $o = Install $copy @('-SkipTests')
  $dst = $keep
  Check '5 a mapped file missing from the checkout stops the install' ($code -ne 0 -and $o -match 'is in the map but not in this checkout') $o
  Check '5 ... and nothing was copied' (@(Get-ChildItem -LiteralPath $dst2 -Recurse -File).Count -eq 0)

  # 6. the live folder was never the destination
  $now = if (Test-Path -LiteralPath $live) { (Get-Item -LiteralPath $live).LastWriteTimeUtc.Ticks } else { 0 }
  Check '6 the live config was not written by this suite' ($now -eq $liveStamp)
} finally {
  Remove-Item Env:AGENTQ_INSTALL_DIR -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
