<#
agentq — cross-agent coordination for builds, deploys, installs and commits on this machine.

WHY: many agents share one clone (and its worktrees). Before this, every lock was
poll-and-race, per worktree, with no reason field and no shared history, so builds
corrupted each other's .next/.turbo, deploys raced, a commit swept another agent's
staged files, and nobody could see who held what or why (incidents 2026-09-03..27).

MODEL
  * A RESOURCE is a string: build:<repo>, build:machine (capacity 2), install:<repo>,
    commit:<repo>, deploy:<repo>:<target>, or anything you name. <repo> is the name of
    the COMMON git dir's parent, so every worktree of one repo shares its resources.
  * A TICKET is a waiter/holder: one JSON file per ticket in
    ~/.codai/coord/queues/<resource>/<seq>-<id>.json. FIFO order = seq, allocated under a
    named OS mutex (Global\agentq-<resource>) so two processes never get the same seq.
  * The first <capacity> live tickets in seq order HOLD the resource. The rest wait.
  * Liveness: holder pid + its process start time (PID-reuse safe) + a heartbeat file
    touched every 20 s by `run`. A dead pid is reaped at once; a heartbeat older than
    -StaleMin (default 10) marks the ticket STALE (visible in status, reason recorded);
    `agentq break` removes it with a reason.
  * A resource can be MARKED frozen|blocked with a reason (~/.codai/coord/marks/). `run`
    and `acquire` refuse a frozen/blocked resource and print who froze it and why.
  * Everything is appended to ~/.codai/coord/journal.jsonl (one JSON per line):
    queued, start, done(exit,dur), fail, break, mark, unmark, note, commit(sha,paths).
    `status`, `log`, `since` read it — this is how agents learn what others did.

COMMANDS (all accept -Repo <path>; default = current dir's repo. -ExpectRepo <path> or
          env AGENTQ_EXPECT_REPO refuses (exit 3) when the resolved repo differs — X-02)
  agentq run     -Resource build -Purpose "why" -- <command...>   queue, hold, run, release
                  -Resource may be a short kind (build|install|deploy:<target>|commit) —
                  expanded to <kind>:<repo>; build also takes build:machine (cap 2) and
                  waits for >= -MinFreeGB RAM (default 6).
  agentq commit  -Purpose "why" -Message "type(scope): msg" -Paths a,b [-NoPush]
                  under commit:<repo>: add+commit ONLY those paths, trailers
                  Agent-Session / Agent-Purpose, then fetch+merge+push with retry.
  agentq status  [-All]            holders, waiters, stale, marks (this repo or all)
  agentq log     [-Last 30] [-All] recent journal entries
  agentq since   [-Hours 12]       what changed in this repo: journal + git log
  agentq mark    -Resource R -State frozen|blocked -Reason "..."   (unmark: -State clear)
  agentq break   -Resource R [-Id <ticket>] -Reason "..."          remove a stale/stuck ticket
  agentq note    -Message "..."    free-form journal entry (handoffs, "don't touch X")
  agentq acquire / release         low-level (scripts): acquire prints the ticket id

EXIT CODES: 0 ok; command's own exit code for `run`; 3 = frozen/blocked or timed out;
2 = usage error.
#>
# Hand-rolled argument parsing: `pwsh -File agentq.ps1 run ... -- cmd -x` passes `--` and
# the command's own dashed flags to the script, which PowerShell's binder rejects
# ("parameter name '' is ambiguous"). Everything after the first `--` is the command.
$Verb = 'status'; $Resource = $null; $Purpose = $null; $Message = $null; $Paths = @()
$Repo = $null; $ExpectRepo = $null; $State = $null; $Reason = $null; $Id = $null
$Capacity = 1; $TimeoutMin = 60; $StaleMin = 10; $Last = 30; $Hours = 12; $MinFreeGB = 6
$All = $false; $NoPush = $false; $NoWait = $false; $Json = $false; $CapacityGiven = $false
# v2 (ADR 0001): slots/leases, release runs, landing (implemented in agentq-v2.ps1).
$Slot = $null; $Role = $null; $WtPath = $null; $Branch = $null; $Onto = $null; $Gate = $null
$Phase = $null; $Unsafe = $false; $Target = $null; $Sha = $null; $Ref = $null; $Follow = $null
$RunId = $null; $OwnerPid = 0; $LeaseId = $null; $Also = @()
$Rest = @()
$argv = @($args)
$dd = [array]::IndexOf($argv, '--')
if ($dd -ge 0) { $Rest = @($argv | Select-Object -Skip ($dd + 1)); $argv = @($argv | Select-Object -First $dd) }
$i = 0
if ($argv.Count -and "$($argv[0])" -notlike '-*') { $Verb = "$($argv[0])"; $i = 1 }
while ($i -lt $argv.Count) {
  $a = "$($argv[$i])"
  $name = $a.TrimStart('-').ToLowerInvariant()
  $next = { if ($i + 1 -ge $argv.Count) { throw "agentq: $a needs a value" }; $script:i++; "$($argv[$script:i])" }
  switch ($name) {
    'resource' { $Resource = & $next }
    'purpose' { $Purpose = & $next }
    'message' { $Message = & $next }
    'paths' { $Paths = @((& $next) -split ',') }
    'repo' { $Repo = & $next }
    'expectrepo' { $ExpectRepo = & $next }
    'state' { $State = & $next }
    'reason' { $Reason = & $next }
    'id' { $Id = & $next }
    'capacity' { $Capacity = [int](& $next); $CapacityGiven = $true }
    'timeoutmin' { $TimeoutMin = [int](& $next) }
    'stalemin' { $StaleMin = [int](& $next) }
    'last' { $Last = [int](& $next) }
    'hours' { $Hours = [double](& $next) }
    'minfreegb' { $MinFreeGB = [double](& $next) }
    'all' { $All = $true }
    'nopush' { $NoPush = $true }
    'nowait' { $NoWait = $true }
    'json' { $Json = $true }
    'slot' { $Slot = & $next }
    'role' { $Role = & $next }
    'path' { $WtPath = & $next }
    'branch' { $Branch = & $next }
    'onto' { $Onto = & $next }
    'gate' { $Gate = & $next }
    'phase' { $Phase = & $next }
    'unsafe' { $Unsafe = $true }
    'target' { $Target = & $next }
    'sha' { $Sha = & $next }
    'ref' { $Ref = & $next }
    'follow' { $Follow = & $next }
    'runid' { $RunId = & $next }
    'ownerpid' { $OwnerPid = [int](& $next) }
    'leaseid' { $LeaseId = & $next }
    'also' { $Also = @((& $next) -split ',' | Where-Object { $_ }) }
    default { throw "agentq: unknown argument '$a' (put the command after --)" }
  }
  $i++
}$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
$QDir = Join-Path $Root 'queues'
$MDir = Join-Path $Root 'marks'
$Journal = Join-Path $Root 'journal.jsonl'
foreach ($d in $Root, $QDir, $MDir) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force $d | Out-Null } }

# Machine-wide capacities for named resources (override with -Capacity on first use).
$DefaultCapacity = @{ 'build:machine' = 2 }

function Now { [DateTime]::UtcNow }
function Iso([datetime]$d) { $d.ToUniversalTime().ToString('o') }
# ISO strings from our own files are UTC; a bare [datetime] cast converts them to LOCAL time
# (3 h off here), which made every holder look dead/stale. Always parse through this.
function ParseUtc($s) { if ($s -is [datetime]) { return $s.ToUniversalTime() }; [DateTimeOffset]::Parse("$s", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }

function Get-SessionId {
  foreach ($v in $env:AGENTQ_SESSION, $env:COPILOT_SESSION_ID, $env:CLAUDE_SESSION_ID) { if ($v) { return $v } }
  # Stable per terminal: the parent shell pid. Get-Process .Parent costs ~20 ms; the CIM query it
  # replaced cost ~570 ms on EVERY agentq call (measured 2026-10-06).
  $pp = try { (Get-Process -Id $PID).Parent.Id } catch { 0 }
  "term-$pp"
}
$Session = Get-SessionId

function Get-RepoInfo([string]$path) {
  $p = if ($path) { $path } else { (Get-Location).Path }
  $top = (& git -C $p rev-parse --show-toplevel 2>$null)
  if (-not $top) { return $null }
  $common = (& git -C $p rev-parse --path-format=absolute --git-common-dir 2>$null)
  $name = Split-Path (Split-Path $common -Parent) -Leaf
  [pscustomobject]@{ Top = ($top -replace '/', '\'); Common = ($common -replace '/', '\'); Name = $name.ToLowerInvariant() }
}

# X-02 (2026-10-05): run_in_terminal sometimes DROPS a leading Set-Location, so a commit/build
# meant for a worktree ran in the shared clone (twice: brivio SW-0302, codai). -ExpectRepo <dir>
# (or env AGENTQ_EXPECT_REPO) refuses unless the resolved repo top equals it.
function Assert-ExpectedRepo($repo) {
  $want = if ($ExpectRepo) { $ExpectRepo } elseif ($env:AGENTQ_EXPECT_REPO) { $env:AGENTQ_EXPECT_REPO } else { $null }
  if (-not $want) { return }
  $w = (Get-RepoInfo $want)
  $wTop = if ($w) { $w.Top } else { $want }
  $norm = { param($p) ([IO.Path]::GetFullPath("$p").TrimEnd('\', '/')).ToLowerInvariant() }
  if (-not $repo -or (& $norm $repo.Top) -ne (& $norm $wTop)) {
    $got = if ($repo) { $repo.Top } else { '(no repo)' }
    [Console]::Error.WriteLine("agentq: REFUSED - expected repo '$wTop' but this runs in '$got' (cwd $((Get-Location).Path)). A dropped Set-Location? Pass -Repo '$wTop'.")
    exit 3
  }
}

function Resolve-Resource([string]$r, $repo) {
  if (-not $r) { throw 'agentq: -Resource is required' }
  if ($r -match ':') {
    # deploy:<target> (no repo) -> deploy:<repo>:<target>; anything with 2+ colons is literal.
    if ($r -match '^(deploy):([^:]+)$' -and $repo) { return "deploy:$($repo.Name):$($Matches[2])" }
    return $r.ToLowerInvariant()
  }
  if (-not $repo) { throw "agentq: '$r' needs a repo (run inside a git repo or pass -Repo)" }
  "$($r.ToLowerInvariant()):$($repo.Name)"
}

function Safe([string]$s) { ($s -replace '[^A-Za-z0-9._-]', '_') }
function QPath([string]$res) { Join-Path $QDir (Safe $res) }

function Write-Journal([hashtable]$e) {
  $e.ts = Iso (Now); if (-not $e.ContainsKey('session')) { $e.session = $Session }
  $line = ($e | ConvertTo-Json -Compress -Depth 6)
  $m = [Threading.Mutex]::new($false, 'Global\agentq-journal')
  try { [void]$m.WaitOne(5000); [IO.File]::AppendAllText($Journal, $line + "`n", [Text.UTF8Encoding]::new($false)) }
  finally { try { $m.ReleaseMutex() } catch {} ; $m.Dispose() }
}

function Get-ProcStart([int]$procId) {
  try { (Get-Process -Id $procId -ErrorAction Stop).StartTime.ToUniversalTime() } catch { $null }
}

function Test-Alive($t) {
  $st = Get-ProcStart ([int]$t.pid)
  if (-not $st) { return $false }
  if ($t.procStart) { return ([math]::Abs(($st - (ParseUtc $t.procStart)).TotalSeconds) -lt 3) }
  $true
}

function Read-Tickets([string]$res) {
  $dir = QPath $res
  if (-not (Test-Path $dir)) { return @() }
  @(Get-ChildItem $dir -Filter '*.json' -File | Sort-Object Name | ForEach-Object {
      try {
        $raw = $null
        for ($r = 0; $r -lt 5; $r++) {
          try { $raw = Get-Content $_.FullName -Raw -ErrorAction Stop; if ($raw) { $raw | ConvertFrom-Json | Out-Null; break } } catch { $raw = $null }
          Start-Sleep -Milliseconds 50
        }
        if (-not $raw) {
          if (-not (Test-Path $_.FullName)) { return }  # released meanwhile
          # Fail closed: hold the slot with a placeholder that looks alive (pid = us).
          [pscustomobject]@{ id = "unreadable-$($_.BaseName)"; resource = $res; pid = $PID; procStart = $null; session = '?'; purpose = 'unreadable ticket'; created = (Iso (Now)); file = $_.FullName; beat = (Now) }
          return
        }
        $t = $raw | ConvertFrom-Json -DateKind String
        $t | Add-Member -NotePropertyName file -NotePropertyValue $_.FullName -Force
        $hb = "$($_.FullName).hb"
        $beat = if (Test-Path $hb) { (Get-Item $hb).LastWriteTimeUtc } else { (ParseUtc $t.created) }
        $t | Add-Member -NotePropertyName beat -NotePropertyValue $beat -Force
        $t
      } catch { $null }
    } | Where-Object { $_ })
}

function Remove-Ticket($t, [string]$why, [string]$kind = 'reap') {
  Remove-Item -LiteralPath $t.file, "$($t.file).hb" -Force -ErrorAction SilentlyContinue
  Write-Journal @{ event = $kind; resource = $t.resource; ticket = $t.id; holderSession = $t.session; purpose = $t.purpose; reason = $why }
}

# Reap dead holders; flag stale ones. Returns live tickets in FIFO order.
function Get-Live([string]$res) {
  $out = @()
  foreach ($t in Read-Tickets $res) {
    if (-not (Test-Alive $t)) { Remove-Ticket $t "holder pid $($t.pid) is gone"; continue }
    $age = ((Now) - (ParseUtc $t.beat)).TotalMinutes
    $t | Add-Member -NotePropertyName stale -NotePropertyValue ($age -gt $StaleMin) -Force
    $t | Add-Member -NotePropertyName beatAgeMin -NotePropertyValue ([math]::Round($age, 1)) -Force
    $out += $t
  }
  $out
}

function Get-Capacity([string]$res) {
  $f = Join-Path (QPath $res) 'capacity'
  if (Test-Path $f) { return [int](Get-Content $f -Raw) }
  if ($DefaultCapacity.ContainsKey($res)) { return $DefaultCapacity[$res] }
  1
}

function Get-Mark([string]$res) {
  $f = Join-Path $MDir ((Safe $res) + '.json')
  if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json -DateKind String } else { $null }
}

function Assert-NotMarked([string]$res) {
  $m = Get-Mark $res
  if ($m) {
    [Console]::Error.WriteLine("agentq: $res is $($m.state.ToUpper()) since $($m.at) by $($m.session): $($m.reason)")
    [Console]::Error.WriteLine("        clear it (only if the reason no longer holds): agentq mark -Resource $res -State clear -Reason '<why>'")
    exit 3
  }
}

function New-Ticket([string]$res, [string]$purpose, [string]$cmd, [string]$repoTop) {
  $dir = QPath $res
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  if ($script:CapacityGiven -or -not (Test-Path (Join-Path $dir 'capacity'))) {
    $cap = if ($script:Capacity -gt 1) { $script:Capacity } else { Get-Capacity $res }
    [IO.File]::WriteAllText((Join-Path $dir 'capacity'), "$cap")
  }
  $m = [Threading.Mutex]::new($false, "Global\agentq-$(Safe $res)")
  try {
    [void]$m.WaitOne(10000)
    $seqFile = Join-Path $dir 'seq'
    $seq = if (Test-Path $seqFile) { [long](Get-Content $seqFile -Raw) + 1 } else { 1 }
    # NOT `Set-Content -NoNewline <path> <v>`: in pwsh 7.6 that positional form writes NOTHING,
    # so seq never advanced, every ticket got seq 1 and two holders ran at once.
    [IO.File]::WriteAllText($seqFile, "$seq")
    $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
    # The holder is the long-lived process: this pwsh running `agentq run` (it spawns and
    # waits for the command). For acquire/release from a script, pass the owning PID via
    # $env:AGENTQ_OWNER_PID.
    $owner = if ($env:AGENTQ_OWNER_PID) { [int]$env:AGENTQ_OWNER_PID } else { $PID }
    $t = [ordered]@{
      id = $id; seq = $seq; resource = $res; pid = $owner; procStart = (Iso (Get-ProcStart $owner))
      session = $Session; purpose = $purpose; cmd = $cmd; repo = $repoTop; host = $env:COMPUTERNAME
      created = (Iso (Now))
    }
    $file = Join-Path $dir ('{0:D8}-{1}.json' -f $seq, $id)
    # Atomic publish: a reader must never see a half-written ticket (it would parse-fail,
    # be skipped, and the next waiter would think it is first — observed as an overlap).
    [IO.File]::WriteAllText("$file.hb", '', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText("$file.tmp", ($t | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    [IO.File]::Move("$file.tmp", $file)
    [pscustomobject]$t | Add-Member -NotePropertyName file -NotePropertyValue $file -PassThru
  } finally { try { $m.ReleaseMutex() } catch {} ; $m.Dispose() }
}

function Wait-Turn($ticket, [int]$timeoutMin, [scriptblock]$extraGate, [object[]]$heldTickets = @()) {
  $deadline = (Now).AddMinutes($timeoutMin)
  $announced = $false
  while ($true) {
    Assert-NotMarked $ticket.resource
    [IO.File]::SetLastWriteTimeUtc("$($ticket.file).hb", (Now))
    # Tickets already held (build:<repo> while waiting for build:machine) must keep beating too:
    # otherwise a long machine wait makes the repo hold look STALE and another agent breaks it.
    foreach ($h in $heldTickets) { try { [IO.File]::SetLastWriteTimeUtc("$($h.file).hb", (Now)) } catch {} }
    $live = @(Get-Live $ticket.resource)
    $cap = Get-Capacity $ticket.resource
    $pos = [array]::IndexOf(@($live | ForEach-Object id), $ticket.id)
    if ($pos -lt 0) { throw "agentq: ticket $($ticket.id) vanished from $($ticket.resource) (broken by another agent? see agentq log)" }
    $gateOk = if ($extraGate) { & $extraGate } else { $true }
    if ($pos -lt $cap -and $gateOk) { return }
    if (-not $announced -or ((Now).Second % 30 -lt 3)) {
      $ahead = @($live | Select-Object -First $pos)
      $holders = @($live | Select-Object -First $cap | Where-Object { $_.id -ne $ticket.id })
      $who = ($holders | ForEach-Object { "$($_.session) '$($_.purpose)' $([math]::Round(((Now) - (ParseUtc $_.created)).TotalMinutes,1))m$(if ($_.stale) { ' STALE' })" }) -join '; '
      $gateMsg = if (-not $gateOk) { ' (waiting for free RAM)' } else { '' }
      [Console]::Error.WriteLine("agentq: waiting for $($ticket.resource) — position $($pos + 1 - $cap + 1)/$([math]::Max(1,$live.Count - $cap + 1)), $($ahead.Count) ahead; held by: $who$gateMsg")
      $announced = $true
    }
    if ((Now) -gt $deadline) {
      Remove-Ticket $ticket "timed out after $timeoutMin min" 'timeout'
      foreach ($h in $heldTickets) { Remove-Ticket $h "released: timed out waiting for $($ticket.resource)" 'timeout' }
      [Console]::Error.WriteLine("agentq: gave up waiting for $($ticket.resource) after $timeoutMin min")
      exit 3
    }
    Start-Sleep -Milliseconds 2000
  }
}

function Test-FreeRam([double]$gb) {
  $os = Get-CimInstance Win32_OperatingSystem
  # Commit charge too: 2026-09-30 "memory allocation failed" with 50 GB RAM free because the commit
  # limit was exhausted (vmmemWSL). FreeVirtualMemory = commit limit - committed (KB).
  $commitGb = [double](Get-Config).minFreeCommitGB
  (($os.FreePhysicalMemory / 1MB) -ge $gb) -and ($gb -le 0 -or $commitGb -le 0 -or ($os.FreeVirtualMemory / 1MB) -ge $commitGb)
}

function Expand-Resources([string]$kind, $repo) {
  $primary = Resolve-Resource $kind $repo
  $list = @($primary)
  if ($primary -like 'build:*' -and $primary -ne 'build:machine') { $list += 'build:machine' }
  foreach ($a in $Also) { $list += (Resolve-Resource $a $repo) }
  $list
}

function Get-SignalUrl { 'http://127.0.0.1:3737/api/copilot/event' }
function Send-Signal([string]$ev, [string]$text) {
  if ($env:AGENTQ_NO_SIGNAL) { return }
  try {
    $body = @{ event = $ev; source = 'agentq'; message = $text } | ConvertTo-Json -Compress
    Invoke-RestMethod -Uri (Get-SignalUrl) -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 1 | Out-Null
  } catch {}
}

# ---------------------------------------------------------------------------------------
function Invoke-Run {
  $repo = Get-RepoInfo $Repo
  Assert-ExpectedRepo $repo
  if (-not $Resource) { throw 'agentq run: -Resource build|install|commit|deploy:<target>|<literal> is required' }
  if (-not $Purpose) { throw 'agentq run: -Purpose "<why>" is required (other agents read it)' }
  $cmdArgs = @($Rest | Where-Object { $_ -ne '--' })
  if (-not $cmdArgs) { throw 'agentq run: nothing to run (agentq run -Resource build -Purpose x -- <command>)' }
  $cmdLine = ($cmdArgs -join ' ')
  $resList = @(Expand-Resources $Resource $repo)
  foreach ($r in $resList) { Assert-NotMarked $r }
  $tickets = @()
  $started = Now
  try {
    # Queue for each resource only once the previous one is HELD. Creating every ticket up front
    # put a build:machine ticket in the first two positions while its run still waited for
    # build:<repo>: a phantom machine hold with no heartbeat, starving everyone (2026-09-30).
    foreach ($r in $resList) {
      $t = New-Ticket $r $Purpose $cmdLine ($repo.Top)
      $heldSoFar = @($tickets)
      $tickets += $t   # before waiting, so the finally below removes it on Ctrl+C or an exception
      Write-Journal @{ event = 'queued'; resource = $r; ticket = $t.id; purpose = $Purpose; cmd = $cmdLine; repo = $repo.Name }
      $gate = if ($t.resource -eq 'build:machine' -and $MinFreeGB -gt 0) { { Test-FreeRam $MinFreeGB } } else { $null }
      if ($NoWait) {
        $live = @(Get-Live $t.resource)
        if ([array]::IndexOf(@($live | ForEach-Object id), $t.id) -ge (Get-Capacity $t.resource)) {
          $h = @($live)[0]
          Remove-Ticket $t 'busy (-NoWait)' 'giveup'
          [Console]::Error.WriteLine("agentq: $($t.resource) is busy: $($h.session) '$($h.purpose)' since $($h.created)")
          exit 3
        }
      } else { Wait-Turn $t $TimeoutMin $gate $heldSoFar }
    }
    $held = ($resList -join ',')
    Write-Journal @{ event = 'start'; resource = $held; tickets = @($tickets | ForEach-Object id); purpose = $Purpose; cmd = $cmdLine; repo = $repo.Name }
    Send-Signal 'agentq-start' "$held — $Purpose"
    $env:AGENTQ_HELD = (@($env:AGENTQ_HELD, $held) | Where-Object { $_ }) -join ','
    $env:AGENTQ_PURPOSE = $Purpose
    $env:AGENTQ_SESSION = $Session

    # Heartbeat: a background job touches every ticket's .hb file every 20 s.
    $hbFiles = @($tickets | ForEach-Object { "$($_.file).hb" })
    $hb = Start-ThreadJob -ArgumentList (, $hbFiles) -ScriptBlock {
      param($files)
      while ($true) { foreach ($f in $files) { try { [IO.File]::SetLastWriteTimeUtc($f, [DateTime]::UtcNow) } catch {} }; Start-Sleep -Seconds 20 }
    }
    try {
      $exe = $cmdArgs[0]; $argv = @($cmdArgs | Select-Object -Skip 1)
      & $exe @argv
      $code = if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } elseif ($?) { 0 } else { 1 }
    } finally { Stop-Job $hb -ErrorAction SilentlyContinue; Remove-Job $hb -Force -ErrorAction SilentlyContinue }
    $dur = [math]::Round(((Now) - $started).TotalSeconds)
    Write-Journal @{ event = $(if ($code -eq 0) { 'done' } else { 'fail' }); resource = $held; exit = $code; durSec = $dur; purpose = $Purpose; cmd = $cmdLine; repo = $repo.Name }
    if ($code -ne 0) { Send-Signal 'agentq-fail' "$held failed ($code) — $Purpose" }
    exit $code
  } finally {
    foreach ($t in $tickets) { Remove-Item -LiteralPath $t.file, "$($t.file).hb" -Force -ErrorAction SilentlyContinue }
  }
}

function Invoke-Commit {
  $repo = Get-RepoInfo $Repo
  Assert-ExpectedRepo $repo
  if (-not $repo) { throw 'agentq commit: not in a git repo' }
  if (-not $Purpose) { throw 'agentq commit: -Purpose is required' }
  if (-not $Message) { throw 'agentq commit: -Message is required' }
  $plist = @($Paths | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  if (-not $plist) { throw 'agentq commit: -Paths a,b,c is required (explicit paths only — never the whole index)' }
  $outside = @($plist | Where-Object { [IO.Path]::IsPathRooted($_) -and -not ([IO.Path]::GetFullPath($_).ToLowerInvariant().StartsWith($repo.Top.ToLowerInvariant() + '\')) })
  if ($outside) { [Console]::Error.WriteLine("agentq: REFUSED - paths outside $($repo.Top): $($outside -join ', ')"); exit 3 }
  $res = "commit:$($repo.Name)"
  Assert-NotMarked $res
  $t = New-Ticket $res $Purpose "commit $($plist -join ' ')" $repo.Top
  Write-Journal @{ event = 'queued'; resource = $res; ticket = $t.id; purpose = $Purpose; paths = $plist; repo = $repo.Name }
  try {
    Wait-Turn $t $TimeoutMin $null
    $env:AGENTQ_HELD = (@($env:AGENTQ_HELD, $res) | Where-Object { $_ }) -join ','
    $env:AGENTQ_PURPOSE = $Purpose; $env:AGENTQ_SESSION = $Session
    Push-Location $repo.Top
    try {
      # A worktree installed with `pnpm install --ignore-scripts` has core.hooksPath=.husky/_ but no
      # .husky/_/pre-commit: git then runs NO hook, silently (brivio 2026-09-29, three times). Refuse
      # instead of committing ungated; the fix is one command.
      $hp = (& git config --get core.hooksPath 2>$null)
      if ($hp -and -not $env:SKIP_HOOKS -and -not $env:FAST_COMMIT) {
        $hookDir = if ([IO.Path]::IsPathRooted($hp)) { $hp } else { Join-Path $repo.Top $hp }
        $hpParent = Split-Path $hp -Parent
        # Single-segment hooksPath (e.g. '.githooks'): parent is '' and Join-Path would throw.
        $declared = if ($hpParent) { Join-Path $repo.Top (Join-Path $hpParent 'pre-commit') } else { Join-Path $repo.Top 'pre-commit' }
        if ((Test-Path -LiteralPath $declared) -and -not (Test-Path -LiteralPath (Join-Path $hookDir 'pre-commit'))) {
          throw "agentq commit: core.hooksPath='$hp' has no pre-commit (hooks would be skipped silently). Run 'pnpm exec husky' in $($repo.Top) first."
        }
      }
      # Stage and commit in ONE critical section, pathspec-limited: a commit without a
      # pathspec takes EVERYTHING staged, including other agents' files (7cc672f7).
      # Deleted paths cannot be `git add`-ed ("pathspec did not match", 2026-09-28):
      # stage those with `git rm --cached`, still limited to @plist.
      # X-03 (2026-10-05): remember what was staged BEFORE we touch the index, so a rejected
      # commit can unstage exactly the paths we added (a later amend swallowed them, 2026-10-02).
      $preStaged = @(& git diff --cached --name-only -- @plist)
      $gone = @($plist | Where-Object { -not (Test-Path -LiteralPath $_) })
      $live = @($plist | Where-Object { Test-Path -LiteralPath $_ })
      if ($live.Count) { & git add -- @live; if ($LASTEXITCODE) { throw "git add failed ($LASTEXITCODE)" } }
      if ($gone.Count) { & git rm -q --cached --ignore-unmatch -- @gone; if ($LASTEXITCODE) { throw "git rm failed ($LASTEXITCODE)" } }
      $msg = "$Message`n`nAgent-Session: $Session`nAgent-Purpose: $Purpose"
      $tmp = [IO.Path]::GetTempFileName()
      [IO.File]::WriteAllText($tmp, $msg, [Text.UTF8Encoding]::new($false))
      & git commit -q -F $tmp -- @plist
      $cc = $LASTEXITCODE; Remove-Item $tmp -Force
      if ($cc) {
        $ours = @(& git diff --cached --name-only -- @plist | Where-Object { $preStaged -notcontains $_ })
        if ($ours.Count) { & git reset -q -- @ours 2>$null }
        throw "git commit failed ($cc) — nothing committed; unstaged $($ours.Count) path(s) agentq had staged"
      }
      $sha = (& git rev-parse --short HEAD).Trim()
      $files = @(& git show --name-only --format= HEAD)
      $foreign = @($files | Where-Object { $f = $_; -not ($plist | Where-Object { $f -like "$($_ -replace '\\','/')*" }) })
      Write-Journal @{ event = 'commit'; resource = $res; sha = $sha; purpose = $Purpose; message = $Message; paths = $files; foreign = $foreign; repo = $repo.Name }
      if ($foreign) { [Console]::Error.WriteLine("agentq: WARNING commit $sha also contains files outside -Paths: $($foreign -join ', ')") }
      Write-Output "committed $sha ($($files.Count) files)"
      if (-not $NoPush) {
        $branch = (& git rev-parse --abbrev-ref HEAD).Trim()
        $pushed = $false
        for ($i = 1; $i -le 4 -and -not $pushed; $i++) {
          $pushOut = @(& git push -q origin "HEAD:$branch" 2>&1 | ForEach-Object { "$_" })
          if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
          # Only a lost race (remote moved) is worth fetch+merge+retry. A pre-push hook
          # rejection (failing gates) would re-run the gates 4x in silence and look frozen.
          if (-not ($pushOut -match 'non-fast-forward|fetch first|rejected .*\(stale|Updates were rejected')) {
            $pushOut | Select-Object -Last 25 | ForEach-Object { [Console]::Error.WriteLine($_) }
            Write-Journal @{ event = 'push-failed'; resource = $res; sha = $sha; branch = $branch; repo = $repo.Name }
            throw "push failed (not a race: pre-push hook or remote refused; output above). Commit $sha is local - fix and push again."
          }
          & git fetch -q origin $branch
          # A merge in a shared clone must never touch another agent's uncommitted files.
          # Distinguish a real content conflict from "incoming change overlaps a dirty file".
          $incoming = @(& git diff --name-only "HEAD...origin/$branch")
          $dirtyNow = @(& git status --porcelain | ForEach-Object { $_.Substring(3).Trim('"') })
          $overlap = @($incoming | Where-Object { $dirtyNow -contains $_ })
          if ($overlap) {
            Write-Journal @{ event = 'push-deferred'; resource = $res; sha = $sha; branch = $branch; overlap = $overlap; repo = $repo.Name }
            throw "push deferred: origin/$branch changes files with UNCOMMITTED local edits (other agents'): $($overlap -join ', '). Commit $sha stays local and rides the next push from this clone; do NOT stash/reset them."
          }
          & git merge-tree --write-tree HEAD "origin/$branch" *> $null
          if ($LASTEXITCODE) { throw "push rejected: merge of origin/$branch has content conflicts — resolve by hand (commit $sha is local)" }
          $mergeOut = @(& git merge -q --no-edit "origin/$branch" 2>&1 | ForEach-Object { "$_" })
          $mergeCode = $LASTEXITCODE
          if ($mergeCode) {
            if (Test-Path (Join-Path (& git rev-parse --git-dir) 'MERGE_HEAD')) { & git merge --abort 2>$null }
            $mergeOut | Select-Object -Last 15 | ForEach-Object { [Console]::Error.WriteLine($_) }
            throw "push rejected: git merge origin/$branch failed ($mergeCode) — commit $sha is local"
          }
        }
        if (-not $pushed) { throw "push failed after 4 attempts (commit $sha is local)" }
        $head = (& git rev-parse --short HEAD).Trim()
        Write-Journal @{ event = 'push'; resource = $res; sha = $head; branch = $branch; repo = $repo.Name }
        Write-Output "pushed $head -> origin/$branch"
        $acts = @(Notify-Landing $repo.Name $branch "$(& git rev-parse HEAD)".Trim() '')
        if ($acts) { Write-Output "releases following origin/${branch}: $($acts -join ', ')" }
      }
    } finally { Pop-Location }
  } finally { Remove-Item -LiteralPath $t.file, "$($t.file).hb" -Force -ErrorAction SilentlyContinue }
}

function Show-Status {
  $repo = Get-RepoInfo $Repo
  $dirs = @(Get-ChildItem $QDir -Directory -ErrorAction SilentlyContinue)
  $rows = @()
  foreach ($d in $dirs) {
    $sample = Get-ChildItem $d.FullName -Filter '*.json' -File | Select-Object -First 1
    if (-not $sample) { continue }
    $res = (Get-Content $sample.FullName -Raw | ConvertFrom-Json -DateKind String).resource
    if (-not $All -and $repo -and $res -notmatch "(^|:)$([regex]::Escape($repo.Name))(:|$)" -and $res -ne 'build:machine') { continue }
    $live = @(Get-Live $res)
    $cap = Get-Capacity $res
    $i = 0
    foreach ($t in $live) {
      $rows += [pscustomobject]@{
        resource = $res; role = $(if ($i -lt $cap) { 'HOLD' } else { "wait#$($i - $cap + 1)" })
        state = $(if ($t.stale) { "STALE($($t.beatAgeMin)m)" } else { 'ok' })
        ageMin = [math]::Round(((Now) - (ParseUtc $t.created)).TotalMinutes, 1)
        session = $t.session; purpose = $t.purpose; id = $t.id
      }
      $i++
    }
  }
  $marks = @(Get-ChildItem $MDir -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json -DateKind String })
  $v2 = Get-V2Status $(if (-not $All -and $repo) { $repo.Name } else { $null })
  if ($Json) { $o = ConvertTo-V2Json $v2; $o.tickets = $rows; $o.marks = $marks; $o | ConvertTo-Json -Depth 5; return }
  if ($marks) {
    Write-Output '== MARKS'
    $marks | ForEach-Object { Write-Output ("{0,-34} {1,-8} since {2} by {3}: {4}" -f $_.resource, $_.state.ToUpper(), $_.at, $_.session, $_.reason) }
  }
  Format-V2Status $v2
  if ($rows) {
    Write-Output '== QUEUES'
    $rows | Format-Table resource, role, state, ageMin, session, purpose, id -AutoSize | Out-String -Width 220 | Write-Output
  } else { Write-Output "== QUEUES: idle$(if (-not $All -and $repo) { " for $($repo.Name) (use -All for every repo)" })" }
}

function Read-Journal([int]$n, $since, [string]$repoName) {
  if (-not (Test-Path $Journal)) { return @() }
  $lines = if ($n -gt 0) { Get-Content $Journal -Tail ([math]::Max($n * 8, 400)) } else { Get-Content $Journal }
  $items = @($lines | ForEach-Object { try { $_ | ConvertFrom-Json -DateKind String } catch { $null } } | Where-Object { $_ })
  if ($since) { $items = @($items | Where-Object { (ParseUtc $_.ts) -ge $since }) }
  if ($repoName) { $items = @($items | Where-Object { ($_.PSObject.Properties.Name -contains 'repo' -and $_.repo -eq $repoName) -or ("$($_.resource)" -match "(^|:)$([regex]::Escape($repoName))(:|$)") }) }
  if ($n -gt 0) { $items = @($items | Select-Object -Last $n) }
  $items
}

function Format-Entry($e) {
  $extra = @()
  foreach ($k in 'exit', 'durSec', 'sha', 'reason', 'state') { if ($e.PSObject.Properties.Name -contains $k -and "$($e.$k)") { $extra += "$k=$($e.$k)" } }
  $what = if ($e.PSObject.Properties.Name -contains 'purpose' -and $e.purpose) { $e.purpose } elseif ($e.PSObject.Properties.Name -contains 'message') { $e.message } else { '' }
  '{0} {1,-8} {2,-30} {3,-14} {4} {5}' -f ((ParseUtc $e.ts)).ToLocalTime().ToString('MM-dd HH:mm'), $e.event, "$($e.resource)", "$($e.session)".Substring(0, [math]::Min(14, "$($e.session)".Length)), $what, ($extra -join ' ')
}

function Show-Log {
  $repo = Get-RepoInfo $Repo
  $name = if ($All -or -not $repo) { $null } else { $repo.Name }
  $items = @(Read-Journal $Last $null $name)
  if ($Json) { $items | ConvertTo-Json -Depth 5; return }
  $items | ForEach-Object { Format-Entry $_ }
}

function Show-Since {
  $repo = Get-RepoInfo $Repo
  if (-not $repo) { throw 'agentq since: not in a git repo' }
  $from = (Now).AddHours(-$Hours)
  Write-Output "== agentq journal for $($repo.Name), last $Hours h"
  $items = @(Read-Journal 0 $from $repo.Name) | Where-Object { $_.event -notin 'queued', 'reap' }
  if ($items) { $items | ForEach-Object { Format-Entry $_ } } else { Write-Output '(no entries)' }
  Write-Output "== git log origin (last $Hours h)"
  & git -C $repo.Top fetch -q 2>$null
  $up = (& git -C $repo.Top rev-parse --abbrev-ref '@{u}' 2>$null)
  $ref = if ($up) { $up } else { 'HEAD' }
  & git -C $repo.Top log $ref --since="$([int]($Hours * 60)) minutes ago" --format='%h %ad %an %s' --date=format:'%m-%d %H:%M' -n 60
  Write-Output '== live queues'
  Show-Status
}

function Set-Mark {
  if (-not $Resource -or -not $State) { throw 'agentq mark -Resource <r> -State frozen|blocked|clear -Reason "..."' }
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  $f = Join-Path $MDir ((Safe $res) + '.json')
  if ($State -eq 'clear') {
    if (-not $Reason) { throw 'agentq mark -State clear needs -Reason (why it is safe again)' }
    Remove-Item $f -Force -ErrorAction SilentlyContinue
    Write-Journal @{ event = 'unmark'; resource = $res; reason = $Reason }
    Write-Output "cleared $res"; return
  }
  if ($State -notin 'frozen', 'blocked') { throw '-State must be frozen, blocked or clear' }
  if (-not $Reason) { throw 'agentq mark needs -Reason (other agents will read it)' }
  $m = [ordered]@{ resource = $res; state = $State; reason = $Reason; session = $Session; at = (Iso (Now)) }
  [IO.File]::WriteAllText($f, ($m | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
  Write-Journal @{ event = 'mark'; resource = $res; state = $State; reason = $Reason }
  Write-Output "$res marked $State"
}

function Invoke-Break {
  if (-not $Resource -or -not $Reason) { throw 'agentq break -Resource <r> [-Id <ticket>] -Reason "..."' }
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  $targets = @(Read-Tickets $res | Where-Object { -not $Id -or $_.id -eq $Id })
  # Without -Id, break only when the choice is unambiguous. "First ticket" once removed a live,
  # healthy holder instead of the STALE one next to it (2026-09-30).
  if (-not $Id -and $targets.Count -gt 1) {
    $list = ($targets | ForEach-Object { "$($_.id) $($_.session) '$($_.purpose)'" }) -join '; '
    [Console]::Error.WriteLine("agentq: $res has $($targets.Count) tickets - pass -Id <ticket>: $list")
    exit 2
  }
  if (-not $targets) { Write-Output "nothing to break on $res"; return }
  foreach ($t in $targets) {
    $alive = Test-Alive $t
    Remove-Ticket $t "$Reason$(if ($alive) { " (holder pid $($t.pid) was still ALIVE)" })" 'break'
    Write-Output "broke ticket $($t.id) on $res (held by $($t.session) '$($t.purpose)', alive=$alive)"
  }
}

function Invoke-Acquire {
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  if (-not $Purpose) { throw 'agentq acquire: -Purpose is required' }
  Assert-NotMarked $res
  $t = New-Ticket $res $Purpose "$($Rest -join ' ')" ($repo.Top)
  Write-Journal @{ event = 'queued'; resource = $res; ticket = $t.id; purpose = $Purpose }
  if ($NoWait) {
    $live = @(Get-Live $res)
    if ([array]::IndexOf(@($live | ForEach-Object id), $t.id) -ge (Get-Capacity $res)) { Remove-Ticket $t 'busy (-NoWait)' 'giveup'; exit 3 }
  } else { Wait-Turn $t $TimeoutMin $null }
  Write-Journal @{ event = 'start'; resource = $res; tickets = @($t.id); purpose = $Purpose }
  Write-Output $t.id
}

function Invoke-Release {
  $repo = Get-RepoInfo $Repo
  $res = Resolve-Resource $Resource $repo
  $t = @(Read-Tickets $res | Where-Object { $_.id -eq $Id })
  foreach ($x in $t) { Remove-Item -LiteralPath $x.file, "$($x.file).hb" -Force -ErrorAction SilentlyContinue }
  Write-Journal @{ event = 'done'; resource = $res; ticket = $Id; exit = 0 }
}

. (Join-Path $PSScriptRoot 'agentq-v2.ps1')
if ($Verb.ToLowerInvariant() -notin 'status', 'log', 'renew', 'lease-check') { Renew-ForCwd }

switch ($Verb.ToLowerInvariant()) {
  'run' { Invoke-Run }
  'commit' { Invoke-Commit }
  'status' { Show-Status }
  'log' { Show-Log }
  'since' { Show-Since }
  'mark' { Set-Mark }
  'break' { Invoke-Break }
  'note' {
    if (-not $Message) { throw 'agentq note -Message "..."' }
    $repo = Get-RepoInfo $Repo
    Write-Journal @{ event = 'note'; resource = $(if ($repo) { "note:$($repo.Name)" } else { 'note' }); message = $Message; repo = $(if ($repo) { $repo.Name } else { '' }) }
    Write-Output 'noted'
  }
  'acquire' { Invoke-Acquire }
  'release' { Invoke-Release }
  'lease' { Invoke-Lease }
  'unlease' { Invoke-Unlease }
  'renew' { Invoke-Renew }
  'sweep' { Invoke-Sweep }
  'lease-check' { Invoke-LeaseCheck }
  'backup' { Invoke-Backup }
  'release-begin' { Invoke-ReleaseBegin }
  'release-phase' { Invoke-ReleasePhase }
  'release-end' { Invoke-ReleaseEnd }
  'release-cancel' { Invoke-ReleaseCancel }
  'notify-landing' { Invoke-NotifyLanding }
  'land' { Invoke-Land; exit $script:LandExit }
  default { Get-Help $PSCommandPath; exit 2 }
}
