# Runs every ps/ test suite against THIS checkout (not the installed copy). Exit 0 only if all pass.
# No arguments = every suite, one after another: ps/install.ps1 depends on that and on the exit code.
#   -Only a,b / -Skip a,b   suite names (exact, case-insensitive; one comma-separated value also works)
#   -List                   print the suite names, exit 0
#   -LogDir <dir>           full output of every suite in <dir>\<name>.log
#   -TimeoutMin n           kill a suite (whole process tree) after n minutes and count it as failed
#   -Parallel n            run up to n suites at once (default 1 = one after another). Suites that must
#                          own the machine (install, term interrupt, reap terminals, git-autosync,
#                          guard cloud, deploy guard) still run alone: the pool drains first.
#   env AGENTQ_TEST_SKIP    comma list, merged into -Skip
#   -LastGreen              print the last green FULL run (hash + time + seconds) and exit 0/1
# A full green run records <root>\.copilot-tmp\last-green.json: the hash of every file under ps/ plus
# the PowerShell build. install.ps1 uses it to skip a repeat of the same content (2026-11-20: a full
# run was ~30 min, so an install that changes nothing must not pay it again). Anything under ps/ that
# changes makes the hash differ, so the record can only ever be a LIE if the tests depend on something
# outside ps/ (env, a machine tool) - `install.ps1 -Full` and this -LastGreen are the way to check.
# Exit: 0 all pass, 1 a suite failed or nothing ran, 2 bad arguments. More: README.md next to this file.
[CmdletBinding(PositionalBinding = $false)]
param([string[]]$Only, [string[]]$Skip, [switch]$List, [switch]$LastGreen, [string]$LogDir, [int]$TimeoutMin = 0, [int]$Parallel = 1,
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest)
$ErrorActionPreference = 'Continue'
# Without this a second bare word would bind to the next parameter (-Only a b = "skip b").
if ($Rest) { Write-Host "run-all: unexpected argument(s): $($Rest -join ' ') - pass several suite names as ONE comma-separated value, e.g. -Only 'args,slo'"; exit 2 }
if ($TimeoutMin -lt 0) { Write-Host 'run-all: -TimeoutMin must be 0 (no limit) or more'; exit 2 }
if ($Parallel -lt 1 -or $Parallel -gt 16) { Write-Host 'run-all: -Parallel must be 1..16'; exit 2 }
$root = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $root 'bin'; $hooks = Join-Path $root 'hooks'
# test-agentq.ps1 resolves agentq.ps1 next to itself: run it from a temp copy beside bin/.
$stage = Join-Path ([IO.Path]::GetTempPath()) ('aq-runall-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$suites = [ordered]@{
  'agentq v1'      = @('-File', (Join-Path $stage 'test-agentq.ps1'))
  'agentq v3'      = @('-File', (Join-Path $stage 'test-agentq-v3.ps1'))
  'agentq v2'      = @('-File', (Join-Path $PSScriptRoot 'test-agentq-v2.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land changelog' = @('-File', (Join-Path $PSScriptRoot 'test-land-changelog.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'worktree v2'    = @('-File', (Join-Path $PSScriptRoot 'test-worktree-v2.ps1'), '-Bin', $bin, '-Hooks', $hooks)
  'repo-migrate'   = @('-File', (Join-Path $PSScriptRoot 'test-repo-migrate.ps1'), '-Tool', (Join-Path $bin 'repo-migrate.ps1'))
  'guard'          = @('-File', (Join-Path $PSScriptRoot 'test-guard-v2.ps1'), '-Guard', (Join-Path $hooks 'guard-tooluse.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'jobs'           = @('-File', (Join-Path $PSScriptRoot 'test-jobs.ps1'), '-Bin', $bin, '-Hooks', $hooks)
  'cloud place'    = @('-File', (Join-Path $PSScriptRoot 'test-agentq-cloud.ps1'), '-Aq', (Join-Path $stage 'agentq.ps1'))
  'adaptive+reg'   = @('-File', (Join-Path $PSScriptRoot 'test-agentq-adaptive.ps1'))
  'reap terminals' = @('-File', (Join-Path $PSScriptRoot 'test-reap-terminals.ps1'), '-Tool', (Join-Path $bin 'reap-terminals.ps1'))
  'term interrupt' = @('-File', (Join-Path $PSScriptRoot 'test-term-interrupt.ps1'), '-Tool', (Join-Path $bin 'term-interrupt.ps1'))
  'git-autosync'   = @('-File', (Join-Path $PSScriptRoot 'test-git-autosync.ps1'), '-Tool', (Join-Path $bin 'git-autosync.ps1'))
  'guard shared'   = @('-File', (Join-Path $PSScriptRoot 'test-guard-shared.ps1'), '-Guard', (Join-Path $hooks 'guard-tooluse.ps1'))
  'shared commit'  = @('-File', (Join-Path $PSScriptRoot 'test-agentq-shared-commit.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'guard cloud'    = @('-File', (Join-Path $PSScriptRoot 'test-guard-cloud.ps1'), '-Guard', (Join-Path $hooks 'guard-tooluse.ps1'))
  # ADR 0003 wave 1
  'publish'        = @('-File', (Join-Path $PSScriptRoot 'test-agentq-publish.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'lease3+prep'    = @('-File', (Join-Path $PSScriptRoot 'test-agentq-lease3.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'args'           = @('-File', (Join-Path $PSScriptRoot 'test-agentq-args.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'help'           = @('-File', (Join-Path $PSScriptRoot 'test-agentq-help.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  # ADR 0003 wave 2/4
  'land finalize'  = @('-File', (Join-Path $PSScriptRoot 'test-land-finalize.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'post-land hook' = @('-File', (Join-Path $PSScriptRoot 'test-post-land.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land precheck'  = @('-File', (Join-Path $PSScriptRoot 'test-land-precheck.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land reclaim'   = @('-File', (Join-Path $PSScriptRoot 'test-land-reclaim.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'job object'     = @('-File', (Join-Path $PSScriptRoot 'test-jobobject.ps1'), '-Bin', $bin)
  'flakes'         = @('-Command', "node '$(Join-Path $PSScriptRoot 'test-flakes.mjs')'; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { 'PASS flakes selftest' }")
  'land batch'     = @('-File', (Join-Path $PSScriptRoot 'test-land-batch.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land default gate' = @('-File', (Join-Path $PSScriptRoot 'test-land-default-gate.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'claims'         = @('-File', (Join-Path $PSScriptRoot 'test-agentq-claims.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land flakes'    = @('-File', (Join-Path $PSScriptRoot 'test-land-flakes.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'store'          = @('-Command', "node '$(Join-Path $PSScriptRoot 'test-store.mjs')'; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { 'PASS store selftest' }")
  # ADR 0007: git-first + devbox teams
  'devbox tools'   = @('-File', (Join-Path $PSScriptRoot 'test-devbox-tools.ps1'), '-Bin', $bin)
  'devbox teams'   = @('-Command', "python '$(Join-Path $PSScriptRoot 'test-devbox-teams.py')' '$(Join-Path $bin 'devbox-teams.py')' 2>&1; if (`$LASTEXITCODE) { 'FAIL devbox-teams planner'; exit `$LASTEXITCODE } else { 'PASS devbox-teams planner (16)' }")
  'slo'            = @('-Command', "node '$(Join-Path $PSScriptRoot 'test-slo.mjs')'; if (`$LASTEXITCODE) { exit `$LASTEXITCODE } else { 'PASS slo selftest' }")
  # ADR 0009 (tracker OQ-*): a suite whose file is not there yet is a SKIP, not a failure
  'lease chat'      = @('-File', (Join-Path $PSScriptRoot 'test-lease-chat.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'), '-Guard', (Join-Path $hooks 'guard-tooluse.ps1'))
  'lease liveness' = @('-File', (Join-Path $PSScriptRoot 'test-agentq-lease-liveness.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land pregate'    = @('-File', (Join-Path $PSScriptRoot 'test-land-pregate.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'land install'   = @('-File', (Join-Path $PSScriptRoot 'test-land-install.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'admission'       = @('-File', (Join-Path $PSScriptRoot 'test-agentq-admission.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'status readonly' = @('-File', (Join-Path $PSScriptRoot 'test-status-readonly.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  # 2026-11-21: the release `phase` is the last checkpoint ENTERED, not the step that failed; the display
  # must show `last-phase=` + the run's own `exit=` separately, and the record keeps its `phase` field.
  'release phase honesty' = @('-File', (Join-Path $PSScriptRoot 'test-release-phase-honesty.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'prune'           = @('-File', (Join-Path $PSScriptRoot 'test-agentq-prune.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'doctor'          = @('-File', (Join-Path $PSScriptRoot 'test-agentq-doctor.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'agentq-sync'    = @('-File', (Join-Path $PSScriptRoot 'test-agentq-sync.ps1'), '-Bin', $bin)
  'hook pre'        = @('-File', (Join-Path $PSScriptRoot 'test-hook-pre.ps1'), '-Hooks', $hooks)
  'install'         = @('-File', (Join-Path $PSScriptRoot 'test-install.ps1'), '-Src', $root)
  # 2026-11-21 (ADR 0014): take-over + `recover` safety net, the commit/push split (D1), the
  # per-session fair share of a resource (D4). Without these lines the suites existed and never ran.
  'recover'         = @('-File', (Join-Path $PSScriptRoot 'test-agentq-recover.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'commit fast'     = @('-File', (Join-Path $PSScriptRoot 'test-agentq-commit-fast.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
  'fair share'      = @('-File', (Join-Path $PSScriptRoot 'test-agentq-fairshare.ps1'), '-Aq', (Join-Path $bin 'agentq.ps1'))
}
$names = @($suites.Keys)
if ($List) { $names | ForEach-Object { Write-Host $_ }; exit 0 }

# ---- the green record: hash of ps/ + the PowerShell build (a full green run writes it, install.ps1 reads it)
# $root is ps/ (test paths are relative to it); the record lives at the REPO root, outside the hashed tree.
$repoRoot = Split-Path -Parent $root
$greenFile = Join-Path $repoRoot '.copilot-tmp\last-green.json'
function Get-SourceHash {
  $lines = @(Get-ChildItem $root -Recurse -File |
    Where-Object { $_.Extension -ne '.log' -and $_.FullName -notmatch '\\\.copilot-tmp\\' } |
    Sort-Object FullName |
    ForEach-Object { "$($_.FullName.Substring($repoRoot.Length))=$(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 | Select-Object -ExpandProperty Hash)" })
  $txt = ($lines -join "`n") + "`npsver=$($PSVersionTable.PSVersion)"
  $bytes = [Text.Encoding]::UTF8.GetBytes($txt)
  "sha256:" + [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($bytes)).Replace('-', '').Substring(0, 32).ToLowerInvariant()
}
function Read-GreenRecord { if (Test-Path -LiteralPath $greenFile) { try { Get-Content -LiteralPath $greenFile -Raw | ConvertFrom-Json -AsHashtable } catch { $null } } else { $null } }
if ($LastGreen) {
  $g = Read-GreenRecord
  if (-not $g) { Write-Host "run-all: no green record at $greenFile"; exit 1 }
  $now = Get-SourceHash
  Write-Host "last green full run: $($g.at)  $($g.suites) suites  $($g.sec) sec  psver $($g.psver)"
  Write-Host "  recorded hash $($g.hash)"
  Write-Host "  current  hash $now"
  if ($g.hash -eq $now) { Write-Host '  -> MATCH: ps/ is byte-identical to the tree that passed'; exit 0 }
  Write-Host '  -> DIFFERS: ps/ changed since that run'; exit 1
}

# ---- selection: -Only / -Skip / AGENTQ_TEST_SKIP (an unknown name is an error, never a silent no-op)
$canon = @{}; foreach ($n in $names) { $canon[$n] = $n }
function Resolve-SuiteNames([string]$What, [string[]]$Values) {
  $ok = @(); $unknown = @()
  foreach ($n in @($Values | Where-Object { $_ } | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
    if ($canon.ContainsKey($n)) { $ok += $canon[$n] } else { $unknown += $n }
  }
  if ($unknown) { Write-Host "run-all: unknown suite name(s) in ${What}: $($unknown -join ', ')"; Write-Host "valid names: $($names -join ', ')"; exit 2 }
  $ok
}
$onlyNames = @(Resolve-SuiteNames '-Only' $Only)
$skipWhy = @{}
foreach ($n in @(Resolve-SuiteNames 'AGENTQ_TEST_SKIP' @($env:AGENTQ_TEST_SKIP))) { $skipWhy[$n] = 'AGENTQ_TEST_SKIP' }
foreach ($n in @(Resolve-SuiteNames '-Skip' $Skip)) { $skipWhy[$n] = '-Skip' }
$selected = if ($onlyNames.Count) { @($names | Where-Object { $onlyNames -contains $_ }) } else { $names }

# ---- -LogDir / -TimeoutMin: the suite runs under cmd.exe with stdout+stderr redirected to a FILE, and
# only the process is waited for. Waiting on a pipe instead never returns when a suite leaves a
# background process holding the inherited handle. The file is read after the process has exited.
function ConvertTo-CmdArg([string]$Text) {
  if ($Text -match '["%]') { throw "argument not supported with -LogDir/-TimeoutMin (double quote or percent sign): $Text" }
  '"' + ($Text -replace '(\\+)$', '$1$1') + '"'
}
function Start-Logged([string]$Exe, [string[]]$Argv, [string]$Log) {
  $line = (@($Exe) + $Argv | ForEach-Object { ConvertTo-CmdArg $_ }) -join ' '
  $psi = [Diagnostics.ProcessStartInfo]::new()
  $psi.FileName = if ($env:ComSpec) { $env:ComSpec } else { 'cmd.exe' }
  $psi.Arguments = '/d /s /c "' + $line + ' > ' + (ConvertTo-CmdArg $Log) + ' 2>&1 < NUL"'
  $psi.UseShellExecute = $false
  [Diagnostics.Process]::Start($psi)
}
function Wait-Logged($Proc, [int]$TimeoutSec) {
  $timedOut = $false
  if ($TimeoutSec -gt 0) {
    if (-not $Proc.WaitForExit([int][math]::Min([int]::MaxValue, [long]$TimeoutSec * 1000))) {
      $timedOut = $true
      & taskkill.exe /T /F /PID $Proc.Id 2>&1 | Out-Null
      $null = $Proc.WaitForExit(15000)
    }
  } else { $Proc.WaitForExit() }
  [pscustomobject]@{ Code = $(if ($Proc.HasExited) { $Proc.ExitCode } else { -1 }); TimedOut = $timedOut }
}
function Invoke-Logged([string]$Exe, [string[]]$Argv, [string]$Log, [int]$TimeoutSec) {
  Wait-Logged (Start-Logged $Exe $Argv $Log) $TimeoutSec
}
# start a suite without waiting for it (the -Parallel pool) and finish/report it later
function Start-Suite([string]$Name, [string[]]$Argv, [string]$Log) {
  [pscustomobject]@{ Name = $Name; Log = $Log; Sw = [Diagnostics.Stopwatch]::StartNew(); TimeoutSec = ($TimeoutMin * 60); TimedOut = $false
    Proc = (Start-Logged $pwshExe $Argv $Log) }
}
function Complete-Suite($Job) {
  $r = Wait-Logged $Job.Proc $Job.TimeoutSec
  [pscustomobject]@{ Name = $Job.Name; Log = $Job.Log; Sec = [int][math]::Round($Job.Sw.Elapsed.TotalSeconds)
    Code = $r.Code; TimedOut = ($r.TimedOut -or $Job.TimedOut) }
}
# one result line per suite (+ FAIL lines, + the tail of the log when a suite died without a FAIL line)
function Report-Suite([string]$Name, [int]$Code, [bool]$TimedOut, [int]$Sec, [string[]]$Lines, [string]$LogPath) {
  $fails = @($Lines | Where-Object { $_ -match '^\s*(FAIL)\b' })
  Write-Host ("{0,-15} exit={1} pass={2} fail={3} sec={4}" -f $Name, $Code, @($Lines | Where-Object { $_ -match '^\s*(PASS|ok)\b' }).Count, $fails.Count, $Sec)
  $fails | ForEach-Object { Write-Host "   $_" }
  if ($TimedOut) { Write-Host "   TIMEOUT after $TimeoutMin min" }
  $failed = [bool]($Code -or $TimedOut)
  if ($failed -and -not $fails.Count -and $useProc) { @($Lines | Where-Object { "$_".Trim() }) | Select-Object -Last 15 | ForEach-Object { Write-Host "   | $_" } }
  if ($failed -and $useProc -and $LogDir -and $LogPath) { Write-Host "   log: $LogPath" }
  return $failed
}
function Read-LogLines([string]$Log) {
  if (-not (Test-Path -LiteralPath $Log)) { return @() }
  # shared read: a process the suite left behind may still hold the file open
  $fs = [IO.File]::Open($Log, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
  try { $text = [IO.StreamReader]::new($fs, [Console]::OutputEncoding).ReadToEnd() } finally { $fs.Dispose() }
  @($text -split "`r?`n")
}
$usePool = $Parallel -gt 1
$useProc = [bool]$LogDir -or $TimeoutMin -gt 0 -or $usePool
New-Item -ItemType Directory $stage | Out-Null
Copy-Item (Join-Path $bin '*') $stage
Copy-Item (Join-Path $PSScriptRoot 'test-agentq.ps1') $stage
Copy-Item (Join-Path $PSScriptRoot 'test-agentq-v3.ps1') $stage
$pwshExe = @(Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue)[0].Source
if (-not $pwshExe) { $pwshExe = (Get-Process -Id $PID).Path }
if ($useProc) {
  $logRoot = if ($LogDir) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogDir) } else { Join-Path $stage 'logs' }
  New-Item -ItemType Directory -Force $logRoot | Out-Null
}

# A suite must not depend on how busy this machine is. Admission by load (ADR 0009 stage 0) judges a real
# start-latency probe: on a saturated workstation a lease or a second build inside a suite waited up to
# admission.maxHoldMin and suites failed that pass on an idle machine. Off for every suite; the suites
# that test admission clear the variable and fake the probe (AGENTQ_PROBE_FAKE).
$prevNoAdmission = $env:AGENTQ_NO_ADMISSION
$env:AGENTQ_NO_ADMISSION = '1'

$bad = @(); $ran = 0; $skipped = 0
$total = [Diagnostics.Stopwatch]::StartNew()
# Hash BEFORE the suites: a run that is edited mid-flight must not record the tree it did not test
# (2026-11-20: a 35-min full run was edited while it ran; without this the record would have claimed
# "green" for code the suites never saw).
$hashAtStart = Get-SourceHash
# Suites that must own the machine: they install, reap terminals, interrupt a shell or rewrite git state.
# Under -Parallel they are a barrier - the pool drains, they run alone, the pool resumes.
$serialOnly = @('install', 'term interrupt', 'reap terminals', 'git-autosync', 'guard cloud', 'deploy guard')
$running = @()
function Get-SuiteArgv($a) {
  # -Command text goes base64 (-EncodedCommand) so it needs no quoting on the cmd.exe line;
  # -OutputFormat Text because an encoded command otherwise writes errors as CLIXML into the log
  if ($a[0] -eq '-Command') { @('-NoProfile', '-OutputFormat', 'Text', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($a[1..($a.Count - 1)] -join ' ')))) } else { @('-NoProfile') + $a }
}
function Get-SuiteLog([string]$k) { Join-Path $logRoot (($k -replace '[^A-Za-z0-9._-]+', '-') + '.log') }
# finish one pooled suite: wait (or kill on timeout), print, and answer whether it failed
function Finish-Suite($j) {
  $expired = $j.TimeoutSec -gt 0 -and $j.Sw.Elapsed.TotalSeconds -gt $j.TimeoutSec
  if ($expired -and -not $j.Proc.HasExited) {
    $j.TimedOut = $true; $j.TimeoutSec = 0
    & taskkill.exe /T /F /PID $j.Proc.Id 2>&1 | Out-Null
    $null = $j.Proc.WaitForExit(15000)
  }
  $r = Complete-Suite $j
  $script:ran++
  [bool](Report-Suite $r.Name $r.Code $r.TimedOut $r.Sec @(Read-LogLines $r.Log) $r.Log)
}
function Drain-Pool {
  foreach ($j in @($running)) {
    $script:running = @($script:running | Where-Object { $_ -ne $j })
    if (Finish-Suite $j) { $script:bad += $j.Name }
  }
}
foreach ($k in $selected) {
  $a = $suites[$k]
  if ($skipWhy.ContainsKey($k)) { Write-Host "SKIP $k ($($skipWhy[$k]))"; $skipped++; continue }
  if ($a[0] -eq '-File' -and -not (Test-Path $a[1])) { Write-Host "SKIP $k (missing $($a[1]))"; $skipped++; continue }
  if ($usePool -and -not ($serialOnly -contains $k)) {
    # a free slot, or the barrier of a serial-only suite (or the end of the list)
    while ($running.Count -ge $Parallel) {
      foreach ($j in @($running)) {
        $expired = $j.TimeoutSec -gt 0 -and $j.Sw.Elapsed.TotalSeconds -gt $j.TimeoutSec
        if ($j.Proc.HasExited -or $expired) {
          $running = @($running | Where-Object { $_ -ne $j })
          if (Finish-Suite $j) { $bad += $j.Name }
          break
        }
      }
      if ($running.Count -ge $Parallel) { Start-Sleep -Milliseconds 200 }
    }
    $log = Get-SuiteLog $k
    try { $running += Start-Suite $k (Get-SuiteArgv $a) $log }
    catch { $ran++; $bad += $k; Write-Host "$k exit=1"; Write-Host "   FAIL run-all could not start the suite: $($_.Exception.Message)" }
    continue
  }
  if ($running.Count) { Drain-Pool }
  $sw = [Diagnostics.Stopwatch]::StartNew(); $code = 0; $timedOut = $false; $log = $null
  if ($useProc) {
    $log = Get-SuiteLog $k
    try {
      $r = Invoke-Logged $pwshExe (Get-SuiteArgv $a) $log ($TimeoutMin * 60)
      $code = $r.Code; $timedOut = $r.TimedOut; $out = @(Read-LogLines $log)
    } catch { $code = 1; $out = @("FAIL run-all could not start the suite: $($_.Exception.Message)") }
  } else {
    $out = @(& pwsh -NoProfile @a 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
  }
  $ran++
  if (Report-Suite $k $code $timedOut ([int][math]::Round($sw.Elapsed.TotalSeconds)) $out $log) { $bad += $k }
}
if ($running.Count) { Drain-Pool }
cmd /c rmdir /s /q "`"$stage`"" 2>$null
if ($null -ne $prevNoAdmission) { $env:AGENTQ_NO_ADMISSION = $prevNoAdmission } else { Remove-Item Env:AGENTQ_NO_ADMISSION -ErrorAction SilentlyContinue }
Write-Host ("TOTAL sec={0} suites={1} failed={2} skipped={3}" -f [int][math]::Round($total.Elapsed.TotalSeconds), $ran, $bad.Count, $skipped)
if ($bad) { Write-Host "FAILED: $($bad -join ', ')"; exit 1 }
# -Only/-Skip (or missing files) can leave nothing to run: that is not a pass
if (-not $ran) { Write-Host 'NO SUITES RAN'; exit 1 }
# A FULL green run (no -Only/-Skip, nothing skipped) is the record `install.ps1` trusts for an unchanged
# tree, so a repeat install does not pay the whole suite again.
if (-not $onlyNames.Count -and -not $skipWhy.Count -and -not $skipped) {
  try {
    New-Item -ItemType Directory -Force (Split-Path $greenFile) | Out-Null
    $hashNow = Get-SourceHash
    if ($hashNow -ne $hashAtStart) { Write-Host 'green record: NOT written - ps/ changed while the suites ran (this green is for neither tree)' }
    else {
    [ordered]@{ hash = $hashNow; at = (Get-Date).ToString('s'); suites = $ran
      sec = [int][math]::Round($total.Elapsed.TotalSeconds); psver = "$($PSVersionTable.PSVersion)"; machine = [Environment]::MachineName } |
      ConvertTo-Json -Compress | Set-Content -LiteralPath $greenFile -Encoding utf8
    Write-Host "green record: $greenFile"
    }
  } catch { Write-Host "green record: not written ($($_.Exception.Message))" }
}
Write-Host 'ALL SUITES PASS'; exit 0
