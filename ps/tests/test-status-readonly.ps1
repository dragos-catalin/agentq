# ADR 0009 stage 0 (OQ-007): `agentq status` (and log, metrics) is read-only. Before, a status call reaped
# dead tickets, rewrote the machine capacity, sampled the adaptive cap, removed an expired burst, marked a
# dead release failed, consumed the caller's lease notices, renewed the lease of the slot it ran in and
# wrote the agent registry. Acceptance: every file in the state folder is unchanged (hash before = after).
# The same state is then cleaned by the verbs whose job it is (sweep, a working call). Isolated in %TEMP%.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqro-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_PRUNE = '1'
# The registry is ON here on purpose: a status call must not write it.
Remove-Item Env:AGENTQ_NO_REGISTRY -ErrorAction SilentlyContinue
$env:AGENTQ_SESSION = 'reader'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'; $env:AGENTQ_CONFIG = $cfg
@{ taskSlotsPerRepo = 3; taskSlotsMachine = 5; minFreeCommitGB = 0; machineCap = 2; leaseDeadIdleMin = 60; leaseMaxIdleMin = 600
  machineCapAdaptive = @{ min = 2; max = 4; cpuLow = 101; cpuHigh = 200; minFreeRamGB = 0; minFreeCommitGB = 0; everySec = 0 }
  admission = @{ enabled = $true; probeMs = 400; window = 3; everySec = 0; staleSec = 300; maxHoldMin = 60 }
} | ConvertTo-Json -Depth 4 | Set-Content $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
# Every file AND folder under the state folder: relative path, size, SHA-256, last write time.
function Snapshot {
  $root = $env:AGENTQ_HOME
  $rows = foreach ($e in @(Get-ChildItem -LiteralPath $root -Recurse -Force | Sort-Object FullName)) {
    $rel = $e.FullName.Substring($root.Length)
    if ($e.PSIsContainer) { "D $rel" } else { "F $rel $($e.Length) $((Get-FileHash -LiteralPath $e.FullName -Algorithm SHA256).Hash) $($e.LastWriteTimeUtc.Ticks)" }
  }
  @($rows)
}
function Diff($a, $b) { @(Compare-Object $a $b | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) }
$utf8 = [Text.UTF8Encoding]::new($false)
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
Push-Location $repo
try {
  $home_ = $env:AGENTQ_HOME
  # --- state that the old status would have changed ---------------------------------------------
  # a real lease (the reader will run status from inside its slot)
  $env:AGENTQ_SESSION = 'owner-A'
  $env:AGENTQ_NO_ADMISSION = '1'   # the lease would take a real load sample; the fixture below provides the record
  $o = AQ lease -Purpose 'work A' -Json; $la = $o -split "`n" | Where-Object { $_ -match '^\{.*leaseId' } | Select-Object -Last 1 | ConvertFrom-Json
  Remove-Item Env:AGENTQ_NO_ADMISSION
  $lf = Join-Path $home_ "leases\repo\$($la.slot).json"
  [IO.File]::SetLastWriteTimeUtc("$lf.hb", [DateTime]::UtcNow.AddMinutes(-20))
  # a dead ticket on a repo resource and one on build:machine
  $past = [DateTime]::UtcNow.AddMinutes(-30).ToString('o')
  foreach ($res in 'build:repo', 'build:machine') {
    $qd = Join-Path $home_ ('queues\' + ($res -replace '[^A-Za-z0-9._-]', '_')); New-Item -ItemType Directory -Force $qd | Out-Null
    $t = [ordered]@{ id = "dead$($res.Length)"; seq = 1; resource = $res; pid = 999999; procStart = $past; session = 'gone'; purpose = 'crashed build'; cmd = 'x'; repo = $repo; created = $past; v = 3; lane = 'gate'; prio = 0; bump = 0; held = $true; ready = $true }
    [IO.File]::WriteAllText((Join-Path $qd '00000001-dead.json'), ($t | ConvertTo-Json), $utf8)
    [IO.File]::WriteAllText((Join-Path $qd '00000001-dead.json.hb'), '', $utf8)
    [IO.File]::WriteAllText((Join-Path $qd 'seq'), '1'); [IO.File]::WriteAllText((Join-Path $qd 'capacity'), $(if ($res -eq 'build:machine') { '9' } else { '1' }))
  }
  $mq = Join-Path $home_ 'queues\build_machine'
  # an adaptive record that is due for a refresh, and an expired burst
  [IO.File]::WriteAllText((Join-Path $mq 'adaptive.json'), (@{ at = $past; cap = 3; cpu = 10; idle = 1; total = 2; min = 2; max = 4; why = 'hold' } | ConvertTo-Json -Compress), $utf8)
  [IO.File]::WriteAllText((Join-Path $mq 'burst.json'), (@{ resource = 'build:machine'; by = 1; until = $past; reason = 'old burst'; session = 'x'; at = $past } | ConvertTo-Json), $utf8)
  # a release run whose process died without release-end
  $rd = Join-Path $home_ 'releases'; New-Item -ItemType Directory -Force $rd | Out-Null
  $relF = Join-Path $rd 'repo__web.json'
  [IO.File]::WriteAllText($relF, (@{ repo = 'repo'; target = 'web'; state = 'running'; sha = 'abc123def456'; phase = 'build'; phaseAt = ([DateTime]::UtcNow.AddMinutes(-10).ToString('o')); committed = $false; follow = 'main'; session = 'rel'; pid = 999999; procStart = $past; supersedeSha = ''; pendingSha = '' } | ConvertTo-Json), $utf8)
  # a pending lease-loss notice for the reader, and a load probe record
  $nd = Join-Path $home_ 'notices'; New-Item -ItemType Directory -Force $nd | Out-Null
  $noticeF = Join-Path $nd 'reader.jsonl'
  [IO.File]::WriteAllText($noticeF, ((@{ ts = $past; event = 'lease-expire'; repo = 'repo'; slot = 'task-9'; leaseId = 'feedbeef'; purpose = 'old work'; branch = ''; reason = 'stale'; ref = 'refs/backup/wt/repo/task-9/x'; by = 'sweeper' } | ConvertTo-Json -Compress) + "`n"), $utf8)
  $ld = Join-Path $home_ 'load'; New-Item -ItemType Directory -Force $ld | Out-Null
  [IO.File]::WriteAllText((Join-Path $ld 'probe.json'), (@{ v = 1; at = $past; ms = 120; src = 'sync'; cpu = $null; samples = @(@{ t = $past; ms = 120 }) } | ConvertTo-Json -Compress -Depth 4), $utf8)
  # a journal with one finished run (metrics reads it)
  Add-Content (Join-Path $home_ 'journal.jsonl') ((@{ ts = ([DateTime]::UtcNow.AddMinutes(-5).ToString('o')); event = 'done'; resource = 'build:repo,build:machine'; exit = 0; holdSec = 12; waitSec = 3; lane = 'gate'; kind = 'test'; session = 'x'; repo = 'repo' } | ConvertTo-Json -Compress))

  # --- 1. read-only verbs leave every byte and every timestamp alone -----------------------------
  $env:AGENTQ_SESSION = 'reader'
  $before = Snapshot
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $s1 = AQ status;        $c1 = $code
  $s2 = AQ status -All;   $c2 = $code
  $s3 = AQ status -Json;  $c3 = $code
  $s4 = AQ log -Last 20;  $c4 = $code
  $s5 = AQ metrics;       $c5 = $code
  $took = $sw.Elapsed.TotalSeconds
  Push-Location $la.path
  try { $s6 = AQ status; $c6 = $code; $s7 = AQ status -All -Json; $c7 = $code } finally { Pop-Location }
  $after = Snapshot
  $d = Diff $before $after
  Check '1 status / status -All / status -Json / log / metrics exit 0' (-not ($c1, $c2, $c3, $c4, $c5, $c6, $c7 | Where-Object { $_ })) "$c1 $c2 $c3 $c4 $c5 $c6 $c7"
  Check '1 state folder unchanged: every file hash, size, timestamp and every folder' ($d.Count -eq 0) (($d | Select-Object -First 8) -join "`n")
  Write-Host ("     {0} entries compared; 5 read-only calls took {1:N1} s" -f $before.Count, $took)
  # the pieces, named (so a regression says which side effect came back)
  Check '1 dead tickets not reaped by status' ((Test-Path (Join-Path $home_ 'queues\build_repo\00000001-dead.json')) -and (Test-Path (Join-Path $mq '00000001-dead.json')))
  Check '1 machine capacity file not rewritten' ((Get-Content (Join-Path $mq 'capacity') -Raw) -eq '9')
  Check '1 adaptive cap not sampled' ((Get-Content (Join-Path $mq 'adaptive.json') -Raw) -match [regex]::Escape($past))
  Check '1 expired burst not removed' (Test-Path (Join-Path $mq 'burst.json'))
  Check '1 dead release not rewritten' ((Get-Content $relF -Raw | ConvertFrom-Json).state -eq 'running')
  Check '1 lease notice not consumed' (Test-Path $noticeF)
  # the fixture lease (session owner-A) is a working call and has its own registry file; the reader must not get one
  Check '1 agent registry not written for the reader' (-not (Test-Path (Join-Path $home_ 'agents\reader.json')))
  Check '1 status from inside a slot does not renew its lease' (([DateTime]::UtcNow - (Get-Item "$lf.hb").LastWriteTimeUtc).TotalMinutes -gt 19)
  Check '1 load probe not sampled' (-not (Get-ChildItem $ld -Filter 'probe-*.jsonl'))

  # --- 2. and status still tells the truth -------------------------------------------------------
  Check '2 a dead ticket is not shown as a holder' ($s2 -notmatch 'crashed build')
  Check '2 the dead release is reported as FAILED' ($s2 -match 'repo/web\s+FAILED') $s2
  Check '2 the lease is listed' ($s2 -match "repo/$($la.slot)\s+task") $s2
  Check '2 the load line comes from the shared record' ($s2 -match '== LOAD start probe 120 ms') $s2
  $j = $s3 | ConvertFrom-Json
  Check '2 -Json: tickets empty, lease + release present' (@($j.tickets).Count -eq 0 -and @($j.leases).Count -eq 1 -and @($j.releases | Where-Object { $_.state -eq 'failed' }).Count -eq 1) $s3

  # --- 3. the verbs whose job it is still clean up ------------------------------------------------
  $env:AGENTQ_SESSION = 'sweeper'
  $o = AQ sweep
  $jl = @(Get-Content (Join-Path $home_ 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
  Check '3 sweep reaps the dead tickets (journal reap)' ($o -match 'reaped=2' -and -not (Test-Path (Join-Path $home_ 'queues\build_repo\00000001-dead.json')) -and @($jl | Where-Object event -eq 'reap').Count -eq 2) $o
  Check '3 sweep records the dead release as failed (journal release-dead)' ((Get-Content $relF -Raw | ConvertFrom-Json).state -eq 'failed' -and @($jl | Where-Object event -eq 'release-dead').Count -eq 1)
  $env:AGENTQ_SESSION = 'reader'
  $o = AQ note -Message 'working call'
  Check '3 the notice is shown (once) on the next working call' ($o -match 'NOTICE your lease feedbeef' -and -not (Test-Path $noticeF)) $o
  Check '3 a working call writes the registry' (Test-Path (Join-Path $home_ 'agents\reader.json'))
  # as an array: a bare -- passed through a PowerShell function is dropped
  $runArgs = @('run', '-Resource', 'build', '-Purpose', 'real work', '-MinFreeGB', '0', '-Repo', $repo, '--', 'pwsh', '-NoProfile', '-Command', 'exit 0')
  $o = AQ @runArgs
  Check '3 a real run refreshes capacity + adaptive cap and drops the expired burst' ($code -eq 0 -and (Get-Content (Join-Path $mq 'capacity') -Raw) -ne '9' -and (Get-Content (Join-Path $mq 'adaptive.json') -Raw) -notmatch [regex]::Escape($past) -and -not (Test-Path (Join-Path $mq 'burst.json'))) $o
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_NO_SIGNAL', 'AGENTQ_NO_ENV_COPY', 'AGENTQ_NO_PREP', 'AGENTQ_NO_PRUNE') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
