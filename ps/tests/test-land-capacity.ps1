# TASK 1 (2026-11-26): `land:<repo>` may be raised to capacity 2 by config - and ONLY the merge phase
# stays serialised. Why it exists: the land ticket was the only place a pre-gate could run, so a land held
# the single land lock for its whole gate, and land was 60 % of all fleet queue time (7 days to 2026-11-26:
# 83.6 h, p90 13.3 min, max 6.4 h). With an opt-in capacity of 2, two lands queue and gate in parallel;
# the merge-to-main + push stays mutually exclusive per repo behind a bounded named mutex
# (Enter-LandMergeMutex), so origin/<onto> is still moved by one land at a time.
# DEFAULT IS UNCHANGED (capacity 1), which is what check group 1 pins before anything else.
#
# Scope note (deliberate): the suite does NOT configure a land GATE. A pre-gate runs BEFORE the land ticket
# (Invoke-LandPregate, by design), so it is already parallel at ANY capacity; capacity governs the ticket,
# and the merge mutex is what makes capacity 2 safe. What this suite proves instead is the property that
# actually changes: two lands are ADMITTED AT THE SAME TIME (group 2, observed on the live queue), their
# MERGES never overlap (group 3, timestamps written by the repo's own finalizer inside the lock), and a
# land that cannot take the mutex REFUSES instead of deadlocking (group 4).
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqlcap-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; $env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'
# A land slot is never gated by admission, but the land path takes a scratch slot for its pre-gate and the
# suite's own probes run `acquire`; opting out of admission (the documented one-call escape) keeps this
# suite a test of the land queue rather than of the box's current load.
$env:AGENTQ_NO_ADMISSION = '1'
$env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_LAND_INSTALL = '1'; $env:AGENTQ_NO_POSTLAND = '1'; $env:AGENTQ_LAND_BATCH = '0'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
Remove-Item Env:AGENTQ_CHAT_ID, Env:AGENTQ_LAND_MERGE_WAIT_SEC -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
$env:AGENTQ_CONFIG = $cfg
$flog = Join-Path $tmp 'finalize.log'
Set-Content -LiteralPath $flog -Value ''
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function WriteCfg([string]$extra) {
  $base = '{"taskSlotsPerRepo":4,"taskSlotsMachine":6,"minFreeCommitGB":0,"scratchSlots":4,"landMergeWaitMin":90'
  $cfgTxt = if ($extra) { "$base,$extra}" } else { "$base}" }
  Set-Content -LiteralPath $cfg -Value $cfgTxt
}
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function CapFile { Join-Path (Join-Path $env:AGENTQ_HOME 'queues') 'land_repo\capacity' }
# One probe of the EFFECTIVE capacity: take a land ticket, then read the sticky capacity file agentq
# rewrites for exactly this guarantee (the same observable build:machine's own suite uses).
function LandCap([string]$extraCfg, [string]$probe) {
  WriteCfg $extraCfg
  $null = AQ acquire -Resource land:repo -Purpose $probe -NoWait
  if (-not (Test-Path (CapFile))) { return '<absent>' }
  (Get-Content (CapFile) -Raw).Trim()
}
# A repo-owned land finalizer: it runs INSIDE the land slot, inside the merge lock, immediately before the
# push - so its timestamps are a recording of the merge window. The b1/c1 topics sleep, b2/c2 do not: an
# overlap is then visible in the data instead of being argued about.
function WriteFinalizer($repo) {
  New-Item -ItemType Directory -Force (Join-Path $repo 'scripts') | Out-Null
  $ps = @'
param([string]$Worktree, [string]$Onto, [string]$Base, [string]$Branch)
$log = $env:FAKE_FINALIZE_LOG
$sec = 0
if ($Branch -like 'b1*' -or $Branch -like 'c1*') { $sec = 8 }
[IO.File]::AppendAllText($log, ("ENTER {0} {1}`n" -f $Branch, [DateTime]::UtcNow.Ticks))
if ($sec) { Start-Sleep -Seconds $sec }
[IO.File]::AppendAllText($log, ("EXIT {0} {1}`n" -f $Branch, [DateTime]::UtcNow.Ticks))
exit 0
'@
  # LF, no BOM: the land slot is a worktree of the same repo and PowerShell reads both, but keeping it
  # byte-clean means `git cherry-pick`/checkout never sees a CRLF-only diff in the test itself.
  [IO.File]::WriteAllText((Join-Path $repo 'scripts\land-finalize.ps1'), ($ps -replace "`r`n", "`n"), (New-Object Text.UTF8Encoding $false))
}
function StartLand([string]$branch, [string]$tag) {
  $so = Join-Path $tmp "$tag.out"; $se = Join-Path $tmp "$tag.err"
  $p = Start-Process pwsh -PassThru -WindowStyle Hidden -RedirectStandardOutput $so -RedirectStandardError $se `
    -ArgumentList @('-NoProfile', '-File', $Aq, 'land', '-Repo', $repo, '-Branch', $branch, '-Onto', 'main', '-Purpose', $tag)
  [pscustomobject]@{ proc = $p; out = $so; err = $se }
}
function LiveTickets { @(Get-ChildItem (Join-Path $env:AGENTQ_HOME 'queues\land_repo') -Filter '*.json' -ErrorAction SilentlyContinue) }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
WriteFinalizer $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n")
git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
$env:FAKE_FINALIZE_LOG = $flog
Push-Location $repo
try {
  # ======================= 1. the DEFAULT is unchanged (capacity 1) =======================
  $c1 = LandCap '' 'cap-default'
  Check '1a no landCapacity key -> land:repo capacity is 1 (today''s behaviour)' ($c1 -eq '1') "cap=$c1"
  $c2 = LandCap '"landCapacity":2' 'cap-two'
  Check '1b landCapacity 2 -> land:repo capacity is 2 (the opt-in)' ($c2 -eq '2') "cap=$c2"
  $c3 = LandCap '"landCapacity":9' 'cap-clamp'
  Check '1c landCapacity 9 -> clamped to 2 (one land slot per repo)' ($c3 -eq '2') "cap=$c3"
  $c4 = LandCap '"landCapacity":0' 'cap-zero'
  Check '1d landCapacity 0 -> clamped back to 1 (never below today''s behaviour)' ($c4 -eq '1') "cap=$c4"
  # The flag is the switch: a `-Capacity 2` on the land resource must not leave the effective cap at 2.
  WriteCfg '"landCapacity":1'
  $null = AQ acquire -Resource land:repo -Purpose 'cap-explicit' -Capacity 2 -NoWait
  $c5 = LandCap '' 'cap-after'
  Check '1e an explicit land -Capacity does not outlive the flag' ($c5 -eq '1') "cap=$c5"

  # 1f/1g: With-Mutex capped its wait at 30 s and DISCARDED the result, so a caller that lost the race sat
  # the full 30 s of dead time and then ran the body anyway - the mutex is free by then, so the 30 s bought
  # nothing at all. Every pool run of this suite reported sec=30 while its own assertions take ~1 s. Pin that
  # the bound is a knob and that an exhausted wait is OBSERVED, not silently swallowed (2026-11-27).
  $v2Text = Get-Content -LiteralPath (Join-Path (Split-Path $Aq -Parent) 'agentq-v2.ps1') -Raw
  Check '1f With-Mutex bounds the wait through a knob, not a bare silent 30000' ($v2Text -match 'AGENTQ_MUTEX_WAIT_MS')
  Check '1g the exhausted mutex wait is observable (WaitOne result used + journalled)' `
    (($v2Text -match 'if \(-not \$m\.WaitOne\(\$w\)\)') -and ($v2Text -match "event = 'mutex-timeout'"))

  # ======================= 2+3. cap 2: two lands at once, merges strictly serialised =======================
  WriteCfg '"landCapacity":2'
  foreach ($b in 'b1', 'b2') {
    git -C $repo checkout -q -b $b main
    [IO.File]::WriteAllText("$repo\$b.txt", "$b`n")
    git -C $repo add -A; git -C $repo commit -qm "topic $b"
    git -C $repo checkout -q main
  }
  Set-Content -LiteralPath $flog -Value ''
  $env:AGENTQ_LAND_MERGE_WAIT_SEC = '300'
  $l1 = StartLand 'b1' 'b1'; $l2 = StartLand 'b2' 'b2'
  $maxTickets = 0
  for ($k = 0; $k -lt 200; $k++) {
    $n = (LiveTickets).Count
    if ($n -gt $maxTickets) { $maxTickets = $n }
    if ($l1.proc.HasExited -and $l2.proc.HasExited) { break }
    Start-Sleep -Milliseconds 100
  }
  $l1.proc.WaitForExit(120000) | Out-Null; $l2.proc.WaitForExit(120000) | Out-Null
  $o1 = "$(Get-Content $l1.out -Raw -ErrorAction SilentlyContinue)$(Get-Content $l1.err -Raw -ErrorAction SilentlyContinue)"
  $o2 = "$(Get-Content $l2.out -Raw -ErrorAction SilentlyContinue)$(Get-Content $l2.err -Raw -ErrorAction SilentlyContinue)"
  Check '2a two land:repo tickets were live at the SAME time (cap 2 admits both)' ($maxTickets -ge 2) "maxTickets=$maxTickets | $o1 | $o2"
  Check '2b both lands succeeded' ($l1.proc.ExitCode -eq 0 -and $l2.proc.ExitCode -eq 0) "b1=$($l1.proc.ExitCode) b2=$($l2.proc.ExitCode) | $o1 | $o2"
  $merged = @(git -C $repo log --format=%s origin/main | Where-Object { $_ -like 'topic *' })
  Check '2c both topics are on origin/main' (($merged -join ',') -match 'topic b1' -and ($merged -join ',') -match 'topic b2') ($merged -join ',')
  # The merge windows: ENTER/EXIT pairs of the repo's own finalizer, which runs inside the merge lock.
  $iv = @{}
  foreach ($ln in @(Get-Content -LiteralPath $flog | Where-Object { $_ })) {
    $p = $ln -split '\s+'
    if (-not $iv.ContainsKey($p[1])) { $iv[$p[1]] = @{} }
    $iv[$p[1]][$p[0]] = [long]$p[2]
  }
  $haveB = ($iv.ContainsKey('b1') -and $iv['b1'].ContainsKey('ENTER') -and $iv['b1'].ContainsKey('EXIT') -and $iv.ContainsKey('b2') -and $iv['b2'].ContainsKey('ENTER') -and $iv['b2'].ContainsKey('EXIT'))
  Check '3a both merges really ran the finalizer (the recording is not vacuous)' $haveB ($iv.Keys -join ',')
  $overlap = $false
  if ($haveB) {
    $overlap = (($iv['b1'].ENTER -lt $iv['b2'].ENTER) -and ($iv['b2'].ENTER -lt $iv['b1'].EXIT)) -or (($iv['b2'].ENTER -lt $iv['b1'].ENTER) -and ($iv['b1'].ENTER -lt $iv['b2'].EXIT))
  }
  Check '3b the two MERGE phases never overlap (serialised by the per-repo mutex)' ($haveB -and -not $overlap) ("b1=$(if ($haveB) { $iv['b1'].ENTER - $iv['b1'].EXIT } else { '?' }) b2=$(if ($haveB) { $iv['b2'].ENTER - $iv['b2'].EXIT } else { '?' }) overlap=$overlap")
  $enter = @($iv.Keys | Where-Object { $iv[$_].ContainsKey('ENTER') }).Count
  $exit = @($iv.Keys | Where-Object { $iv[$_].ContainsKey('EXIT') }).Count
  Check '3c every ENTER has exactly one EXIT (the mutex is released, not leaked)' ($enter -eq 2 -and $exit -eq 2) "enter=$enter exit=$exit"
  $jrn = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.event -like 'land-merge-*' })
  Check '3d the merge window is journalled (enter+exit) so a repo''s merge can be read back' (@($jrn | Where-Object { $_.event -eq 'land-merge-enter' }).Count -ge 2 -and @($jrn | Where-Object { $_.event -eq 'land-merge-exit' }).Count -ge 2) ($jrn | ConvertTo-Json -Compress)

  # ======================= 4. refusal, not deadlock =======================
  foreach ($b in 'c1', 'c2') {
    git -C $repo checkout -q -b $b main
    [IO.File]::WriteAllText("$repo\$b.txt", "$b`n")
    git -C $repo add -A; git -C $repo commit -qm "topic $b"
    git -C $repo checkout -q main
  }
  # 2 s bound (the suite escape; config is whole minutes): c1 holds the merge for ~8 s, so c2 MUST refuse.
  $env:AGENTQ_LAND_MERGE_WAIT_SEC = '2'
  Remove-Item Env:FAKE_FINALIZE_LOG -ErrorAction SilentlyContinue
  $env:FAKE_FINALIZE_LOG = $flog
  $c1L = StartLand 'c1' 'c1'
  Start-Sleep -Milliseconds 2500
  $c2L = StartLand 'c2' 'c2'
  $c1L.proc.WaitForExit(120000) | Out-Null; $c2L.proc.WaitForExit(120000) | Out-Null
  $e2 = "$(Get-Content $c2L.out -Raw -ErrorAction SilentlyContinue)$(Get-Content $c2L.err -Raw -ErrorAction SilentlyContinue)"
  Check '4a the second land REFUSES with exit 3 instead of deadlocking' ($c2L.proc.ExitCode -eq 3) "c2=$($c2L.proc.ExitCode) | $e2"
  Check '4b the refusal names the bound and says nothing was pushed' ($e2 -match 'merge mutex was not free within' -and $e2 -match 'Nothing queued, nothing pushed') $e2
  $to = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.event -eq 'land-merge-mutex-timeout' })
  Check '4c the refusal is journalled (land-merge-mutex-timeout)' ($to.Count -ge 1) ($to | ConvertTo-Json -Compress)
  $c2Land = @(Get-Content $c2L.out -Raw -ErrorAction SilentlyContinue | Where-Object { $_ })
  $merged2 = @(git -C $repo log --format=%s origin/main | Where-Object { $_ -like 'topic *' })
  Check '4d the refused topic was NOT pushed, the holder''s was' (($merged2 -join ',') -match 'topic c1' -and -not (($merged2 -join ',') -match 'topic c2')) ($merged2 -join ',')
  Remove-Item Env:AGENTQ_LAND_MERGE_WAIT_SEC -ErrorAction SilentlyContinue
} finally {
  Pop-Location
  Remove-Item Env:FAKE_FINALIZE_LOG, Env:FAKE_GATE_LOG -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
