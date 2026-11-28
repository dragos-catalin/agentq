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
# Snapshot the checkout and install FROM THE SNAPSHOT: every check here compares the installed bytes to
# the source it copied from, so an external writer touching ps/ mid-suite (another agent, an autosync, a
# hook) made the suite fail with a drift that does not exist (2026-11-20: 3 FAILs in a parallel run,
# green alone). The copy is what the installer reads, so the semantics are unchanged.
$liveSrc = $Src
$Src = Join-Path $tmp 'src'
Copy-Item -LiteralPath $liveSrc -Destination $Src -Recurse -Force
$installer = Join-Path $Src 'install.ps1'
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

  # 3b. a NESTED key inside a map the installed config already has - the landGate case (2026-11-21):
  # a top-level-only merge kept the installed `landGate` value and silently dropped a new per-repo entry
  # from the checkout, so the live config never carried codai's gate. Mutation: make Merge-ConfigMap
  # non-recursive and this Check goes red.
  $cg = Get-Content -LiteralPath $cfgDst -Raw | ConvertFrom-Json -AsHashtable
  $cg['landGate'] = @{ keepme = 'local' }
  [IO.File]::WriteAllText($cfgDst, ($cg | ConvertTo-Json -Depth 8))
  $o = Install $Src @('-SkipTests')
  $cg2 = Get-Content -LiteralPath $cfgDst -Raw | ConvertFrom-Json -AsHashtable
  Check '3b a nested key the installed map lacks is added from the checkout' ($code -eq 0 -and $cg2['landGate']['keepme'] -eq 'local' -and $cg2['landGate'].Count -eq ($srcCfg['landGate'].Count + 1) -and $o -match 'added landGate\.') $o

  # 3d. an EXISTING nested key whose VALUE the checkout CHANGED - the landGate case (2026-11-25). A land
  # gate is a repo policy, not a machine value, so the checkout owns it. Installed-wins made a gate change
  # undeliverable twice over: the value was kept AND, because the merge reported only ADDED keys, the
  # merged text was discarded and the live file was not even rewritten. Mutation: put the generic
  # `$o[$k] = Merge-ConfigMap $path $tv $fv` branch back in front of the landGate one and this Check goes
  # red (measured: it does).
  $cl = Get-Content -LiteralPath $cfgDst -Raw | ConvertFrom-Json -AsHashtable
  $clRepo = @($srcCfg['landGate'].Keys)[0]
  $clOld = "$($cl['landGate'][$clRepo])"
  $cl['landGate'][$clRepo] = 'a stale gate the checkout disagrees with'
  [IO.File]::WriteAllText($cfgDst, ($cl | ConvertTo-Json -Depth 8))
  $o = Install $Src @('-SkipTests')
  $cl2 = Get-Content -LiteralPath $cfgDst -Raw | ConvertFrom-Json -AsHashtable
  Check "3d a landGate value the checkout changed replaces the installed one (checkout owns the gate)" ($code -eq 0 -and "$($cl2['landGate'][$clRepo])" -eq "$($srcCfg['landGate'][$clRepo])" -and "$($cl2['landGate'][$clRepo])" -ne 'a stale gate the checkout disagrees with' -and $o -match [regex]::Escape("changed landGate.$clRepo = $($srcCfg['landGate'][$clRepo])")) "${clRepo}: was '$clOld' -> '$($cl2['landGate'][$clRepo])' || $o"
  Check '3d a landGate repo only the installed copy names is still kept' ($cl2['landGate']['keepme'] -eq 'local')
  Check '3d the gate fix is in sync afterwards (a re-install changes nothing)' ((Install $Src @('-Check')) -match 'in sync')

  # 3c. an ARRAY the installed config already has must GROW. Treating a list as a scalar ("the installed
  # copy wins") means a new list item never reaches the live config: 2026-11-23 the checkout's
  # `gateSuites.agentq` went from 17 to 25 names, the merge kept the installed 17, and the gate therefore
  # ran without the six land suites - a land-engine change could land behind a gate that never exercised
  # the land engine. Mutation: drop the array branch in Merge-ConfigMap and this Check goes red.
  $ca = Get-Content -LiteralPath $cfgDst -Raw | ConvertFrom-Json -AsHashtable
  $ga = @($srcCfg['gateSuites']['agentq'])
  $ca['gateSuites']['agentq'] = @(@($ga)[0], @($ga)[1]) + @('suite only the local copy has')
  [IO.File]::WriteAllText($cfgDst, ($ca | ConvertTo-Json -Depth 8))
  $o = Install $Src @('-SkipTests')
  $ca2 = Get-Content -LiteralPath $cfgDst -Raw | ConvertFrom-Json -AsHashtable
  $got = @($ca2['gateSuites']['agentq'])
  Check '3c an installed array gains the checkout items, keeping its own and its order' ($code -eq 0 -and $got.Count -eq ($ga.Count + 1) -and $got[0] -eq $ga[0] -and $got[1] -eq $ga[1] -and ($got -contains 'suite only the local copy has') -and $got[-1] -eq $ga[-1] -and $o -match 'gateSuites\.agentq \+=') "count=$($got.Count) got=$($got -join ', ') || $o"
  Check '3c the union is in sync afterwards (a re-install changes nothing)' ((Install $Src @('-Check')) -match 'in sync')

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

  # 4a. a SOURCE file that carries a Zone.Identifier ("downloaded from the Internet") must not leave the
  # installed copy un-runnable: Copy-Item preserves alternate data streams, so without an Unblock-File the
  # live copy fails with "cannot be loaded ... is not digitally signed" under RemoteSigned and the daemon
  # silently never starts (2026-11-20, live git-autosync.ps1). Mutation: drop the Unblock-File in
  # install.ps1 and the second Check below goes red.
  Start-Sleep -Milliseconds 1100
  $motwSrc = Join-Path $Src 'hooks\hook-pre.ps1'
  [IO.File]::WriteAllText("$motwSrc`:Zone.Identifier", "[ZoneTransfer]`r`nZoneId=3`r`n")
  Add-Content -LiteralPath $victim -Value '# edited again'
  $o = Install $Src @('-SkipTests')
  Check '4a the MOTW source is installed (drift seen)' ($code -eq 0 -and $o -match 'installed hooks\\hook-pre\.ps1') $o
  $unblocked = -not (Get-Item -LiteralPath $victim -Stream Zone.Identifier -ErrorAction SilentlyContinue)
  Check '4a the installed copy has NO Zone.Identifier (it must be runnable)' $unblocked

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

  # 7. the green-record freshness read (the "install: tests SKIPPED" path). A full green run of the
  # same ps/ content must not be paid for twice: 45 suites are ~36 min, the skip is ~2 s. `at` is an
  # ISO-8601 string in the file and a [datetime] after ConvertFrom-Json, and stringifying a [datetime]
  # uses the MACHINE's culture: with `Get-Date "$($g.at)"` the skip silently never fired outside
  # en-US (2026-11-21: 36 min for a byte-identical tree). The helper is read from the installer text,
  # like the map above, so this fails if it is removed or made culture-dependent again.
  $gblock = [regex]::Match($text, '(?s)# --- green record freshness \(begin\).*?# --- green record freshness \(end\) ---').Value
  Check '7 the freshness helper is in the installer' ($gblock -match 'function Test-GreenRecordFresh')
  if ($gblock) { Invoke-Expression $gblock }
  $gf = Join-Path $tmp 'last-green.json'
  $keepCulture = [Threading.Thread]::CurrentThread.CurrentCulture
  try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('ro-RO')
    [IO.File]::WriteAllText($gf, ('{"hash":"sha256:x","at":"' + (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss') + '","suites":45,"sec":10}'))
    Check '7a a record from seconds ago is fresh under a non-US culture (ro-RO)' ((Test-GreenRecordFresh $gf 24) -eq $true)
    [IO.File]::WriteAllText($gf, ('{"hash":"sha256:x","at":"' + (Get-Date).AddHours(-30).ToString('yyyy-MM-ddTHH:mm:ss') + '"}'))
    Check '7b a record older than MaxHours is stale' ((Test-GreenRecordFresh $gf 24) -eq $false)
    [IO.File]::WriteAllText($gf, '{"hash":"sha256:x","at":"not-a-date"}')
    Check '7c an unreadable time is not fresh (fail closed)' ((Test-GreenRecordFresh $gf 24) -eq $false)
  } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $keepCulture }
  Check '7d a missing record is not fresh' ((Test-GreenRecordFresh (Join-Path $tmp 'nope.json') 24) -eq $false)
  Check '7e the installer calls the helper instead of parsing $g.at inline' ($text -match 'Test-GreenRecordFresh \$gf')

  # 6. the live folder was never the destination
  $now = if (Test-Path -LiteralPath $live) { (Get-Item -LiteralPath $live).LastWriteTimeUtc.Ticks } else { 0 }
  Check '6 the live config was not written by this suite' ($now -eq $liveStamp)

  # 8. the install gate ANNOUNCES itself (2026-11-28). Three concurrent installs once waited 17 min,
  #    1,9 h and 2,5 h on `Global\agentq-install-gate` and printed nothing at all: the single line about
  #    the gate came after the wait, so a wedged holder looked exactly like a wedged install. This is a
  #    protocol, not cosmetics - a line BEFORE the wait, a cap in minutes, the holder marker, and the
  #    marker removed on the way out. The suite installs with -SkipTests, so the block is pinned by text
  #    (the same shape as 7e).
  $waitIdx = $text.IndexOf('$gotGate = $gate.WaitOne(')
  $sayIdx = $text.IndexOf('Format-InstallGateWait -WaitMin')
  Check '8a the waiter says it is waiting BEFORE it waits' (($waitIdx -gt 0) -and ($sayIdx -gt 0) -and ($sayIdx -lt $waitIdx))
  Check '8b the wait is capped in minutes, not 45 of them' (($text -match 'Get-InstallGateWaitMin') -and (-not ($text -match '\$gate\.WaitOne\(45 \* 60 \* 1000\)')))
  $capFn = [regex]::Match($text, '(?s)function Get-InstallGateWaitMin \{.*?\n\}').Value
  Check '8c the cap is 12 min and can never drop under 3 (pure helper)' (($capFn -match '\$CapMin = 12') -and ($capFn -match 'if \(\$CapMin -lt 3\) \{ return 3 \}'))
  Check '8d the waiter names the holder from the published marker' ($text.Contains('agentq-install-gate.holder.json') -and $text.Contains('Format-InstallGateWait -WaitMin $waitMin -Holder $holder'))
  Check '8e the holder publishes the marker and removes it on release' ($text.Contains('[IO.File]::WriteAllText("$gateMarker.new"') -and $text.Contains('Remove-Item -LiteralPath $gateMarker'))
  Check '8f the wait is reported with its real duration' ($text.Contains('install gate acquired after $waitedSec s of waiting'))
  Check '8g a dead holder is treated as acquired, not as an error' ($text.Contains('catch [System.Threading.AbandonedMutexException]') -and $text.Contains('the previous holder died without releasing it'))
} finally {
  Remove-Item Env:AGENTQ_INSTALL_DIR -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
