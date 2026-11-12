# ADR 0009 stage 0 (OQ-011): `agentq doctor` - a READ-ONLY health report (stale index locks, empty
# package-store folders, install/config drift, dead lease owners, dead jobs and keepers, old marks,
# state size). Every case asserts the row AND the exit code. Isolated in %TEMP%; the installed copy and
# the source checkout are fakes (AGENTQ_INSTALL_DIR, -Src), scheduled tasks are skipped.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqdr-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$coord = Join-Path $tmp 'coord'; $wt = Join-Path $tmp 'wt'; $inst = Join-Path $tmp 'inst'; $srcPs = Join-Path $tmp 'src\ps'
$cfg = Join-Path $tmp 'cfg.json'
$envSet = 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_REGISTRY', 'AGENTQ_SESSION', 'AGENTQ_INSTALL_DIR', 'AGENTQ_DOCTOR_NO_TASKS'
$env:AGENTQ_HOME = $coord
$env:CODAI_WT_ROOT = $wt
$env:AGENTQ_CONFIG = $cfg
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_SESSION = 'test-doctor'
$env:AGENTQ_INSTALL_DIR = $inst
$env:AGENTQ_DOCTOR_NO_TASKS = '1'
foreach ($v in 'AGENTQ_SRC', 'AGENTQ_DOCTOR_FAULT', 'AGENTQ_DOCTOR_SERIAL', 'AGENTQ_SYSTEM_HOME') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfgText = '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"minFreeCommitGB":0}'
[IO.File]::WriteAllText($cfg, $cfgText)
$fail = 0
$script:code = 0; $script:raw = ''
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
# doctor -Json -> the report object (rows are asserted on); $script:raw keeps the text for failure output
function DJ {
  $script:raw = AQ doctor -Json @args
  $line = @($script:raw -split "`n" | Where-Object { $_ -match '^\{.*"rows"' }) | Select-Object -Last 1
  if ($line) { $line | ConvertFrom-Json } else { $null }
}
function Rows($rep, [string]$check, [string]$status) { if (-not $rep) { return @() }; @($rep.rows | Where-Object { $_.check -eq $check -and $_.status -eq $status -and $_.kind -ne 'summary' }) }
function Put([string]$file, [string]$text) { [IO.Directory]::CreateDirectory((Split-Path -Parent $file)) | Out-Null; [IO.File]::WriteAllText($file, $text) }
function Sha([string]$file) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
function Ago([double]$min) { [DateTime]::UtcNow.AddMinutes(-$min) }
function Get-DeadPid { for ($c = 4194300; $c -gt 1000; $c -= 4) { if (-not (Get-Process -Id $c -ErrorAction SilentlyContinue)) { return $c } }; throw 'no free pid' }

# ---- fixtures --------------------------------------------------------------------------------
$coreSrc = [ordered]@{ 'bin\agentq.ps1' = "# core A`n"; 'bin\agentq-v2.ps1' = "# core B`n"; 'hooks\run-build.ps1' = "# hook C`n" }
$cfgSrc = '{"machineCap":2,"journalRotateMB":64,"pinned":{"alpha":["one"]}}'
function Write-Manifest {
  $files = [ordered]@{}
  foreach ($rel in @($coreSrc.Keys) + 'bin\agentq-config.json') { $files[$rel] = Sha (Join-Path $inst $rel) }
  # a hash in lower case must still match (the installer's casing is its own business)
  $files['bin\agentq.ps1'] = $files['bin\agentq.ps1'].ToLowerInvariant()
  Put (Join-Path $inst 'bin\agentq-install.json') ([ordered]@{ src = $srcPs; sha = ''; at = [DateTime]::UtcNow.ToString('o'); files = $files } | ConvertTo-Json)
}
# Clean state: empty coord, no slots, installed copy == source checkout == manifest.
function Reset-State {
  foreach ($d in $coord, $wt, $inst, (Join-Path $tmp 'src'), (Join-Path $tmp 'gd')) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
  # a state folder that has been used before: agentq creates these four on any first call
  foreach ($d in $coord, $wt, (Join-Path $coord 'queues'), (Join-Path $coord 'marks'), (Join-Path $coord 'leases'), (Join-Path $coord 'releases')) { New-Item -ItemType Directory -Force $d | Out-Null }
  foreach ($rel in $coreSrc.Keys) { Put (Join-Path $srcPs $rel) $coreSrc[$rel]; Put (Join-Path $inst $rel) $coreSrc[$rel] }
  Put (Join-Path $srcPs 'bin\agentq-config.json') $cfgSrc; Put (Join-Path $inst 'bin\agentq-config.json') $cfgSrc
  Write-Manifest
  [IO.File]::WriteAllText($cfg, $cfgText)
}
# A worktree slot: <wt>\<repo>\<slot>\.git is a FILE naming the gitdir. Returns the gitdir.
function New-FakeSlot([string]$repoName, [string]$slot) {
  $sp = Join-Path $wt "$repoName\$slot"; $gd = Join-Path $tmp "gd\$repoName\$slot"
  [IO.Directory]::CreateDirectory($sp) | Out-Null; [IO.Directory]::CreateDirectory($gd) | Out-Null
  Put (Join-Path $sp '.git') "gitdir: $gd`n"
  $gd
}
function New-Lock([string]$gitDir, [double]$ageMin) { $l = Join-Path $gitDir 'index.lock'; [IO.File]::WriteAllText($l, ''); [IO.File]::SetLastWriteTimeUtc($l, (Ago $ageMin)); $l }
# node_modules\.pnpm\<entry>\node_modules\<name>; $state = ok | empty | nopkg | nodir
function New-StoreEntry([string]$slotPath, [string]$entry, [string]$pkgRel, [string]$state) {
  $nm = Join-Path $slotPath "node_modules\.pnpm\$entry\node_modules"
  [IO.Directory]::CreateDirectory($nm) | Out-Null
  if ($state -eq 'nodir') { return }
  $pd = Join-Path $nm $pkgRel; [IO.Directory]::CreateDirectory($pd) | Out-Null
  if ($state -eq 'ok') { Put (Join-Path $pd 'package.json') '{"name":"x"}' }
  if ($state -eq 'nopkg') { Put (Join-Path $pd 'index.js') '' }
}
# The fields a real lease has (New-Lease in agentq-v2.ps1) + the .hb heartbeat file.
function New-FakeLease([string]$slot, [int]$ownerPid, [double]$idleMin) {
  $sp = Join-Path $wt "repo\$slot"; [IO.Directory]::CreateDirectory($sp) | Out-Null
  $f = Join-Path $coord "leases\repo\$slot.json"
  Put $f ([ordered]@{ leaseId = "l-$slot"; repo = 'repo'; slot = $slot; role = 'task'; path = $sp; branch = ''; purpose = 'fixture lease'; session = 'sess-a'
      pid = $ownerPid; procStart = $null; created = (Ago ($idleMin + 5)).ToString('o'); host = 'test'; claims = @() } | ConvertTo-Json)
  [IO.File]::WriteAllText("$f.hb", ''); [IO.File]::SetLastWriteTimeUtc("$f.hb", (Ago $idleMin))
  $f
}
function New-FakeJob([string]$id, [hashtable]$fields) {
  $j = @{ id = $id; state = 'running'; pid = 0; label = 'fixture job'; command = 'pnpm test'; cwd = $tmp; log = (Join-Path $tmp 'none.log') }
  foreach ($k in $fields.Keys) { $j[$k] = $fields[$k] }
  $f = Join-Path $coord "jobs\$id.json"; Put $f ($j | ConvertTo-Json); $f
}
function New-FakeMark([string]$res, [double]$ageDays) {
  Put (Join-Path $coord ("marks\" + ($res -replace '[^A-Za-z0-9._-]', '_') + '.json')) ([ordered]@{ resource = $res; state = 'frozen'; reason = 'incident drill'; session = 'sess-a'; at = (Ago ($ageDays * 1440)).ToString('o') } | ConvertTo-Json)
}
# Everything under $dir: relative path + SHA256 + LastWriteTimeUtc ticks (directories by name).
function Get-TreeState([string]$dir) {
  @(Get-ChildItem -LiteralPath $dir -Recurse -Force | Sort-Object FullName | ForEach-Object {
      $rel = $_.FullName.Substring($dir.Length)
      if ($_.PSIsContainer) { "D $rel" } else { "F $rel $((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash) $($_.LastWriteTimeUtc.Ticks)" }
    })
}

$deadPid = Get-DeadPid
$gitProc = $null
Push-Location $tmp
try {
  # ---- 1 clean state -----------------------------------------------------------------------
  Reset-State
  $o = AQ doctor -All
  Check '1 clean: exit 0' ($code -eq 0) $o
  Check '1 clean: last line counts' (@($o -split "`n")[-1] -eq 'doctor: 0 problem(s), 0 warning(s)') $o
  Check '1 clean: one ok line per check' ($o -match '(?m)^ok\s+stale-index-lock\s+0 slot\(s\) checked' -and $o -match '(?m)^ok\s+empty-package-store' -and $o -match '(?m)^ok\s+install-drift' -and $o -match '(?m)^ok\s+config-drift' -and $o -match '(?m)^ok\s+dead-owner' -and $o -match '(?m)^ok\s+dead-keeper' -and $o -match '(?m)^ok\s+marks' -and $o -match '(?m)^ok\s+state-size' -and $o -match '(?m)^ok\s+scheduled-tasks\s+skipped') $o
  Check '1 clean: no FAIL / warn line' ($o -notmatch '(?m)^(FAIL|warn)\b') $o

  # ---- 2 stale index.lock ------------------------------------------------------------------
  Reset-State
  $gd1 = New-FakeSlot 'repo' 'task-1'; $gd2 = New-FakeSlot 'repo' 'task-2'; $gd3 = New-FakeSlot 'repo' 'task-3'
  $null = New-Lock $gd1 10      # stale
  $null = New-Lock $gd2 0       # a git command that is running right now
  $r = DJ -All
  $rows = Rows $r 'stale-index-lock' 'fail'
  Check '2 lock aged 10 min reported' ($rows.Count -eq 1 -and $rows[0].subject -eq 'repo/task-1' -and $rows[0].detail -match 'index\.lock' -and $rows[0].hint -match 'lease') $raw
  Check '2 fresh lock not reported' (@($rows | Where-Object { $_.subject -eq 'repo/task-2' }).Count -eq 0) $raw
  Check '2 exit 1, 1 problem' ($code -eq 1 -and $r.problems -eq 1) $raw
  $o = AQ doctor -All
  Check '2 human: FAIL row + count + exit 1' ($code -eq 1 -and $o -match '(?m)^FAIL\s+stale-index-lock\s+repo/task-1' -and $o -match 'doctor: 1 problem\(s\), 0 warning\(s\)' -and $o -match '3 slot\(s\) checked') $o
  # an old lock while a git process works on that slot is not stale
  $null = New-Lock $gd3 10
  $psi = [Diagnostics.ProcessStartInfo]::new('git'); $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = $tmp
  foreach ($a in 'hash-object', '--stdin', '--path', (Join-Path $wt 'repo\task-3\file.txt')) { $psi.ArgumentList.Add($a) }
  $gitProc = [Diagnostics.Process]::Start($psi)   # waits on stdin until killed
  Start-Sleep -Milliseconds 700
  $r = DJ -All
  $rows = Rows $r 'stale-index-lock' 'fail'
  Check '2 old lock + git process on the slot: not reported' (-not $gitProc.HasExited -and $rows.Count -eq 1 -and $rows[0].subject -eq 'repo/task-1') $raw
  try { $gitProc.Kill($true) } catch {}; $gitProc.WaitForExit(5000) | Out-Null; $gitProc = $null
  $r = DJ -All
  Check '2 same lock once the git process is gone: reported' (@(Rows $r 'stale-index-lock' 'fail').Count -eq 2 -and $code -eq 1) $raw

  # ---- 3 empty package store -----------------------------------------------------------------
  Reset-State
  $null = New-FakeSlot 'repo' 'task-1'; $sp = Join-Path $wt 'repo\task-1'
  New-StoreEntry $sp '@scope+pkg@1.0.0_x' '@scope\pkg' 'ok'
  New-StoreEntry $sp 'plain@2.0.0' 'plain' 'ok'
  New-StoreEntry $sp 'under_score@1.3.0' 'under_score' 'ok'                     # '_' inside the NAME
  New-StoreEntry $sp '@scope+core@7.0.0_@types+node@20.0.0' '@scope\core' 'ok'  # '@' inside the peer suffix
  New-StoreEntry $sp 'hollow@4.5.0' 'hollow' 'empty'
  New-StoreEntry $sp '@scope+half@6.3.0_abc' '@scope\half' 'nopkg'
  [IO.Directory]::CreateDirectory((Join-Path $sp 'node_modules\.pnpm\node_modules\.bin')) | Out-Null
  [IO.Directory]::CreateDirectory((Join-Path $sp 'node_modules\.pnpm\.cache')) | Out-Null
  Put (Join-Path $sp 'node_modules\.pnpm\lock.yaml') 'lockfileVersion: 9'
  $r = DJ -All
  $rows = Rows $r 'empty-package-store' 'fail'
  $subjects = @($rows | ForEach-Object { $_.subject } | Sort-Object)
  Check '3 exactly the two broken entries' ($rows.Count -eq 2 -and ($subjects -join '|') -eq 'repo/task-1 @scope+half@6.3.0_abc|repo/task-1 hollow@4.5.0') $raw
  Check '3 detail names the package directory, hint the install' (@($rows | Where-Object { $_.detail -match 'no package\.json' -and $_.hint -match 'frozen install' }).Count -eq 2) $raw
  Check '3 exit 1, 2 problems' ($code -eq 1 -and $r.problems -eq 2) $raw
  # a missing package directory, and the cap of 20 rows per slot
  $null = New-FakeSlot 'repo' 'task-2'; $sp2 = Join-Path $wt 'repo\task-2'
  1..23 | ForEach-Object { New-StoreEntry $sp2 "gone$_@1.0.0" "gone$_" 'nodir' }
  $r = DJ -All
  $rows2 = @(Rows $r 'empty-package-store' 'fail' | Where-Object { $_.subject -like 'repo/task-2*' })
  Check '3 23 broken entries -> 20 rows + "+3 more"' ($rows2.Count -eq 21 -and @($rows2 | Where-Object { $_.detail -match '^\+3 more' }).Count -eq 1 -and @($rows2 | Where-Object { $_.detail -match 'package directory is missing' }).Count -eq 20) $raw
  # several slots: each finding carries its own slot and the exact package directory
  foreach ($n in 3, 4, 5) { $null = New-FakeSlot 'repo' "task-$n"; New-StoreEntry (Join-Path $wt "repo\task-$n") 'plain@2.0.0' 'plain' 'ok'; New-StoreEntry (Join-Path $wt "repo\task-$n") "void$n@1.0.0" "void$n" 'empty' }
  # entries that are not npm packages (no version, an old git entry) are skipped, not reported
  [IO.Directory]::CreateDirectory((Join-Path $wt 'repo\task-3\node_modules\.pnpm\noversion')) | Out-Null
  [IO.Directory]::CreateDirectory((Join-Path $wt 'repo\task-3\node_modules\.pnpm\host+user+thing@abcdef')) | Out-Null
  $r = DJ -All
  $all = Rows $r 'empty-package-store' 'fail'
  $want = Join-Path $wt 'repo\task-4\node_modules\.pnpm\void4@1.0.0\node_modules\void4'
  Check '3 five slots: 2 + 21 + 3 rows, exit 1' ($all.Count -eq 26 -and $code -eq 1 -and $r.problems -eq 26) $raw
  Check '3 row names slot, entry and the exact package directory' (@($all | Where-Object { $_.subject -eq 'repo/task-4 void4@1.0.0' -and $_.detail -eq "package directory has no package.json: $want" }).Count -eq 1) $raw
  Check '3 entries that are not npm packages are skipped' (@($all | Where-Object { $_.subject -match 'noversion|host\+user' }).Count -eq 0 -and @($r.rows | Where-Object { $_.check -eq 'empty-package-store' -and $_.kind -eq 'summary' -and $_.detail -match '^35 package entries in 5 slot' }).Count -eq 1) $raw

  # ---- 4 install drift + config drift ----------------------------------------------------------
  Reset-State
  # 4a hand edit of an installed file (manifest hash no longer matches); source unknown
  Put (Join-Path $inst 'bin\agentq-install.json') ((Get-Content (Join-Path $inst 'bin\agentq-install.json') -Raw | ConvertFrom-Json | ForEach-Object { $_.src = ''; $_ }) | ConvertTo-Json)
  Put (Join-Path $inst 'bin\agentq-v2.ps1') "# core B, edited by hand`n"
  $r = DJ -All
  $rows = Rows $r 'install-drift' 'fail'
  Check '4a manifest mismatch -> fail' ($rows.Count -eq 1 -and $rows[0].subject -eq 'bin\agentq-v2.ps1' -and $rows[0].detail -match 'changed after install' -and $code -eq 1) $raw
  Check '4a manifest present: no "source unknown" warning' ($r.warnings -eq 0) $raw
  Remove-Item (Join-Path $inst 'hooks\run-build.ps1')
  $r = DJ -All
  Check '4a file listed in the manifest but gone -> fail' (@(Rows $r 'install-drift' 'fail' | Where-Object { $_.subject -eq 'hooks\run-build.ps1' -and $_.detail -match 'missing' }).Count -eq 1 -and $r.problems -eq 2) $raw
  # 4b the source checkout moved on: one core file differs -> warn, exit 0
  Reset-State
  Put (Join-Path $srcPs 'bin\agentq.ps1') "# core A, newer in the checkout`n"
  $r = DJ -All -Src $srcPs
  $rows = Rows $r 'install-drift' 'warn'
  Check '4b -Src with a differing core file -> warn' ($rows.Count -eq 1 -and $rows[0].subject -eq 'bin\agentq.ps1' -and $rows[0].detail -match 'differs from the source checkout') $raw
  Check '4b warning only: exit 0' ($code -eq 0 -and $r.problems -eq 0 -and $r.warnings -eq 1) $raw
  # 4c config: a new key only in the source -> warn naming it; a different value -> local override, no warning
  Reset-State
  Put (Join-Path $srcPs 'bin\agentq-config.json') '{"machineCap":2,"journalRotateMB":64,"pinned":{"alpha":["one"]},"newKnob":{"a":1}}'
  Put (Join-Path $inst 'bin\agentq-config.json') '{"journalRotateMB":64,"machineCap":4,"pinned":{"alpha":["one"]},"localOnly":true}'
  $r = DJ -All -Src $srcPs
  $rows = Rows $r 'config-drift' 'warn'
  Check '4c new source key -> warn naming the key' ($rows.Count -eq 1 -and $rows[0].subject -eq 'newKnob' -and $rows[0].detail -match 'new key not installed') $raw
  $info = Rows $r 'config-drift' 'ok'
  Check '4c different value -> ONE local-override row' (@($info | Where-Object { $_.subject -eq 'local override' -and $_.detail -eq 'machineCap' }).Count -eq 1) $raw
  Check '4c key only in the installed copy -> one info row' (@($info | Where-Object { $_.subject -eq 'only in the installed copy' -and $_.detail -eq 'localOnly' }).Count -eq 1) $raw
  Check '4c config edited after install is not a problem: exit 0, 1 warning' ($code -eq 0 -and $r.problems -eq 0 -and $r.warnings -eq 1) $raw
  # same keys in another order, nested objects equal -> nothing
  Put (Join-Path $srcPs 'bin\agentq-config.json') '{"pinned":{"alpha":["one"]},"machineCap":2,"journalRotateMB":64}'
  Put (Join-Path $inst 'bin\agentq-config.json') $cfgSrc
  $r = DJ -All -Src $srcPs
  Check '4c key order alone is not drift' ($code -eq 0 -and $r.warnings -eq 0 -and @(Rows $r 'config-drift' 'ok').Count -eq 0) $raw
  # 4d neither a source nor a manifest
  Reset-State
  Remove-Item (Join-Path $inst 'bin\agentq-install.json')
  $r = DJ -All
  $rows = Rows $r 'install-drift' 'warn'
  Check '4d no source, no manifest -> one warn' ($rows.Count -eq 1 -and $rows[0].detail -match 'source checkout unknown: pass -Src' -and $code -eq 0 -and $r.warnings -eq 1) $raw

  # ---- 5 lease with a dead owner ---------------------------------------------------------------
  Reset-State
  $lf = New-FakeLease 'task-2' $deadPid 45
  $r = DJ -All
  $rows = Rows $r 'dead-owner' 'warn'
  Check '5 dead owner idle 45 min -> warn' ($rows.Count -eq 1 -and $rows[0].subject -eq 'repo/task-2' -and $rows[0].detail -match 'owner process gone' -and $rows[0].detail -match 'idle 45 min' -and $rows[0].detail -match 'sess-a' -and $rows[0].detail -match 'fixture lease') $raw
  Check '5 warning only: exit 0' ($code -eq 0 -and $r.problems -eq 0 -and $r.warnings -eq 1) $raw
  [IO.File]::WriteAllText("$lf.chat", '')
  $r = DJ -All
  Check '5 fresh .chat file -> not a warning' ($r.warnings -eq 0 -and $code -eq 0 -and @(Rows $r 'dead-owner' 'ok' | Where-Object { $_.detail -match 'kept alive by a chat' }).Count -eq 1) $raw
  [IO.File]::SetLastWriteTimeUtc("$lf.chat", (Ago 40))
  $r = DJ -All
  Check '5 .chat file 40 min old -> warn again' (@(Rows $r 'dead-owner' 'warn').Count -eq 1) $raw
  Remove-Item "$lf.chat"
  $null = New-FakeLease 'task-2' $deadPid 10
  $r = DJ -All
  Check '5 dead owner idle 10 min -> no row' ($r.warnings -eq 0 -and @(Rows $r 'dead-owner' 'warn').Count -eq 0) $raw
  $null = New-FakeLease 'task-2' $PID 45
  $r = DJ -All
  Check '5 live owner idle 45 min -> no row' ($r.warnings -eq 0 -and @(Rows $r 'dead-owner' 'warn').Count -eq 0) $raw

  # ---- 6 job registry ----------------------------------------------------------------------------
  Reset-State
  $jf = New-FakeJob '20260101-000000-dead' @{ pid = $deadPid; label = 'nightly gate' }
  $null = New-FakeJob '20260101-000001-live' @{ pid = $PID }
  $null = New-FakeJob '20260101-000002-done' @{ pid = $deadPid; state = 'done' }
  $r = DJ -All
  $rows = Rows $r 'dead-keeper' 'fail'
  Check '6 running job with a dead pid -> fail' ($rows.Count -eq 1 -and $rows[0].subject -eq '20260101-000000-dead' -and $rows[0].detail -match 'marked running but its process is gone' -and $rows[0].detail -match 'nightly gate') $raw
  Check '6 exit 1, 1 problem' ($code -eq 1 -and $r.problems -eq 1) $raw
  # a recycled pid (alive, but another start time) is a dead job too
  $null = New-FakeJob '20260101-000003-recycled' @{ pid = $PID; pidStart = 1 }
  $r = DJ -All
  Check '6 live pid with another start time -> fail' (@(Rows $r 'dead-keeper' 'fail' | Where-Object { $_.subject -eq '20260101-000003-recycled' }).Count -eq 1 -and $r.problems -eq 2) $raw
  # job files older than 3 days are not read
  Get-ChildItem (Join-Path $coord 'jobs') -Filter '*.json' | ForEach-Object { [IO.File]::SetLastWriteTimeUtc($_.FullName, (Ago (4 * 1440))) }
  $r = DJ -All
  Check '6 job files older than 3 days are ignored' ($code -eq 0 -and $r.problems -eq 0) $raw
  # 6b a live keeper for a slot nobody leases
  Reset-State
  $null = New-FakeJob '20260101-000004-keep' @{ pid = $PID; label = 'slot keeper'; command = 'pwsh -File keeper.ps1'; cwd = (Join-Path $wt 'repo\task-3') }
  $null = New-FakeJob '20260101-000005-work' @{ pid = $PID; label = 'unit tests'; cwd = (Join-Path $wt 'repo\task-3') }
  $r = DJ -All
  $rows = Rows $r 'dead-keeper' 'warn'
  Check '6b keeper for an unleased slot -> warn with the pid' ($rows.Count -eq 1 -and $rows[0].subject -eq '20260101-000004-keep' -and $rows[0].detail -match 'no longer leased' -and $rows[0].detail -match "pid $PID" -and $code -eq 0) $raw
  $null = New-FakeLease 'task-3' $PID 1
  $r = DJ -All
  Check '6b the same keeper while the slot is leased -> no row' (@(Rows $r 'dead-keeper' 'warn').Count -eq 0 -and $r.warnings -eq 0) $raw

  # ---- 7 marks -----------------------------------------------------------------------------------
  Reset-State
  New-FakeMark 'deploy:repo:api' 8
  New-FakeMark 'build:repo' 1
  $r = DJ -All
  $rows = Rows $r 'marks' 'warn'
  Check '7 mark older than 7 days -> warn' ($rows.Count -eq 1 -and $rows[0].subject -eq 'deploy:repo:api' -and $rows[0].detail -match 'forgotten freeze\?' -and $rows[0].detail -match 'incident drill') $raw
  Check '7 warning only: exit 0' ($code -eq 0 -and $r.problems -eq 0 -and $r.warnings -eq 1) $raw

  # ---- 8 + 9 -Json equals the human report; nothing is written -----------------------------------
  Reset-State
  $gd1 = New-FakeSlot 'repo' 'task-1'; $null = New-Lock $gd1 10
  New-StoreEntry (Join-Path $wt 'repo\task-1') 'hollow@4.5.0' 'hollow' 'empty'
  $null = New-FakeLease 'task-2' $deadPid 45
  $null = New-FakeJob '20260101-000000-dead' @{ pid = $deadPid }
  New-FakeMark 'deploy:repo:api' 8
  Put (Join-Path $srcPs 'bin\agentq.ps1') "# core A, newer in the checkout`n"
  Put (Join-Path $coord 'journal.jsonl') "{`"event`":`"note`"}`n"
  Put (Join-Path $coord 'notices\other-session.jsonl') "{}`n"
  $before = Get-TreeState $tmp
  $r = DJ -All
  $jsonCode = $code
  $o = AQ doctor -All
  $after = Get-TreeState $tmp
  Check '8 -Json parses: rows + generatedAt' ($null -ne $r -and @($r.rows).Count -gt 0 -and "$($r.generatedAt)" -ne '') $raw
  Check '8 -Json counts = its rows' ($r.problems -eq @($r.rows | Where-Object status -eq 'fail').Count -and $r.warnings -eq @($r.rows | Where-Object status -eq 'warn').Count -and $r.problems -eq 3 -and $r.warnings -eq 3) $raw
  Check '8 human report has the same counts and exit code' ($o -match "doctor: $($r.problems) problem\(s\), $($r.warnings) warning\(s\)" -and $code -eq 1 -and $jsonCode -eq 1) $o
  Check '8 every row has the six fields' (@($r.rows | Where-Object { @($_.PSObject.Properties.Name) -join ',' -ne 'check,status,kind,subject,detail,hint' }).Count -eq 0) $raw
  $diff = @(Compare-Object $before $after)
  Check '9 read-only: no file or folder changed (path + SHA256 + mtime)' ($before.Count -gt 20 -and $diff.Count -eq 0) (($diff | Select-Object -First 5 | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ' ; ')
  Check '9 the stale lock and the broken entry are still there' ((Test-Path (Join-Path $gd1 'index.lock')) -and (Test-Path (Join-Path $wt 'repo\task-1\node_modules\.pnpm\hollow@4.5.0'))) ''

  # ---- 10 scope: current repo vs -All --------------------------------------------------------------
  Reset-State
  $alpha = Join-Path $tmp 'alpha'
  if (-not (Test-Path $alpha)) { git init -q -b main $alpha }
  $ga = New-FakeSlot 'alpha' 'task-1'; $null = New-Lock $ga 10
  $gb = New-FakeSlot 'beta' 'task-1'; $null = New-Lock $gb 10
  $r = DJ -Repo $alpha
  $rows = Rows $r 'stale-index-lock' 'fail'
  Check '10 -Repo: only that repo''s slots' ($rows.Count -eq 1 -and $rows[0].subject -eq 'alpha/task-1' -and $code -eq 1) $raw
  $r = DJ -All -Repo $alpha
  Check '10 -All: every repo' (@(Rows $r 'stale-index-lock' 'fail').Count -eq 2) $raw
  if (-not (git -C $tmp rev-parse --show-toplevel 2>$null)) {
    $r = DJ
    Check '10 outside a repo, no -All: behaves as -All' (@(Rows $r 'stale-index-lock' 'fail').Count -eq 2) $raw
  } else { Write-Host 'SKIP 10 outside a repo (the temp dir is inside a git repo)' }

  # ---- 11 state size ---------------------------------------------------------------------------------
  Reset-State
  1..301 | ForEach-Object { Put (Join-Path $coord "notices\n-$_.txt") '' }
  1..101 | ForEach-Object { [IO.Directory]::CreateDirectory((Join-Path $coord "queues\build_r$_")) | Out-Null }
  Put (Join-Path $coord 'queues\build_r1\adaptive.json') '{}'           # not a ticket: the folder still counts as empty
  Put (Join-Path $coord 'queues\build_busy\0001.json') '{"id":"t"}'     # a ticket: not empty
  [IO.File]::WriteAllText($cfg, '{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"minFreeCommitGB":0,"journalRotateMB":0.001}')
  Put (Join-Path $coord 'journal.jsonl') ('x' * 4096)
  $r = DJ -All
  $rows = Rows $r 'state-size' 'warn'
  Check '11 notices > 300 -> warn, hint agentq prune' (@($rows | Where-Object { $_.subject -eq 'notices' -and $_.detail -match '^301 files' -and $_.hint -match 'agentq prune' }).Count -eq 1) $raw
  Check '11 queue folders without a ticket > 100 -> warn' (@($rows | Where-Object { $_.subject -eq 'queues' -and $_.detail -match '^101 of 102' }).Count -eq 1) $raw
  Check '11 journal over 1.5x journalRotateMB -> warn' (@($rows | Where-Object { $_.subject -eq 'journal' }).Count -eq 1) $raw
  Check '11 warnings only: exit 0' ($code -eq 0 -and $r.problems -eq 0 -and $r.warnings -eq 3) $raw

  # ---- 12 a check that throws does not stop the others ---------------------------------------------
  Reset-State
  New-FakeMark 'deploy:repo:api' 8
  $gd1 = New-FakeSlot 'repo' 'task-1'; $null = New-Lock $gd1 10
  $env:AGENTQ_DOCTOR_FAULT = 'stale-index-lock'
  $r = DJ -All
  Remove-Item Env:AGENTQ_DOCTOR_FAULT
  $crash = Rows $r 'stale-index-lock' 'warn'
  Check '12 crashed check -> one warn row "check crashed"' ($crash.Count -eq 1 -and $crash[0].detail -match '^check crashed: ') $raw
  Check '12 the other checks still ran' (@(Rows $r 'marks' 'warn').Count -eq 1 -and @($r.rows | Where-Object { $_.kind -eq 'summary' }).Count -eq 8 -and $code -eq 0) $raw
} finally {
  if ($gitProc) { try { $gitProc.Kill($true) } catch {} }
  Pop-Location
  foreach ($v in $envSet + 'AGENTQ_DOCTOR_FAULT' + 'AGENTQ_DOCTOR_SERIAL') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
