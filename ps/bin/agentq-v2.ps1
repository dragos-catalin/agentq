# agentq v2 (ADR 0001, docs/adr/0001-slots-leases-release-supersede.md): worktree SLOTS + LEASES,
# RELEASE RUNS + SUPERSEDE, LANDING QUEUE. Dot-sourced by agentq.ps1 (shares its script scope:
# $Root, $Session, $RepoArg, $Slot, ... and helpers Write-Journal, New-Ticket, Wait-Turn, Test-Alive).

# PowerShell variables are case-insensitive: `$repo = Get-RepoInfo `$Repo` inside a function REPLACES
# the -Repo argument. v2 code reads the argument only through `$RepoArg`.
$RepoArg = $Repo
# leases + releases are machine state: the system store when one exists (ADR 0007), else the user store
$LDir = Join-Path $SysRoot 'leases'
$RDir = Join-Path $SysRoot 'releases'
foreach ($d in $LDir, $RDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }

# ---- policy -------------------------------------------------------------------------------
# AGENTQ_CONFIG overrides the file (tests); missing keys fall back to these defaults.
$script:Cfg = $null
$script:LeaseActivity = $null
function Get-Config {
  if ($script:Cfg) { return $script:Cfg }
  $c = @{
    taskSlotsPerRepo = 3; taskSlotsMachine = 10; releaseSlots = @{}; pinned = @{}
    # leaseMaxIdleMin: the hard cap on a slot nobody works in. 24 h let a chat that merely POLLED keep a
    # slot for a day (2026-11-19: 17 leases, several idle 5-7 h, none stale because a bound chat was
    # fresh); 6 h reclaims an idle slot within a workday. A genuine long job outside the slot uses -Hold.
    leaseDeadIdleMin = 120; leaseMaxIdleMin = 360; unleasedRemoveIdleHours = 168; minFreeCommitGB = 12
    # v3 scheduler (devcloud F1): machine cap, soft slots, aging, idle-yield watchdog, override limits.
    machineCap = 2; quickBurst = 1; agingMin = 5; idleYieldMin = 5; idleCpuSec = 10
    bumpMax = 50; burstMax = 2; burstMaxMin = 60; overridesPerHour = 6; runBuildTimeoutMin = 240
    journalRotateMB = 64
  }
  $f = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $PSScriptRoot 'agentq-config.json' }
  if (Test-Path -LiteralPath $f) {
    $j = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable
    foreach ($k in $j.Keys) { $c[$k] = $j[$k] }
  }
  # system policy (devbox): machine caps/slot counts are set once by root for every user and win over
  # a user's copy, so nobody raises the machine cap for themselves (ADR 0007)
  if ($SystemMode -and -not $env:AGENTQ_CONFIG) {
    $sf = Join-Path $SysRoot 'system.json'
    if (Test-Path -LiteralPath $sf) {
      $s = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json -AsHashtable
      if ($s.ContainsKey('policy') -and $s['policy']) { foreach ($k in $s['policy'].Keys) { $c[$k] = $s['policy'][$k] } }
    }
  }
  $script:Cfg = $c
  $c
}
function Get-WtRoot { if ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT } elseif ($IsWindows) { 'E:\gh\.wt' } else { '/work/.wt' } }
function Get-ReleaseSlotCount([string]$repoName) { $r = (Get-Config).releaseSlots; if ($r -and $r.ContainsKey($repoName)) { [int]$r[$repoName] } else { 1 } }
# Index access, not property access: under StrictMode 3 `(Get-Config).scratchSlots` THROWS when the key is
# absent (the default map has no scratchSlots), so a scratch lease failed before the default 3 could apply.
function Get-ScratchSlotCount { $c = Get-Config; if ($c -and $c.ContainsKey('scratchSlots') -and $c['scratchSlots']) { [int]$c['scratchSlots'] } else { 3 } }
function Get-PinnedSlots([string]$repoName) { $p = (Get-Config)['pinned']; if ($p -and $p.ContainsKey($repoName)) { @($p[$repoName]) } else { @() } }
# The ONLY slot names that exist. Anything else is legacy and gets migrated away.
function Get-SlotRole([string]$repoName, [string]$slot) {
  if ($slot -match '^task-(\d+)$') { if ([int]$Matches[1] -ge 1 -and [int]$Matches[1] -le (Get-Config).taskSlotsPerRepo) { return 'task' }; return $null }
  # scratch-N (ADR 0012): a SHORT-LIVED slot for work that must not consume a task slot - a subagent's
  # one-off task, a scratch edit. Not counted in taskSlotsPerRepo / taskSlotsMachine, reclaimed after
  # leaseScratchIdleMin (15 min) with no work. Unsaved state is still backed up before reclaiming.
  if ($slot -match '^scratch-(\d+)$') { if ([int]$Matches[1] -ge 1 -and [int]$Matches[1] -le (Get-ScratchSlotCount)) { return 'scratch' }; return $null }
  if ($slot -eq 'release') { return 'release' }
  if ($slot -match '^release-(\d+)$') { if ([int]$Matches[1] -ge 2 -and [int]$Matches[1] -le (Get-ReleaseSlotCount $repoName)) { return 'release' }; return $null }
  if ($slot -eq 'land') { return 'land' }
  if ((Get-PinnedSlots $repoName) -contains $slot) { return 'pinned' }
  $null
}

# ---- helpers ------------------------------------------------------------------------------
# Get-Config returns a HASHTABLE, and PSObject.Properties does NOT list a hashtable's keys, so the old
# property-name check always missed and every config value read through P silently fell back to its default
# (leaseIdleMin, leaseOwnerIdleMin, leaseScratchIdleMin, leaseChatGraceMin, holdDefaultMin were never honoured).
function P($o, [string]$n, $d = '') {
  if ($null -eq $o) { return $d }
  if ($o -is [System.Collections.IDictionary]) { if ($o.Contains($n) -and $null -ne $o[$n]) { return $o[$n] } ; return $d }
  if ($o.PSObject.Properties.Name -contains $n -and $null -ne $o.$n) { $o.$n } else { $d }
}
function Write-JsonAtomic([string]$file, $obj) {
  $dir = Split-Path -Parent $file
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Force $dir | Out-Null
    if ((Split-Path -Parent $dir) -eq $LDir) { Set-RepoGroupDir $dir (Split-Path -Leaf $dir) }
  }
  $tmp = "$file.$PID.tmp"
  [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
  [IO.File]::Move($tmp, $file, $true)
}
function Read-JsonFile([string]$file) {
  for ($r = 0; $r -lt 5; $r++) {
    try { return (Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -DateKind String) } catch { if (-not (Test-Path -LiteralPath $file)) { return $null } }
    Start-Sleep -Milliseconds 40
  }
  'UNREADABLE'
}
function With-Mutex([string]$name, [scriptblock]$body) {
  $m = [Threading.Mutex]::new($false, "Global\agentq-$(Safe $name)$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  try { try { [void]$m.WaitOne(30000) } catch [Threading.AbandonedMutexException] {} ; & $body }
  finally { try { $m.ReleaseMutex() } catch {} ; $m.Dispose() }
}
function Get-MainTop($repo) { Split-Path -Parent $repo.Common }
function Get-SlotPath([string]$repoName, [string]$slot) { Join-Path (Join-Path (Get-WtRoot) $repoName) $slot }
function Get-LeaseFile([string]$repoName, [string]$slot) { Join-Path (Join-Path $LDir $repoName) "$slot.json" }
function Get-DefaultOwner { if ($OwnerPid -gt 0) { return $OwnerPid }; if ($env:AGENTQ_OWNER_PID) { return [int]$env:AGENTQ_OWNER_PID }; try { (Get-Process -Id $PID).Parent.Id } catch { $PID } }
function Short([string]$s, [int]$n = 10) { if (-not $s) { return '' }; $s.Substring(0, [math]::Min($n, $s.Length)) }

# ---- lease activity beyond the slot (ADR 0003 W1-3) ---------------------------------------------
# 24 leases of live work expired in 15 days (ADR 0002) and ~9 more after DC-021: the owner shell died
# or the work ran OUTSIDE the slot (job-start gates, run-build, land, agentq calls from the main clone).
# A lease is now also active while (a) a live agentq ticket runs with its repo inside the slot,
# (b) a running job-start job has its cwd or command inside the slot, or (c) an agentq call names the
# lease (-LeaseId) or comes from the lease's session. Computed once per process (Read-Leases runs
# on every status/sync call).
function Get-ExtraLeaseActivity {
  if ($null -ne $script:LeaseActivity) { return $script:LeaseActivity }
  $acts = @()
  try {
    foreach ($d in @(Get-ChildItem $QDir -Directory -ErrorAction SilentlyContinue)) {
      foreach ($f in @(Get-ChildItem -LiteralPath $d.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
          $t = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -DateKind String
          if (-not $t.repo -or -not (Test-Alive $t)) { continue }
          $hb = "$($f.FullName).hb"; $at = if (Test-Path -LiteralPath $hb) { (Get-Item -LiteralPath $hb).LastWriteTimeUtc } else { $f.LastWriteTimeUtc }
          $acts += [pscustomobject]@{ path = (Norm-Dir "$($t.repo)"); text = ''; at = $at }
        } catch {}
      }
    }
    # system sweep (root timer on the devbox) judges every user's leases: it must see every user's jobs
    $jds = @(Join-Path $Root 'jobs')
    if ($SystemMode -and -not $IsWindows -and [Environment]::UserName -eq 'root') { $jds += @(Get-ChildItem -Path '/home/*/.codai/coord/jobs' -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName) }
    foreach ($jd in $jds) { if (Test-Path -LiteralPath $jd) {
      $cut = (Now).AddDays(-2)
      foreach ($f in @(Get-ChildItem -LiteralPath $jd -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -gt $cut } | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 200)) {
        try {
          $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -DateKind String
          if ((P $j 'state' '') -ne 'running' -or -not (P $j 'pid' 0)) { continue }
          if (-not (Get-Process -Id ([int]$j.pid) -ErrorAction SilentlyContinue)) { continue }
          $log = P $j 'log' ''; $at = if ($log -and (Test-Path -LiteralPath $log)) { (Get-Item -LiteralPath $log).LastWriteTimeUtc } else { $f.LastWriteTimeUtc }
          $acts += [pscustomobject]@{ path = $(if (P $j 'cwd' '') { Norm-Dir "$($j.cwd)" } else { '' }); text = "$(P $j 'command' '')".ToLowerInvariant(); at = $at }
        } catch {}
      }
    } }
  } catch {}
  $script:LeaseActivity = $acts
  $acts
}
function Get-LeaseExtraBeat($l) {
  $lp = "$(P $l 'path' '')"; if (-not $lp) { return $null }
  $ln = Norm-Dir $lp; $lt = $lp.ToLowerInvariant()
  $best = $null
  foreach ($a in @(Get-ExtraLeaseActivity)) {
    $hit = ($a.path -and $a.path.StartsWith($ln)) -or ($a.text -and $a.text.Contains($lt))
    if ($hit -and (-not $best -or $a.at -gt $best)) { $best = $a.at }
  }
  $best
}
# Any agentq call FOR THE LEASE'S OWN REPO from its session, or naming it with -LeaseId, renews it.
# ADR 0012: this used to renew EVERY lease of the session, so one `agentq run` for repo A kept a lease in
# repo B alive - measured 2026-11-19: session term-32600 held 5 leases across 3 repos and all 5 showed a
# 17-minute heartbeat while nobody had touched those slots for hours.
function Renew-ForSession {
  try {
    $ri = Get-RepoInfo $(if ($RepoArg) { $RepoArg } else { (Get-Location).Path })
    $rn = if ($ri) { $ri.Name } else { $null }
    foreach ($f in @(Get-ChildItem -LiteralPath $LDir -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $raw = [IO.File]::ReadAllText($f.FullName)
      if (-not ($raw.Contains("`"$Session`"") -or ($LeaseId -and $raw.Contains("`"$LeaseId`"")))) { continue }
      $l = $raw | ConvertFrom-Json
      if ($LeaseId -and (P $l 'leaseId') -eq $LeaseId) { Touch-Lease ([pscustomobject]@{ file = $f.FullName }); continue }
      if ((P $l 'session') -ne $Session) { continue }
      if (-not $rn -or (P $l 'repo') -ne $rn) { continue }
      Touch-Lease ([pscustomobject]@{ file = $f.FullName })
    }
  } catch {}
}

# ---- lease-loss notices (ADR 0003 W1-3) -------------------------------------------------------
# An expired or broken lease used to be discovered only by finding foreign files in "my" slot. The
# holder's session now gets a notice that agentq prints (stderr) on its next call, and `status`
# lists losses of the last 24 h with the backup ref to restore from.
# System mode: the notice is for ANOTHER user, so it goes next to the lease (leases/<repo>, group r-<repo>)
# where that user's agentq finds it; the user store would only ever be read by the writer.
function Get-NoticeDirs { if ($SystemMode) { @(Get-ChildItem -LiteralPath $LDir -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName) } else { @(Join-Path $Root 'notices') } }
function Add-LeaseNotice($l, [string]$event, [string]$why, [string]$ref) {
  try {
    $nd = if ($SystemMode) { Join-Path $LDir "$($l.repo)" } else { Join-Path $Root 'notices' }
    if (-not (Test-Path -LiteralPath $nd)) { New-Item -ItemType Directory -Force $nd | Out-Null }
    $n = [ordered]@{ ts = (Iso (Now)); event = $event; repo = $l.repo; slot = $l.slot; leaseId = (P $l 'leaseId'); purpose = (P $l 'purpose'); branch = (P $l 'branch'); reason = $why; ref = $ref; by = $Session }
    $nf = if ($SystemMode) { 'notice-' + (Safe "$(P $l 'session')") + '.jsonl' } else { (Safe "$(P $l 'session')") + '.jsonl' }
    [IO.File]::AppendAllText((Join-Path $nd $nf), (($n | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
  } catch {}
}
function Show-LeaseNotices {
  try {
    $nf = if ($SystemMode) { 'notice-' + (Safe $Session) + '.jsonl' } else { (Safe $Session) + '.jsonl' }
    $lines = @()
    foreach ($nd in Get-NoticeDirs) {
      $f = Join-Path $nd $nf
      if (-not (Test-Path -LiteralPath $f)) { continue }
      $lines += @(Get-Content -LiteralPath $f | Where-Object { $_ })
      Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
    if (-not $lines) { return }
    foreach ($ln in $lines) {
      $n = $ln | ConvertFrom-Json
      $restore = if ($n.ref) { " Unsaved state is in $($n.ref): git diff --binary <base> $($n.ref) --output=x.patch, then git apply --3way x.patch in a NEW lease." } else { ' Nothing unsaved was in it.' }
      [Console]::Error.WriteLine("agentq: NOTICE your lease $($n.leaseId) on $($n.repo)/$($n.slot) ('$($n.purpose)') ended at $($n.ts): $($n.event) - $($n.reason).$restore Do not write to that slot again.")
    }
  } catch {}
}
function Get-RecentLeaseLosses([int]$hours = 24) {
  try {
    $cut = (Now).AddHours(-$hours)
    @(Get-JournalFiles | ForEach-Object { Get-Content -LiteralPath $_ -Tail 4000 -ErrorAction Stop } | Where-Object { $_ -match '"event":"(lease-expire|lease-break)"' } | ForEach-Object { try { $_ | ConvertFrom-Json -DateKind String } catch { $null } } | Where-Object { $_ -and (ParseUtc $_.ts) -gt $cut })
  } catch { @() }
}

# ---- leases -------------------------------------------------------------------------------
# Liveness for AGENTS (no long-lived process): owner shell pid + activity heartbeat (guard hook on
# every tool call touching the slot, agentq calls from inside it, renew).
# Stale = (owner dead AND idle > leaseDeadIdleMin, 3 min for the land slot) OR idle > leaseMaxIdleMin.
#
# ADR 0009 stage 0 (OQ-001): the CHAT is the unit that works, not a shell. 185 lease-break and 40
# lease-expire in 7 days came from leases whose owner shell had ended (a keeper reaped with its terminal,
# a one-shot lease job) while the chat kept working outside the slot: deploys, queue waits, subagents.
# The per-tool-call hook (hooks/guard-tooluse.ps1) knows the chat id. When a chat WORKS in a slot (an edit
# inside it, or a working command that names it) the hook binds the chat to the lease in <lease>.json.chat
# ({ leaseId, chats: [ids] }) and from then on touches that file on EVERY tool call of the chat, whatever
# the call is about. A chat whose last tool call is younger than leaseDeadIdleMin counts exactly like a
# live owner shell: the lease is stale only when the SLOT has been idle longer than leaseMaxIdleMin
# (24 h), the same limit a lease with a live keeper has. idleMin keeps meaning "slot idle"; chatIdleMin
# is the chat. A chat that stops (or moves on for more than leaseDeadIdleMin) gives no protection.
function Read-LeaseChat([string]$leaseFile) {
  $r = @{ chats = @(); at = $null; releaseBy = ''; releaseAt = $null }
  try {
    $cf = "$leaseFile.chat"
    if ([IO.File]::Exists($cf)) {
      $r.at = [IO.File]::GetLastWriteTimeUtc($cf)
      $j = [IO.File]::ReadAllText($cf) | ConvertFrom-Json
      $r.chats = @(P $j 'chats' @() | ForEach-Object { "$_" } | Where-Object { $_ })
    }
    # <lease>.json.release: written by the hook when a chat runs `unlease` for this lease (who released it).
    $rf = "$leaseFile.release"
    if ([IO.File]::Exists($rf)) { $r.releaseAt = [IO.File]::GetLastWriteTimeUtc($rf); $r.releaseBy = "$([IO.File]::ReadAllText($rf))".Trim() }
  } catch {}
  $r
}
# OQ-001 / ADR 0009 stage 0: the chat side of a lease, computed in ONE place so `unlease` and the journal
# cannot drift apart (they did: the reaper's 20-min chat grace sat INSIDE the SLO's 30-min live window, so
# a slot could be expired while the SLO still called its chat live).
#   idle   = minutes since the bound chat's last call (null = no chat ever bound to this lease)
#   byChat = the release was initiated by a chat bound to this lease (the hook records it in <lease>.release):
#            the holder gave its own slot back from another shell - not a loss.
#   live   = the state the SLO counts as a loss when a lease ends, and that `unlease` refuses to break.
# 30 must match TARGETS.liveChatIdleMin in agentq-slo.mjs (the number the daily report judges against).
function Get-LeaseChatFacts($l) {
  $ch = Read-LeaseChat $l.file
  $idle = if ($ch.at) { [math]::Round(((Now) - $ch.at).TotalMinutes, 1) } else { $null }
  $byChat = [bool]($ch.releaseBy -and $ch.releaseAt -and ((Now) - $ch.releaseAt).TotalMinutes -le 15 -and (@($ch.chats) -contains $ch.releaseBy))
  $live = ($null -ne $idle) -and ($idle -le 30) -and (-not $byChat) -and (-not (@($ch.chats) -contains $Session))
  [pscustomobject]@{ chats = @($ch.chats); idle = $idle; byChat = $byChat; live = $live }
}
function Read-Leases([string]$repoName) {
  $dirs = if ($repoName) { @(Join-Path $LDir $repoName) } else { @(Get-ChildItem $LDir -Directory -ErrorAction SilentlyContinue | ForEach-Object FullName) }
  $cfg = Get-Config
  $out = @()
  foreach ($d in $dirs) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    # -ErrorAction: on a multi-user machine another group's repo dir is unreadable by design (skip it)
    foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $l = Read-JsonFile $f.FullName
      if ($null -eq $l) { continue }
      if ($l -eq 'UNREADABLE') {
        # Fail closed: an unreadable lease still holds its slot (owner = us, so it looks alive).
        $rn = Split-Path $d -Leaf
        $l = [pscustomobject]@{ leaseId = 'unreadable'; repo = $rn; slot = $f.BaseName; role = '?'; path = (Get-SlotPath $rn $f.BaseName); branch = ''; purpose = 'unreadable lease file'; session = '?'; pid = $PID; procStart = $null; created = (Iso (Now)) }
      }
      $createdAt = ParseUtc (P $l 'created' (Iso (Now)))
      # LIVENESS = WORK IN THE SLOT (ADR 0012, 2026-11-19). Three beats, in order of authority:
      #   .work - a tool call that NAMES the slot (an edit inside it, a command whose cwd is in it), written
      #           only by hooks/guard-tooluse.ps1. Primary proof somebody works IN the slot.
      #   .hb   - an agentq call from this lease's repo/session (Renew-ForCwd / Renew-ForSession) or renew.
      #   slot git activity (index/HEAD/logs) - work from outside agentq (DC-021).
      # The retired model treated "the chat made ANY tool call" as liveness, so a chat that moved on held
      # its slots for hours: measured 2026-11-19, 14 leases, 6 with no slot activity for 5-23 h, none stale.
      $hbFile = "$($f.FullName).hb"
      $beats = @($(if (Test-Path -LiteralPath $hbFile) { (Get-Item -LiteralPath $hbFile).LastWriteTimeUtc } else { $createdAt }))
      $workFile = "$($f.FullName).work"
      if (Test-Path -LiteralPath $workFile) { $beats += (Get-Item -LiteralPath $workFile).LastWriteTimeUtc }
      $act = Get-SlotGitActivity (P $l 'path' '')
      # Ignore the index writes of the lease's own checkout (first 2 min after creation).
      if ($act -and $act -gt $createdAt.AddMinutes(2)) { $beats += $act }
      $beat = @($beats | Sort-Object -Descending)[0]
      $alive = Test-Alive ([pscustomobject]@{ pid = [int](P $l 'pid' 0); procStart = (P $l 'procStart' $null) })
      $idle = ((Now) - $beat).TotalMinutes
      $lrole = "$(P $l 'role' '')"
      # A live owner pid is a reason to be more patient, never a licence to hold a slot forever: the old
      # rule let an open shell keep a slot for 24 h with nobody in it.
      if ($lrole -eq 'land') { $deadIdle = 3 }                       # the land process heartbeats every 20 s
      elseif ($lrole -eq 'scratch') { $deadIdle = [double](P $cfg 'leaseScratchIdleMin' 15) }
      elseif ($alive) { $deadIdle = [double](P $cfg 'leaseOwnerIdleMin' 90) }
      else { $deadIdle = [double](P $cfg 'leaseIdleMin' 45) }
      # A bound chat's call that NAMES the slot buys a SHORT grace (a burst of calls, a build that touches
      # no git). It is no longer a licence to hold the slot while the chat works somewhere else.
      $chatAt = $null
      if ($lrole -in 'task', 'pinned', 'scratch') { try { $chatF = "$($f.FullName).chat"; if ([IO.File]::Exists($chatF)) { $chatAt = [IO.File]::GetLastWriteTimeUtc($chatF) } } catch {} }
      # 30 = the live-chat window the SLO judges against (TARGETS.liveChatIdleMin). At 20 the reaper expired
      # slots whose chat the same report still called live - the avoidable half of `slotsLostLiveChat`.
      $graceMin = if ($lrole -eq 'scratch') { 0 } else { [double](P $cfg 'leaseChatGraceMin' 30) }
      $chatOld = (-not $chatAt) -or (((Now) - $chatAt).TotalMinutes -gt $graceMin)
      # -Hold: an explicit, journalled "I am running a long job OUTSIDE the slot, keep it" with its own expiry.
      $held = $false
      $hu = P $l 'holdUntil' $null
      if ($hu) { $huT = ParseUtc $hu; $held = [bool]($huT -and $huT -gt (Now)) }
      $stale = (-not $held) -and ((($idle -gt $deadIdle) -and $chatOld) -or ($idle -gt $cfg.leaseMaxIdleMin))
      # W1-3: the ticket/job scan costs seconds on a big registry, so only a lease that would be
      # stale pays for it (most calls see no stale lease and never scan).
      if ($stale) {
        $xa = Get-LeaseExtraBeat $l
        if ($xa -and $xa -gt $beat) { $beat = $xa; $idle = ((Now) - $beat).TotalMinutes; $stale = (-not $held) -and ((($idle -gt $deadIdle) -and $chatOld) -or ($idle -gt $cfg.leaseMaxIdleMin)) }
      }
      $l | Add-Member -NotePropertyName file -NotePropertyValue $f.FullName -Force
      $l | Add-Member -NotePropertyName beat -NotePropertyValue $beat -Force
      $l | Add-Member -NotePropertyName alive -NotePropertyValue $alive -Force
      $l | Add-Member -NotePropertyName idleMin -NotePropertyValue ([math]::Round($idle, 1)) -Force
      $l | Add-Member -NotePropertyName stale -NotePropertyValue $stale -Force
      $l | Add-Member -NotePropertyName chatIdleMin -NotePropertyValue $(if ($chatAt) { [math]::Round(((Now) - $chatAt).TotalMinutes, 1) } else { $null }) -Force
      # why this lease is (or is not) taken by the next sweep: the threshold that applied, the chat grace,
      # -Hold, and a short reason. Used by `who` and by the lease-kept journal line Invoke-Sweep writes.
      $why = if ($stale) { 'stale' } elseif ($held) { 'held' } elseif ($idle -le $deadIdle) { 'recent work' } elseif (-not $chatOld) { 'chat grace' } else { 'ok' }
      $l | Add-Member -NotePropertyName thresholdMin -NotePropertyValue ([math]::Round($deadIdle, 1)) -Force
      $l | Add-Member -NotePropertyName graceMin -NotePropertyValue ([math]::Round($graceMin, 1)) -Force
      $l | Add-Member -NotePropertyName held -NotePropertyValue $held -Force
      $l | Add-Member -NotePropertyName why -NotePropertyValue $why -Force
      $out += $l
    }
  }
  $out
}
# Windows paths compare case-insensitively; Linux paths are case-sensitive, so no lowering there.
function Norm-Dir([string]$p) { $ds = [IO.Path]::DirectorySeparatorChar; $n = [IO.Path]::GetFullPath($p).TrimEnd('\', '/') + $ds; if ($IsWindows) { $n.ToLowerInvariant() } else { $n } }
function Get-SlotGitActivity([string]$slotPath) {
  if (-not $slotPath) { return $null }
  try {
    $gf = Join-Path $slotPath '.git'
    if (-not (Test-Path -LiteralPath $gf -PathType Leaf)) { return $null }
    $gd = ((Get-Content -LiteralPath $gf -Raw) -replace '^gitdir:\s*', '').Trim()
    if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $slotPath $gd }
    $times = foreach ($n in 'index', 'HEAD', 'logs\HEAD') { $p = Join-Path $gd $n; if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTimeUtc } }
    @($times | Sort-Object -Descending)[0]
  } catch { $null }
}
# Lease whose slot contains $path, or whose slot lies inside $path (deleting a parent dir hits it too).
function Find-LeaseForPath([string]$path) {
  if (-not $path) { return $null }
  $p = Norm-Dir $path
  foreach ($l in Read-Leases $null) {
    $lp = Norm-Dir "$(P $l 'path')"
    if ($p.StartsWith($lp) -or $lp.StartsWith($p)) { return $l }
  }
  $null
}
function Touch-Lease($l) { try { if (-not (Test-Path -LiteralPath "$($l.file).hb")) { [IO.File]::WriteAllText("$($l.file).hb", '') }; [IO.File]::SetLastWriteTimeUtc("$($l.file).hb", (Now)) } catch {} }
function Renew-ForCwd {
  # Any agentq call from inside a slot (cwd or -Repo) counts as activity for that slot's lease.
  try {
    $start = if ($RepoArg) { $RepoArg } else { (Get-Location).Path }
    if ((Norm-Dir $start).StartsWith((Norm-Dir (Get-WtRoot)))) { $l = Find-LeaseForPath $start; if ($l) { Touch-Lease $l } }
  } catch {}
}
function Test-GitClean([string]$path) { -not @(& git --no-optional-locks -C $path status --porcelain --untracked-files=normal 2>$null | Where-Object { $_ }).Count }
function Test-OnRemote([string]$path, [string]$sha) {
  if (-not $sha) { return $false }
  [bool]@(& git -C $path for-each-ref --count=1 --contains $sha --format='%(refname)' refs/remotes 2>$null | Where-Object { $_ }).Count
}

# Snapshot EVERYTHING not on a remote (tracked edits, untracked non-ignored files, unpushed commits)
# into one commit via a TEMP index - never a stash (stashes are shared by all worktrees of a repo,
# memory 2026-09-30) - and publish it as refs/backup/wt/<repo>/<slot>/<ts>: not a branch, so no CI
# (verified on GitHub 2026-10-06). Repos without origin get a bundle in <wtroot>\_bundles.
# Returns the ref, '' when nothing is unique; THROWS when the backup could not be proven.
# -CommitsOnly (release slots): tracked/untracked changes there are build byproducts, only unpushed
# commits are worth keeping.
function Backup-Slot([string]$path, [string]$repoName, [string]$slot, [string]$why, [switch]$CommitsOnly) {
  if (-not $path -or -not (Test-Path -LiteralPath $path)) { return '' }
  $head = (& git -C $path rev-parse --verify -q HEAD 2>$null)
  if ($LASTEXITCODE -or -not $head) { throw "backup: $path has no valid HEAD (broken worktree) - inspect by hand" }
  $clean = $CommitsOnly -or (Test-GitClean $path)
  if ($clean -and (Test-OnRemote $path $head)) { return '' }
  $commit = $head; $big = @()
  if (-not $clean) {
    $gitDir = (& git -C $path rev-parse --path-format=absolute --git-dir).Replace('/', [IO.Path]::DirectorySeparatorChar)
    $tmpIdx = Join-Path ([IO.Path]::GetTempPath()) ("aq-idx-" + [guid]::NewGuid().ToString('N'))
    $idx = Join-Path $gitDir 'index'
    if (Test-Path -LiteralPath $idx) { Copy-Item -LiteralPath $idx $tmpIdx -Force }
    $prevIdx = $env:GIT_INDEX_FILE
    try {
      $env:GIT_INDEX_FILE = $tmpIdx
      & git -C $path add -A 2>$null | Out-Null
      if ($LASTEXITCODE) { throw "backup: git add -A on a temp index failed in $path" }
      # GitHub rejects blobs > 100 MB: leave huge untracked files out and name them in the message.
      $big = @(& git -C $path diff --cached --name-only --diff-filter=A HEAD 2>$null | Where-Object { $_ } | Where-Object { $f = Join-Path $path $_; (Test-Path -LiteralPath $f) -and (Get-Item -LiteralPath $f).Length -gt 50MB })
      foreach ($b in $big) { & git -C $path rm -q --cached -- $b 2>$null | Out-Null }
      $tree = (& git -C $path write-tree).Trim()
      if ($LASTEXITCODE -or -not $tree) { throw 'backup: write-tree failed' }
    } finally {
      if ($prevIdx) { $env:GIT_INDEX_FILE = $prevIdx } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
      Remove-Item -LiteralPath $tmpIdx -Force -ErrorAction SilentlyContinue
    }
    $msgFile = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($msgFile, "agentq backup ${repoName}/${slot}: $why`n`nhead: $head`nsession: $Session`nskipped-large: $($big -join ', ')`n", [Text.UTF8Encoding]::new($false))
    $commit = (& git -C $path -c user.name=agentq -c user.email=agentq@localhost commit-tree $tree -p $head -F $msgFile).Trim()
    Remove-Item $msgFile -Force
    if ($LASTEXITCODE -or -not $commit) { throw 'backup: commit-tree failed' }
  }
  $ref = "refs/backup/wt/$repoName/$slot/$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))-$(Short ([guid]::NewGuid().ToString('N')) 4)"
  & git -C $path update-ref $ref $commit
  if ($LASTEXITCODE) { throw "backup: update-ref $ref failed" }
  $hasOrigin = [bool](@(& git -C $path remote 2>$null) -contains 'origin')
  $pushError = ''; $bundle = ''
  if ($hasOrigin) {
    # --no-verify: a backup ref is not a release; pre-push gates (minutes) would make expiry unusable.
    # Output is CAPTURED (it used to go to $null): a refused push (GitHub GH001 on a >100 MB blob,
    # 2026-10-15) then surfaced only as "could not be verified (got '')" and wedged every later land.
    $pushOut = @(& git -C $path push --no-verify origin "${commit}:$ref" 2>&1 | ForEach-Object { "$_" })
    $pushCode = $LASTEXITCODE
    $remote = ''
    for ($try = 1; $try -le 3 -and -not $pushCode; $try++) {
      $remote = "$((& git -C $path ls-remote origin $ref 2>$null) | Select-Object -First 1)" -split '\s+' | Select-Object -First 1
      if ($remote -eq $commit) { break }
      Start-Sleep -Milliseconds (500 * $try)
    }
    if ($pushCode -or $remote -ne $commit) {
      $pushError = (@($pushOut | Where-Object { $_ -match '\S' } | Select-Object -Last 6) -join ' | ')
      if (-not $pushError) { $pushError = "push exit $pushCode; ls-remote got '$remote'" }
      $pushError = $pushError.Substring(0, [math]::Min(500, $pushError.Length))
    }
  }
  # Origin unreachable (network, wrong URL) = fail closed, the caller keeps the lease. Only an origin
  # that answered and REFUSED the ref (GH001 size limit, a hook) gets the local-bundle fallback.
  if ($pushError -and $pushError -notmatch 'remote rejected|pre-receive hook declined|GH001|rejected') {
    throw "backup: push of $ref to origin failed ($pushError); local ref kept"
  }
  if (-not $hasOrigin -or $pushError) {
    # No origin, or origin refused the ref: keep a LOCAL bundle and prove it with `bundle verify`.
    # With origin only the commits not on it go in (brivio's full history would be GBs).
    $bdir = Join-Path (Get-WtRoot) '_bundles'; New-Item -ItemType Directory -Force $bdir | Out-Null
    $bundle = Join-Path $bdir "$repoName-$slot-$((Get-Date).ToString('yyyyMMdd-HHmmss'))-$(Short ([guid]::NewGuid().ToString('N')) 4).bundle"
    $bargs = @('bundle', 'create', '-q', $bundle, $ref); if ($hasOrigin) { $bargs += @('--not', '--remotes=origin') }
    & git -C $path @bargs 2>$null
    if ($LASTEXITCODE -or -not (Test-Path -LiteralPath $bundle)) { throw "backup: bundle $bundle failed (local ref $ref kept)$(if ($pushError) { "; origin refused the push: $pushError" })" }
    & git -C $path bundle verify -q $bundle 2>$null | Out-Null
    if ($LASTEXITCODE) { throw "backup: bundle $bundle does not verify (local ref $ref kept)$(if ($pushError) { "; origin refused the push: $pushError" })" }
    if ($pushError) { [Console]::Error.WriteLine("agentq: backup push of $ref refused by origin ($pushError); kept as verified bundle $bundle") }
  }
  $j = @{ event = 'backup'; resource = "slot:${repoName}:$slot"; sha = $commit; ref = $ref; reason = $why; repo = $repoName }
  if ($pushError) { $j.pushError = $pushError }
  if ($bundle) { $j.bundle = $bundle }
  Write-Journal $j
  if ($pushError) { "$ref (bundle $bundle)" } else { $ref }
}

# ---- slot readiness (ADR 0003 W1-4) ---------------------------------------------------------------
# A stale <gitdir>/index.lock left by a killed checkout made `lease` fail with "checkout origin/main
# failed" 54 times and blocked prod releases for 3 h (2026-10-15). Remove it only when no git process
# is using that worktree.
function Clear-StaleIndexLock([string]$path) {
  try {
    $gf = Join-Path $path '.git'
    if (-not (Test-Path -LiteralPath $gf -PathType Leaf)) { return }
    $gd = ((Get-Content -LiteralPath $gf -Raw) -replace '^gitdir:\s*', '').Trim()
    if (-not [IO.Path]::IsPathRooted($gd)) { $gd = Join-Path $path $gd }
    $lock = Join-Path $gd 'index.lock'
    if (-not (Test-Path -LiteralPath $lock)) { return }
    $needle = $path.TrimEnd('\').ToLowerInvariant()
    # @(...) around the if: an empty array returned by a statement becomes $null, and $null.Count throws
    # under StrictMode 3 (swallowed by the catch below -> the stale lock was never removed)
    $busy = @(if ($IsWindows) { Get-CimInstance Win32_Process -Filter "Name='git.exe'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)".ToLowerInvariant().Contains($needle) } }
      else { Get-Process -Name git -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)".ToLowerInvariant().Contains($needle) } })
    if ($busy.Count) { return }
    if (((Now) - (Get-Item -LiteralPath $lock).LastWriteTimeUtc).TotalSeconds -lt 30) { return }
    Remove-Item -LiteralPath $lock -Force -ErrorAction SilentlyContinue
    Write-Journal @{ event = 'slot-unlock'; resource = "slot:$path"; reason = 'stale index.lock removed (no git process on the worktree)' }
  } catch {}
}
# Fresh slots failed their first commit/gate ~19 times: missing node_modules after a lockfile change,
# no .husky/_ (hooks silently skipped), unbuilt workspace dists. Prepare-Slot makes the slot usable:
#  - repo script scripts/slot-prep.ps1 -Worktree <path> -Main <main> if present (repo knows best);
#  - else for pnpm repos: frozen install under install:<repo> when the lockfile differs from the last
#    prep, and .husky/_ copied from the main clone when the worktree lacks it.
# Never fails the lease: problems are printed + journaled (slot-prep-failed) and the slot is marked
# not ready in <coord>/prep/<repo>--<slot>.json, so the agent knows before its first commit.
function Prepare-Slot([string]$main, [string]$path, [string]$repoName) {
  if ($env:AGENTQ_NO_PREP -eq '1') { return }
  # State lives in the coord dir, not in the slot: an untracked file there made every clean slot look
  # dirty (unlease backed it up, worktree v2 test 2026-10-18).
  $pd = Join-Path $Root 'prep'; if (-not (Test-Path -LiteralPath $pd)) { New-Item -ItemType Directory -Force $pd | Out-Null }
  $stateF = Join-Path $pd ((Safe "$repoName--$(Split-Path $path -Leaf)") + '.json')
  $st = [ordered]@{ at = (Iso (Now)); lock = ''; steps = @(); ready = $true }
  try {
    $custom = Join-Path $path 'scripts\slot-prep.ps1'
    if (Test-Path -LiteralPath $custom) {
      $out = @(& pwsh -NoProfile -File $custom -Worktree $path -Main $main 2>&1 | ForEach-Object { "$_" })
      $st.steps += "slot-prep.ps1 rc=$LASTEXITCODE"
      if ($LASTEXITCODE) { $st.ready = $false; $out | Select-Object -Last 15 | ForEach-Object { [Console]::Error.WriteLine("  slot-prep: $_") } }
    } elseif (Test-Path -LiteralPath (Join-Path $path 'pnpm-lock.yaml')) {
      $lockHash = (Get-FileHash -LiteralPath (Join-Path $path 'pnpm-lock.yaml') -Algorithm SHA1).Hash
      $prev = $null; if (Test-Path -LiteralPath $stateF) { try { $prev = Get-Content -LiteralPath $stateF -Raw | ConvertFrom-Json } catch {} }
      $st.lock = $lockHash
      $nm = Test-Path -LiteralPath (Join-Path $path 'node_modules\.modules.yaml')
      if (-not $nm -or -not $prev -or (P $prev 'lock' '') -ne $lockHash -or -not (P $prev 'ready' $false)) {
        $aq = Join-Path $PSScriptRoot 'agentq.ps1'
        $out = @(& pwsh -NoProfile -File $aq run -Resource install -Purpose "slot prep $repoName/$(Split-Path $path -Leaf)" -Repo $path -- pnpm install --frozen-lockfile --prefer-offline 2>&1 | ForEach-Object { "$_" })
        $st.steps += "pnpm install rc=$LASTEXITCODE"
        if ($LASTEXITCODE) { $st.ready = $false; $out | Select-Object -Last 12 | ForEach-Object { [Console]::Error.WriteLine("  slot-prep: $_") } }
      } else { $st.steps += 'pnpm install skipped (lockfile unchanged)' }
    }
    $hp = "$(& git -C $path config --get core.hooksPath 2>$null)".Trim()
    if ($hp -eq '.husky/_' -and -not (Test-Path -LiteralPath (Join-Path $path '.husky\_\pre-commit'))) {
      $srcH = Join-Path $main '.husky\_'
      if (Test-Path -LiteralPath $srcH) { Copy-Item -LiteralPath $srcH -Destination (Join-Path $path '.husky') -Recurse -Force; $st.steps += 'copied .husky/_ from main clone' }
      else { $st.ready = $false; $st.steps += '.husky/_ missing (run pnpm exec husky)' }
    }
  } catch { $st.ready = $false; $st.steps += "error: $($_.Exception.Message)" }
  try { [IO.File]::WriteAllText($stateF, ($st | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)) } catch {}
  if (-not $st.ready) {
    Write-Journal @{ event = 'slot-prep-failed'; resource = "slot:${repoName}:$(Split-Path $path -Leaf)"; reason = ($st.steps -join '; '); repo = $repoName }
    [Console]::Error.WriteLine("agentq: WARNING slot $path is not ready: $($st.steps -join '; ')")
  }
  $st
}

# Bring a slot to a fresh state at $ref (+ optional branch). The caller holds the lease and has
# already backed up anything unique, so discarding inside THIS slot is safe by construction.
function Initialize-Slot([string]$main, [string]$path, [string]$ref, [string]$branch, [bool]$copyEnv) {
  & git -C $main worktree prune 2>$null
  $registered = @(& git -C $main worktree list --porcelain | Where-Object { $_ -like 'worktree *' } | ForEach-Object { Norm-Dir $_.Substring(9) })
  $isReg = $registered -contains (Norm-Dir $path)
  if (-not $isReg) {
    if (Test-Path -LiteralPath $path) {
      $left = @(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'node_modules', '.copilot-tmp' })
      if ($left.Count) { throw "slot ${path}: directory exists but is not a worktree of $main ($($left.Count) entries) - run 'worktree.ps1 migrate' first" }
      if ($IsWindows) { cmd /c rmdir /s /q "`"$path`"" 2>$null } else { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
    & git -C $main worktree add -q --detach $path $ref 2>&1 | Out-Null
    if ($LASTEXITCODE) { throw "slot ${path}: git worktree add failed" }
  } else {
    Clear-StaleIndexLock $path
    foreach ($op in 'merge', 'cherry-pick', 'rebase') { & git -C $path $op --abort 2>$null | Out-Null }
    & git -C $path reset -q --hard 2>$null
    & git -C $path checkout -q --detach $ref 2>$null
    if ($LASTEXITCODE) { Clear-StaleIndexLock $path; & git -C $path reset -q --hard 2>$null; & git -C $path checkout -q -f --detach $ref 2>$null }
    if ($LASTEXITCODE) { $why = @(& git -C $path checkout -q --detach $ref 2>&1 | ForEach-Object { "$_" }) -join ' | '; throw "slot ${path}: checkout $ref failed ($why)" }
    & git -C $path reset -q --hard $ref
    & git -C $path clean -fdq 2>$null   # not -x: keeps node_modules and build caches (the point of reuse)
  }
  if ($branch) {
    if ((& git -C $path rev-parse --verify -q "refs/heads/$branch" 2>$null)) { & git -C $path checkout -q $branch 2>$null }
    elseif ((& git -C $path rev-parse --verify -q "refs/remotes/origin/$branch" 2>$null)) { & git -C $path checkout -q -b $branch --track "origin/$branch" 2>$null }
    else { & git -C $path checkout -q -b $branch $ref 2>$null }
    if ($LASTEXITCODE) { throw "slot ${path}: cannot check out branch $branch (checked out in another worktree?)" }
  }
  if ($copyEnv) {
    $cands = @(Get-ChildItem -LiteralPath $main -File -Force -Filter '.env*' -ErrorAction SilentlyContinue)
    foreach ($d in 'apps', 'packages') { $b = Join-Path $main $d; if (Test-Path $b) { $cands += Get-ChildItem -LiteralPath $b -Directory | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Force -Filter '.env*' -ErrorAction SilentlyContinue } } }
    foreach ($f in $cands) { if ($f.Name -like '*.example') { continue }; $rel = $f.FullName.Substring($main.Length).TrimStart('\', '/'); $t = Join-Path $path $rel; New-Item -ItemType Directory -Force -Path (Split-Path -Parent $t) | Out-Null; Copy-Item -LiteralPath $f.FullName -Destination $t -Force }
  }
}

function Remove-LeaseRecord($l, [string]$event, [string]$why, [string]$backupRef) {
  # Free the agent's branch: a slot left on `feat/x` blocks `git checkout feat/x` everywhere else and
  # makes deleting the branch impossible. State is already backed up (or clean) at this point.
  $p = "$(P $l 'path')"
  if ($event -notin 'lease-failed', 'lease-expire-failed' -and $p -and (Test-Path -LiteralPath (Join-Path $p '.git'))) { & git -C $p checkout -q --detach 2>$null | Out-Null }
  # OQ-001: what the chat side looked like when the lease ended. `byChat` = the release was run by a
  # chat bound to this lease (the hook records who ran `unlease`), i.e. the worker gave its own slot back
  # from another shell; that is not a loss. chatIdleMin <= 30 on anything else is the metric to drive to 0.
  $f = Get-LeaseChatFacts $l
  $chatIdle = $f.idle
  $byChat = $f.byChat
  if ($event -eq 'lease-expire-failed') { Remove-Item -LiteralPath "$($l.file).release" -Force -ErrorAction SilentlyContinue }
  else { Remove-Item -LiteralPath $l.file, "$($l.file).hb", "$($l.file).chat", "$($l.file).work", "$($l.file).release" -Force -ErrorAction SilentlyContinue }
  if ($event -in 'lease-expire', 'lease-break' -and (P $l 'session') -ne $Session) { Add-LeaseNotice $l $event $why $backupRef }
  # Slot history (2026-11-21): the holder + the backup ref survive the lease record, so a later takeover
  # can still name whose work it just found and point at the exact ref to restore from.
  Add-SlotHistory $l.repo $l.slot $event (P $l 'session') $backupRef '' $why
  Write-Journal @{ event = $event; resource = "slot:$($l.repo):$($l.slot)"; ticket = (P $l 'leaseId'); holderSession = (P $l 'session'); purpose = (P $l 'purpose'); reason = $why; ref = $backupRef; repo = $l.repo; chats = @($f.chats).Count; chatIdleMin = $chatIdle; byChat = $byChat }
}
# Expire = back up (proven) THEN drop the record. A failed backup keeps the lease (fail closed).
function Expire-Lease($l, [string]$why) {
  try { $ref = Backup-Slot (P $l 'path') $l.repo $l.slot $why -CommitsOnly:((P $l 'role') -eq 'release') }
  catch { Write-Journal @{ event = 'lease-expire-failed'; resource = "slot:$($l.repo):$($l.slot)"; reason = "$why; $($_.Exception.Message)"; repo = $l.repo }; return $false }
  Remove-LeaseRecord $l 'lease-expire' $why $ref
  $true
}
function Get-TaskLeaseCount { @(Read-Leases $null | Where-Object { (P $_ 'role') -eq 'task' }).Count }

# Take a slot lease (exclusive). Task role picks the first free task-N. Returns the lease object.
function New-Lease($repo, [string]$slot, [string]$role, [string]$purpose, [string]$branch, [int]$owner, [int]$timeoutMin, [bool]$noWait, [bool]$wait, $maxMin, [bool]$maxMinGiven) {
  $repoName = $repo.Name
  $cfg = Get-Config
  # `-Wait` (2026-11-18): the bound is -MaxMin (default 5 min) and expiry exits 7 with one stdout line.
  # Without it the legacy -TimeoutMin (default 60) applies and expiry exits 3, exactly as before.
  $boundMin = if ($wait) { if ($maxMinGiven) { [double]$maxMin } else { 5 } } else { $timeoutMin }
  # ADR 0013: a SUBAGENT must never queue. Its parent owns the work slot; the subagent works INSIDE that
  # slot (or takes a scratch slot), and if it cannot get one quickly it RETURNS to the parent with a note
  # instead of burning its session on a wait - the measured cost of the old behaviour was slots held by
  # dead chats and ~52.9 h/week of queue time, much of it subagents waiting for a pool their lead already
  # had. CODAI_SUBAGENT=1 (the harness sets it for subagents) turns every unnamed lease into a 60 s probe.
  if (($env:CODAI_SUBAGENT -eq '1' -or $env:AGENTQ_FAIL_FAST -eq '1') -and -not $slot -and -not $wait) {
    $wait = $true
    if (-not $maxMinGiven) { $maxMin = 1; $maxMinGiven = $true }
  }
  # $slotValid: ADR 0001 says only standard slots exist. An unknown -Slot is NEVER leased; it is either a
  # hard error (no -Wait) or a slot that never frees (with -Wait), so -Wait cannot invent a bogus slot.
  $slotValid = $true
  if ($slot) {
    $r = Get-SlotRole $repoName $slot
    if ($r) { $role = $r } else { $slotValid = $false }
    # -Wait: an unknown slot simply never frees; the bound decides (exit 7), so no throw.
    if (-not $r -and -not $wait) { throw "agentq lease: '$slot' is not a standard slot for $repoName (task-1..$($cfg.taskSlotsPerRepo), release$(if ((Get-ReleaseSlotCount $repoName) -gt 1) { ', release-2..' + (Get-ReleaseSlotCount $repoName) }), land$(if (Get-PinnedSlots $repoName) { ', pinned: ' + ((Get-PinnedSlots $repoName) -join ',') })) - ADR 0001" }
  }
  if (-not $role) { $role = 'task' }
  # -MaxMin 0 = give up at once: a deadline a moment in the past makes the first check expire.
  $deadline = if ($wait -and $boundMin -le 0) { (Now).AddSeconds(-1) } else { (Now).AddMinutes($boundMin) }
  $announced = $false
  $loadSaid = $false
  $limitSaid = $false
  # Auto-escalation (ADR 0012): an agent blocked on a slot must not have to ask the owner what to do.
  # After 10 minutes of waiting we run the sanctioned remedies once: propose (break a hung/STALE queue
  # holder, bump my waiting tickets) and sweep (expire stale leases and dead tickets). Journaled by both.
  $waitStart = Now
  $escalated = $false
  # One exit for both expiry sites: -Wait prints ONE line to stdout and exits 7; otherwise the legacy
  # stderr message + exit 3 (byte-identical to what callers parsed before).
  $expire = {
    param([string]$whyWait, [string]$whyLegacy)
    $held = (@(Read-Leases $repoName) | ForEach-Object { "$($_.slot)=$($_.session) '$($_.purpose)' idle $($_.idleMin)m" }) -join '; '
    if ($wait) {
      Write-Output ("agentq: no free {0} in {1} within {2} min - {3}{4}" -f $(if ($slot) { "slot $slot" } else { "$role slot" }), $repoName, $boundMin, $whyWait, $(if ($held) { "; held: $held" } else { '' }))
      Write-Output "  next: agentq eval -Resource '$($role):$repoName' tells you whether a holder can be preempted (and the exact command), or agentq propose -Reason '...' breaks a hung one automatically."
      if ($env:CODAI_SUBAGENT -eq '1' -or $env:AGENTQ_FAIL_FAST -eq '1') { Write-Output "  SUBAGENT: do not wait. Hand the work back to the parent session (agentq note -Message 'blocked on <resource>: <what is left>') and end the turn." }
      Write-Journal @{ event = 'lease-timeout'; resource = "slot:${repoName}:$(if ($slot) { $slot } else { $role })"; purpose = $purpose; reason = $whyWait; repo = $repoName; waitedMin = $boundMin }
      exit 7
    }
    [Console]::Error.WriteLine("agentq: $whyLegacy. Held: $held")
    # Same event as the -Wait path so the SLO sees BOTH kinds of give-up (the legacy one was invisible:
    # the 40 lease-timeouts of 2026-11-12..19 counted only -Wait bounds, not -TimeoutMin abandons).
    Write-Journal @{ event = 'lease-timeout'; resource = "slot:${repoName}:$(if ($slot) { $slot } else { $role })"; purpose = $purpose; reason = $whyLegacy; repo = $repoName; waitedMin = $timeoutMin }
    exit 3
  }
  # A frozen/blocked slot is a hard stop (exit 3). Only -Wait checks it, so the plain lease is unchanged.
  if ($wait) {
    foreach ($mk in @("slot:${repoName}:$(if ($slot) { $slot } else { $role })", "slot:$repoName")) {
      $m = Get-Mark $mk
      if ($m) { Write-Output ("agentq: refused - {0} is {1}: {2}" -f $mk, "$($m.state)".ToUpper(), $m.reason); exit 3 }
    }
  }
  while ($true) {
    # OQ-004: a saturated machine takes no NEW task agent. Release/land/pinned slots are never gated (they
    # finish work already admitted); after admission.maxHoldMin the lease is granted anyway.
    $loadHeld = $false
    if ($role -eq 'task') {
      $ld = Get-AdmissionLoad
      if ($ld.saturated -and -not (Test-AdmissionOverride "slot:$repoName" $purpose $ld)) {
        $loadHeld = $true
        if (-not $loadSaid) { [Console]::Error.WriteLine("agentq: machine saturated (start probe median $($ld.median) ms > $($ld.thresholdMs) ms): no new task slot until it recovers or $([double](Get-AdmissionConfig).maxHoldMin) min pass (agentq status shows the probe)"); $loadSaid = $true }
      }
    }
    if ($loadHeld) {
      if ($noWait -or (Now) -gt $deadline) {
        if ($wait) { & $expire "the machine is saturated (start probe median $($ld.median) ms > $($ld.thresholdMs) ms)" '' }
        [Console]::Error.WriteLine("agentq: no task slot granted - the machine is saturated$(if (-not $noWait) { " (waited $timeoutMin min)" })"); exit 3
      }
      Start-Sleep -Seconds 5; continue
    }
    # OQ-005: the machine-wide limit on task leases in force right now (owner presence + night schedule).
    $agl = Get-AgentLimit
    $got = With-Mutex "lease-$repoName" {
      $leases = @(Read-Leases $repoName)
      $cands = if (-not $slotValid) { @() }
      elseif ($slot) { @($slot) }
      elseif ($role -eq 'task') { @(1..$cfg.taskSlotsPerRepo | ForEach-Object { "task-$_" }) }
      elseif ($role -eq 'scratch') { @(1..(Get-ScratchSlotCount) | ForEach-Object { "scratch-$_" }) }
      elseif ($role -eq 'release') { @('release') + @(2..([math]::Max(2, (Get-ReleaseSlotCount $repoName))) | Where-Object { $_ -le (Get-ReleaseSlotCount $repoName) } | ForEach-Object { "release-$_" }) }
      else { @($role) }
      $capHit = $false
      foreach ($s in $cands) {
        $cur = $leases | Where-Object { $_.slot -eq $s } | Select-Object -First 1
        if ($cur -and $cur.stale) { if (-not (Expire-Lease $cur "stale (idle $($cur.idleMin) min, owner alive=$($cur.alive)) - reclaimed by $Session")) { continue }; $cur = $null }
        # -Reclaim (idea 8): a live lease whose ONLY protection is a chat grace (idle past its threshold,
        # not held) is taken for a blocked agent instead of a foreign `unlease` break. Requires -Reason.
        if ($cur -and $Reclaim -and -not (P $cur 'held' $false) -and $cur.idleMin -gt (P $cur 'thresholdMin' 0)) {
          $rcWhy = "reclaimed by $Session for '$purpose' ($Reason): idle $($cur.idleMin) min > threshold $((P $cur 'thresholdMin' 0)) min, why='$(P $cur 'why' '')'"
          if (Expire-Lease $cur $rcWhy) {
            Write-Journal @{ event = 'lease-reclaim'; resource = "slot:${repoName}:$s"; ticket = (P $cur 'leaseId'); by = $Session; purpose = $purpose; reason = $Reason; idleMin = $cur.idleMin; repo = $repoName }
            $cur = $null
          }
        }
        if ($cur) { continue }
        if ($role -eq 'task' -and (Get-TaskLeaseCount) -ge $agl.limit) { $capHit = $true; break }
        $p = Get-SlotPath $repoName $s
        $st = Get-ProcStart $owner
        $l = [ordered]@{
          leaseId = [guid]::NewGuid().ToString('N').Substring(0, 8); repo = $repoName; slot = $s; role = $role; path = $p
          branch = "$branch"; purpose = $purpose; session = $Session; pid = $owner; procStart = $(if ($st) { Iso $st } else { $null }); created = (Iso (Now)); host = $env:COMPUTERNAME
          claims = @($(if ($role -in 'task', 'pinned') { $Claims } else { @() }))
        }
        $f = Get-LeaseFile $repoName $s
        # a chat binding / work clock left by a previous lease of this slot must not keep the new one alive
        Remove-Item -LiteralPath "$f.chat", "$f.work", "$f.release" -Force -ErrorAction SilentlyContinue
        Write-JsonAtomic $f $l
        [IO.File]::WriteAllText("$f.hb", '')
        Write-Journal @{ event = 'lease'; resource = "slot:${repoName}:$s"; ticket = $l.leaseId; purpose = $purpose; branch = "$branch"; repo = $repoName; loadWaitSec = (Get-LoadWaitSec) }
        return ([pscustomobject]$l | Add-Member -NotePropertyName file -NotePropertyValue $f -PassThru)
      }
      if ($capHit) { 'MACHINE-CAP' } else { $null }
    }
    if ($got -and $got -isnot [string]) { return $got }
    if ($got -eq 'MACHINE-CAP' -and $agl.limit -lt $agl.base -and -not $limitSaid) {
      $limitSaid = $true
      Write-Journal @{ event = 'agent-limit-hold'; resource = "slot:$repoName"; purpose = $purpose; limit = [int]$agl.limit; base = [int]$agl.base; reason = $agl.why; repo = $repoName }
    }
    if ($noWait -or (Now) -gt $deadline) {
      $why = if ($got -eq 'MACHINE-CAP') { "machine-wide task slot cap ($($agl.limit)) reached$(if ($agl.limit -ne $agl.base) { " - agent limit: $($agl.why); $($agl.base) otherwise" })" } else { "no free $role slot in $repoName" }
      $whyWait = if ($got -eq 'MACHINE-CAP') { "the machine-wide task slot cap ($($agl.limit)) is reached" } else { 'it is still held' }
      & $expire $whyWait $why
    }
    if (-not $announced) { [Console]::Error.WriteLine("agentq: waiting for a free $role slot in $repoName ..."); $announced = $true }
    if (-not $escalated -and ((Now) - $waitStart).TotalMinutes -ge 10) {
      $escalated = $true
      [Console]::Error.WriteLine('agentq: waited 10 min - trying the sanctioned remedies once (propose + sweep)')
      try { $prevR = $Reason; $script:Reason = "auto-escalation: waited 10 min for a $role slot in $repoName"; $null = Invoke-Propose } catch { } finally { $script:Reason = $prevR }
      try { $null = Invoke-Sweep } catch { }
    }
    Start-Sleep -Seconds 3
  }
}

# ---- path claims (ADR 0005 / ADR 0003 W4-2) ----------------------------------------------------
# Advisory: a lease may declare the paths it will touch ('apps/hub/**,packages/ui/**'). Overlaps with other
# live leases of the repo are printed + journaled (claim-overlap); a land ticket from a claiming slot carries
# the claims, and among WAITING land tickets an overlapping younger lease ranks after the older one.
function Get-ClaimPrefix([string]$g) {
  $g = $g.Replace('\', '/').TrimStart('/')
  $i = $g.IndexOfAny([char[]]'*?[')
  $p = if ($i -ge 0) { $g.Substring(0, $i) } else { $g }
  # Only whole segments count: 'apps/hu*' -> 'apps/'; 'apps/hub/**' -> 'apps/hub/'
  if ($i -ge 0 -and -not $p.EndsWith('/')) { $j = $p.LastIndexOf('/'); $p = if ($j -ge 0) { $p.Substring(0, $j + 1) } else { '' } }
  $p
}
function Test-GlobOverlap([string]$a, [string]$b) {
  $pa = Get-ClaimPrefix $a; $pb = Get-ClaimPrefix $b
  $wa = $a -match '[*?\[]'; $wb = $b -match '[*?\[]'
  if (-not $wa -and -not $wb) { return $a.TrimStart('/') -eq $b.TrimStart('/') }
  # Literal path vs glob: the literal must lie under the glob's prefix (or equal it as a dir).
  if (-not $wa) { return ($a.TrimStart('/') + '/').StartsWith($pb) -or $a.TrimStart('/').StartsWith($pb) }
  if (-not $wb) { return ($b.TrimStart('/') + '/').StartsWith($pa) -or $b.TrimStart('/').StartsWith($pa) }
  $pa.StartsWith($pb) -or $pb.StartsWith($pa)
}
function Test-ClaimOverlap($ca, $cb) {
  $hits = @()
  foreach ($x in @($ca)) { foreach ($y in @($cb)) { if ($x -and $y -and (Test-GlobOverlap "$x" "$y")) { $hits += "$x ~ $y" } } }
  $hits
}
function Show-ClaimOverlaps($repoName, $lease, $claims) {
  if (-not @($claims).Count) { return }
  foreach ($o in @(Read-Leases $repoName | Where-Object { $_.leaseId -ne $lease.leaseId -and -not $_.stale -and @(P $_ 'claims' @()).Count })) {
    $hits = @(Test-ClaimOverlap $claims (P $o 'claims' @()))
    if (-not $hits.Count) { continue }
    Write-Journal @{ event = 'claim-overlap'; resource = "slot:${repoName}:$($lease.slot)"; ticket = $lease.leaseId; paths = $hits; reason = "overlaps $($o.slot) ($($o.session) '$($o.purpose)')"; repo = $repoName }
    [Console]::Error.WriteLine("agentq: claim overlap with $repoName/$($o.slot) ($($o.session), '$($o.purpose)', since $((P $o 'created' '?'))): $($hits -join '; '). Coordinate, or expect your land to queue after theirs.")
  }
}
# Land waiters: a ticket whose claims overlap an OLDER lease's claims ranks after that ticket.
function Sort-ByClaims([object[]]$w) {
  $list = [System.Collections.Generic.List[object]]::new(); foreach ($x in $w) { $list.Add($x) }
  for ($pass = 0; $pass -lt $list.Count; $pass++) {
    $moved = $false
    for ($i = 0; $i -lt $list.Count - 1; $i++) {
      $a = $list[$i]
      $ca = @(P $a 'claims' @()); if (-not $ca.Count) { continue }
      for ($j = $i + 1; $j -lt $list.Count; $j++) {
        $b = $list[$j]; $cb = @(P $b 'claims' @()); if (-not $cb.Count) { continue }
        $la = "$(P $a 'leaseCreated' '')"; $lb = "$(P $b 'leaseCreated' '')"
        if ($la -and $lb -and [string]::CompareOrdinal($lb, $la) -lt 0 -and @(Test-ClaimOverlap $ca $cb).Count) { $list.RemoveAt($j); $list.Insert($i, $b); $moved = $true; break }
      }
      if ($moved) { break }
    }
    if (-not $moved) { break }
  }
  @($list)
}
function Invoke-Claim {
  if (-not $LeaseId -or -not @($Claims).Count) { throw "agentq claim -LeaseId <id> -Claims 'apps/x/**,packages/y/**' (replaces the lease's claims)" }
  $l = Read-Leases $null | Where-Object { (P $_ 'leaseId') -eq $LeaseId } | Select-Object -First 1
  if (-not $l) { throw "agentq claim: no live lease $LeaseId" }
  $raw = Get-Content -LiteralPath $l.file -Raw | ConvertFrom-Json -AsHashtable
  $raw.claims = @($Claims)
  Write-JsonAtomic $l.file $raw
  Write-Journal @{ event = 'claim'; resource = "slot:$($l.repo):$($l.slot)"; ticket = $LeaseId; paths = @($Claims); repo = $l.repo }
  Write-Output "claims on $($l.repo)/$($l.slot): $(@($Claims) -join ', ')"
  Show-ClaimOverlaps $l.repo $l @($Claims)
}

function Invoke-Lease {
  $script:TakeoverNote = ''
  $repo = Get-RepoInfo $RepoArg
  Assert-ExpectedRepo $repo
  if (-not $repo) { throw 'agentq lease: not in a git repo (pass -Repo)' }
  if (-not $Purpose -and -not $Wait) { throw 'agentq lease: -Purpose is required (other agents read it)' }
  # -Reclaim (idea 8) takes another session's grace-held slot, so it needs a journalled reason like `break`.
  if ($Reclaim -and -not $Reason) { throw "agentq lease: -Reclaim needs -Reason '...' (it expires another session's slot that only a chat grace was holding)" }
  # -Wait is also a bounded "is a slot free?" probe (usually with -MaxMin 0), so a missing -Purpose is
  # not an error there: record an explicit placeholder rather than refuse. Plain lease: still required.
  if (-not $Purpose) { $script:Purpose = '(no -Purpose: agentq lease -Wait probe)' }
  # ADR 0012 (2026-11-19): ONE task slot per session per repo. 4 of the 14 live leases that day were
  # subagent slots - a subagent shares its lead's session, and "lease another task slot" is what made
  # ~160 leases/day against a pool of 11 per repo. A second task lease from the same session is refused
  # with the two sanctioned alternatives; -Slot task-N is the deliberate override.
  if ((-not $Slot) -and "$Role" -in '', 'task' -and -not $Wait) {
    $mine = @(Read-Leases $repo.Name | Where-Object { (P $_ 'role') -eq 'task' -and (P $_ 'session') -eq $Session -and -not $_.stale })
    if ($mine.Count) {
      $heldTxt = ($mine | ForEach-Object { "$($_.slot) ($($_.leaseId), idle $($_.idleMin)m, '$($_.purpose)')" }) -join '; '
      [Console]::Error.WriteLine("agentq: this session already holds a task slot in $($repo.Name): $heldTxt`n  Subagents work in the LEAD's slot - pass them its path instead of leasing. For isolated one-off work use a scratch slot: agentq lease -Role scratch -Purpose '<why>' (not counted against the caps, reclaimed after 15 min without work). To take a second task slot on purpose, name it: -Slot task-N.")
      exit 3
    }
  }
  $main = Get-MainTop $repo
  $owner = Get-DefaultOwner
  $l = New-Lease $repo $Slot $Role $Purpose $Branch $owner $TimeoutMin $NoWait $Wait $MaxMin $MaxMinGiven
  # -Hold: an explicit, bounded, journalled claim that the holder runs a long job OUTSIDE the slot.
  if ($Hold -and $l) {
    $hm = if ($HoldMin) { [double]$HoldMin } else { [double](P (Get-Config) 'holdDefaultMin' 180) }
    try {
      $raw = Get-Content -LiteralPath $l.file -Raw | ConvertFrom-Json -AsHashtable
      $raw['holdUntil'] = Iso ((Now).AddMinutes($hm))
      Write-JsonAtomic $l.file $raw
      Write-Journal @{ event = 'lease-hold'; resource = "slot:$($l.repo):$($l.slot)"; ticket = $l.leaseId; holdMin = $hm; purpose = $Purpose; repo = $l.repo }
    } catch { [Console]::Error.WriteLine("agentq: -Hold could not be recorded: $($_.Exception.Message)") }
  }
  try {
    & git -C $main fetch -q origin 2>$null
    $refToUse = if ($Ref) { $Ref } else { $up = (& git -C $main rev-parse --abbrev-ref '@{u}' 2>$null); if ($up) { $up } else { 'HEAD' } }
    # Anything still unique in the dir (previous holder crashed between backup and release, a legacy
    # tree) is backed up before the reset. A failed backup aborts the lease: nothing is discarded.
    # The backup used to be INVISIBLE (the ref was discarded with [void]): 2026-11-20 21:59 another session
    # leased codai/task-3 while a previous holder's unsaved work was still in it - the work WAS saved
    # (refs/backup/wt/codai/task-3/20261120-215948-8a2e) but nobody was told, so the holder concluded it was
    # lost and rebuilt it. Now the takeover is printed, journalled, notified, and `agentq recover` can list
    # and restore it. The backup still aborts the lease when it cannot be proven (fail closed).
    if (Test-Path -LiteralPath $l.path) {
      $prevRef = Backup-Slot $l.path $repo.Name $l.slot "pre-reset for new lease $($l.leaseId)" -CommitsOnly:($l.role -eq 'release')
      # Nothing unique left in the dir (the reclaim/expire that preceded us already saved it) is NOT
      # "nothing to report": the slot history holds the ref that path recorded, so the take-over is still
      # announced and points at the exact backup. Without this the common case - a stale reclaim - stayed silent.
      if (-not $prevRef) {
        $h = @(Get-SlotHistory $repo.Name $l.slot 20 | Where-Object { (P $_ 'holder') -and (P $_ 'holder') -ne "$Session" })
        if ($h.Count -and (P $h[-1] 'ref')) { $prevRef = "$(P $h[-1] 'ref')" }
      }
      if ($prevRef) { Publish-SlotTakeover $repo.Name $l.slot $prevRef $l.leaseId $l.path }
    }
    Initialize-Slot $main $l.path $refToUse $Branch (-not $env:AGENTQ_NO_ENV_COPY)
    if ($l.role -in 'task', 'pinned', 'scratch') { [void](Prepare-Slot $main $l.path $repo.Name) }
    if (@($Claims).Count) { Show-ClaimOverlaps $repo.Name $l @($Claims) }
    Add-SlotHistory $repo.Name $l.slot 'lease' $Session '' '' $Purpose
  } catch {
    if ($script:TakeoverNote) { Write-Output $script:TakeoverNote }
    Remove-LeaseRecord $l 'lease-failed' "$($_.Exception.Message)" ''
    throw
  }
  $res = [pscustomobject]@{ leaseId = $l.leaseId; repo = $l.repo; slot = $l.slot; role = $l.role; path = $l.path; branch = "$Branch"; head = "$(& git -C $l.path rev-parse --short HEAD)".Trim() }
  if ($Json) { $res | ConvertTo-Json -Compress } else {
    Write-Output "leased $($l.repo)/$($l.slot) ($($l.leaseId)) -> $($l.path) @ $($res.head)$(if ($Branch) { " on $Branch" })"
    if ($script:TakeoverNote) { Write-Output $script:TakeoverNote }
    # $PSCommandPath here is agentq-v2.ps1 (dot-sourced), which cannot be run on its own.
    Write-Output "release when done: pwsh -NoProfile -File `"$(Join-Path $PSScriptRoot 'agentq.ps1')`" unlease -Repo `"$($l.path)`" -LeaseId $($l.leaseId)"
  }
}

function Invoke-Unlease {
  $repo = Get-RepoInfo $RepoArg
  $repoName = if ($repo) { $repo.Name } else { $null }
  if (-not $Slot -and $RepoArg) { $l0 = Find-LeaseForPath $RepoArg; if ($l0) { $script:Slot = $l0.slot; $repoName = $l0.repo } }
  if (-not $Slot -or -not $repoName) { throw 'agentq unlease -Repo <slot dir> [-Slot <slot>] -LeaseId <id> [-Reason ...]' }
  $l = (Read-Leases $repoName | Where-Object { $_.slot -eq $Slot } | Select-Object -First 1)
  if (-not $l) { Write-Output "no lease on $repoName/$Slot"; return }
  # Releasing a lease needs its exact id (break-by-id, ADR 0001 section 2); a foreign one also a reason.
  if ($LeaseId -ne $l.leaseId) {
    [Console]::Error.WriteLine("agentq: $repoName/$Slot is leased by $($l.session) ($($l.leaseId), '$($l.purpose)', idle $($l.idleMin)m, alive=$($l.alive)). Pass -LeaseId $($l.leaseId)$(if ($l.session -ne $Session) { " -Reason '...'" })")
    exit 2
  }
  $foreign = ($l.session -ne $Session)
  if ($foreign -and -not $Reason) { [Console]::Error.WriteLine("agentq: lease belongs to $($l.session); breaking it needs -Reason"); exit 2 }
  # OQ-001 / ADR 0009 stage 0: the one loss the SLO drives to 0 is a lease ended while its holder's chat was
  # still live (`slotsLostLiveChat` - 3 lease-break + 1 lease-expire in the 24 h to 2026-11-20, reasons like
  # "the research-reference gate is on main"). The breaker is rarely wrong about the WORK, but the holder's
  # chat still holds plan and context and the slot is reset under it. Refuse exactly what the SLO would
  # count: a break initiated by the holder's own chat (from another shell), or any break once the chat is
  # older than the window, still goes through. The override is explicit and journalled: -Force -Reason.
  $f = Get-LeaseChatFacts $l
  if ($foreign -and -not $Force -and $f.live) {
    $who = if ($f.chats.Count) { @($f.chats) -join ', ' } else { '(unknown)' }
    [Console]::Error.WriteLine("agentq: NOT released - $repoName/$Slot is held by $($l.session) ('$($l.purpose)') and its chat was active $($f.idle) min ago (chat $who). That is the loss the SLO counts as slotsLostLiveChat: the holder's context is still alive while the slot is reset under it. Coordinate with it (agentq status -All, hub /ops/agentq) or wait; if the holder is genuinely gone and only the chat file is stale-fresh, re-run with -Force -Reason '<why>' (journalled, and the holder is notified).")
    exit 3
  }
  $why = if ($Reason) { $Reason } else { 'released by holder' }
  try { $ref = Backup-Slot (P $l 'path') $repoName $Slot $why -CommitsOnly:((P $l 'role') -eq 'release') }
  catch { [Console]::Error.WriteLine("agentq: NOT released - backup failed: $($_.Exception.Message)"); exit 3 }
  Remove-LeaseRecord $l $(if ($foreign) { 'lease-break' } else { 'unlease' }) $why $ref
  Write-Output "released $repoName/$Slot$(if ($ref) { " (unsaved state backed up to $ref)" } else { ' (clean, nothing to back up)' })"
}

function Invoke-Renew {
  $p = if ($WtPath) { $WtPath } else { (Get-Location).Path }
  $l = if ($LeaseId) { Read-Leases $null | Where-Object { (P $_ 'leaseId') -eq $LeaseId } | Select-Object -First 1 } else { Find-LeaseForPath $p }
  if ($l) { Touch-Lease $l; Write-Output "renewed $($l.repo)/$($l.slot)" } else { Write-Output "no lease covers $p" }
}

# ---- slot history & recovery (2026-11-21) ---------------------------------------------------
# Every take-over resets the worktree (`reset --hard` + `clean -fd`), and every reset is preceded by
# Backup-Slot (which fails closed), so work is never actually discarded. It was invisible: 2026-11-20
# 21:59 a new lease on codai/task-3 found the previous holder's unsaved work, backed it up to
# refs/backup/wt/codai/task-3/20261120-215948-8a2e and told NOBODY - the holder concluded the work was
# lost and rebuilt it. Three additions close that: a slot HISTORY that outlives the lease record, a loud
# take-over notice (new holder + previous holder), and `agentq recover` to list and restore any backup.
function Get-SlotHistoryFile([string]$repoName, [string]$slot) {
  $d = Join-Path $Root 'slots'; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force $d | Out-Null }
  Join-Path $d ((Safe "$repoName--$slot") + '.jsonl')
}
function Add-SlotHistory([string]$repoName, [string]$slot, [string]$event, [string]$holder, [string]$ref, [string]$sha, [string]$why) {
  try {
    $r = [ordered]@{ ts = (Iso (Now)); event = $event; repo = $repoName; slot = $slot; holder = "$holder"; by = "$Session"; ref = "$ref"; sha = "$sha"; why = "$why" }
    [IO.File]::AppendAllText((Get-SlotHistoryFile $repoName $slot), (($r | ConvertTo-Json -Compress) + "`n"), [Text.UTF8Encoding]::new($false))
  } catch { }
}
function Get-SlotHistory([string]$repoName, [string]$slot, [int]$last = 40) {
  $f = Get-SlotHistoryFile $repoName $slot
  if (-not (Test-Path -LiteralPath $f)) { return @() }
  $rows = @()
  foreach ($line in @(Get-Content -LiteralPath $f -ErrorAction SilentlyContinue)) {
    if (-not "$line".Trim()) { continue }
    try { $rows += ($line | ConvertFrom-Json) } catch { }
  }
  @($rows | Select-Object -Last $last)
}
# The repo's MAIN clone, resolved from a repo NAME: a slot may not exist yet, the shared clone always does.
function Get-RepoMainFor([string]$repoName) {
  $gh = Split-Path -Parent (Get-WtRoot)
  $p = Join-Path $gh $repoName
  if (Test-Path -LiteralPath (Join-Path $p '.git')) { return $p }
  foreach ($s in @(@(1..4 | ForEach-Object { "task-$_" }) + @('land', 'release'))) {
    $c = Get-SlotPath $repoName $s
    if (Test-Path -LiteralPath (Join-Path $c '.git')) { return $c }
  }
  $null
}
function Get-SlotBackups([string]$repoName, [string]$slot, [int]$last = 8, [switch]$Fetch) {
  $main = Get-RepoMainFor $repoName
  if (-not $main) { return @() }
  if ($Fetch) { & git -C $main fetch -q origin 'refs/backup/wt/*:refs/backup/wt/*' 2>$null | Out-Null }
  # `for-each-ref` matches with FNM_PATHNAME, so a single `*` never crosses a `/`: `refs/backup/wt/<repo>/*`
  # matches 0 refs (measured 2026-11-21 - 1607 refs under codai, 0 hits) while `<repo>/<slot>/*` works by
  # accident. `/**` crosses the slash; the slot is then selected in PowerShell.
  $pat = "refs/backup/wt/$repoName/**"
  $rows = @()
  foreach ($line in @(& git -C $main for-each-ref --sort=-creatordate --sort=-refname '--format=%(refname)|%(objectname)|%(creatordate:iso-strict)|%(subject)' $pat 2>$null)) {
    if (-not "$line") { continue }
    $f = "$line" -split '\|', 4
    if (@($f).Count -lt 4) { continue }
    $nm = @($f[0] -split '/')
    $slotName = if ($nm.Count -ge 6) { $nm[4] } else { '' }
    if ($slot -and $slotName -ne $slot) { continue }
    $rows += [pscustomobject]@{
      Ref = $f[0]; Sha = $f[1]; At = $f[2]; Subject = $f[3]
      Slot = $slotName
      Kind = $(if ($f[3] -like 'agentq backup *') { 'files' } else { 'commits' })
    }
  }
  @($rows | Select-Object -First $last)
}
# A backup is accepted as a full ref, a sha, or a '<slot>/<stamp>' suffix.
function Resolve-BackupRef([string]$repoName, [string]$what) {
  if (-not $what) { return $null }
  $main = Get-RepoMainFor $repoName; if (-not $main) { return $null }
  $full = if ($what -like 'refs/*') { $what } else { "refs/backup/wt/$repoName/$what" }
  foreach ($cand in @($what, $full)) {
    $obj = "$(& git -C $main rev-parse --verify -q $cand 2>$null)".Trim()
    if ($obj) { return [pscustomobject]@{ Ref = $cand; Sha = $obj } }
  }
  $null
}
# A take-over is loud now: journal + slot history + a notice to the previous holder + the note the new
# holder reads on stdout. The note is also printed when the lease FAILS after the backup, so it cannot be lost.
function Publish-SlotTakeover([string]$repoName, [string]$slot, [string]$ref, [string]$leaseId, [string]$path) {
  $sha = ''
  try { $sha = "$(& git -C $path rev-parse --short $ref 2>$null)".Trim() } catch { }
  $prev = @(Get-SlotHistory $repoName $slot 20 | Where-Object { (P $_ 'event') -eq 'lease' -and (P $_ 'holder') -and (P $_ 'holder') -ne "$Session" })
  $holder = if ($prev.Count) { "$(P $prev[-1] 'holder')" } else { '' }
  Add-SlotHistory $repoName $slot 'takeover-backup' $holder $ref $sha "taken by $Session for lease $leaseId"
  Write-Journal @{ event = 'lease-takeover'; resource = "slot:${repoName}:$slot"; ticket = $leaseId; holderSession = $holder; by = $Session; ref = $ref; sha = $sha; repo = $repoName }
  if ($holder -and $holder -ne "$Session") {
    # The same notice channel a holder already reads (any agentq call prints its notices).
    Add-LeaseNotice ([ordered]@{ repo = $repoName; slot = $slot; leaseId = $leaseId; purpose = "slot taken over by $Session"; branch = ''; session = $holder }) 'lease-takeover' "another session leased $repoName/$slot while your unsaved work was still in it; it was backed up BEFORE the reset" $ref
  }
  $who = if ($holder) { " (last holder: $holder)" } else { '' }
  $script:TakeoverNote = "agentq: this slot still held another session's unsaved work$who - it was backed up BEFORE the reset, nothing was discarded.`n  ref      $ref  ($sha)`n  see it   agentq recover -Repo $repoName -Slot $slot`n  restore  agentq recover -Repo $repoName -Ref $ref -To `"<path of YOUR slot>`" -Apply"
}
function Invoke-Recover {
  $repoName = $null
  if ($RepoArg) { $r = Get-RepoInfo $RepoArg; $repoName = if ($r) { $r.Name } else { (Split-Path -Leaf $RepoArg).ToLowerInvariant() } }
  elseif ($To) { $r = Get-RepoInfo $To; if ($r) { $repoName = $r.Name } }
  else { $r = Get-RepoInfo $null; if ($r) { $repoName = $r.Name } }
  if (-not $repoName) { throw 'agentq recover: pass -Repo <name|path> (or run it inside the repo)' }
  $main = Get-RepoMainFor $repoName
  if (-not $main) { throw "agentq recover: no clone found for '$repoName' under $(Split-Path -Parent (Get-WtRoot))" }
  $what = if ($Sha) { $Sha } elseif ($Ref) { $Ref } else { $null }
  if (-not $what) {
    $rows = @(Get-SlotBackups $repoName $Slot -Fetch)
    if ($Json) { @{ repo = $repoName; slot = $Slot; backups = $rows } | ConvertTo-Json -Depth 4; return }
    if (-not $rows.Count) { Write-Output "no backups for $repoName$(if ($Slot) { "/$Slot" }) - a reset is always preceded by one, so there is nothing to recover"; return }
    Write-Output "backups for $repoName$(if ($Slot) { "/$Slot" })$(if (-not $Slot) { ' (every slot)' }), newest first. A reset is always preceded by one of these - nothing here was discarded."
    foreach ($b in $rows) { Write-Output ("  {0,-58} {1,-9} {2,-25} {3,-8} {4}" -f $b.Ref, $b.Sha.Substring(0, 8), $b.At, $b.Kind, $b.Subject) }
    $h = @(Get-SlotHistory $repoName $Slot 12)
    if ($h.Count) {
      Write-Output "who was there (slot history - outlives the lease record):"
      foreach ($x in $h) {
        $rf = "$(P $x 'ref')"; if ($rf.Length -gt 44) { $rf = $rf.Substring(0, 44) }
        Write-Output ("  {0}  {1,-16} holder={2,-13} by={3,-13} {4}  {5}" -f (P $x 'ts'), (P $x 'event'), (P $x 'holder'), (P $x 'by'), $rf, (P $x 'why'))
      }
    }
    Write-Output "restore: agentq recover -Repo $repoName -Ref <ref|sha|slot/stamp> [-To <path of your own slot> -Apply]"
    return
  }
  $res = Resolve-BackupRef $repoName $what
  if (-not $res) { throw "agentq recover: '$what' is not a ref/sha in $repoName (agentq recover -Repo $repoName lists them)" }
  $subj = "$(& git -C $main log -1 --format=%s $($res.Sha) 2>$null)".Trim()
  $kind = if ($subj -like 'agentq backup *') { 'files' } else { 'commits' }
  $stat = @(& git -C $main show --stat --format='%h %s' $res.Sha 2>$null | ForEach-Object { "$_" })
  Write-Output "backup $($res.Sha.Substring(0, 8))  kind=$kind  $subj"
  $stat | Select-Object -First 25 | ForEach-Object { Write-Output "  $_" }
  if (-not $To) {
    Write-Output "nothing written. To restore into a slot YOU hold:"
    Write-Output "  agentq recover -Repo $repoName -Ref $($res.Sha) -To `"<path of your slot>`" -Apply"
    Write-Output "  (or by hand: git -C `"<slot>`" checkout $($res.Sha.Substring(0, 8)) -- .   # files |  git -C `"<slot>`" cherry-pick $($res.Sha.Substring(0, 8))   # commits)"
    return
  }
  $rt = Get-RepoInfo $To
  if (-not $rt) { throw "agentq recover: -To '$To' is not a git worktree" }
  if ((Norm-Dir $rt.Top) -eq (Norm-Dir (Get-MainTop $rt)) -and -not $Force) {
    throw "agentq recover: -To '$To' is the SHARED clone - restoring there mixes another session's draft into shared state. Restore into a leased slot (agentq lease -Purpose recover), or pass -Force."
  }
  $lease = Find-LeaseForPath $rt.Top
  if ($lease -and (P $lease 'session') -ne $Session -and -not $Force) {
    throw "agentq recover: '$To' is leased by $($lease.session) ('$($lease.purpose)') - do not write into another session's slot. Lease your own: agentq lease -Purpose recover"
  }
  if (-not $Apply) { Write-Output "dry run - nothing written. Re-run with -Apply to restore $($res.Sha.Substring(0, 8)) into $($rt.Top)"; return }
  if ($kind -eq 'commits') { Write-Output "the ref is a real commit (not a file snapshot): apply it with the strategy you want, e.g. git -C `"$($rt.Top)`" cherry-pick $($res.Sha)"; return }
  $before = @(& git -C $rt.Top status --porcelain 2>$null | Where-Object { $_ }).Count
  $cio = @(& git -C $rt.Top checkout $res.Sha -- . 2>&1 | ForEach-Object { "$_" })
  if ($LASTEXITCODE) { throw "agentq recover: checkout $($res.Sha.Substring(0, 8)) into $($rt.Top) failed: $($cio -join ' | ')" }
  $after = @(& git -C $rt.Top status --porcelain 2>$null | Where-Object { $_ })
  Write-Output "recovered $($res.Sha.Substring(0, 8)) into $($rt.Top): $($after.Count) changed path(s) (was $before). Review: git -C `"$($rt.Top)`" status"
  Write-Journal @{ event = 'recover'; resource = "slot:${repoName}:$(Split-Path $rt.Top -Leaf)"; ref = $res.Ref; sha = $res.Sha; repo = $repoName; by = $Session }
}

function Invoke-Sweep {
  $n = 0; $kept = 0
  foreach ($l in Read-Leases $null) {
    if (-not $l.stale) {
      # AUDITABLE "why not stale" (idea 3): a lease past its threshold that a chat grace or -Hold keeps is
      # exactly the case that made `sweep: expired=0` opaque (2026-11-19: 17 leases, 0 stale, several idle
      # 5-7 h because a bound chat was fresh). One journal line per such lease, keyed to the sweep.
      if ($l.idleMin -gt (P $l 'thresholdMin' 0)) {
        Write-Journal @{ event = 'lease-kept'; resource = "slot:$($l.repo):$($l.slot)"; ticket = (P $l 'leaseId'); idleMin = $l.idleMin; thresholdMin = (P $l 'thresholdMin' 0); chatIdleMin = (P $l 'chatIdleMin' $null); graceMin = (P $l 'graceMin' 0); held = [bool](P $l 'held' $false); why = "$(P $l 'why' '')"; repo = $l.repo }
      }
      continue
    }
    if (Expire-Lease $l "stale (idle $($l.idleMin) min, owner alive=$($l.alive))") { $n++; Write-Output "expired $($l.repo)/$($l.slot) ($($l.session) '$($l.purpose)')" }
    else { $kept++; Write-Output "KEPT $($l.repo)/$($l.slot): backup failed (journal: lease-expire-failed)" }
  }
  [void](Read-Releases $null)   # side effect: dead runs are recorded as failed
  # OQ-007: `status` no longer reaps; dead tickets of resources nobody queues on are reaped here.
  $reaped = 0
  foreach ($qd in @(Get-ChildItem $QDir -Directory -ErrorAction SilentlyContinue)) {
    foreach ($tf in @(Get-ChildItem -LiteralPath $qd.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'adaptive.json', 'burst.json' })) {
      try {
        $t = Get-Content -LiteralPath $tf.FullName -Raw | ConvertFrom-Json -DateKind String
        if (-not (P $t 'resource' '') -or (Test-Alive $t)) { continue }
        $t | Add-Member -NotePropertyName file -NotePropertyValue $tf.FullName -Force
        Remove-Ticket $t "holder pid $($t.pid) is gone"; $reaped++
      } catch {}
    }
  }
  try { Invoke-RotateJournal } catch { Write-Output "rotate skipped: $_" }
  # OQ-006: prune state nobody needs (agents, jobs, notices, releases, idle queue folders).
  $pruned = 0
  if ($env:AGENTQ_NO_PRUNE -ne '1') {
    try { . (Join-Path $PSScriptRoot 'agentq-prune.ps1'); $pr = Invoke-Prune -Quiet; if ($pr -and $pr.ContainsKey('total')) { $pruned = [int]$pr.total } } catch { Write-Output "prune skipped: $_" }
  }
  Write-Output "sweep: expired=$n kept=$kept reaped=$reaped pruned=$pruned"
}

# `agentq who [<repo>]` (ADR 0012): one line per lease answering "is this slot really in use?" - who holds
# it, for what, how long the SLOT has been idle (the work clock) and whether the next sweep takes it.
# Read-only: it never expires or renews anything, so it is safe to run from any session.
function Invoke-Who {
  $only = $null
  if ($RepoArg) { $r = Get-RepoInfo $RepoArg; if ($r) { $only = $r.Name } }
  $rows = @(Read-Leases $only | Sort-Object -Property idleMin -Descending)
  if (-not $rows.Count) { Write-Output $(if ($only) { "no leases in $only" } else { 'no leases' }); return }
  # filters (idea 5): --stale-only for triage, --idle-hours N for "what has been idle at least N hours".
  if ($StaleOnly) { $rows = @($rows | Where-Object { $_.stale }) }
  if ($IdleHours -gt 0) { $rows = @($rows | Where-Object { $_.idleMin -ge ([double]$IdleHours * 60) }) }
  if (-not $rows.Count) { if ($Json) { @{ leases = @() } | ConvertTo-Json -Depth 4 } else { Write-Output "no leases match the filter$(if ($only) { " in $only" })" }; return }
  # NOT $json: PowerShell variable names are case-insensitive, so a local $json would shadow the -Json
  # flag ($Json) and `who -Json` would silently print the table (found by test-agentq-lease-liveness.ps1).
  $jsonRows = @()
  foreach ($l in $rows) {
    $purp = "$(P $l 'purpose' '')"; if ($purp.Length -gt 46) { $purp = $purp.Substring(0, 46) }
    # why the next sweep takes it or not (idea 4): held | recent work | chat grace | stale.
    $row = [ordered]@{ repo = $l.repo; slot = $l.slot; role = (P $l 'role' ''); session = (P $l 'session' ''); idleMin = $l.idleMin; chatIdleMin = (P $l 'chatIdleMin' $null); alive = [bool]$l.alive; stale = [bool]$l.stale; why = "$(P $l 'why' '')"; purpose = "$(P $l 'purpose' '')"; path = (P $l 'path' '') }
    if ($Json) { $jsonRows += $row; continue }
    Write-Output ("{0,-10} {1,-10} {2,-8} {3,-13} idle {4,7}m  chat {5,7}  alive {6,-5} {7,-5} why={8,-12} {9}" -f `
        $l.repo, $l.slot, (P $l 'role' ''), (P $l 'session' ''), $l.idleMin, $(if ($null -ne (P $l 'chatIdleMin' $null)) { (P $l 'chatIdleMin') } else { '-' }), [bool]$l.alive, $(if ($l.stale) { 'STALE' } else { '' }), "$(P $l 'why' '')", $purp)
  }
  if ($Json) { @{ leases = $jsonRows } | ConvertTo-Json -Depth 4 }
  else {
    $stale = @($rows | Where-Object stale).Count
    Write-Output ""
    Write-Output "total $($rows.Count) lease(s), $stale stale (the next sweep backs them up and takes them). idle = work clock: minutes since anyone touched that SLOT (a tool call naming it, an agentq call for its repo, or git activity in it)."
  }
}

# For scripts and guards: exit 3 + holder when -Path is (inside, or a parent of) a leased slot.
function Invoke-LeaseCheck {
  $l = Find-LeaseForPath $WtPath
  if ($l) { Write-Output "LEASED $($l.repo)/$($l.slot) by $($l.session) ($($l.leaseId)) '$($l.purpose)' idle $($l.idleMin)m stale=$($l.stale)"; exit 3 }
  Write-Output 'FREE'; exit 0
}

# Back up an arbitrary worktree (migration of legacy, non-standard trees). Prints the ref or ''.
function Invoke-Backup {
  if (-not $WtPath) { throw 'agentq backup -Path <worktree> [-Slot <name>] -Reason "..."' }
  $l = Find-LeaseForPath $WtPath
  if ($l) { [Console]::Error.WriteLine("agentq: $WtPath is leased by $($l.session) ($($l.leaseId)) - refusing"); exit 3 }
  $ri = Get-RepoInfo $WtPath
  if (-not $ri) { throw "agentq backup: $WtPath is not a git worktree" }
  $name = if ($Slot) { $Slot } else { Split-Path $WtPath -Leaf }
  Write-Output (Backup-Slot $WtPath $ri.Name $name $(if ($Reason) { $Reason } else { 'manual backup' }))
}

# ---- release runs -------------------------------------------------------------------------
function Get-ReleaseFile([string]$repoName, [string]$target) { Join-Path $RDir "$(Safe $repoName)__$(Safe $target.ToLowerInvariant()).json" }
function Read-Releases([string]$repoName) {
  $out = @()
  foreach ($f in Get-ChildItem $RDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
    if ($repoName -and -not $f.Name.StartsWith("$(Safe $repoName)__")) { continue }
    $r = Read-JsonFile $f.FullName
    if (-not $r -or $r -eq 'UNREADABLE') { continue }
    $alive = Test-Alive ([pscustomobject]@{ pid = [int](P $r 'pid' 0); procStart = (P $r 'procStart' $null) })
    if (-not $alive -and (P $r 'state') -in 'running', 'preempting') {
      # The release process died without release-end: record it as failed (never auto-restarted).
      $r.state = 'failed'; $r | Add-Member -NotePropertyName endedReason -NotePropertyValue 'process died' -Force
      # A read-only verb (status) reports it as failed without recording it; sweep and working verbs record.
      if (-not $script:ReadOnly) {
        Write-JsonAtomic $f.FullName $r
        Write-Journal @{ event = 'release-dead'; resource = "deploy:$($r.repo):$($r.target)"; sha = $r.sha; reason = 'release process died'; repo = $r.repo }
      }
    }
    $r | Add-Member -NotePropertyName file -NotePropertyValue $f.FullName -Force
    $r | Add-Member -NotePropertyName alive -NotePropertyValue $alive -Force
    $out += $r
  }
  $out
}
function Get-ReleaseRecord {
  $f = $null
  if ($env:AGENTQ_RELEASE_FILE -and (Test-Path -LiteralPath $env:AGENTQ_RELEASE_FILE)) { $f = $env:AGENTQ_RELEASE_FILE }
  elseif ($Target) { $ri = Get-RepoInfo $RepoArg; if ($ri) { $c = Get-ReleaseFile $ri.Name $Target; if (Test-Path -LiteralPath $c) { $f = $c } } }
  if (-not $f) { return $null }
  $r = Read-JsonFile $f
  if (-not $r -or $r -eq 'UNREADABLE') { return $null }
  $r | Add-Member -NotePropertyName file -NotePropertyValue $f -Force -PassThru
}
function Save-Release($r) { Write-JsonAtomic $r.file ($r | Select-Object * -ExcludeProperty file, alive) }

function Invoke-ReleaseBegin {
  $repo = Get-RepoInfo $RepoArg
  if (-not $repo -or -not $Target -or -not $Sha) { throw 'agentq release-begin -Repo <r> -Target <t> -Sha <sha> [-Ref r] [-Follow branch] [-OwnerPid n]' }
  $f = Get-ReleaseFile $repo.Name $Target
  $owner = Get-DefaultOwner
  $script:rbOut = $null
  With-Mutex "release-$($repo.Name)-$Target" {
    $cur = (Read-Releases $repo.Name | Where-Object { $_.file -eq $f } | Select-Object -First 1)
    if ($cur -and $cur.alive -and (P $cur 'state') -in 'running', 'preempting') { [Console]::Error.WriteLine("agentq: release $($repo.Name)/$Target already running: $($cur.runId) @ $($cur.sha)"); exit 3 }
    $st = Get-ProcStart $owner
    $r = [ordered]@{
      runId = $(if ($RunId) { $RunId } else { [guid]::NewGuid().ToString('N').Substring(0, 8) }); repo = $repo.Name; target = $Target.ToLowerInvariant()
      sha = $Sha; ref = "$Ref"; follow = "$Follow"; phase = 'prepare'; preemptible = $true; committed = $false; phaseAt = (Iso (Now))
      state = 'running'; supersedeSha = ''; pendingSha = ''; session = $Session; pid = $owner; procStart = $(if ($st) { Iso $st } else { $null }); started = (Iso (Now)); purpose = "$Purpose"
    }
    Write-JsonAtomic $f $r
    Write-Journal @{ event = 'release-begin'; resource = "deploy:$($repo.Name):$($r.target)"; sha = $Sha; ticket = $r.runId; purpose = "$Purpose"; branch = "$Follow"; repo = $repo.Name }
    $script:rbOut = $f
  }
  Write-Output $script:rbOut
}

# Checkpoint. Exit 0 = continue; exit 4 = SUPERSEDED: stop NOW, without further side effects.
# No-op (exit 0) outside a release run, so release scripts also work standalone.
function Invoke-ReleasePhase {
  $r = Get-ReleaseRecord
  if (-not $r) { exit 0 }
  if (-not $Phase) { throw 'agentq release-phase -Phase <name> [-Unsafe]' }
  $script:phaseCode = 0
  With-Mutex "release-$($r.repo)-$($r.target)" {
    $x = Read-JsonFile $r.file | Add-Member -NotePropertyName file -NotePropertyValue $r.file -Force -PassThru
    if ($x.state -eq 'preempting' -and -not $x.committed) {
      $x.state = 'superseded'; $x.phase = "stopped-before:$Phase"; $x.phaseAt = (Iso (Now))
      Save-Release $x
      Write-Journal @{ event = 'release-superseded'; resource = "deploy:$($x.repo):$($x.target)"; sha = $x.sha; reason = "superseded by $($x.supersedeSha) before phase $Phase"; repo = $x.repo }
      [Console]::Error.WriteLine("agentq: release $($x.runId) @ $(Short $x.sha 12) SUPERSEDED by $($x.supersedeSha) - stopping before '$Phase'")
      $script:phaseCode = 4
      return
    }
    if ($x.state -eq 'superseded') { $script:phaseCode = 4; return }
    $x.phase = $Phase; $x.phaseAt = (Iso (Now))
    if ($Unsafe) { $x.committed = $true }
    $x.preemptible = -not $x.committed
    Save-Release $x
    Write-Journal @{ event = 'release-phase'; resource = "deploy:$($x.repo):$($x.target)"; sha = $x.sha; state = $Phase; reason = $(if ($Unsafe) { 'unsafe' } else { 'safe' }); repo = $x.repo }
  }
  exit $script:phaseCode
}

# Ends a run; prints {state, next} - next = sha to release next (supersede tip / pending), or ''.
function Invoke-ReleaseEnd {
  $r = Get-ReleaseRecord
  if (-not $r) { Write-Output '{}'; return }
  if (-not $State) { throw 'agentq release-end -State done|failed|superseded' }
  $script:reOut = $null
  With-Mutex "release-$($r.repo)-$($r.target)" {
    $x = Read-JsonFile $r.file | Add-Member -NotePropertyName file -NotePropertyValue $r.file -Force -PassThru
    if ($x.state -ne 'superseded') { $x.state = $(if ($State -eq 'superseded' -and $x.committed) { 'failed' } else { $State }) }
    $x.phaseAt = (Iso (Now))
    # The run's exit code, recorded SEPARATELY from `phase`. `phase` is the last checkpoint the run
    # ENTERED (release-phase); it is never an attribution of which step failed, and an exit code cannot
    # honestly be mapped onto a phase: the failure happens somewhere in the wrapped command, which may
    # be inside, after, or entirely outside any named checkpoint. 2026-11-21: a release exited 1 (its
    # post-deploy gate returned `incomplete`) while `phase` still read `github`, and `phase=github` was
    # read as "the GitHub step failed". Additive field; old readers ignore it, the display shows it as
    # `exit=<n>` next to `last-phase=<p>`.
    if ($null -ne $Code) { $x | Add-Member -NotePropertyName exitCode -NotePropertyValue ([int]$Code) -Force }
    $next = switch ($x.state) { 'superseded' { $x.supersedeSha } 'done' { $x.pendingSha } default { '' } }
    if ($next -eq 'cancel') { $next = '' }
    Save-Release $x
    Write-Journal @{ event = 'release-end'; resource = "deploy:$($x.repo):$($x.target)"; sha = $x.sha; state = $x.state; reason = "next=$next"; repo = $x.repo }
    $script:reOut = [pscustomobject]@{ runId = $x.runId; state = $x.state; next = $next; follow = $x.follow } | ConvertTo-Json -Compress
  }
  Write-Output $script:reOut
}

# A landing (sha now on origin/<branch>) during a running release of that branch: preempt if the run
# has not crossed an unsafe phase, else coalesce into ONE pending run at the newest tip.
# -OnlyTarget restricts to one target (deploy-clean coalescing). Returns 'target:action' strings.
function Notify-Landing([string]$repoName, [string]$branch, [string]$sha, [string]$onlyTarget) {
  $script:notifyActs = @()
  foreach ($r in Read-Releases $repoName) {
    if (-not $r.alive -or (P $r 'state') -notin 'running', 'preempting') { continue }
    if ($onlyTarget -and $r.target -ne $onlyTarget.ToLowerInvariant()) { continue }
    if ((P $r 'follow') -ne $branch -or $r.sha -eq $sha) { continue }
    With-Mutex "release-$($r.repo)-$($r.target)" {
      $x = Read-JsonFile $r.file | Add-Member -NotePropertyName file -NotePropertyValue $r.file -Force -PassThru
      if ($x.state -notin 'running', 'preempting') { return }
      if ($x.committed) { $x.pendingSha = $sha; $act = 'pending' } else { $x.state = 'preempting'; $x.supersedeSha = $sha; $act = 'preempt' }
      Save-Release $x
      Write-Journal @{ event = "release-$act"; resource = "deploy:$($x.repo):$($x.target)"; sha = $sha; reason = "landing on $branch during run $($x.runId) @ $(Short $x.sha 12) phase $($x.phase)"; repo = $x.repo }
      $script:notifyActs += "$($x.target):$act"
    }
  }
  $script:notifyActs
}
function Invoke-NotifyLanding {
  $repo = Get-RepoInfo $RepoArg
  if (-not $repo -or -not $Branch) { throw 'agentq notify-landing -Repo <r> -Branch <b> [-Sha <sha>] [-Target <t>]' }
  $s = if ($Sha) { $Sha } else { "$(& git -C $repo.Top rev-parse "origin/$Branch")".Trim() }
  $acts = @(Notify-Landing $repo.Name $Branch $s $Target)
  if ($Json) { @{ sha = $s; actions = $acts } | ConvertTo-Json -Compress; return }
  Write-Output "notify-landing $($repo.Name) $Branch @ $(Short $s 12): $(if ($acts) { $acts -join ', ' } else { 'no running release follows it' })"
  if ($Target -and -not $acts) { exit 1 }
}
function Invoke-ReleaseCancel {
  $repo = Get-RepoInfo $RepoArg
  if (-not $repo -or -not $Target -or -not $Reason) { throw 'agentq release-cancel -Target <t> -Reason "..."' }
  $f = Get-ReleaseFile $repo.Name $Target
  $script:rcCode = 0
  With-Mutex "release-$($repo.Name)-$Target" {
    $r = Read-JsonFile $f
    if (-not $r -or $r -eq 'UNREADABLE' -or $r.state -ne 'running') { Write-Output "no running release $($repo.Name)/$Target"; return }
    if ($r.committed) { [Console]::Error.WriteLine("agentq: release $($r.runId) is past an unsafe phase ($($r.phase)); it cannot be preempted. Freeze deploy:$($repo.Name):$Target to stop the NEXT run."); $script:rcCode = 3; return }
    $r.state = 'preempting'; $r.supersedeSha = 'cancel'
    Write-JsonAtomic $f $r
    Write-Journal @{ event = 'release-cancel'; resource = "deploy:$($repo.Name):$Target"; sha = $r.sha; reason = $Reason; repo = $repo.Name }
    Write-Output "release $($r.runId) will stop at its next checkpoint"
  }
  exit $script:rcCode
}

# ---- landing queue ------------------------------------------------------------------------
# Union-merge one conflicted path IN BYTES: git writes the three stages to files and merges them in
# place; nothing is decoded by PowerShell. The old resolver piped `git show :N:path` through the
# pipeline (native output decoded with the console code page, CP437 under pwsh) and re-wrote it as
# UTF-8, so every non-ASCII byte became 2-3 bytes on each land - brivio's CHANGELOG went 24 -> 124 MB
# and GitHub refused the push (GH001, 2026-10-15). Order: ours (onto) then theirs (the pick).
function Merge-UnionBytes([string]$wt, [string]$p) {
  $line = "$(& git -C $wt checkout-index --stage=all --temp -- $p 2>$null)".Trim()
  if ($LASTEXITCODE -or -not $line) { return $false }
  $names = ($line -split "`t")[0] -split ' '
  if ($names.Count -lt 3) { return $false }
  $tmps = @($names | Where-Object { $_ -ne '.' } | ForEach-Object { Join-Path $wt $_ })
  try {
    if ($names[1] -eq '.' -or $names[2] -eq '.') { return $false }   # delete/modify: not a union case
    $base = if ($names[0] -eq '.') { $e = Join-Path $wt ('.aq-empty-' + [guid]::NewGuid().ToString('N')); [IO.File]::WriteAllBytes($e, [byte[]]@()); $tmps += $e; $e } else { Join-Path $wt $names[0] }
    $ours = Join-Path $wt $names[1]; $theirs = Join-Path $wt $names[2]
    & git -C $wt merge-file --union $ours $base $theirs 2>$null | Out-Null
    if ($LASTEXITCODE) { return $false }   # --union never leaves conflicts; non-zero = error
    Copy-Item -LiteralPath $ours -Destination (Join-Path $wt $p) -Force
    & git -C $wt add -- $p
    return (-not $LASTEXITCODE)
  } finally { foreach ($x in $tmps) { Remove-Item -LiteralPath $x -Force -ErrorAction SilentlyContinue } }
}

# A CHANGELOG blob that grows past 1.5x its size on origin is a resolver bug, never a real entry
# (a real one adds KBs to a 24 MB file). Returns 'path: old -> new' strings for offenders.
function Get-OversizedChangelogs([string]$wt, [string]$baseRef, [double]$factor = 1.5, [int]$floorBytes = 4096) {
  $out = @()
  foreach ($p in @(& git -C $wt diff --name-only $baseRef HEAD 2>$null | Where-Object { $_ -match '(^|/)CHANGELOG\.md$' })) {
    $old = "$(& git -C $wt cat-file -s "${baseRef}:$p" 2>$null)".Trim()
    if ($LASTEXITCODE -or -not $old) { continue }   # new file: nothing to compare against
    $new = "$(& git -C $wt cat-file -s "HEAD:$p" 2>$null)".Trim()
    if ($LASTEXITCODE -or -not $new) { continue }   # deleted
    # The factor alone is calibrated for the multi-MB root CHANGELOG. Small per-package changelogs
    # (200-300 bytes) exceed 1.5x on every legitimate release entry, so the allowance is the LARGER of
    # the factor and a fixed floor: a resolver duplicating a small file still blows past both
    # (github 2026-11-17: five kit packages of ~200 bytes could not land a one-line entry).
    $limit = [Math]::Max($factor * [double]$old, [double]$old + $floorBytes)
    if ([double]$new -gt $limit) { $out += "${p}: $old -> $new bytes" }
  }
  $out
}
# ADR 0003 W2-3: a push refused by the pre-push hook ONLY because of machine load (vitest worker start
# timeouts, hook timeouts, EBUSY/EPERM on Windows temp files) is retried once; the journal records it
# as a flake. Real failures (assertions, type errors, lint) never match these patterns.
$InfraFlakePatterns = @(
  'Failed to start (forks|threads) worker', 'Timeout starting (forks|threads) runner', 'Hook timed out in \d+ms',
  'Test timed out in \d+ms', 'EBUSY: resource busy or locked', 'EPERM: operation not permitted, (rename|unlink|open)',
  'ENOTEMPTY: directory not empty, rmdir .*vitest', 'spawn .* ENOMEM', 'JavaScript heap out of memory', 'Worker exited unexpectedly'
)
function Test-InfraFlake([string[]]$out) {
  $txt = $out -join "`n"
  if ($txt -match '(AssertionError|error TS\d+|✗ .*lint|Expected .* to (be|equal))') { return $null }
  foreach ($p in $InfraFlakePatterns) { if ($txt -match $p) { return $Matches[0] } }
  $null
}
# ADR 0003 W2-3 flake ledger (agentq-flakes.mjs, <AGENTQ_HOME>/flakes/<repo>.json): every pre-push
# failure in land is recorded per tree hash; a test that failed and then passed on the same tree is
# quarantined (14 d). A push whose only failures are quarantined tests is retried once and, if the
# retry fails the same way, pushed with --no-verify (journal 'flake-quarantined'). AGENTQ_NO_FLAKES=1 off.
$LandRaceRe = 'non-fast-forward|fetch first|Updates were rejected|cannot lock ref .* but expected'
function Invoke-Flakes([string]$repoName, [string[]]$argv) {
  if ($env:AGENTQ_NO_FLAKES) { return $null }
  $ledger = Join-Path (Join-Path $Root 'flakes') "$repoName.json"
  try {
    $j = @(& node (Join-Path $PSScriptRoot 'agentq-flakes.mjs') @argv --ledger $ledger 2>$null)
    if ($LASTEXITCODE -or -not $j) { return $null }
    $j[-1] | ConvertFrom-Json
  } catch { $null }
}
function Record-Flakes([string]$repoName, [string]$wt, [string[]]$out, [int]$attempt) {
  $tree = "$(& git -C $wt rev-parse 'HEAD^{tree}' 2>$null)".Trim()
  if (-not $tree) { return $null }
  $log = Join-Path ([IO.Path]::GetTempPath()) ("aq-flk-" + [guid]::NewGuid().ToString('N') + '.log')
  try { [IO.File]::WriteAllLines($log, [string[]]$out); Invoke-Flakes $repoName @('record', '--tree', $tree, '--log', $log, '--attempt', "$attempt") }
  finally { Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue }
}
function Pass-Flakes([string]$repoName, [string]$wt) {
  $tree = "$(& git -C $wt rev-parse 'HEAD^{tree}' 2>$null)".Trim()
  if (-not $tree) { return }
  $r = Invoke-Flakes $repoName @('pass', '--tree', $tree)
  if ($r -and @($r.flipped).Count) { Write-Journal @{ event = 'flake-flip'; resource = "land:$repoName"; paths = @($r.flipped); reason = "failed then passed on tree $(Short $tree)"; repo = $repoName } }
}
function Invoke-FlakesVerb {
  $repo = Get-RepoInfo $RepoArg
  if (-not $repo) { throw 'agentq flakes: not in a git repo (or pass -Repo <path>)' }
  if ($Id) {
    if (-not $Reason) { throw 'agentq flakes -Id <test key or substring> -Reason "why" lifts a quarantine' }
    $r = Invoke-Flakes $repo.Name @('clear', '--test', $Id)
    Write-Journal @{ event = 'flake-clear'; resource = "land:$($repo.Name)"; paths = @($r.cleared); reason = $Reason; repo = $repo.Name }
    Write-Output "flakes: lifted $(@($r.cleared).Count) quarantine(s)"; @($r.cleared) | ForEach-Object { Write-Output "  $_" }; return
  }
  $r = Invoke-Flakes $repo.Name @('list')
  if ($Json) { $r | ConvertTo-Json -Depth 5; return }
  Write-Output "== quarantined tests ($($repo.Name)) - they still run; a land fails only on other failures"
  if (-not $r -or -not @($r.quarantined).Count) { Write-Output '  (none)' }
  foreach ($q in @($r.quarantined)) { Write-Output ("  {0}  flips={1} until={2}  ({3})" -f $q.test, $q.flips, "$($q.until)".Substring(0, 10), $q.reason) }
  Write-Output '== recent land trees'
  foreach ($t in @($r.trees) | Select-Object -First 10) { Write-Output ("  {0} {1} green={2} attempts={3} lastFailed={4}" -f "$($t.ts)".Substring(0, 16), (Short $t.tree), $t.green, $t.attempts, $t.lastFailed) }
}
# ---- land batching (ADR 0003 W2-5) ----------------------------------------------------------------
# Opt-in per repo (config landBatch { repo: true }; defaults codai + brivio; AGENTQ_LAND_BATCH=0 off).
# The land holder absorbs up to landBatchMax-1 waiting land tickets for the same -Onto and the same
# -Gate whose topic merges cleanly onto origin/<onto> (merge-tree, no working tree), picks all topics
# in queue order, runs ONE gate and ONE push. A failed batch (gate 6, push 7, oversize 8, finalize 9)
# is bisected: each half is rebuilt on the then-current tip and gated again, so a half that passes is
# accepted (optimistic) and only the culprit fails. A topic that conflicts with an earlier topic of
# the batch is dropped back to the queue and lands on its own turn. Absorbed waiters learn their
# result from <AGENTQ_HOME>/batches/<repo>/<ticket>.json while still in Wait-Turn. Batch size drops to
# 2 when more than 30 % of the last 10 batches of the repo needed a bisection.
function Get-LandBatchOn([string]$repoName) {
  if ($env:AGENTQ_LAND_BATCH -eq '0') { return $false }
  $c = Get-Config
  $b = if ($c.ContainsKey('landBatch')) { $c['landBatch'] } else { @{ codai = $true; brivio = $true } }
  [bool]($b -is [System.Collections.IDictionary] -and $b.Contains($repoName) -and $b[$repoName])
}
function Get-LandBatchSize([string]$repoName) {
  $c = Get-Config
  $max = if ($c.ContainsKey('landBatchMax')) { [int]$c.landBatchMax } else { 4 }
  $max = [math]::Max(2, [math]::Min(4, $max))
  $recent = @(Get-Content -LiteralPath (Get-JournalFor @{ repo = $repoName }) -Tail 4000 -ErrorAction SilentlyContinue | Where-Object { $_ -like '*"land-batch"*' } |
      ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ -and $_.event -eq 'land-batch' -and "$($_.repo)" -eq $repoName } | Select-Object -Last 10)
  if ($recent.Count -ge 4 -and (@($recent | Where-Object { $_.bisected }).Count / $recent.Count) -gt 0.3) { return 2 }
  $max
}
function Resolve-LandRef([string]$main, [string]$b) {
  if ((& git -C $main rev-parse --verify -q "refs/heads/$b" 2>$null)) { return "refs/heads/$b" }
  if ((& git -C $main rev-parse --verify -q "refs/remotes/origin/$b" 2>$null)) { return "refs/remotes/origin/$b" }
  $null
}
# The land slot is rebased and the topic merged onto it, but its node_modules are whatever the previous
# land left: when the merged result changes a lockfile the slot's deps are stale, and only the pre-push
# typecheck notices, with type errors that look like code errors (brivio 2026-11-18/19, CS-56: stripe
# 23.0.0 in the slot vs 23.1.0 in the branch -> TS2322 on the ApiVersion literal; the land gate does not
# typecheck, so it ran 103/103 green). Install the merged lockfile in the land slot before the gate.
# AGENTQ_NO_LAND_INSTALL=1 opts out (journaled), like the other land escapes.
function Restore-LandDeps([object]$repo, [string]$wt, [string]$baseRev) {
  if ($env:AGENTQ_NO_LAND_INSTALL -eq '1' -or -not $baseRev) { return $true }
  $res = "land:$($repo.Name)"
  $locks = @(& git -C $wt diff --name-only "$baseRev" HEAD 2>$null | Where-Object { $_ -match '(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock)$' })
  if (-not $locks.Count) { return $true }
  $argv = if (@($locks | Where-Object { $_ -match '(^|/)pnpm-lock\.yaml$' }).Count) { @('pnpm', 'install', '--frozen-lockfile', '--prefer-offline') }
    elseif (@($locks | Where-Object { $_ -match '(^|/)package-lock\.json$' }).Count) { @('npm', 'ci') }
    else { @('yarn', 'install', '--immutable') }
  $cmd = $argv -join ' '
  [Console]::Out.WriteLine("land: lockfile changed ($($locks -join ', ')) - running '$cmd' in the land slot before the gate")
  Write-Journal @{ event = 'land-install'; resource = $res; reason = "$cmd ($($locks -join ', '))"; repo = $repo.Name }
  $exe = $argv[0]; $rest = @($argv | Select-Object -Skip 1)
  $sw = [Diagnostics.Stopwatch]::StartNew(); $code = 0; $out = @()
  Push-Location -LiteralPath $wt
  try { $out = @(& $exe @rest 2>&1 | ForEach-Object { "$_" }); $code = [int]$LASTEXITCODE } finally { Pop-Location }
  $sec = [int][math]::Round($sw.Elapsed.TotalSeconds)
  if ($code) {
    $tail = (@($out | Select-Object -Last 8) -join ' | ')
    Write-Journal @{ event = 'land-install-failed'; resource = $res; exit = $code; durSec = $sec; reason = $tail.Substring(0, [math]::Min(500, $tail.Length)); repo = $repo.Name }
    [Console]::Error.WriteLine("land: '$cmd' failed ($code) in the land slot - nothing gated, nothing pushed. Fix the lockfile on the topic and land again (AGENTQ_NO_LAND_INSTALL=1 skips this).")
    $out | Select-Object -Last 8 | ForEach-Object { [Console]::Error.WriteLine("  install: $_") }
    return $false
  }
  Write-Journal @{ event = 'land-install-ok'; resource = $res; durSec = $sec; reason = $cmd; repo = $repo.Name }
  return $true
}
# ---- green trees + land pre-gate (ADR 0009 stage 0, OQ-002 / OQ-003) -------------------------------
# Baseline, busiest repo, 7 days: the land ticket was HELD 80.8 h, 41.8 h of it running the land gate
# (p50 7.2 min), 12.8 h in the 45 gate runs that then failed - every one of them made the whole queue
# wait. Two changes:
#  * Green ledger (<AGENTQ_HOME>/green/<repo>.json): a tree that passed a gate command is remembered by
#    (tree hash, gate command) for greenTtlHours (168). The in-queue gate is skipped for such a tree
#    (journal `land-gate-skipped-green`). The key is the exact tree, so a land whose result differs by
#    one byte runs the gate as before.
#  * Pre-gate: `agentq land` run from a leased task slot first builds the REBASED result (merge-tree of
#    the topic onto the current origin/<onto>, no working tree involved), puts it in the slot (a
#    temporary detached checkout of a local, never-pushed merge commit; the slot's branch and HEAD are
#    restored afterwards), runs the gate there through run-build and records the tree as green. Only
#    then is the land ticket taken. A failing gate ends the land with exit 6 BEFORE the queue
#    (`land-pregate-failed`). When origin moved while the gate ran, one more round is tried
#    (landPregateRounds, default 2); after that the land queues anyway and the in-queue gate decides.
#    Skipped, with the reason journaled (`land-pregate-skipped`), when: not run from a leased task slot,
#    the slot has uncommitted or untracked files, the merge needs the land resolver, or a lockfile
#    differs between the slot and the rebased result (its node_modules would be stale).
#    Config `landPregate`: true | false | { <repo>: bool } (default true); AGENTQ_LAND_NO_PREGATE=1 off.
# The gate runs in a different directory (the slot) than the in-queue gate did (the land slot); the
# repo's pre-push hook still runs at the push, in the land slot, as before.
function Get-GateKey([string]$tree, [string]$gate) {
  $h = [BitConverter]::ToString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes("$gate"))).Replace('-', '').Substring(0, 12).ToLowerInvariant()
  "$tree|$h"
}
function Get-GreenFile([string]$repoName) { Join-Path (Join-Path $Root 'green') ((Safe $repoName) + '.json') }
function Test-GreenTree([string]$repoName, [string]$tree, [string]$gate) {
  if (-not $tree -or -not $gate -or $env:AGENTQ_NO_GREEN -eq '1') { return $null }
  try {
    $f = Get-GreenFile $repoName
    if (-not [IO.File]::Exists($f)) { return $null }
    $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json -AsHashtable -DateKind String
    $k = Get-GateKey $tree $gate
    if (-not $j -or -not $j.ContainsKey($k)) { return $null }
    $e = $j[$k]
    $c = Get-Config
    $ttl = if ($c.ContainsKey('greenTtlHours')) { [double]$c['greenTtlHours'] } else { 168.0 }
    if (((Now) - (ParseUtc $e['at'])).TotalHours -gt $ttl) { return $null }
    $e
  } catch { $null }
}
function Set-GreenTree([string]$repoName, [string]$tree, [string]$gate, [int]$sec, [string]$where) {
  if (-not $tree -or -not $gate -or $env:AGENTQ_NO_GREEN -eq '1') { return }
  try {
    With-Mutex "green-$repoName" {
      $f = Get-GreenFile $repoName
      $j = @{}
      if ([IO.File]::Exists($f)) { try { $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json -AsHashtable -DateKind String } catch { $j = @{} } }
      if (-not $j) { $j = @{} }
      $j[(Get-GateKey $tree $gate)] = [ordered]@{ at = (Iso (Now)); sec = $sec; where = $where; by = $Session; gate = "$gate" }
      # keep the 300 newest (ISO strings sort by time)
      if ($j.Count -gt 300) { foreach ($old in @($j.Keys | Sort-Object { "$($j[$_]['at'])" } | Select-Object -First ($j.Count - 300))) { $j.Remove($old) } }
      Write-JsonAtomic $f $j
    }
  } catch {}
}
function Get-LandPregateOn([string]$repoName) {
  if ($env:AGENTQ_LAND_NO_PREGATE -eq '1') { return $false }
  $c = Get-Config
  if (-not $c.ContainsKey('landPregate')) { return $true }
  $v = $c['landPregate']
  if ($v -is [Collections.IDictionary]) { if ($v.Contains($repoName)) { return [bool]$v[$repoName] }; return $true }
  [bool]$v
}
# Runs the land gate through run-build in $dir. Sets $script:GateExit / $script:GateSec; output flows on.
function Invoke-GateRun([string]$dir, [string]$purpose) {
  $rb = if ($env:AGENTQ_RUN_BUILD) { $env:AGENTQ_RUN_BUILD } else { Join-Path $env:USERPROFILE '.copilot\hooks\run-build.ps1' }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  & pwsh -NoProfile -File $rb -Root $dir -Wait -TimeoutMin 120 -Purpose $purpose -Command $Gate
  $script:GateExit = [int]$LASTEXITCODE
  $script:GateSec = [int][math]::Round($sw.Elapsed.TotalSeconds)
}
# Result in $script:PregateResult: ok | failed | skipped. Uses $Gate, $Onto, $Branch from Invoke-Land.
function Invoke-LandPregate($repo, [string]$main, [string]$topicRef) {
  $script:PregateResult = 'skipped'
  $res = "land:$($repo.Name)"
  if (-not (Get-LandPregateOn $repo.Name)) { return }
  $skip = {
    param([string]$why)
    Write-Journal @{ event = 'land-pregate-skipped'; resource = $res; branch = $Branch; reason = $why; repo = $repo.Name }
    Write-Output "land: pre-gate skipped ($why); the gate runs in the queue as before"
  }
  $cwdN = Norm-Dir (Get-Location).Path
  $slot = Read-Leases $repo.Name | Where-Object { $_.role -in 'task', 'pinned' -and -not $_.stale -and $cwdN.StartsWith((Norm-Dir "$(P $_ 'path')")) } | Select-Object -First 1
  if (-not $slot) { & $skip 'not run from a leased task slot'; return }
  $sp = "$(P $slot 'path')"
  $topicSha = "$(& git -C $main rev-parse --verify -q "$topicRef^{commit}" 2>$null)".Trim()
  if (-not $topicSha) { & $skip 'the topic does not resolve to a commit'; return }
  if (-not (Test-GitClean $sp)) { & $skip 'the slot has uncommitted or untracked files'; return }
  $c = Get-Config
  $rounds = if ($c.ContainsKey('landPregateRounds')) { [math]::Max(1, [int]$c['landPregateRounds']) } else { 2 }
  for ($round = 1; $round -le $rounds; $round++) {
    & git -C $main fetch -q origin $Onto 2>$null
    $tip = "$(& git -C $main rev-parse "origin/$Onto" 2>$null)".Trim()
    $mt = @(& git -C $main merge-tree --write-tree --no-messages "origin/$Onto" $topicSha 2>$null | ForEach-Object { "$_" })
    if ($LASTEXITCODE -or -not $mt.Count) { & $skip 'the merge onto the tip needs the land resolver'; return }
    $tree = $mt[0].Trim()
    if ($tree -eq "$(& git -C $main rev-parse "$tip^{tree}" 2>$null)".Trim()) { $script:PregateResult = 'ok'; return }   # nothing to land
    $green = Test-GreenTree $repo.Name $tree $Gate
    if ($green) {
      Write-Journal @{ event = 'land-pregate-ok'; resource = $res; branch = $Branch; tree = $tree; durSec = 0; cached = $true; reason = "tree $(Short $tree 12) already passed this gate at $($green['at'])"; repo = $repo.Name }
      Write-Output "land: pre-gate not needed - tree $(Short $tree 12) already passed '$Gate' ($($green['where']), $($green['at']))"
      $script:PregateResult = 'ok'; return
    }
    $head = "$(& git -C $sp rev-parse HEAD 2>$null)".Trim()
    $headTree = "$(& git -C $sp rev-parse 'HEAD^{tree}' 2>$null)".Trim()
    $branchNow = "$(& git -C $sp symbolic-ref -q --short HEAD 2>$null)".Trim()
    $moved = $false
    if ($headTree -ne $tree) {
      $locks = @(& git -C $sp diff --name-only $headTree $tree 2>$null | Where-Object { $_ -match '(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb?|Cargo\.lock|uv\.lock|poetry\.lock|gradle\.lockfile)$' })
      if ($locks.Count) { & $skip "a lockfile differs between the slot and the rebased result ($($locks -join ', ')): rebase the slot on origin/$Onto and install to get the pre-gate"; return }
      $m = "$(& git -C $sp -c user.name=agentq -c user.email=agentq@localhost commit-tree $tree -p $tip -p $topicSha -m "agentq pre-gate: $Branch onto $Onto (local only)" 2>$null)".Trim()
      if ($LASTEXITCODE -or -not $m) { & $skip 'could not build the rebased result'; return }
      & git -C $sp checkout -q --detach $m 2>$null
      if ($LASTEXITCODE) { & $skip 'could not check out the rebased result in the slot'; return }
      $moved = $true
    }
    Write-Output "land: pre-gate round $round - '$Gate' on $Branch rebased onto origin/$Onto @ $(Short $tip) (tree $(Short $tree 12)) in $sp, before the land ticket"
    $script:GateExit = 1; $script:GateSec = 0
    try { Invoke-GateRun $sp "land pregate $Branch" }
    finally {
      if ($moved) {
        if ($branchNow) { & git -C $sp checkout -q $branchNow 2>$null } else { & git -C $sp checkout -q --detach $head 2>$null }
        if ($LASTEXITCODE -or "$(& git -C $sp rev-parse HEAD 2>$null)".Trim() -ne $head) {
          Write-Journal @{ event = 'land-pregate-restore-failed'; resource = $res; branch = $Branch; sha = $head; reason = "slot $sp was left on the pre-gate commit"; repo = $repo.Name }
          [Console]::Error.WriteLine("land: WARNING could not put $sp back on $(if ($branchNow) { $branchNow } else { $head }). Run: git -C `"$sp`" checkout $(if ($branchNow) { $branchNow } else { "--detach $head" })")
        }
      }
    }
    if ($script:GateExit) {
      Write-Journal @{ event = 'land-pregate-failed'; resource = $res; exit = $script:GateExit; branch = $Branch; tree = $tree; durSec = $script:GateSec; reason = $Gate; repo = $repo.Name }
      [Console]::Error.WriteLine("land: gate failed ($($script:GateExit)) for $Branch rebased onto origin/$Onto running '$Gate', BEFORE the queue - nothing queued, nothing pushed. Fix it in the slot and land again. (AGENTQ_LAND_NO_PREGATE=1 runs the gate in the queue instead.)")
      $script:PregateResult = 'failed'; return
    }
    Set-GreenTree $repo.Name $tree $Gate $script:GateSec 'pre-gate'
    Write-Journal @{ event = 'land-pregate-ok'; resource = $res; branch = $Branch; tree = $tree; durSec = $script:GateSec; cached = $false; reason = $Gate; repo = $repo.Name }
    $script:PregateResult = 'ok'
    & git -C $main fetch -q origin $Onto 2>$null
    if ("$(& git -C $main rev-parse "origin/$Onto" 2>$null)".Trim() -eq $tip) { return }
    if ($round -lt $rounds) { Write-Output "land: origin/$Onto moved while the pre-gate ran - checking the new tip" }
  }
}
# Commits of $ref not yet upstream: patch-id dedupe (--cherry-pick) plus `(cherry picked from commit X)`
# trailers upstream (a pick whose CHANGELOG conflict was resolved has a different patch-id).
function Get-LandPicks([string]$wt, [string]$ref) {
  $picks = @(& git -C $wt rev-list --reverse --no-merges --cherry-pick --right-only "origin/$Onto...$ref" 2>$null | Where-Object { $_ })
  $mb = "$(& git -C $wt merge-base "origin/$Onto" $ref 2>$null)".Trim()
  $range = if ($mb) { "$mb..origin/$Onto" } else { "origin/$Onto" }
  $done = @{}; foreach ($m in [regex]::Matches((@(& git -C $wt log --format=%B $range 2>$null) -join "`n"), 'cherry picked from commit ([0-9a-f]{40})')) { $done[$m.Groups[1].Value] = $true }
  @($picks | Where-Object { -not $done.ContainsKey($_) })
}
# Cherry-picks $picks into the land slot, resolving the documented conflicts. Sets $script:PickBad to
# @{ sha; paths } on an unresolvable conflict (pick aborted), else $null. Emits resolver output.
function Add-LandPicks([string]$wt, [string[]]$picks) {
  $script:PickBad = $null
  foreach ($c in $picks) {
    & git -C $wt cherry-pick -x --allow-empty $c 2>&1 | Out-Null
    if (-not $LASTEXITCODE) { continue }
    $conf = @(& git -C $wt diff --name-only --diff-filter=U 2>$null | Where-Object { $_ })
    if (-not $conf.Count) { & git -C $wt cherry-pick --skip 2>$null | Out-Null; continue }   # became empty
    $resolver = Join-Path $wt 'scripts\land-resolve.ps1'
    if (Test-Path -LiteralPath $resolver) { & pwsh -NoProfile -File $resolver -Paths ($conf -join ',') -Worktree $wt 2>&1 | ForEach-Object { Write-Output "  resolver: $_" } }
    foreach ($p in @(& git -C $wt diff --name-only --diff-filter=U 2>$null | Where-Object { $_ -match '(^|/)CHANGELOG\.md$' })) {
      if (-not (Merge-UnionBytes $wt $p)) { break }
    }
    $left = @(& git -C $wt diff --name-only --diff-filter=U 2>$null | Where-Object { $_ })
    $markers = @(& git -C $wt diff --cached --name-only 2>$null | Where-Object { $_ } | Where-Object { $f = Join-Path $wt $_; (Test-Path -LiteralPath $f -PathType Leaf) -and (Select-String -LiteralPath $f -Pattern '^(<{7}|>{7})( |$)' -Quiet) })
    if ($left.Count -or $markers.Count) {
      & git -C $wt cherry-pick --abort 2>$null | Out-Null
      $script:PickBad = @{ sha = $c; paths = @($left + $markers) }
      return
    }
    # Resolution can make the pick empty (its change is already upstream, e.g. a union-merged
    # CHANGELOG from an earlier landing): skip it instead of failing --continue.
    & git -C $wt diff --cached --quiet 2>$null
    if (-not $LASTEXITCODE) { & git -C $wt cherry-pick --skip 2>&1 | Out-Null; continue }
    & git -C $wt -c core.editor=true cherry-pick --continue 2>&1 | Out-Null
    if ($LASTEXITCODE) { & git -C $wt cherry-pick --abort 2>$null | Out-Null; throw "land: cherry-pick --continue failed for $c" }
  }
}
# ---- post-land hook (ADR 0008; brivio ADR-0339 D14) -------------------------------------------------
# After a land has PUSHED, the pushed tree's scripts/post-land.ps1 (when it has one) is started with
# PowerShell 7, detached and hidden, and never waited for: its exit code, its output, an exception or a
# hang cannot change the land. Called from the one `if ($pushed)` block of Invoke-LandSet, so it runs
# once per push (a batch of absorbed lands is one push) with the pushed tip.
#  - Which copy: the blob of the PUSHED commit, read from the object database and written byte for byte
#    to <AGENTQ_HOME>/post-land/<repo>/<run>/post-land.ps1. The land slot is reset by the next landing and
#    the main clone's working tree can lag behind origin. Run directories older than a day are removed
#    here, on the next run, instead of racing the detached process.
#  - A generated launcher (run.ps1, same directory) sets AGENTQ_POSTLAND_REPO (main clone),
#    AGENTQ_POSTLAND_BRANCH (-Onto) and AGENTQ_POSTLAND_SHA (pushed tip), makes the main clone the working
#    directory and keeps the script's output and exit code in output.log.
#  - Windows: the process is created by WMI (Win32_Process.Create, ShowWindow 0 = no visible window), so
#    it is a child of the WMI provider host and in none of our job objects. A land that runs under
#    `agentq run` sits in a kill-on-close job (W2-4): a normal child - also one started the way job-start
#    does it, ShellExecute + Hidden - died the moment that run returned, and CREATE_BREAKAWAY_FROM_JOB is
#    refused (win32 5) by a job without BREAKAWAY_OK (both measured 2026-11-11). The hook gets the user's
#    logon environment, not the land's. Other systems: nohup + background through /bin/sh.
# Journal: `post-land` (repo, branch, sha, pid) when started; `post-land-failed` (reason) when it could
# not be started; nothing when the tree has no such script. AGENTQ_NO_POSTLAND=1 skips the hook.
$PostLandLauncher = @'
# Generated by agentq (post-land hook, ADR 0008). Runs scripts/post-land.ps1 of the pushed commit; nothing waits for it.
$env:AGENTQ_POSTLAND_REPO = @@REPO@@
$env:AGENTQ_POSTLAND_BRANCH = @@BRANCH@@
$env:AGENTQ_POSTLAND_SHA = @@SHA@@
# Tickets and purpose of the land that started this process are not ours (inherited where the OS passes them on).
foreach ($v in 'AGENTQ_HELD', 'AGENTQ_PURPOSE', 'AGENTQ_LANE', 'AGENTQ_TICKET_FILES') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
$log = Join-Path $PSScriptRoot 'output.log'
$code = 0
try {
  Set-Location -LiteralPath $env:AGENTQ_POSTLAND_REPO -ErrorAction Stop
  & (Join-Path $PSScriptRoot 'post-land.ps1') *>> $log
  $code = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
} catch { "post-land: $($_.Exception.Message)" >> $log; $code = 1 }
"EXIT=$code" >> $log
exit $code
'@
function Start-PostLand([string]$repoName, [string]$main, [string]$branch, [string]$sha) {
  if ($env:AGENTQ_NO_POSTLAND -eq '1' -or -not $sha) { return }
  try {
    $spec = "${sha}:scripts/post-land.ps1"
    $kind = "$(& git -C $main cat-file -t $spec 2>$null)".Trim()
    if ($LASTEXITCODE -or $kind -ne 'blob') { return }
    $plRoot = Join-Path $Root 'post-land'
    $cut = (Now).AddDays(-1)
    foreach ($rd in @(Get-ChildItem -LiteralPath $plRoot -Directory -ErrorAction SilentlyContinue)) {
      foreach ($old in @(Get-ChildItem -LiteralPath $rd.FullName -Directory -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -lt $cut })) {
        Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
      }
    }
    $dir = Join-Path (Join-Path $plRoot $repoName) ('{0}-{1}-{2}' -f (Now).ToString('yyyyMMdd-HHmmss'), (Short $sha 12), (Short ([guid]::NewGuid().ToString('N')) 4))
    New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
    # The blob, byte for byte (PowerShell's pipeline would re-encode it and rewrite its line ends).
    $script = Join-Path $dir 'post-land.ps1'
    $psi = [Diagnostics.ProcessStartInfo]::new('git')
    foreach ($a in '-C', $main, 'cat-file', 'blob', $spec) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
    $pr = [Diagnostics.Process]::Start($psi)
    $errTask = $pr.StandardError.ReadToEndAsync()
    $fs = [IO.File]::Create($script)
    try { $pr.StandardOutput.BaseStream.CopyTo($fs) } finally { $fs.Dispose() }
    $pr.WaitForExit()
    if ($pr.ExitCode) { throw "git cat-file blob $spec failed ($($pr.ExitCode)): $($errTask.Result)" }
    $lit = { param([string]$s) "'" + [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($s) + "'" }
    $launcher = Join-Path $dir 'run.ps1'
    $text = $PostLandLauncher.Replace('@@REPO@@', (& $lit $main)).Replace('@@BRANCH@@', (& $lit $branch)).Replace('@@SHA@@', (& $lit $sha))
    [IO.File]::WriteAllText($launcher, ($text -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $pw = (Get-Process -Id $PID).Path
    $childPid = 0
    if ($IsWindows) {
      $cmd = '"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}"' -f $pw, $launcher
      $su = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
      $r = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; CurrentDirectory = $main; ProcessStartupInformation = $su } -OperationTimeoutSec 30 -ErrorAction Stop
      if ([int]$r.ReturnValue -ne 0) { throw "Win32_Process.Create returned $($r.ReturnValue)" }
      $childPid = [int]$r.ProcessId
    } else {
      $so = @(& /bin/sh -c 'nohup "$0" -NoProfile -NonInteractive -File "$1" </dev/null >/dev/null 2>&1 & echo $!' $pw $launcher)
      $childPid = [int]"$($so | Select-Object -Last 1)".Trim()
    }
    if ($childPid -le 0) { throw 'the process was not created (no pid)' }
    Write-Journal @{ event = 'post-land'; resource = "land:$repoName"; sha = $sha; branch = $branch; pid = $childPid; reason = "scripts/post-land.ps1 of $(Short $sha 12) started detached; its output goes to $(Join-Path $dir 'output.log')"; repo = $repoName }
  } catch {
    try {
      $why = "$($_.Exception.Message)"
      Write-Journal @{ event = 'post-land-failed'; resource = "land:$repoName"; sha = $sha; branch = $branch; reason = $why.Substring(0, [math]::Min(500, $why.Length)); repo = $repoName }
    } catch {}
  }
}
# One attempt to land a set of topics as ONE push (up to 3 rounds when origin moves). Uses $repo,
# $main, $wt, $res from Invoke-Land. Result in $script:LandSetOut:
#   results[branch] = @{ exit; sha; nothing }, failExit (whole-set failure), failSet, dropped, sha.
function Invoke-LandSet([object[]]$set) {
  $o = @{ results = @{}; failExit = 0; failSet = @(); dropped = @(); sha = '' }
  $script:LandSetOut = $o
  $flakeRetried = $false
  $active = @($set)
  $label = ($set | ForEach-Object { $_.branch }) -join '+'
  for ($round = 1; $round -le 3; $round++) {
    & git -C $main fetch -q origin $Onto 2>$null
    if (Test-Path -LiteralPath $wt) { [void](Backup-Slot $wt $repo.Name 'land' 'leftover in land slot') }
    Initialize-Slot $main $wt "origin/$Onto" '' $true
    $baseRev = "$(& git -C $wt rev-parse HEAD)".Trim()
    $picked = @()
    foreach ($tp in @($active)) {
      $picks = @(Get-LandPicks $wt $tp.ref)
      if (-not $picks.Count) {
        Write-Output "land: $($tp.branch) is already on origin/$Onto (nothing to pick)"
        $o.results[$tp.branch] = @{ exit = 0; sha = "$(& git -C $wt rev-parse HEAD)".Trim(); nothing = $true }
        $active = @($active | Where-Object { $_.branch -ne $tp.branch }); continue
      }
      $before = "$(& git -C $wt rev-parse HEAD)".Trim()
      Add-LandPicks $wt $picks
      $bad = $script:PickBad
      if ($bad) {
        & git -C $wt reset -q --hard $before 2>$null
        $active = @($active | Where-Object { $_.branch -ne $tp.branch })
        if ($tp.own -or $set.Count -eq 1) {
          Write-Journal @{ event = 'land-conflict'; resource = $res; sha = $bad.sha; paths = @($bad.paths); reason = "conflict picking $(Short $bad.sha) onto origin/$Onto"; repo = $repo.Name }
          [Console]::Error.WriteLine("land: CONFLICT picking $(Short $bad.sha) onto origin/${Onto}: $(@($bad.paths) -join ', '). Nothing pushed. Rebase $($tp.branch) on origin/$Onto in your task slot, push it, and land again.")
          $o.results[$tp.branch] = @{ exit = 5; sha = ''; nothing = $false }
        } else {
          Write-Journal @{ event = 'land-batch-drop'; resource = $res; sha = $bad.sha; paths = @($bad.paths); branch = $Onto; reason = "$($tp.branch) conflicts with an earlier topic of the batch; it lands on its own turn"; repo = $repo.Name }
          Write-Output "land: $($tp.branch) conflicts with another topic of the batch - back to the queue"
          $o.dropped += $tp
        }
        continue
      }
      $picked += $tp
    }
    $o.failSet = $picked
    if (-not $picked.Count) { return }
    $names = ($picked | ForEach-Object { $_.branch }) -join '+'
    if (-not (Restore-LandDeps $repo $wt $baseRev)) { $o.failExit = 10; return }
    if ($Gate) {
      # OQ-003: the exact tree about to be pushed already passed this gate (in the caller's slot, or in
      # an earlier land attempt): do not hold the land ticket for a second run of the same check.
      $gateTree = "$(& git -C $wt rev-parse 'HEAD^{tree}' 2>$null)".Trim()
      $green = Test-GreenTree $repo.Name $gateTree $Gate
      if ($green) {
        Write-Journal @{ event = 'land-gate-skipped-green'; resource = $res; branch = $Onto; tree = $gateTree; paths = @($picked | ForEach-Object { $_.branch }); reason = "tree $(Short $gateTree 12) passed '$Gate' at $($green['at']) ($($green['where']))"; repo = $repo.Name }
        Write-Output "land: gate skipped for $names - tree $(Short $gateTree 12) already passed '$Gate' ($($green['where']), $($green['at']))"
      } else {
        $script:GateExit = 1; $script:GateSec = 0
        Invoke-GateRun $wt "land gate $names"
        $gx = $script:GateExit
        if ($gx) {
          Write-Journal @{ event = 'land-gate-failed'; resource = $res; exit = $gx; reason = $Gate; paths = @($picked | ForEach-Object { $_.branch }); repo = $repo.Name }
          [Console]::Error.WriteLine("land: gate failed ($gx) for $names - '$Gate' exited non-zero; nothing pushed")
          $o.failExit = 6; return
        }
        Set-GreenTree $repo.Name $gateTree $Gate $script:GateSec 'land'
      }
    }
    # Repo-owned land finalize (ADR 0003 W3, changelog fragments): assembles changes/*.md into ONE
    # chore(release) commit on the CURRENT origin/<onto>, so two topics never claim the same version.
    $finalizer = Join-Path $wt 'scripts\land-finalize.ps1'
    if (Test-Path -LiteralPath $finalizer) {
      $baseSha = "$(& git -C $wt rev-parse "origin/$Onto" 2>$null)".Trim()
      $fo = @(& pwsh -NoProfile -File $finalizer -Worktree $wt -Onto $Onto -Base $baseSha -Branch $picked[0].branch 2>&1 | ForEach-Object { "$_" })
      $frc = $LASTEXITCODE
      $fo | ForEach-Object { Write-Output "  finalize: $_" }
      if ($frc) {
        $why2 = "$(@($fo | Select-Object -Last 3) -join ' | ')"
        Write-Journal @{ event = 'land-finalize-failed'; resource = $res; exit = $frc; branch = $Onto; reason = $why2.Substring(0, [math]::Min(500, $why2.Length)); repo = $repo.Name }
        [Console]::Error.WriteLine("land: scripts/land-finalize.ps1 exit $frc - nothing pushed. Fix the fragment(s) on $names and land again.")
        Initialize-Slot $main $wt "origin/$Onto" '' $false
        $o.failExit = 9; return
      }
    }
    $big = @(Get-OversizedChangelogs $wt "origin/$Onto")
    if ($big.Count) {
      Write-Journal @{ event = 'land-oversized'; resource = $res; exit = 8; branch = $Onto; paths = $big; reason = "CHANGELOG grew past 1.5x origin/$Onto"; repo = $repo.Name }
      [Console]::Error.WriteLine("land: REFUSED - CHANGELOG grew past 1.5x its size on origin/${Onto}: $($big -join '; '). Nothing pushed. Rebuild $names on origin/$Onto (take its CHANGELOG, re-add your entry) and land again.")
      # Drop the bad result so the land-finished backup does not try to push it to origin.
      Initialize-Slot $main $wt "origin/$Onto" '' $false
      $o.failExit = 8; return
    }
    $pushed = $false; $noVerify = $false; $isRace = $false
    $out = @(& git -C $wt push origin "HEAD:$Onto" 2>&1 | ForEach-Object { "$_" })
    if (-not $LASTEXITCODE) { $pushed = $true } else {
      $isRace = [bool]($out -match $LandRaceRe)
      if (-not $isRace -and -not $flakeRetried) {
        $fr = Record-Flakes $repo.Name $wt $out 1
        $flake = Test-InfraFlake $out
        $retryWhy = if ($flake) { "infra: $flake" } elseif ($fr -and $fr.allQuarantined) { "only quarantined tests failed: $(@($fr.failed) -join '; ')" } else { $null }
        if ($retryWhy) {
          $flakeRetried = $true
          Write-Journal @{ event = 'flake'; resource = $res; exit = 7; branch = $Onto; reason = "pre-push failure, retrying once ($retryWhy)"; repo = $repo.Name }
          Write-Output "land: pre-push failed ($retryWhy) - retrying the push once"
          $out = @(& git -C $wt push origin "HEAD:$Onto" 2>&1 | ForEach-Object { "$_" })
          if (-not $LASTEXITCODE) { $pushed = $true } else {
            $isRace = [bool]($out -match $LandRaceRe)
            if (-not $isRace) {
              $fr2 = Record-Flakes $repo.Name $wt $out 2
              if ($fr2 -and $fr2.allQuarantined) {
                Write-Journal @{ event = 'flake-quarantined'; resource = $res; exit = 7; branch = $Onto; paths = @($fr2.failed); reason = 'pre-push failed twice on quarantined tests only; pushed with --no-verify'; repo = $repo.Name }
                Write-Output "land: only quarantined tests failed again ($(@($fr2.failed) -join '; ')) - landing without the hook (agentq flakes lists them)"
                $out = @(& git -C $wt push --no-verify origin "HEAD:$Onto" 2>&1 | ForEach-Object { "$_" })
                if (-not $LASTEXITCODE) { $pushed = $true; $noVerify = $true } else { $isRace = [bool]($out -match $LandRaceRe) }
              }
            }
          }
        }
      }
    }
    if ($pushed) {
      $o.sha = "$(& git -C $wt rev-parse HEAD)".Trim()
      if (-not $noVerify) { Pass-Flakes $repo.Name $wt }
      foreach ($tp in $picked) { $o.results[$tp.branch] = @{ exit = 0; sha = $o.sha; nothing = $false } }
      $o.failSet = @()
      # One push = one post-land hook run, at the pushed tip. Detached: it can neither fail nor delay the land.
      $null = Start-PostLand $repo.Name $main $Onto $o.sha
      return
    }
    if ($isRace) { Write-Output "land: origin/$Onto moved, retry round $($round + 1)"; continue }
    $out | Select-Object -Last 20 | ForEach-Object { [Console]::Error.WriteLine($_) }
    $tail = (@($out | Select-Object -Last 6) -join ' | ')
    Write-Journal @{ event = 'land-push-failed'; resource = $res; exit = 7; branch = $Onto; reason = $tail.Substring(0, [math]::Min(500, $tail.Length)); repo = $repo.Name }
    $o.failExit = 7; return
  }
  [Console]::Error.WriteLine("land: origin kept moving (3 rounds) - try again ($label)")
  $o.failExit = 3
}
# Lands $set; a whole-set failure of more than one topic is split in halves and each half retried.
function Invoke-LandBisect([object[]]$set) {
  Invoke-LandSet $set
  $r = $script:LandSetOut
  foreach ($k in @($r.results.Keys)) { $script:LandAcc.results[$k] = $r.results[$k] }
  $script:LandAcc.dropped += @($r.dropped)
  if ($r.sha) { $script:LandAcc.shas += $r.sha }
  if (-not $r.failExit) { return }
  $fs = @($r.failSet)
  if ($fs.Count -gt 1 -and $r.failExit -in 6, 7, 8, 9, 10) {
    $script:LandAcc.bisected = $true
    $h = [int][math]::Ceiling($fs.Count / 2)
    $left = @($fs[0..($h - 1)]); $right = @($fs[$h..($fs.Count - 1)])
    Write-Output "land: batch of $($fs.Count) failed (exit $($r.failExit)) - bisecting: $(($left | ForEach-Object { $_.branch }) -join '+') | $(($right | ForEach-Object { $_.branch }) -join '+')"
    Invoke-LandBisect $left
    Invoke-LandBisect $right
  } else { foreach ($tp in $fs) { $script:LandAcc.results[$tp.branch] = @{ exit = $r.failExit; sha = ''; nothing = $false } } }
}
# One land slot per repo: pick the topic's not-yet-upstream commits onto origin/<onto>, resolve the
# documented conflicts, gate, push (never forced), notify running releases. Exit 0 landed / already
# landed, 5 conflict, 6 gate failed, 7 push refused, 8 CHANGELOG grew > 1.5x (refused before push),
# 9 repo land-finalize refused, 10 the merged result's lockfile could not be installed in the land slot,
# 3 busy/remote kept moving. With batching (above) the same codes apply
# per topic; an absorbed waiter exits with its topic's code.
# After each push the pushed tree's scripts/post-land.ps1 is started detached (Start-PostLand, ADR 0008);
# it never changes these codes.
function Invoke-Land {
  $repo = Get-RepoInfo $RepoArg
  Assert-ExpectedRepo $repo
  if (-not $repo -or -not $Branch -or -not $Onto) { throw 'agentq land -Branch <topic> -Onto <dev|main> [-Gate "<cmd>"] -Purpose "why"' }
  Assert-SharedCloneWriteAllowed $repo 'land'
  $why = if ($Purpose) { $Purpose } else { "land $Branch -> $Onto" }
  $main = Get-MainTop $repo
  $res = "land:$($repo.Name)"
  Assert-NotMarked $res
  # ADR-0303 A (brivio): a repo may declare its default land gate in config (`landGate: { repo: cmd }`),
  # so every land runs it without each agent remembering -Gate. `-Gate none` opts out, journaled.
  if (-not $Gate) {
    $lg = (Get-Config)['landGate']
    if ($lg -and $lg.ContainsKey($repo.Name) -and "$($lg[$repo.Name])") { $Gate = "$($lg[$repo.Name])"; Write-Output "land: default gate for $($repo.Name): $Gate" }
  } elseif ($Gate -eq 'none') {
    Write-Journal @{ event = 'land-gate-skipped'; resource = $res; branch = $Branch; reason = $why; repo = $repo.Name }
    $Gate = $null
  }
  # Visibility for the ungated majority: the 2026-11-21 readiness pass found 94 of 95 repos declare no
  # `landGate` and 80 of them have no pre-push hook either, so their lands merge and push with NO check
  # at all. Nothing is refused (an ungated land still beats a land that never happens) - but it is said
  # out loud and journaled, because a silent ungated land is how a broken tree reaches other agents.
  if (-not $Gate) {
    Write-Journal @{ event = 'land-ungated'; resource = $res; branch = $Branch; onto = $Onto; reason = $why; repo = $repo.Name }
    [Console]::Error.WriteLine("land: NO GATE for $($repo.Name) - $Branch -> $Onto will be merged and pushed unchecked. Close it once: add  `"landGate`": { `"$($repo.Name)`": `"<cmd>`" }  to bin/agentq-config.json (or pass -Gate `"<cmd>`").")
  }
  # W2-6: refuse BEFORE queueing when the topic cannot merge onto the current tip (outside the files the
  # land resolver/finalizer handle). Saves the whole queue wait + slot setup of a land that ends in exit 5.
  # The precheck MUST judge the SAME ref land will merge: Resolve-LandRef (below, used by the pre-gate and
  # the merge) prefers the LOCAL tip refs/heads/<branch>, which after a rebase in the slot is a clean
  # descendant while the PUSHED tip is still the pre-rebase, conflicting commit. Reading the remote ref
  # here refused exactly the correctly-rebased branch (brivio 2026-11-21, docs/DEV_PERFORMANCE.md) and
  # told the user to rebase what they had already rebased. Judging a ref land does not merge is worse than
  # no precheck: it either false-refuses (this bug) or false-passes and still ends in exit 5 in the slot.
  & git -C $main fetch -q origin $Onto 2>$null
  $preRef = Resolve-LandRef $main $Branch
  if ($preRef -and -not $env:AGENTQ_LAND_NO_PRECHECK) {
    $preWhere = if ($preRef -like 'refs/heads/*') { 'local tip' } else { 'pushed tip' }
    $mt = @(& git -C $main merge-tree --write-tree --name-only --no-messages "origin/$Onto" $preRef 2>$null | ForEach-Object { "$_" })
    if ($LASTEXITCODE -eq 1) {
      $hard = @($mt | Select-Object -Skip 1 | Where-Object { $_ -and $_ -notmatch '(^|/)(CHANGELOG\.md|package\.json)$' -and $_ -notmatch '^changes/' })
      if ($hard.Count) {
        Write-Journal @{ event = 'land-precheck-conflict'; resource = $res; branch = $Onto; ref = $preRef; paths = $hard; reason = "$Branch ($preWhere) conflicts with origin/$Onto before queueing"; repo = $repo.Name }
        [Console]::Error.WriteLine("land: $Branch ($preWhere $preRef) does not merge onto origin/$Onto (conflicts: $($hard -join ', ')). Nothing queued. Resolve those files on $Branch (rebase it onto origin/$Onto if origin/$Onto moved) and land again.")
        $script:LandExit = 5; return
      }
    }
  }
  # OQ-002: run the gate on the rebased result in the caller's slot BEFORE taking the land ticket.
  if ($Gate) {
    $pgRef = Resolve-LandRef $main $Branch
    if ($pgRef) {
      Invoke-LandPregate $repo $main $pgRef
      if ($script:PregateResult -eq 'failed') { $script:LandExit = 6; return }
    }
  }
  $t = New-Ticket $res $why "land $Branch -> $Onto" $main
  $cwdN = Norm-Dir (Get-Location).Path
    $srcLease = Read-Leases $repo.Name | Where-Object { $_.role -in 'task', 'pinned' -and $cwdN.StartsWith((Norm-Dir "$(P $_ 'path')")) } | Select-Object -First 1
  if (-not $srcLease) { $srcLease = Read-Leases $repo.Name | Where-Object { $_.session -eq $Session -and $_.role -in 'task', 'pinned' } | Sort-Object { "$(P $_ 'created' '')" } | Select-Object -First 1 }
  $tc = if ($srcLease) { @(P $srcLease 'claims' @()) } else { @() }
  try { Update-Ticket $t @{ landBranch = $Branch; landOnto = $Onto; landGate = "$Gate"; claims = $tc; leaseCreated = $(if ($srcLease) { "$(P $srcLease 'created' '')" } else { '' }) } } catch {}
  Write-Journal @{ event = 'queued'; resource = $res; ticket = $t.id; purpose = $why; repo = $repo.Name }
  $lease = $null; $hb = $null; $set = @(); $peersDone = $false
  $bdir = Join-Path (Join-Path $Root 'batches') $repo.Name
  $myResult = Join-Path $bdir "$($t.id).json"
  $script:LandExit = 1
  try {
    $script:WaitAborted = $false
    $script:WaitAbort = { Test-Path -LiteralPath $myResult }.GetNewClosure()
    Wait-Turn $t $TimeoutMin $null
    $script:WaitAbort = $null
    if ($script:WaitAborted -or (Test-Path -LiteralPath $myResult)) {
      # Absorbed into another holder's batch (W2-5): its result is ours.
      $r = Read-JsonFile $myResult
      Remove-Item -LiteralPath $myResult -Force -ErrorAction SilentlyContinue
      $x = [int](P $r 'exit' 1)
      if ($x -eq 0) { Write-Output "landed $Branch -> origin/$Onto @ $(Short (P $r 'sha' '') 12) (in a batch by $(P $r 'by' '?'))" }
      else { [Console]::Error.WriteLine("land: $Branch failed in a batch by $(P $r 'by' '?') (exit $x$(if (P $r 'reason' '') { ': ' + (P $r 'reason' '') })) - nothing of it was pushed") }
      $script:LandExit = $x; return
    }
    $lease = New-Lease $repo 'land' 'land' $why '' $PID 10 $false
    $hb = Start-ThreadJob -ArgumentList (, @("$($t.file).hb", "$($lease.file).hb")) -ScriptBlock { param($fs) while ($true) { foreach ($f in $fs) { try { [IO.File]::SetLastWriteTimeUtc($f, [DateTime]::UtcNow) } catch {} }; Start-Sleep -Seconds 20 } }
    $env:AGENTQ_HELD = (@($env:AGENTQ_HELD, $res) | Where-Object { $_ }) -join ','
    $wt = $lease.path
    & git -C $main fetch -q origin 2>$null
    $topicRef = Resolve-LandRef $main $Branch
    if (-not $topicRef) { throw "land: branch $Branch not found locally or on origin" }
    $set = @(@{ branch = $Branch; ref = $topicRef; own = $true; session = $Session; purpose = $why; ticket = $null })
    if (Get-LandBatchOn $repo.Name) {
      $max = Get-LandBatchSize $repo.Name
      $cand = @(Get-Live $res | Where-Object { $_.id -ne $t.id -and -not (P $_ 'held' $false) -and "$(P $_ 'landOnto' '')" -eq $Onto -and "$(P $_ 'landGate' '')" -eq "$Gate" -and (P $_ 'landBranch' '') -and -not (P $_ 'batchedBy' '') } | Sort-Object { [long]$_.seq })
      foreach ($w in $cand) {
        if ($set.Count -ge $max) { break }
        $wb = "$($w.landBranch)"
        if (@($set | Where-Object { $_.branch -eq $wb }).Count) { continue }
        $wr = Resolve-LandRef $main $wb
        if (-not $wr) { continue }
        & git -C $main merge-tree --write-tree --name-only --no-messages "origin/$Onto" $wr 2>$null | Out-Null
        if ($LASTEXITCODE) { continue }
        try { Update-Ticket $w @{ batchedBy = $t.id } } catch { continue }
        $set += @{ branch = $wb; ref = $wr; own = $false; session = "$($w.session)"; purpose = "$($w.purpose)"; ticket = $w }
      }
      if ($set.Count -gt 1) { Write-Output "land: batching $($set.Count) topics onto origin/${Onto}: $(($set | ForEach-Object { $_.branch }) -join ', ')" }
    }
    $script:LandAcc = @{ results = @{}; dropped = @(); bisected = $false; shas = @() }
    Invoke-LandBisect $set
    $acc = $script:LandAcc
    $acts = @()
    foreach ($s in @($acc.shas | Select-Object -Unique)) { $acts += @(Notify-Landing $repo.Name $Onto $s '') }
    foreach ($tp in $set) {
      $r = $acc.results[$tp.branch]
      if ($r -and $r.exit -eq 0 -and -not $r.nothing) {
        Write-Journal @{ event = 'land'; resource = $res; sha = $r.sha; branch = $Onto; purpose = $tp.purpose; session = $tp.session; reason = "$($tp.branch) -> $Onto$(if ($set.Count -gt 1) { " (batch of $($set.Count))" }); releases: $($acts -join ',')"; repo = $repo.Name }
      }
    }
    if ($set.Count -gt 1) {
      Write-Journal @{ event = 'land-batch'; resource = $res; branch = $Onto; size = $set.Count; bisected = [bool]$acc.bisected; paths = @($set | ForEach-Object { "$($_.branch)=$(if ($acc.results[$_.branch]) { $acc.results[$_.branch].exit } else { 'requeued' })" }); repo = $repo.Name }
    }
    foreach ($tp in @($set | Where-Object { -not $_.own })) {
      $r = $acc.results[$tp.branch]
      if ($r) { Write-JsonAtomic (Join-Path $bdir "$($tp.ticket.id).json") @{ exit = [int]$r.exit; sha = "$($r.sha)"; by = $Session; holder = $t.id; reason = "$(if ($r.exit) { 'failed on its own after bisection' })" } }
      else { try { Update-Ticket $tp.ticket @{ batchedBy = '' } } catch {} }
    }
    $peersDone = $true
    $own = $acc.results[$Branch]
    if (-not $own) { throw "land: internal error - no result for $Branch" }
    if ($own.exit -eq 0 -and -not $own.nothing) { Write-Output "landed $Branch -> origin/$Onto @ $(Short $own.sha 12)$(if ($acts) { " (releases: $($acts -join ', '))" })" }
    $script:LandExit = [int]$own.exit
  } finally {
    $script:WaitAbort = $null
    # A holder that dies mid-batch hands every absorbed waiter back to the queue.
    if (-not $peersDone) { foreach ($tp in @($set | Where-Object { -not $_.own })) { try { Update-Ticket $tp.ticket @{ batchedBy = '' } } catch {} } }
    if ($hb) { Stop-Job $hb -ErrorAction SilentlyContinue; Remove-Job $hb -Force -ErrorAction SilentlyContinue }
    if ($lease) {
      $l = (Read-Leases $repo.Name | Where-Object { $_.slot -eq 'land' -and $_.leaseId -eq $lease.leaseId } | Select-Object -First 1)
      if ($l) { $ref = try { Backup-Slot $l.path $repo.Name 'land' 'land finished' } catch { "backup-failed: $($_.Exception.Message)" }; Remove-LeaseRecord $l 'unlease' 'land finished' $ref }
    }
    Remove-Item -LiteralPath $t.file, "$($t.file).hb" -Force -ErrorAction SilentlyContinue
  }
}

# ---- publish (ADR 0003 W1-2) -------------------------------------------------------------
# The supported form of the hand-written "temp-index plumbing commit" (reinvented ~18 times, 2026-10).
# Takes ONLY -Paths from the current working tree (any clone or slot), builds a commit whose parent is
# the CURRENT origin/<Onto> tip in a throwaway index (the shared index/worktree are never touched),
# refuses when the result would delete lines in a file the caller did not change relative to its own
# base (= reverting work that landed meanwhile), pushes a fresh topic, verifies it on the remote, and
# with -Land hands it to Invoke-Land. Blobs are written from the file bytes via the repo's own
# clean filters (git hash-object --path), so EOL/attributes match what a normal commit would store.
#
# Batched (2026-10-28): the first version spawned ~6 git processes PER PATH (hash-object, ls-tree,
# update-index, then 3x rev-parse in the revert guard). A 233-path codai publish took 45+ min on a busy
# workstation (process start 0.5-4 s each). Now: one `hash-object --stdin-paths` (still applies the
# path's clean filters), one `update-index --index-info`, and one `ls-tree -r` per tree compared.
function Get-PubTreeMap([string]$top, [string]$rev) {
  # path -> "mode sha" for every blob in $rev (one process). -z: no quoting, paths may contain spaces.
  $map = @{}
  if (-not $rev) { return $map }
  $raw = (& git -C $top -c core.quotepath=off ls-tree -r -z --full-tree $rev 2>$null) -join "`n"
  foreach ($e in ($raw -split "`0")) {
    if (-not $e) { continue }
    $tab = $e.IndexOf("`t"); if ($tab -lt 0) { continue }
    $meta = $e.Substring(0, $tab).Trim() -split '\s+'
    $map[$e.Substring($tab + 1).TrimStart("`n")] = "$($meta[0]) $($meta[2])"
  }
  $map
}
function Invoke-GitStdin([string]$top, [string[]]$gitArgs, [string[]]$lines) {
  # PowerShell pipes native stdin with CRLF and the console code page; git plumbing needs LF + UTF-8 exactly
  # ("Ignoring path a.txt\r"). Returns stdout lines; throws on a non-zero exit.
  $psi = [Diagnostics.ProcessStartInfo]::new('git')
  foreach ($a in @('-C', $top) + $gitArgs) { $psi.ArgumentList.Add($a) }
  $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $psi.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
  $pr = [Diagnostics.Process]::Start($psi)
  $errTask = $pr.StandardError.ReadToEndAsync()
  $outTask = $pr.StandardOutput.ReadToEndAsync()
  $pr.StandardInput.NewLine = "`n"
  foreach ($l in $lines) { $pr.StandardInput.Write($l + "`n") }
  $pr.StandardInput.Close()
  $pr.WaitForExit()
  if ($pr.ExitCode) { throw "git $($gitArgs -join ' ') failed ($($pr.ExitCode)): $($errTask.Result)" }
  @($outTask.Result -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_ })
}
function Invoke-Publish {
  $repo = Get-RepoInfo $RepoArg
  Assert-ExpectedRepo $repo
  if (-not $repo) { throw 'agentq publish: not in a git repo' }
  if (-not $Purpose -or -not $Message) { throw 'agentq publish -Paths a,b -Message "type(scope): msg" -Purpose "why" [-Onto main] [-Base <ref>] [-Land] [-NoPush]' }
  $plist = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() -replace '\\', '/' } | Where-Object { $_ })
  if (-not $plist) { throw 'agentq publish: -Paths a,b,c is required' }
  $top = $repo.Top
  $onto = if ($Onto) { $Onto } else { $b = "$(& git -C $top rev-parse --abbrev-ref '@{u}' 2>$null)".Trim(); if ($b -match '^[^/]+/(.+)$') { $Matches[1] } else { 'main' } }
  & git -C $top fetch -q origin $onto 2>$null
  if ($LASTEXITCODE) { throw "agentq publish: git fetch origin $onto failed" }
  $tip = "$(& git -C $top rev-parse "origin/$onto")".Trim()
  # Base = the commit the caller edited on top of; default HEAD. Used only for the revert guard.
  $base = if ($Base) { "$(& git -C $top rev-parse --verify "$Base^{commit}" 2>$null)".Trim() } else { "$(& git -C $top rev-parse HEAD)".Trim() }
  if (-not $base) { throw "agentq publish: -Base $Base is not a commit" }
  $idx = Join-Path ([IO.Path]::GetTempPath()) ("aq-pub-" + [guid]::NewGuid().ToString('N') + '.idx')
  $oldIdx = $env:GIT_INDEX_FILE
  $reverts = @(); $changed = @()
  # ls-tree -z output is decoded as UTF-8 (non-ASCII paths); agentq runs in its own pwsh process.
  [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  $tipMap = Get-PubTreeMap $top $tip
  try {
    $env:GIT_INDEX_FILE = $idx
    & git -C $top read-tree $tip; if ($LASTEXITCODE) { throw 'read-tree failed' }
    $present = @($plist | Where-Object { Test-Path -LiteralPath (Join-Path $top $_) -PathType Leaf })
    $absent = @($plist | Where-Object { $present -notcontains $_ })
    $blobs = @()
    if ($present.Count) {
      # --stdin-paths hashes each file AS its path, so .gitattributes clean filters / eol apply like --path.
      $blobs = @(Invoke-GitStdin $top @('hash-object', '-w', '--stdin-paths') $present)
      if ($blobs.Count -ne $present.Count) { throw "hash-object --stdin-paths failed ($($blobs.Count)/$($present.Count) blobs)" }
    }
    $wtModes = @{}
    if ($present | Where-Object { -not $tipMap.ContainsKey($_) }) {
      # New paths: take the mode the caller's own index has (exec bit), one process for all of them.
      $raw = (& git -C $top -c core.quotepath=off ls-files -s -z 2>$null) -join "`n"
      foreach ($e in ($raw -split "`0")) { $tab = $e.IndexOf("`t"); if ($tab -gt 0) { $wtModes[$e.Substring($tab + 1).TrimStart("`n")] = ($e.Substring(0, $tab).Trim() -split '\s+')[0] } }
    }
    $lines = [Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $present.Count; $i++) {
      $p = $present[$i]
      $mode = if ($tipMap.ContainsKey($p)) { ($tipMap[$p] -split ' ')[0] } elseif ($wtModes.ContainsKey($p)) { $wtModes[$p] } else { '100644' }
      $lines.Add("$mode $($blobs[$i])`t$p")
    }
    foreach ($p in $absent) { $lines.Add("0 0000000000000000000000000000000000000000`t$p") }
    if ($lines.Count) { Invoke-GitStdin $top @('update-index', '--index-info') $lines | Out-Null }
    $tree = "$(& git -C $top write-tree)".Trim()
  } finally {
    if ($oldIdx) { $env:GIT_INDEX_FILE = $oldIdx } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $idx -Force -ErrorAction SilentlyContinue
  }
  if ($tree -eq "$(& git -C $top rev-parse "$tip^{tree}")".Trim()) { Write-Output "publish: nothing to publish - origin/$onto already has these $($plist.Count) path(s) as on disk"; return }
  # Revert guard: for every path, compare (base -> disk) with (tip -> result). Lines the tip has that
  # base did not have, and that our result drops, would be someone else's landed work being undone.
  $baseMap = if ($base -eq $tip) { $tipMap } else { Get-PubTreeMap $top $base }
  $oursMap = Get-PubTreeMap $top $tree
  $blobOf = { param($m, $p) if ($m.ContainsKey($p)) { ($m[$p] -split ' ')[1] } else { '' } }
  foreach ($p in $plist) {
    $onTip = & $blobOf $tipMap $p
    $onBase = & $blobOf $baseMap $p
    $ours = & $blobOf $oursMap $p
    if ($onTip -ne $ours) { $changed += $p }
    if ($onTip -and $onBase -and $onTip -ne $onBase -and $ours -ne $onTip) {
      $tipAdds = @(& git -C $top diff --no-color --unified=0 $onBase $onTip 2>$null | Where-Object { $_ -match '^\+[^+]' } | ForEach-Object { $_.Substring(1) })
      $dropped = @(& git -C $top diff --no-color --unified=0 $onTip $ours 2>$null | Where-Object { $_ -match '^-[^-]' } | ForEach-Object { $_.Substring(1) })
      $lost = @($tipAdds | Where-Object { $dropped -contains $_ })
      if ($lost.Count) { $reverts += "$p ($($lost.Count) line(s) landed after your base would be removed)" }
    }
    if ($onTip -and -not $ours -and $onBase -ne $onTip) { $reverts += "$p (deleted, but origin/$onto changed it after your base)" }
  }
  if ($reverts.Count -and -not $Force) {
    Write-Journal @{ event = 'publish-refused'; resource = "commit:$($repo.Name)"; purpose = $Purpose; paths = $plist; reason = ($reverts -join '; '); repo = $repo.Name }
    [Console]::Error.WriteLine("publish: REFUSED - would revert work that landed on origin/$onto after your base $(Short $base):`n  " + ($reverts -join "`n  ") + "`nRebase those files on origin/$onto (or pass -Force if the removal is intended).")
    exit 5
  }
  $msgFile = [IO.Path]::GetTempFileName()
  [IO.File]::WriteAllText($msgFile, "$Message`n`nAgent-Session: $Session`nAgent-Purpose: $Purpose", [Text.UTF8Encoding]::new($false))
  $sha = "$(& git -C $top commit-tree $tree -p $tip -F $msgFile)".Trim(); Remove-Item $msgFile -Force
  if (-not $sha) { throw 'commit-tree failed' }
  $stat = @(& git -C $top diff --numstat $tip $sha)
  Write-Output "publish: $(Short $sha 12) on origin/$onto @ $(Short $tip 12) ($($changed.Count) file(s))"
  $stat | ForEach-Object { Write-Output "  $_" }
  Write-Journal @{ event = 'publish'; resource = "commit:$($repo.Name)"; sha = $sha; branch = $onto; purpose = $Purpose; message = $Message; paths = $changed; repo = $repo.Name }
  if ($NoPush) { Write-Output "publish: -NoPush, commit $sha exists only locally"; return }
  $topic = if ($Branch) { $Branch } else { "publish/$(($Session -replace '[^A-Za-z0-9-]', '-').ToLowerInvariant())-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))" }
  $out = @(& git -C $top push -q --no-verify origin "$($sha):refs/heads/$topic" 2>&1 | ForEach-Object { "$_" })
  $remote = "$(& git -C $top ls-remote origin "refs/heads/$topic")".Trim() -split '\s+' | Select-Object -First 1
  if ($remote -ne $sha) { $out | Select-Object -Last 10 | ForEach-Object { [Console]::Error.WriteLine($_) }; throw "publish: push of $topic not verified on origin (got '$remote')" }
  Write-Output "publish: pushed origin/$topic = $(Short $sha 12)"
  if (-not $DoLand) { Write-Output "publish: land it with: agentq land -Branch $topic -Onto $onto -Purpose `"$Purpose`""; return }
  $script:Branch = $topic; $script:Onto = $onto
  Invoke-Land
  if ($script:LandExit -eq 0) { & git -C $top push -q --no-verify origin ":refs/heads/$topic" 2>$null | Out-Null }
}


# ---- status sections (called from Show-Status) -------------------------------------------
function Get-V2Status([string]$repoName) {
  $leases = @(Read-Leases $repoName)
  $rels = @(Read-Releases $repoName | Where-Object { (P $_ 'state') -in 'running', 'preempting' -or ((Now) - (ParseUtc (P $_ 'phaseAt' (Iso (Now))))).TotalHours -lt 6 })
  [pscustomobject]@{ leases = $leases; releases = $rels }
}
function Format-V2Status($v) {
  if ($v.releases) {
    # `phase` in the record is the LAST checkpoint the run entered (release-phase), and `state` is the
    # run's own outcome. The two are independent: a FAILED run is NOT a failed phase, and nothing in the
    # record attributes a failing exit code to a phase (the failure happens somewhere in the wrapped
    # command, which is not tied to a checkpoint). So the column is labelled `last-phase` = the last
    # checkpoint recorded, NOT the step that failed, and the run's exit code (only when recorded) is
    # printed NEXT TO it, never as though it belonged to the phase. 2026-11-21: a release exited 1 (its
    # post-deploy gate returned `incomplete`) while last-phase still read `github`, and `phase=github`
    # was read by a human as "the GitHub step failed".
    Write-Output "== RELEASES   (state = the run outcome; last-phase = the last checkpoint recorded, NOT the step that failed; exit = the run's own exit code when recorded)"
    foreach ($r in $v.releases) {
      $extra = @(); if ($r.supersedeSha) { $extra += "supersede->$(Short $r.supersedeSha)" }; if ($r.pendingSha) { $extra += "pending->$(Short $r.pendingSha)" }
      $exitCode = (P $r 'exitCode' $null)
      $exitTxt = if ($null -ne $exitCode) { "exit=$exitCode" } else { 'exit=?' }
      Write-Output ("{0,-28} {1,-11} {2,-10} {3} last-phase={4}{5} follow={6} {7} {8}" -f "$($r.repo)/$($r.target)", "$($r.state)".ToUpper(), (Short $r.sha), $exitTxt, $r.phase, $(if ($r.committed) { ' (committed)' } else { ' (preemptible)' }), $r.follow, $r.session, ($extra -join ' '))
    }
  }
  $lost = @(Get-RecentLeaseLosses 24)
  if ($lost.Count) {
    Write-Output '== LEASES LOST (24 h) - restore from the ref'
    $lost | Format-Table @{n = 'when'; e = { "$($_.ts)".Substring(0, 16) } }, event, resource, holderSession, purpose, ref -AutoSize | Out-String -Width 220 | Write-Output
  }
  if ($v.leases) {
    Write-Output '== SLOTS (leases)'
    # chatMin = minutes since the last tool call of a chat bound to the slot (OQ-001); '-' = no chat bound.
    # 'chat' state = the owner shell is gone and a live chat is what keeps the lease.
    $v.leases | Sort-Object repo, slot | Format-Table @{n = 'slot'; e = { "$($_.repo)/$($_.slot)" } }, role, @{n = 'state'; e = { if ($_.stale) { 'STALE' } elseif (-not $_.alive -and $null -ne $_.chatIdleMin -and $_.chatIdleMin -le 30) { 'chat' } elseif (-not $_.alive) { 'owner-gone' } else { 'ok' } } }, idleMin, @{n = 'chatMin'; e = { if ($null -ne $_.chatIdleMin) { $_.chatIdleMin } else { '-' } } }, branch, session, purpose, leaseId -AutoSize | Out-String -Width 230 | Write-Output
  }
}
function ConvertTo-V2Json($v) {
  @{
    leases = @($v.leases | ForEach-Object { [pscustomobject]@{
        leaseId = $_.leaseId; repo = $_.repo; slot = $_.slot; role = $_.role
        # state mirrors Format-V2Status' == SLOTS column (the table and the JSON must agree).
        state = $(if ($_.stale) { 'STALE' } elseif (-not $_.alive -and $null -ne $_.chatIdleMin -and $_.chatIdleMin -le 30) { 'chat' } elseif (-not $_.alive) { 'owner-gone' } else { 'ok' })
        idleMin = $_.idleMin; chatIdleMin = $_.chatIdleMin; branch = $_.branch; session = $_.session; purpose = $_.purpose
        path = $_.path; pid = $_.pid; created = $_.created; beat = (Iso $_.beat); alive = $_.alive; stale = $_.stale } })
    releases = @($v.releases | ForEach-Object { $_ | Select-Object * -ExcludeProperty file })
  }
}
