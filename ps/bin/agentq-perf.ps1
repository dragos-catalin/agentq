# ------------------------------------------------------------------------------------------------
# agentq perf (2026-11-24): record EVERY lane run, keep the history, keep a baseline, report it.
#
# WHY
#   A lane that holds for minutes was invisible AFTER the fact. The journal has `acquired`/`done`
#   pairs, but nothing per RUN: no duration per lane, no wait-vs-hold split, no baseline, no average.
#   An agent that waited 40 min could not see that the lane's p90 had tripled, nor that the holder was
#   a `commit:<repo>` counted as one run after the commit/push split (ADR 0014 D1).
#
# WHERE - the choke point
#   The choke point is the TICKET FILE, not a function: one JSON file per ticket in the queue dir, and a
#   run ENDS when that file is removed. Removal is inlined at six sites - the reap family shares
#   Remove-Ticket, every other lane removes in place - so the recorder is called at each of them, BEFORE
#   the file goes:
#     agentq.ps1    Remove-Ticket         every reap / break / timeout / giveup: a holder that died, a
#                                         -NoWait giveup, a waiter that never got the resource
#     agentq.ps1    Drop-Ticket           the early giveback of commit:<repo> (ADR 0014 D1 - the index
#                                         lock ends before the pre-push gates) and of push:<repo>
#     agentq.ps1    Invoke-Run finally    every `run` lane: build / install / deploy, local and cloud
#     agentq.ps1    Invoke-Commit finally a commit that FAILED never reached the early drop, so its
#                                         ticket is still there and this records its real verdict
#     agentq.ps1    Invoke-Release        the normal end of `acquire` (outcome 'done', exit 0)
#     agentq-v2.ps1 Invoke-Land finally   land:<repo>
#   That covers build:machine, build:<repo>, install:<repo>, commit:<repo>, push:<repo>, land:<repo> and
#   deploy:<repo>:<target>; deploy-clean.ps1 takes its own ticket through `agentq run`, so deploy needs no
#   site of its own. The ticket file is BOTH the input (it carries `created`/`acquired`) and the lock: a
#   second call for the same ticket finds no file and returns, so each ticket yields exactly ONE record
#   however many of these sites it passes through - no journal scan, no second process in the hot path.
#
# WHAT
#   <user store>/perf/<repo>.jsonl   one line per run. Append-only, NEVER rotated: the baseline is
#                                    defined over ALL retained history. ~350 B/run; 500 runs/day is
#                                    ~175 KB/day, ~64 MB/year.
#   <user store>/perf/baseline.json  per repo+lane p50/p90/mean/max/n/fail. Rewritten ONLY by
#                                    `agentq perf -RefreshBaseline`, never silently.
#   one `perf` journal event per run, so agentq-sync (which pushes the journal, not perf/) and the
#   hub's /ops/agentq see the run with no schema change.
#
# NEVER in a run's way: every entry point is wrapped; the first failure is journaled once as
# `perf-write-failed` and the recorder then goes quiet for the rest of the process.
# AGENTQ_NO_PERF=1 disables recording completely (the A/B overhead measurement and the suite use it).
#
# Every number the report prints is formatted INVARIANT: the file must be byte-identical whatever the
# machine's culture is, and `78,1` in a report read by an agent is an ambiguity, not a style.
# ------------------------------------------------------------------------------------------------

# Pre-initialised at the top level of a DOT-SOURCED file on purpose: under Set-StrictMode a read of an
# unset script-scope variable throws, and Complete-TicketRun runs inside `finally` blocks where a throw
# would replace the real error. None of these names is set by the argument parser (see the 2026-11-22
# clobber note in agentq.ps1), so nothing here can wipe a flag.
$script:PerfFailed = $false
$script:PerfExit = 0
# The hot fields, in the order ConvertTo-PerfLine writes them, are read by ONE regex for the whole file.
# `[^"\\]*` is deliberate: it matches only a value that needed no JSON escaping, so a weird resource or a
# session with a quote makes the match FAIL and the line falls through to the full JSON parser instead of
# being silently truncated. Speed where it is safe, correctness where it is not.
$script:PerfRx = [regex]::new('^\{"v":(\d+),"ts":(\d+),"w":(-?[\d.]+),"h":(-?[\d.]+),"d":(-?[\d.]+),"x":(-?\d+),"rc":"([^"\\]*)","rp":"([^"\\]*)","ln":"([^"\\]*)","kd":"([^"\\]*)","ok":([01]),"oc":"([^"\\]*)","ss":"([^"\\]*)","hs":"([^"\\]*)","us":"([^"\\]*)"')
$script:PerfInv = [Globalization.CultureInfo]::InvariantCulture
# -999 = the caller had no exit code for this ticket (a break/reap of a waiter). `null` would be more
# honest in JSON but costs every consumer a null branch; one sentinel is enough and it is documented.
$script:PerfNoExit = -999

function Get-PerfDir { Join-Path $Root 'perf' }

function Test-PerfEnabled { return ($env:AGENTQ_NO_PERF -ne '1' -and -not $script:PerfFailed) }

# A recordable repo NAME. The resource already carries it (`build:codai`, `deploy:brivio:web`) and that is
# the name the report groups by - NOT the ticket's `repo`, which is a PATH whose leaf is a slot name
# (`task-1`) inside a worktree. No git subprocess, no per-run cost.
function Get-PerfRepoName([string]$res, [string]$repoPath) {
  if ($res -eq 'build:machine' -or $res -eq 'machine') { return 'machine' }
  $r = "$(Get-ResourceRepo $res)"
  if ($r) { return $r.ToLowerInvariant() }
  if ($repoPath) { return (Split-Path -Leaf ($repoPath.TrimEnd('\', '/'))).ToLowerInvariant() }
  'other'
}

function Get-PerfFileName([string]$repoKey) { (($repoKey -replace '[\\/:*?"<>|]', '_') + '.jsonl') }
function Get-PerfFile([string]$repoKey) { Join-Path (Get-PerfDir) (Get-PerfFileName $repoKey) }
function Get-PerfBaselineFile { Join-Path (Get-PerfDir) 'baseline.json' }

# The ONE place a write failure is reported: once per process, out of the run's way, and it says so.
function Write-PerfFailure([string]$why, [string]$where) {
  if ($script:PerfFailed) { return }
  $script:PerfFailed = $true
  try { Write-Journal @{ event = 'perf-write-failed'; resource = 'perf'; where = $where; reason = "$why" } } catch {}
  try {
    [Console]::Error.WriteLine("agentq: perf: cannot record ($where): $why")
    [Console]::Error.WriteLine("        the measured run itself is NOT affected; nothing is recorded for the rest of this process")
  } catch {}
}

function ConvertTo-PerfDouble([string]$s) {
  if (-not $s) { return 0.0 }
  try { [double]::Parse($s, $script:PerfInv) } catch { 0.0 }
}
function ConvertTo-PerfInt([string]$s, [int]$dflt = 0) {
  $v = 0
  if ([int]::TryParse("$s", [ref]$v)) { return $v }
  $dflt
}

# JSON string escaping with the invariant on numbers: the file must be byte-identical whatever the
# machine's culture is, and a purpose containing a newline must not split one record into two lines.
function ConvertTo-PerfString([string]$s) {
  if (-not $s) { return '""' }
  $sb = [Text.StringBuilder]::new($s.Length + 2)
  [void]$sb.Append('"')
  foreach ($ch in $s.ToCharArray()) {
    $c = [int]$ch
    if ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($ch -eq '"') { [void]$sb.Append('\"') }
    elseif ($c -lt 32) {
      switch ($c) {
        8 { [void]$sb.Append('\b') }
        9 { [void]$sb.Append('\t') }
        10 { [void]$sb.Append('\n') }
        12 { [void]$sb.Append('\f') }
        13 { [void]$sb.Append('\r') }
        default { [void]$sb.Append('\u'); [void]$sb.Append($c.ToString('x4', $script:PerfInv)) }
      }
    } else { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  $sb.ToString()
}

function Format-PerfNum([double]$v, [string]$fmt = '0.###') { [string]::Format($script:PerfInv, $fmt, $v) }

# One line per run. The key order is FIXED and load-bearing: the hot, quote-free fields come first so the
# report reads them with one regex (~25 us/line); `ps`/`cm` come last and are parsed only for the handful
# of lines the report actually prints.
function ConvertTo-PerfLine($r) {
  # `[Collections.Generic.List[string]]`, NOT `[List[string]]`: `List` is not a PowerShell type
  # accelerator and there is no implicit `System.Collections.Generic` search, so the short form throws
  # "Unable to find type [List]." AT RUNTIME - inside the recorder's catch, where it looks like a store
  # problem rather than a typo (found live 2026-11-28 by test-agentq-perf.ps1, which is why that suite
  # fails if the recording call disappears).
  $p = [Collections.Generic.List[string]]::new(24)
  $p.Add('"v":1')
  $p.Add('"ts":' + [string]$r.ts)
  $p.Add('"w":' + (Format-PerfNum ([double]$r.w)))
  $p.Add('"h":' + (Format-PerfNum ([double]$r.h)))
  $p.Add('"d":' + (Format-PerfNum ([double]$r.d)))
  $p.Add('"x":' + [string]$r.x)
  $p.Add('"rc":' + (ConvertTo-PerfString "$($r.rc)"))
  $p.Add('"rp":' + (ConvertTo-PerfString "$($r.rp)"))
  $p.Add('"ln":' + (ConvertTo-PerfString "$($r.ln)"))
  $p.Add('"kd":' + (ConvertTo-PerfString "$($r.kd)"))
  $p.Add('"ok":' + $(if ($r.ok) { '1' } else { '0' }))
  $p.Add('"oc":' + (ConvertTo-PerfString "$($r.oc)"))
  $p.Add('"ss":' + (ConvertTo-PerfString "$($r.ss)"))
  $p.Add('"hs":' + (ConvertTo-PerfString "$($r.hs)"))
  $p.Add('"us":' + (ConvertTo-PerfString "$($r.us)"))
  $p.Add('"st":' + (ConvertTo-PerfString "$($r.st)"))
  $p.Add('"aq":' + (ConvertTo-PerfString "$($r.aq)"))
  $p.Add('"rs":' + (ConvertTo-PerfString "$($r.rs)"))
  $p.Add('"ps":' + (ConvertTo-PerfString "$($r.ps)"))
  $p.Add('"cm":' + (ConvertTo-PerfString "$($r.cm)"))
  '{' + ($p -join ',') + '}'
}

# Append one record. The mutex mirrors Write-Journal's: several agentq processes finish on the same repo
# at the same time, and [IO.File]::AppendAllText holds the file open exclusively, so without it a
# concurrent record would be lost (or worse, throw inside a finally).
function Add-PerfLine([string]$file, [string]$line) {
  $dir = Split-Path -Parent $file
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $m = [Threading.Mutex]::new($false, "Global\agentq-perf$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  $got = $false
  try {
    try { $got = $m.WaitOne(5000) } catch [Threading.AbandonedMutexException] { $got = $true }
    if (-not $got) { throw 'perf file lock timeout (another agentq is writing)' }
    [IO.File]::AppendAllText($file, $line + "`n", [Text.UTF8Encoding]::new($false))
  } finally { if ($got) { try { $m.ReleaseMutex() } catch {} }; $m.Dispose() }
}

# ------------------------------------------------------------------------------------------------
# THE recorder. Called at every ticket-removal site, BEFORE the files are removed - the ticket file is the
# input (it holds `created`/`acquired`), and its absence is what makes a second call a no-op (the commit
# path drops its ticket twice: once when the index lock ends, once in the finally).
# Never throws, never blocks a run, never fails a run.
# ------------------------------------------------------------------------------------------------
function Complete-TicketRun($t, [string]$Outcome = '', [int]$Exit = -999, [string]$Reason = '') {
  try {
    if (-not (Test-PerfEnabled)) { return }
    if (-not $t) { return }
    $f = "$(P $t 'file')"
    if (-not $f -or -not (Test-Path -LiteralPath $f)) { return }
    $cur = $t
    try { $cur = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -DateKind String } catch {}
    $created = $null
    try { $created = ParseUtc "$(P $cur 'created' '')" } catch { $created = $null }
    if (-not $created) { try { $created = (Get-Item -LiteralPath $f).CreationTimeUtc } catch { $created = $null } }
    if (-not $created) { return }
    $acqRaw = "$(P $cur 'acquired' '')"
    $acq = $null
    if ($acqRaw) { try { $acq = ParseUtc $acqRaw } catch { $acq = $null } }
    $end = Now
    $dur = [math]::Round(($end - $created).TotalSeconds, 3)
    $hold = if ($acq) { [math]::Round(($end - $acq).TotalSeconds, 3) } else { 0 }
    # A waiter that never got the resource still has a lifetime worth recording - that IS the "I waited
    # for minutes" story - and for it the whole lifetime is the wait.
    $wait = if ($acq) { [math]::Round(($acq - $created).TotalSeconds, 3) } else { $dur }
    $res = "$(P $cur 'resource' '')"
    $repoKey = Get-PerfRepoName $res "$(P $cur 'repo' '')"
    $oc = if ($Outcome) { $Outcome } elseif ($acq) { 'ok' } else { 'giveup' }
    $cmd = "$(P $cur 'cmd' '')"
    $row = [ordered]@{
      ts = [long]([DateTimeOffset]$end.ToUniversalTime()).ToUnixTimeSeconds()
      w = $wait; h = $hold; d = $dur; x = $Exit
      rc = $res; rp = $repoKey; ln = "$(P $cur 'lane' 'gate')"; kd = (Get-CmdKind $cmd)
      ok = @('ok', 'done') -contains $oc
      oc = $oc
      ss = "$(P $cur 'session' '')"; hs = [Environment]::MachineName; us = [Environment]::UserName
      st = (Iso $created); aq = $(if ($acq) { Iso $acq } else { '' })
      rs = $Reason
      ps = "$(P $cur 'purpose' '')"; cm = $cmd
    }
    Add-PerfLine (Get-PerfFile $repoKey) (ConvertTo-PerfLine $row)
    # The same run, compact, one journal line: agentq-sync pushes the journal (not perf/), so this is the
    # only reason the hub's /ops/agentq sees a run at all - and the gateway takes an opaque journal line,
    # so no gateway change is needed for any of this.
    try {
      Write-Journal @{ event = 'perf'; resource = $res; repo = $repoKey; lane = $row.ln; kind = $row.kd; outcome = $oc; exit = $Exit; waitSec = $wait; holdSec = $hold; durSec = $dur; purpose = $row.ps }
    } catch {}
  } catch { Write-PerfFailure "$($_.Exception.Message)" 'record' }
}

# ------------------------------------------------------------------------------------------------
# readers: the report and the baseline. Never the journal.
# ------------------------------------------------------------------------------------------------
function ConvertFrom-PerfRunLine([string]$line) {
  $m = $script:PerfRx.Match($line)
  if ($m.Success) {
    return [pscustomobject]@{
      ts = [long]$m.Groups[2].Value
      w = ConvertTo-PerfDouble $m.Groups[3].Value
      h = ConvertTo-PerfDouble $m.Groups[4].Value
      d = ConvertTo-PerfDouble $m.Groups[5].Value
      x = ConvertTo-PerfInt $m.Groups[6].Value $script:PerfNoExit
      rc = $m.Groups[7].Value; rp = $m.Groups[8].Value; ln = $m.Groups[9].Value; kd = $m.Groups[10].Value
      ok = ($m.Groups[11].Value -eq '1')
      oc = $m.Groups[12].Value; ss = $m.Groups[13].Value; hs = $m.Groups[14].Value; us = $m.Groups[15].Value
      raw = $line
    }
  }
  # Slow path: only for a line with a quote/backslash/control char inside a HOT field. Correct, and rare
  # enough that it never matters - but it must exist, or such a record would vanish from the history.
  try {
    $o = $line | ConvertFrom-Json -DateKind String
    return [pscustomobject]@{
      ts = [long](ConvertTo-PerfDouble "$(P $o 'ts' 0)")
      w = ConvertTo-PerfDouble "$(P $o 'w' 0)"; h = ConvertTo-PerfDouble "$(P $o 'h' 0)"; d = ConvertTo-PerfDouble "$(P $o 'd' 0)"
      x = ConvertTo-PerfInt "$(P $o 'x' $script:PerfNoExit)" $script:PerfNoExit
      rc = "$(P $o 'rc' '')"; rp = "$(P $o 'rp' '')"; ln = "$(P $o 'ln' '')"; kd = "$(P $o 'kd' '')"
      ok = ("$(P $o 'ok' 0)" -eq '1'); oc = "$(P $o 'oc' '')"; ss = "$(P $o 'ss' '')"; hs = "$(P $o 'hs' '')"; us = "$(P $o 'us' '')"
      raw = $line
    }
  } catch { return $null }
}

# $sinceSec <= 0 means "all retained history" (the baseline is defined over it, so the window must not
# silently clamp it to zero records).
function Get-PerfRuns([string]$repoKey, [double]$sinceSec) {
  $dir = Get-PerfDir
  if (-not (Test-Path -LiteralPath $dir)) { return @() }
  $want = if ($repoKey) { Get-PerfFileName $repoKey } else { '' }
  $files = @(Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -File -ErrorAction SilentlyContinue | Where-Object { -not $want -or $_.Name -eq $want })
  $cut = if ($sinceSec -gt 0) { [long]([DateTimeOffset](Now).ToUnixTimeSeconds() - [long]$sinceSec) } else { [long]0 }
  $rows = [Collections.Generic.List[object]]::new()
  $enc = [Text.UTF8Encoding]::new($false)
  foreach ($f in $files) {
    try {
      foreach ($line in [IO.File]::ReadLines($f.FullName, $enc)) {
        if (-not $line -or $line.Length -lt 20 -or $line[0] -ne '{') { continue }
        $r = ConvertFrom-PerfRunLine $line
        if (-not $r) { continue }
        if ($r.ts -lt $cut) { continue }
        $rows.Add($r)
      }
    } catch { Write-PerfFailure "$($_.Exception.Message)" "read $($f.Name)" }
  }
  $rows
}

# Nearest rank: sorted[ceil(p*n)-1]. Stated here because "p90" has three common definitions and a report
# is useless if the reader cannot reproduce the number.
function Get-Percentile($sorted, [double]$p) {
  $s = @($sorted)
  if ($s.Count -eq 0) { return 0 }
  $i = [int][math]::Ceiling($p * $s.Count) - 1
  if ($i -lt 0) { $i = 0 }
  if ($i -ge $s.Count) { $i = $s.Count - 1 }
  [math]::Round([double]$s[$i], 1)
}

function Get-PerfStats($rows) {
  $a = @($rows)
  $n = $a.Count
  if ($n -eq 0) { return [pscustomobject]@{ n = 0; fail = 0; w50 = 0; w90 = 0; wMean = 0; h50 = 0; h90 = 0; hMax = 0; hMean = 0 } }
  $holds = @($a | ForEach-Object { [double]$_.h } | Sort-Object)
  $waits = @($a | ForEach-Object { [double]$_.w } | Sort-Object)
  [pscustomobject]@{
    n = $n
    fail = @($a | Where-Object { -not $_.ok }).Count
    w50 = Get-Percentile $waits 0.5; w90 = Get-Percentile $waits 0.9
    wMean = [math]::Round((($waits | Measure-Object -Average).Average), 1)
    h50 = Get-Percentile $holds 0.5; h90 = Get-Percentile $holds 0.9
    hMax = [math]::Round($holds[-1], 1)
    hMean = [math]::Round((($holds | Measure-Object -Average).Average), 1)
  }
}

function Group-PerfRows($rows) {
  $g = [ordered]@{}
  foreach ($r in @($rows)) {
    $k = "$($r.rp)|$($r.rc)"
    if (-not $g.Contains($k)) { $g[$k] = [Collections.Generic.List[object]]::new() }
    $g[$k].Add($r)
  }
  $g
}

function Get-PerfWindowSec([string]$spec) {
  if (-not $spec) { return 7 * 86400 }
  if ($spec -notmatch '^\s*(\d+(?:[.,]\d+)?)\s*([smhdw]?)\s*$') { throw "agentq perf: -Since must look like 90s, 30m, 48h, 7d or 2w (got '$spec')" }
  $n = [double]::Parse(($Matches[1] -replace ',', '.'), $script:PerfInv)
  switch ("$($Matches[2])") {
    's' { $n }
    'm' { $n * 60 }
    'h' { $n * 3600 }
    'w' { $n * 604800 }
    default { $n * 86400 }
  }
}

# -Repo takes a NAME (codai) or the path an agent has in its clipboard (E:\gh\codai).
function Get-PerfRepoFilter([string]$repo) {
  if (-not $repo) { return '' }
  if (Test-Path -LiteralPath $repo) {
    try { $i = Get-RepoInfo $repo; if ($i) { return $i.Name.ToLowerInvariant() } } catch {}
    return (Split-Path -Leaf ($repo.TrimEnd('\', '/'))).ToLowerInvariant()
  }
  $repo.ToLowerInvariant()
}

function Read-PerfBaseline {
  $f = Get-PerfBaselineFile
  if (-not (Test-Path -LiteralPath $f)) { return $null }
  try { return (Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable) } catch { return $null }
}

# ALL retained history, never the -Since window: a baseline that moves with the window is not a baseline.
function Update-PerfBaseline {
  $rows = @(Get-PerfRuns '' 0)
  $groups = Group-PerfRows $rows
  $lanes = [ordered]@{}
  foreach ($k in @($groups.Keys)) {
    $s = Get-PerfStats $groups[$k]
    $lanes[$k] = [ordered]@{ n = $s.n; p50 = $s.h50; p90 = $s.h90; mean = $s.hMean; max = $s.hMax; fail = $s.fail }
  }
  $obj = [ordered]@{ v = 1; at = (Iso (Now)); src = 'all retained history'; runs = $rows.Count; lanes = $lanes }
  $f = Get-PerfBaselineFile
  $dir = Split-Path -Parent $f
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $tmp = "$f.$PID.tmp"
  [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move($tmp, $f, $true)
  Write-Output "perf: baseline refreshed -> $f"
  Write-Output "      $(@($lanes.Keys).Count) lanes, $($rows.Count) runs, source: all retained history"
}

function Get-PerfText($line) {
  try {
    $o = $line | ConvertFrom-Json -DateKind String
    return @("$(P $o 'ps' '')", "$(P $o 'cm' '')")
  } catch { return @('', '') }
}

function Format-PerfWindow([double]$sec) {
  if ($sec -ge 604800 -and ($sec % 604800) -eq 0) { return "$([int]($sec / 604800))w" }
  if ($sec -ge 86400 -and ($sec % 86400) -eq 0) { return "$([int]($sec / 86400))d" }
  if ($sec -ge 3600 -and ($sec % 3600) -eq 0) { return "$([int]($sec / 3600))h" }
  if ($sec -ge 60) { return "$([int]($sec / 60))m" }
  "$([int]$sec)s"
}

function Format-PerfAt([string]$iso) {
  try { return ([DateTimeOffset]::Parse($iso, $script:PerfInv)).UtcDateTime.ToString('yyyy-MM-ddTHH:mmZ', $script:PerfInv) } catch { return $iso }
}

# ------------------------------------------------------------------------------------------------
# the report: `agentq perf [-Repo R] [-Lane L] [-Since 7d] [-Top n] [-Slow] [-Trend] [-RefreshBaseline]
#                          [-FailOnRegression] [-Json]`
# Read-only unless -RefreshBaseline (agentq.ps1 keeps `perf` in $script:ReadOnly except for that flag).
# Exit 0, or 2 with -FailOnRegression when a lane regressed (p90 > 1.5 x baseline p90 and n >= 10).
# ------------------------------------------------------------------------------------------------
function Show-Perf {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $sinceSec = Get-PerfWindowSec $Since
  $repoFilter = Get-PerfRepoFilter $Repo
  if ($RefreshBaseline) { Update-PerfBaseline }
  $rows = @(Get-PerfRuns $repoFilter $sinceSec)
  if ($Lane) { $rows = @($rows | Where-Object { "$($_.rc)" -like "*$Lane*" -or "$($_.ln)" -like "*$Lane*" }) }
  $base = Read-PerfBaseline
  $from = (Now).AddSeconds(-$sinceSec)
  $groups = Group-PerfRows $rows
  $keys = @($groups.Keys)
  $stats = [ordered]@{}
  foreach ($k in $keys) { $stats[$k] = Get-PerfStats $groups[$k] }
  # worst hold p90 first: the lane most likely to block someone is the one to read first
  $keys = @($keys | Sort-Object { -$stats[$_].h90 }, { -$stats[$_].n })
  $rowsSorted = @($rows | Sort-Object { -[double]$_.h })
  $sessions = @($rows | Group-Object ss | Sort-Object Count -Descending)

  $regressions = @(); $notJudged = @(); $shown = @()
  foreach ($k in $keys) {
    $s = $stats[$k]
    $bl = if ($base -and $base.ContainsKey('lanes') -and $base.lanes.ContainsKey($k)) { $base.lanes[$k] } else { $null }
    $b90 = if ($bl) { [double]$bl.p90 } else { $null }
    $ratio = if ($b90 -and $b90 -gt 0) { [math]::Round($s.h90 / $b90, 2) } else { $null }
    $o = [pscustomobject]@{ key = $k; repo = ($k -split '\|')[0]; lane = ($k -split '\|')[1]; s = $s; base90 = $b90; ratio = $ratio; flag = ($null -ne $ratio -and $ratio -gt 1.5 -and $s.n -ge 10) }
    $shown += $o
    if ($o.flag) { $regressions += $o }
    if ($s.n -lt 10) { $notJudged += $o }
  }

  if ($Json) {
    $out = [ordered]@{
      ok = $true; sinceSec = $sinceSec; since = (Iso $from); until = (Iso (Now))
      runs = $rows.Count; lanes = $keys.Count; sessions = $sessions.Count
      baselineAt = $(if ($base) { "$($base.at)" } else { $null })
      baselineSrc = $(if ($base) { "$($base.src)" } else { $null })
      stats = @($shown | ForEach-Object { [ordered]@{ lane = $_.key; repo = $_.repo; resource = $_.lane; n = $_.s.n; fail = $_.s.fail; w50 = $_.s.w50; w90 = $_.s.w90; h50 = $_.s.h50; h90 = $_.s.h90; max = $_.s.hMax; mean = $_.s.hMean; base90 = $_.base90; ratio = $_.ratio; regression = [bool]$_.flag } })
      regressions = @($regressions | ForEach-Object { "$($_.key)" })
      notJudged = @($notJudged | ForEach-Object { [ordered]@{ lane = "$($_.key)"; n = $_.s.n } })
      holders = @($sessions | ForEach-Object { $st = Get-PerfStats $_.Group; [ordered]@{ session = "$($_.Name)"; n = $st.n; holdMean = $st.hMean; waitMean = $st.wMean; fail = $st.fail } })
      ms = $sw.ElapsedMilliseconds
    }
    $out | ConvertTo-Json -Depth 6
    if ($FailOnRegression -and $regressions.Count) { $script:PerfExit = 2 }
    return
  }

  Write-Output "agentq perf - $(Format-PerfWindow $sinceSec) window ($(Iso $from) -> $(Iso (Now)))"
  Write-Output "  $($rows.Count) runs, $($keys.Count) lanes, $($sessions.Count) sessions$(if ($Lane) { ", -Lane '$Lane'" })"
  if ($base) {
    Write-Output "  baseline $(Format-PerfAt "$($base.at)") - $($base.src) ($($base.runs) runs, $(@($base.lanes.Keys).Count) lanes)"
  } else {
    Write-Output "  baseline: none yet - freeze one with 'agentq perf -RefreshBaseline' once the history is worth comparing against"
  }
  if (-not $rows.Count) {
    Write-Output ''
    Write-Output '  no run recorded in this window. Recording starts with the next ticket: nothing is backfilled from'
    Write-Output '  the journal, because the ticket file is the source and those files are gone.'
  } else {
    $wRepo = 4; $wLane = 4
    foreach ($o in $shown) {
      if ($o.repo.Length -gt $wRepo) { $wRepo = [math]::Min(22, $o.repo.Length) }
      if ($o.lane.Length -gt $wLane) { $wLane = [math]::Min(26, $o.lane.Length) }
    }
    Write-Output ''
    Write-Output (('  {0,-' + $wRepo + '} {1,-' + $wLane + '} {2,6} {3,5} {4,6} {5,6} {6,6} {7,7} {8,7} {9,7} {10,7} {11,6}') -f 'repo', 'lane', 'n', 'fail', 'w50', 'w90', 'h50', 'h90', 'max', 'mean', 'base90', 'ratio')
    foreach ($o in $shown) {
      $s = $o.s
      $ratioTxt = if ($null -ne $o.ratio) { (Format-PerfNum ([double]$o.ratio) '0.00') + 'x' } elseif ($null -ne $o.base90) { '-' } else { 'n/a' }
      Write-Output (('  {0,-' + $wRepo + '} {1,-' + $wLane + '} {2,6} {3,5} {4,6} {5,6} {6,6} {7,7} {8,7} {9,7} {10,7} {11,6}{12}') -f `
          $o.repo, $o.lane, [string]$s.n, [string]$s.fail, (Format-PerfNum ([double]$s.w50) '0.#'), (Format-PerfNum ([double]$s.w90) '0.#'), `
          (Format-PerfNum ([double]$s.h50) '0.#'), (Format-PerfNum ([double]$s.h90) '0.#'), (Format-PerfNum ([double]$s.hMax) '0.#'), `
          (Format-PerfNum ([double]$s.hMean) '0.#'), $(if ($null -ne $o.base90) { Format-PerfNum ([double]$o.base90) '0.#' } else { '-' }), $ratioTxt, `
          $(if ($o.flag) { '  !' } else { '' }))
    }
    Write-Output ''
    Write-Output '  seconds. w = wait for the ticket, h = hold. p50/p90 = nearest rank. A trailing ``!`` marks a regression.'
    if ($regressions.Count) {
      Write-Output "== REGRESSIONS (hold p90 > 1.5 x baseline p90, n >= 10): $($regressions.Count)"
      foreach ($o in $regressions) {
        Write-Output ("   {0}  p90 {1}s vs baseline {2}s ({3}x, n={4})" -f $o.key, (Format-PerfNum ([double]$o.s.h90) '0.#'), (Format-PerfNum ([double]$o.base90) '0.#'), (Format-PerfNum ([double]$o.ratio) '0.00'), [string]$o.s.n)
      }
    } else {
      Write-Output '== regressions (hold p90 > 1.5 x baseline p90, n >= 10): none'
    }
    if ($notJudged.Count) {
      Write-Output "== not judged, n < 10, so a 1.5x move here is noise: $(($notJudged | ForEach-Object { "$($_.key) ($($_.s.n))" }) -join ', ')"
    }
    $top = [math]::Max(0, [math]::Min(50, $Top))
    if ($top -gt 0 -and $rowsSorted.Count) {
      # -Slow switches the selection from "the N slowest" to "the N over 2x their lane's baseline p90",
      # which is the question an agent actually has when something felt wrong.
      $cand = if ($Slow) {
        @($rowsSorted | Where-Object {
            $bl = if ($base -and $base.ContainsKey('lanes')) { $base.lanes["$($_.rp)|$($_.rc)"] } else { $null }
            $b = if ($bl) { [double]$bl.p90 } else { (Get-PerfStats $groups["$($_.rp)|$($_.rc)"]).h90 }
            $b -gt 0 -and [double]$_.h -gt 2 * $b
          } | Select-Object -First $top)
      } else { @($rowsSorted | Select-Object -First $top) }
      if ($cand.Count) {
        Write-Output $(if ($Slow) { '== slow runs (hold > 2 x the lane baseline p90)' } else { "== slowest runs (top $($cand.Count) by hold)" })
        foreach ($r in $cand) {
          $txt = Get-PerfText "$($r.raw)"
          $verdict = if ($r.ok) { 'ok' } else { "FAILED/$($r.oc)" }
          $exit = if ([int]$r.x -eq $script:PerfNoExit) { '' } else { " exit=$($r.x)" }
          $when = [DateTimeOffset]::FromUnixTimeSeconds([long]$r.ts).UtcDateTime.ToString('yyyy-MM-ddTHH:mmZ', $script:PerfInv)
          Write-Output ("   {0,7}s  {1,-$wLane} {2}  {3,-18} {4}{5}  {6}" -f (Format-PerfNum ([double]$r.h) '0.#'), $r.rc, $when, "$($r.ss) [$($r.kd)]", $verdict, $exit, "$($txt[1])")
        }
      }
    }
    if ($sessions.Count) {
      Write-Output '== holders (session, runs, hold mean, wait mean, failed)'
      foreach ($g in @($sessions | Select-Object -First 8)) {
        $st = Get-PerfStats $g.Group
        Write-Output ("   {0,-20} {1,4} runs {2,9}s hold {3,9}s wait  {4} failed" -f "$($g.Name)", [string]$st.n, (Format-PerfNum ([double]$st.hMean) '0.#'), (Format-PerfNum ([double]$st.wMean) '0.#'), [string]$st.fail)
      }
    }
    $days = @($rows | Group-Object { [DateTimeOffset]::FromUnixTimeSeconds([long]$_.ts).ToLocalTime().ToString('yyyy-MM-dd', $script:PerfInv) } | Sort-Object Name)
    if ($days.Count -ge 2 -or $Trend) {
      Write-Output "== daily hold p50 (s), $($days.Count) day(s) oldest first"
      foreach ($o in @($shown | Select-Object -First 8)) {
        $cells = @($days | ForEach-Object { $d = $_; $st = Get-PerfStats @($d.Group | Where-Object { "$($_.rp)|$($_.rc)" -eq $o.key }); (Format-PerfNum ([double]$st.h50) '0.#') })
        Write-Output ("   {0,-$wLane} {1}" -f $o.lane, ($cells -join ' '))
      }
    }
  }
  Write-Output ''
  Write-Output ("perf: reported in {0} ms (own read+compute; process start excluded)" -f $sw.ElapsedMilliseconds)
  if ($rows.Count -and $rows.Count -lt 50) { Write-Output "      only $($rows.Count) runs in this window - read every percentile below n=10 as a hint, not a number" }
  if ($FailOnRegression -and $regressions.Count) { $script:PerfExit = 2 }
}
