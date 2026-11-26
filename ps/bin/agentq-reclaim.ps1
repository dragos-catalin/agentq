# agentq-reclaim — release a slot lease ONLY when it is provably safe, with a report-first default.
#
# WHY THIS EXISTS
#   The pool starves when sessions die and leave leases behind, but `agentq sweep` judges staleness from a
#   work clock that ANY agentq call naming the repo refreshes — including the `agentq land` calls waiting for
#   the very slot it should free. The standing net for that is the scheduled `dead-lease-reaper`, which frees
#   ONLY a provably-dead owner and (correctly) refuses to touch a live one. This verb is the explicit,
#   proof-based, on-demand reclaim: it prints, for EVERY lease, whether it is safe to release and WHY, and it
#   acts only under `-Apply`. Its default is to release NOTHING.
#
# SAFETY PREDICATE (see Test-SlotSafeToRelease)
#   A lease is released only when ALL hold:
#     * the record parsed                        (an unreadable record is kept, never guessed at)
#     * the slot is not this process's own       (its pid is not $PID, and the cwd is not inside the slot)
#     * no land pre-gate is active               (`pregateUntil` not in the future; `pregatePid` not alive)
#     * the slot directory exists and git reads  (a git error, or a missing slot, fails closed)
#     * the owner pid state is provable:
#         - GONE      (Get-Process cannot find the pid)                       -> release, backup-first
#         - RECYCLED  (pid alive, start time disagrees by > 5 s with procStart) -> release, backup-first
#         - ALIVE     (pid alive, start time matches) -> release ONLY if the slot is clean AND pushed
#                       AND has been idle >= -IdleHours (default 24). Otherwise kept.
#
#   The clean+pushed clauses gate the ALIVE release; for a proven-gone/recycled owner the release proceeds
#   because the release mechanism itself is the safety net: `agentq unlease` -> Backup-Slot is FAIL-CLOSED and
#   pushes the tree to refs/backup/wt/<repo>/<slot>/<ts> BEFORE the record is dropped, so `agentq recover` can
#   restore it. Requiring clean+pushed there would make reclaim useless exactly in the starvation case the
#   reaper exists for, and would contradict the dead-owner case proving a real backup.
#
# RELEASE MECHANISM
#   Never deletes anything. Every release shells out to `agentq unlease -Repo <slot> -Slot <slot> -LeaseId <id>
#   -Force -Reason <why>` (backup-first, fails closed). If unlease refuses, the lease is kept.
#
# USAGE
#   pwsh -NoProfile -File agentq-reclaim.ps1                      # REPORT ONLY (default) - the WhatIf mode
#   pwsh -NoProfile -File agentq-reclaim.ps1 -Apply               # release only the leases proven safe
#   pwsh -NoProfile -File agentq-reclaim.ps1 -Json                # machine-readable, one JSON object per lease
#   pwsh -NoProfile -File agentq-reclaim.ps1 -IdleHours 12 -Repo codai
#
#   Honours $env:AGENTQ_HOME for the coord root (leases + journal) so a test can run against a temp root.
[CmdletBinding()]
param(
  # Act. Without this the run is report-only (the default must release nothing).
  [switch]$Apply,
  # Accepted for symmetry with the default; a no-op (report-only is already the default).
  [switch]$WhatIf,
  # One JSON object per lease on stdout (for tests / pipelines), instead of the human table.
  [switch]$Json,
  # The ALIVE-owner case: only a slot idle at least this long (hours) is releasable.
  [double]$IdleHours = 24,
  # Restrict to one repo's lease directory (case-insensitive leaf match).
  [string]$Repo,
  # Extra note appended to the journal entry / the unlease -Reason.
  [string]$Reason
)

$ErrorActionPreference = 'Continue'
try { $PSNativeCommandUseErrorActionPreference = $false } catch {}

function Get-CoordRoot {
  if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path (Join-Path $HOME '.codai') 'coord' }
}

# Property getter that never throws on a missing key (the lease JSON is user/other-agent data).
# Named LProp, not GP: `gp` is a built-in alias for Get-ItemProperty and an ALIAS outranks a FUNCTION.
function LProp($o, $n, $d) {
  if ($null -ne $o -and ($o.PSObject.Properties.Name -contains $n)) { return $o.$n }
  return $d
}

# A live process start time in UTC, or $null when the pid does not exist. Mirrors agentq's Get-ProcStart.
function Get-ProcStart([int]$procId) {
  try { (Get-Process -Id $procId -ErrorAction Stop).StartTime.ToUniversalTime() } catch { $null }
}

function Parse-Utc($s) {
  if (-not $s) { return $null }
  # A DateTime/DateTimeOffset argument arrives only if some caller already parsed the JSON; handle it so a
  # value never round-trips through [string] (which loses the kind and lets Parse double-convert).
  if ($s -is [datetime]) { try { return ([datetime]$s).ToUniversalTime() } catch { return $null } }
  if ($s -is [datetimeoffset]) { try { return ([datetimeoffset]$s).UtcDateTime } catch { return $null } }
  try { [DateTimeOffset]::Parse([string]$s, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal).UtcDateTime } catch { $null }
}

# GONE / RECYCLED / ALIVE / unknown. 'unknown' = a live pid whose recorded procStart is unreadable, i.e. the
# reuse question cannot be answered -> fail closed (kept).
function Get-OwnerState($procId, $procStartStr) {
  $id = 0
  try { $id = [int]$procId } catch { $id = 0 }
  if ($id -le 0) { return 'unknown' }
  $st = Get-ProcStart $id
  if (-not $st) { return 'gone' }
  $ps = Parse-Utc $procStartStr
  if (-not $ps) { return 'unknown' }
  if ([math]::Abs(($st - $ps).TotalSeconds) -gt 5) { return 'recycled' }
  return 'alive'
}

# Idle minutes = now - the newest of {created, <file>.hb, <file>.work, <file>.chat} — the same beats the lease
# system itself uses. The .json's own mtime is deliberately NOT a beat: it is the record's write time, so a
# freshly written lease would always look idle 0. No beat at all => very idle.
function Get-IdleMin($file, $lease) {
  $beats = New-Object System.Collections.ArrayList
  $c = Parse-Utc (LProp $lease 'created' $null)
  if ($c) { [void]$beats.Add($c) }
  foreach ($suf in @('.hb', '.work', '.chat')) {
    $p = "$file$suf"
    try { if (Test-Path -LiteralPath $p) { [void]$beats.Add([IO.File]::GetLastWriteTimeUtc($p)) } } catch {}
  }
  if ($beats.Count -eq 0) { return 1000000.0 }
  $max = @($beats | Sort-Object -Descending)[0]
  return ([DateTime]::UtcNow - $max).TotalMinutes
}

function Invoke-Git([string]$slot, [string[]]$gitArgs) {
  try {
    $o = & git -C $slot @gitArgs 2>$null
    return [pscustomobject]@{ Ok = $true; Code = $LASTEXITCODE; Out = @($o) }
  } catch {
    return [pscustomobject]@{ Ok = $false; Code = -1; Out = @() }
  }
}

# A live land pre-gate holds the slot. Future deadline, or a live gate process -> not safe.
function Test-PregateLive($lease, $now) {
  $pu = Parse-Utc (LProp $lease 'pregateUntil' $null)
  if ($pu -and $pu -gt $now) { return @{ Live = $true; Why = 'land pre-gate deadline in the future' } }
  $pp = LProp $lease 'pregatePid' $null
  if ($pp) {
    $ppid = 0; try { $ppid = [int]$pp } catch { $ppid = 0 }
    if ($ppid -gt 0) {
      $st = Get-ProcStart $ppid
      if ($st) {
        $ps = Parse-Utc (LProp $lease 'pregateProcStart' $null)
        if (-not $ps -or [math]::Abs(($st - $ps).TotalSeconds) -le 5) { return @{ Live = $true; Why = 'land pre-gate process alive' } }
      }
    }
  }
  return @{ Live = $false; Why = $null }
}

# This process's own slot: its recorded pid is us, or the cwd is inside the slot path (boundary-aware, so
# scratch-1 is not treated as a prefix of scratch-11).
function Test-SelfOwned($lease) {
  $id = 0; try { $id = [int](LProp $lease 'pid' 0) } catch { $id = 0 }
  if ($id -gt 0 -and $id -eq $PID) { return $true }
  $p = "$(LProp $lease 'path' '')".TrimEnd('\', '/')
  if (-not $p) { return $false }
  try {
    $cwd = (Get-Location).Path.TrimEnd('\', '/')
    if ($cwd.Equals($p, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($cwd.StartsWith($p + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $true }
  } catch {}
  return $false
}

# THE PREDICATE. One decision object: Safe / Verdict ('keep'|'release') / Reason.
function Test-SlotSafeToRelease($lease, $facts) {
  if (-not $facts.Parseable) { return [pscustomobject]@{ Safe = $false; Verdict = 'keep'; Reason = 'unreadable lease record' } }
  if ($facts.SelfOwned) { return [pscustomobject]@{ Safe = $false; Verdict = 'keep'; Reason = 'this process or cwd holds the slot' } }
  if ($facts.PregateLive) { return [pscustomobject]@{ Safe = $false; Verdict = 'keep'; Reason = "land pre-gate active: $($facts.PregateWhy)" } }
  if (-not $facts.SlotExists) { return [pscustomobject]@{ Safe = $false; Verdict = 'keep'; Reason = 'slot directory missing (release via the main clone with -Repo)' } }
  if (-not $facts.GitOk) { return [pscustomobject]@{ Safe = $false; Verdict = 'keep'; Reason = 'git could not be read (fail closed)' } }
  if ($facts.OwnerState -eq 'unknown') { return [pscustomobject]@{ Safe = $false; Verdict = 'keep'; Reason = 'owner pid state unprovable (fail closed)' } }
  if ($facts.OwnerState -eq 'gone') { return [pscustomobject]@{ Safe = $true; Verdict = 'release'; Reason = 'owner pid gone (backup-first release)' } }
  if ($facts.OwnerState -eq 'recycled') { return [pscustomobject]@{ Safe = $true; Verdict = 'release'; Reason = 'owner pid recycled, start-time mismatch (backup-first release)' } }
  # ALIVE and matching: only a long-idle, clean, pushed slot.
  if (-not $facts.Clean) { return [pscustomobject]@{ Safe = $false; Verdict = 'keep'; Reason = 'uncommitted work (git status not empty)' } }
  if (-not $facts.Pushed) { return [pscustomobject]@{ Safe = $false; Verdict = 'keep'; Reason = 'unpushed commits (or no upstream)' } }
  if ($facts.IdleMin -lt ($facts.IdleHours * 60)) {
    return [pscustomobject]@{ Safe = $false; Verdict = 'keep'; Reason = "owner alive, idle $([math]::Round($facts.IdleMin / 60, 1))h < $($facts.IdleHours)h" }
  }
  return [pscustomobject]@{ Safe = $true; Verdict = 'release'; Reason = "owner alive but idle $([math]::Round($facts.IdleMin / 60, 1))h, clean and pushed" }
}

function Write-ReclaimJournal($entry) {
  $root = Get-CoordRoot
  $dir = Join-Path $root 'leases'
  $j = Join-Path $root 'journal.jsonl'
  try { if (-not (Test-Path -LiteralPath $root)) { New-Item -ItemType Directory -Force -Path $root | Out-Null } } catch {}
  $entry.ts = (Get-Date).ToUniversalTime().ToString('o')
  if (-not $entry.Contains('session')) { $entry.session = 'agentq-reclaim' }
  $line = ($entry | ConvertTo-Json -Compress -Depth 6)
  $mtx = $null
  try { $mtx = [Threading.Mutex]::new($false, "Global\agentq-reclaim-journal$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })") } catch {}
  if ($mtx) { try { [void]$mtx.WaitOne(5000) } catch {} }
  try { [IO.File]::AppendAllText($j, $line + "`n", [Text.UTF8Encoding]::new($false)) } catch {}
  finally { if ($mtx) { try { $mtx.ReleaseMutex() } catch {}; $mtx.Dispose() } }
}

# Backup-first release via the existing mechanism. NEVER deletes anything.
function Invoke-ReclaimRelease($lease, $why) {
  $agentq = Join-Path $PSScriptRoot 'agentq.ps1'
  if (-not (Test-Path -LiteralPath $agentq)) { return @{ Ok = $false; Why = "agentq unlease unavailable: $agentq not found" } }
  $slot = "$(LProp $lease 'slot' '')"
  $path = "$(LProp $lease 'path' '')"
  $id = "$(LProp $lease 'leaseId' '')"
  if (-not $slot -or -not $id) { return @{ Ok = $false; Why = 'lease id/slot missing - refusing to guess' } }
  $r = "agentq-reclaim: $why"
  if ($Reason) { $r = "$r; $Reason" }
  $uargs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $agentq, 'unlease', '-Repo', $path, '-Slot', $slot, '-LeaseId', $id, '-Force', '-Reason', $r)
  $out = @(& pwsh @uargs 2>&1 | ForEach-Object { "$_" })
  $code = $LASTEXITCODE
  if ($code -eq 0) { return @{ Ok = $true; Why = (@($out | Where-Object { $_ -match '\S' }) -join ' | ') } }
  return @{ Ok = $false; Why = "unlease exit ${code}: " + (@($out | Where-Object { $_ -match '\S' }) -join ' | ') }
}

# ---- main -------------------------------------------------------------------------------------
$root = Get-CoordRoot
$ldir = Join-Path $root 'leases'
$now = [DateTime]::UtcNow
$rows = @()

if (-not (Test-Path -LiteralPath $ldir)) {
  Write-Output "agentq-reclaim: no lease directory at $ldir (nothing to do)"
  exit 0
}

$dirs = if ($Repo) { @(Join-Path $ldir $Repo) } else { @(Get-ChildItem -LiteralPath $ldir -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName) }

$files = @()
foreach ($d in $dirs) { if (Test-Path -LiteralPath $d) { $files += @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue) } }
$files = @($files | Sort-Object FullName)

foreach ($f in $files) {
  $lease = $null
  $parseable = $false
  try {
    $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop
    if ($raw -and $raw.Trim()) {
      # -DateKind String: ConvertFrom-Json would otherwise turn every ISO timestamp into a DateTime with the
      # WRONG Kind (Kind=Local holding the UTC wall clock), so procStart/pregateUntil comparisons shifted by
      # the local offset (measured on ro-RO: a live owner read as "recycled"). Keep the raw strings.
      try { $lease = $raw | ConvertFrom-Json -DateKind String } catch { $lease = $raw | ConvertFrom-Json }
      $parseable = $true
    }
  } catch { $parseable = $false }

  $repoName = Split-Path (Split-Path $f.FullName -Parent) -Leaf
  $slot = if ($parseable) { "$(LProp $lease 'slot' $f.BaseName)" } else { $f.BaseName }

  # facts
  $facts = [ordered]@{
    Parseable   = $parseable
    SlotExists  = $false
    GitOk       = $false
    Clean       = $false
    Pushed      = $false
    IdleMin     = 0.0
    IdleHours   = $IdleHours
    OwnerState  = 'unknown'
    PregateLive = $false
    PregateWhy  = $null
    SelfOwned   = $false
  }
  if ($parseable) {
    $facts.SelfOwned = Test-SelfOwned $lease
    $pg = Test-PregateLive $lease $now
    $facts.PregateLive = [bool]$pg.Live
    $facts.PregateWhy = $pg.Why
    $facts.IdleMin = Get-IdleMin $f.FullName $lease
    $facts.OwnerState = Get-OwnerState (LProp $lease 'pid' $null) (LProp $lease 'procStart' $null)
    $path = "$(LProp $lease 'path' '')"
    if ($path -and (Test-Path -LiteralPath $path)) {
      $facts.SlotExists = $true
      $st = Invoke-Git $path @('status', '--porcelain')
      if ($st.Ok -and $st.Code -eq 0) {
        $facts.GitOk = $true
        $facts.Clean = (@($st.Out | Where-Object { $_ -match '\S' }).Count -eq 0)
        $up = Invoke-Git $path @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}')
        if ($up.Ok -and $up.Code -eq 0 -and (@($up.Out | Where-Object { $_ -match '\S' }).Count -gt 0)) {
          $lp = Invoke-Git $path @('log', '--oneline', '@{u}..HEAD')
          $facts.Pushed = ($lp.Ok -and $lp.Code -eq 0 -and (@($lp.Out | Where-Object { $_ -match '\S' }).Count -eq 0))
        } else {
          $facts.Pushed = $false   # no upstream => unsafe
        }
      }
    }
  }

  $v = Test-SlotSafeToRelease $lease ([pscustomobject]$facts)

  $verdict = 'keep'
  $reason = $v.Reason
  $pidVal = if ($parseable) { (LProp $lease 'pid' $null) } else { $null }
  if ($v.Safe) {
    if ($Apply) {
      $res = Invoke-ReclaimRelease $lease $v.Reason
      if ($res.Ok) { $verdict = 'released'; $reason = "$($v.Reason); $($res.Why)" }
      else { $verdict = 'release-failed'; $reason = "$($v.Reason); $($res.Why)" }
    } else {
      $verdict = 'would-release'
    }
  }

  $entry = [ordered]@{
    event    = 'lease-reclaim'
    resource = "slot:${repoName}:$slot"
    slot     = $slot
    repo     = $repoName
    pid      = $pidVal
    leaseId  = if ($parseable) { (LProp $lease 'leaseId' $null) } else { $null }
    verdict  = $verdict
    reason   = $reason
    safe     = [bool]$v.Safe
    by       = 'agentq-reclaim'
    apply    = [bool]$Apply
  }
  Write-ReclaimJournal $entry
  $rows += [pscustomobject]$entry

  if ($Json) {
    Write-Output ($entry | ConvertTo-Json -Compress)
  } else {
    $tag = switch ($verdict) { 'released' { 'RELEASED' } 'would-release' { 'WOULD-RELEASE' } 'release-failed' { 'RELEASE-FAILED' } default { 'keep' } }
    Write-Output ("{0,-14} {1}/{2} pid={3} :: {4}" -f $tag, $repoName, $slot, $pidVal, $reason)
  }
}

if (-not $Json) {
  $rel = @($rows | Where-Object { $_.verdict -eq 'released' }).Count
  $would = @($rows | Where-Object { $_.verdict -eq 'would-release' }).Count
  $kept = @($rows | Where-Object { $_.verdict -eq 'keep' }).Count
  $failed = @($rows | Where-Object { $_.verdict -eq 'release-failed' }).Count
  Write-Output ("agentq-reclaim: $($rows.Count) lease(s) - kept $kept, would-release $would, released $rel, failed $failed (mode $(if ($Apply) { 'APPLY' } else { 'report-only' }))")
}
exit 0
