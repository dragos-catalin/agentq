<#
agentq-sync — mirror ~/.codai/coord to hub.codai.ro and bring hub marks back.

Every tick: POST /v1/agentq/sync on the codai gateway with this machine's live tickets,
current marks, the journal lines appended since the last accepted push, and the ids of
hub mark ops applied locally. The response lists hub ops not yet applied; each one is
written into marks/ in agentq.ps1 Set-Mark's exact shape (+ a journal line), so
`agentq run/acquire/commit` and the guard hook honour a freeze set in the hub.
Each pass also collects daemon health (default git-autosync; agentq-config.json
`autosync.daemons`) into <root>/daemons/<name>.json and a top-level `daemons` array.

Auth: a codai API key whose owner is super_admin, stored DPAPI-encrypted (CurrentUser)
in ~/.codai/agentq-sync.key. Never printed.

  agentq-sync.ps1 -SetKey              read the key from STDIN (pipe it; never echo it)
  agentq-sync.ps1 -Once [-DryRun]      one push (DryRun: print the payload summary, no POST)
  agentq-sync.ps1 -Loop [-IntervalSec 15]
  agentq-sync.ps1 -Install             scheduled task 'agentq-sync': ONE PUSH PER TICK (1-min repetition
                                       + at-logon, IgnoreNew, bounded run) so every tick loads the current
                                       code (a -Loop process keeps the copy it loaded at start; see the
                                       git-autosync DAEMON note, ADR 0010). Replaces any running model first.
  agentq-sync.ps1 -InstallLoop         the old long-lived -Loop task (warm, but the code is FROZEN at start)
  agentq-sync.ps1 -Status              state file + task state

Env: AGENTQ_HOME (like agentq.ps1), AGENTQ_SYNC_URL (default https://ai.codai.ro),
AGENTQ_SYNC_STATE (default ~/.codai/agentq-sync.state.json).
#>
param(
  [switch]$Once, [switch]$Loop, [switch]$Install, [switch]$InstallLoop, [switch]$SetKey, [switch]$Status, [switch]$DryRun,
  [int]$IntervalSec = 15, [string]$Url
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$Version = '2'
$MaxLines = 500
$Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
$QDir = Join-Path $Root 'queues'
$MDir = Join-Path $Root 'marks'
$Journal = Join-Path $Root 'journal.jsonl'
$KeyFile = Join-Path $HOME '.codai\agentq-sync.key'
$StateFile = if ($env:AGENTQ_SYNC_STATE) { $env:AGENTQ_SYNC_STATE } else { Join-Path $HOME '.codai\agentq-sync.state.json' }
$Base = if ($Url) { $Url } elseif ($env:AGENTQ_SYNC_URL) { $env:AGENTQ_SYNC_URL } else { 'https://ai.codai.ro' }
$Utf8 = [Text.UTF8Encoding]::new($false)
$DefaultCapacity = @{ 'build:machine' = 2 }
# Background-job registry (<root>/jobs/*.json, job-start.ps1). Optional: an install without the lib
# simply sends jobs = [] and a gateway that does not know `jobs` ignores the field.
$JobsLib = Join-Path $PSScriptRoot 'agentq-jobs-lib.ps1'
if (Test-Path -LiteralPath $JobsLib) { . $JobsLib }
# ADR 0009 stage 0 (OQ-004): this loop is the one resident agentq process, so it also takes the load
# sample (start latency of a trivial process) once a minute. Optional: without the file nothing changes.
$ProbeLib = Join-Path $PSScriptRoot 'agentq-probe.ps1'
if (Test-Path -LiteralPath $ProbeLib) { . $ProbeLib }
$script:ProbeAt = [DateTime]::MinValue
function Invoke-ProbeTick {
  if (-not (Get-Command Invoke-LoadProbe -ErrorAction SilentlyContinue)) { return }
  if (([DateTime]::UtcNow - $script:ProbeAt).TotalSeconds -lt 55) { return }
  $script:ProbeAt = [DateTime]::UtcNow
  try { $null = Invoke-LoadProbe $Root 50 12 'sync' } catch { }
}
function Get-Jobs {
  if (-not (Get-Command Get-JobsForSync -ErrorAction SilentlyContinue)) { return @() }
  try { @(Get-JobsForSync) } catch { [Console]::Error.WriteLine("agentq-sync: jobs skipped: $_"); @() }
}

# Daemon health (<root>/daemons/<name>.json + a top-level `daemons` array in the push). The list is
# fleet policy: agentq-config.json `autosync.daemons` (default just git-autosync). Each daemon is run
# with `-Doctor -Json`, which prints the frozen record { name, at, verdict, okCount, warnCount,
# failCount, lines, failStreak, history }; agentq-sync keeps history (cap 48, newest last) and
# failStreak current and writes the record back. A daemon that fails to run is SKIPPED, never a push
# failure. The tool is resolved next to this script (the source copy), or via AGENTQ_GIT_AUTOSYNC (tests).
$script:DaemonNamesComputed = $false; $script:DaemonNames = @()
function Get-DaemonNames {
  if ($script:DaemonNamesComputed) { return $script:DaemonNames }
  $names = @('git-autosync')
  $cfgPath = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $HOME '.copilot\bin\agentq-config.json' }
  if (Test-Path -LiteralPath $cfgPath) {
    try {
      $c = Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json -AsHashtable -DateKind String
      if ($c -is [System.Collections.IDictionary] -and $c.ContainsKey('autosync') -and $c['autosync'] -is [System.Collections.IDictionary] -and $c['autosync'].ContainsKey('daemons')) {
        $names = @($c['autosync']['daemons'] | ForEach-Object { "$_" })
      }
    } catch { }
  }
  $script:DaemonNames = @($names | Where-Object { $_ })
  $script:DaemonNamesComputed = $true
  $script:DaemonNames
}
function Get-DaemonTool([string]$name) {
  if ($name -eq 'git-autosync') {
    if ($env:AGENTQ_GIT_AUTOSYNC) { return $env:AGENTQ_GIT_AUTOSYNC }
    $local = Join-Path $PSScriptRoot 'git-autosync.ps1'
    if (Test-Path -LiteralPath $local) { return $local }
  }
  $null
}
# Run one daemon with `-Doctor -Json` and parse the ONE JSON line it prints. Bounded (60 s) and guarded:
# any failure (missing tool, crash, timeout, unparseable output) returns $null and the caller skips it.
function Get-DaemonRecord([string]$name) {
  $tool = Get-DaemonTool $name
  if (-not $tool -or -not (Test-Path -LiteralPath $tool)) { return $null }
  $psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
  foreach ($a in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $tool, '-Doctor', '-Json')) { $psi.ArgumentList.Add($a) }
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  try { $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8 } catch { }
  $p = $null
  try {
    $p = [Diagnostics.Process]::Start($psi)
    $outT = $p.StandardOutput.ReadToEndAsync(); $null = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) { try { $p.Kill($true) } catch { }; $p.Dispose(); return $null }
    try { $p.WaitForExit() } catch { }
    $text = "$($outT.GetAwaiter().GetResult())"
    $p.Dispose()
  } catch { if ($p) { try { $p.Dispose() } catch { } }; return $null }
  $line = @($text -split "`r?`n" | Where-Object { "$_".Trim() -like '{*' } | Select-Object -Last 1)
  if (-not $line) { return $null }
  try { return ($line.Trim() | ConvertFrom-Json -AsHashtable -DateKind String) } catch { return $null }
}
# Merge a fresh verdict into the persisted record: history grows by one (cap 48, newest last), failStreak
# increments on `fail` and resets otherwise. lines capped at 60 x 400 chars (the frozen contract).
function Update-DaemonRecord([string]$name, $rec) {
  $dir = Join-Path $Root 'daemons'
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  $f = Join-Path $dir "$name.json"
  $prev = $null
  if (Test-Path -LiteralPath $f) { try { $prev = Get-Content -LiteralPath $f -Raw | ConvertFrom-Json -AsHashtable -DateKind String } catch { $prev = $null } }
  $history = @()
  if ($prev -and $prev.ContainsKey('history') -and $prev['history']) { $history = @($prev['history']) }
  $streak = if ($prev -and $prev.ContainsKey('failStreak') -and $null -ne $prev['failStreak']) { [int]$prev['failStreak'] } else { 0 }
  $verdict = "$($rec['verdict'])"
  $history += [ordered]@{ at = "$($rec['at'])"; verdict = $verdict }
  if ($history.Count -gt 48) { $history = @($history[($history.Count - 48)..($history.Count - 1)]) }
  $streak = if ($verdict -eq 'fail') { $streak + 1 } else { 0 }
  $lines = @(if ($rec.ContainsKey('lines') -and $rec['lines']) { @($rec['lines']) | Select-Object -First 60 | ForEach-Object { $s = "$_"; if ($s.Length -gt 400) { $s.Substring(0, 400) } else { $s } } } else { @() })
  $out = [ordered]@{
    name = "$name"; at = "$($rec['at'])"; verdict = $verdict
    okCount = [int]$rec['okCount']; warnCount = [int]$rec['warnCount']; failCount = [int]$rec['failCount']
    lines = $lines; failStreak = $streak; history = $history
  }
  [IO.File]::WriteAllText($f, ($out | ConvertTo-Json -Depth 6), $Utf8)
  $out
}
function Get-Daemons {
  $out = [Collections.Generic.List[object]]::new()
  foreach ($name in @(Get-DaemonNames)) {
    try {
      $rec = Get-DaemonRecord $name
      if (-not $rec) { [Console]::Error.WriteLine("agentq-sync: daemon '$name' skipped (no record)"); continue }
      $out.Add((Update-DaemonRecord $name $rec))
    } catch { [Console]::Error.WriteLine("agentq-sync: daemon '$name' skipped: $_") }
  }
  $out
}

function Iso([datetime]$d) { $d.ToUniversalTime().ToString('o') }
function ParseUtc($s) { if ($s -is [datetime]) { return $s.ToUniversalTime() }; [DateTimeOffset]::Parse("$s", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
function Safe([string]$s) { ($s -replace '[^A-Za-z0-9._-]', '_') }
# Clip to the gateway's agentqPushSchema limits. An over-long ticket `cmd` (a whole pwsh
# one-liner) made the schema reject the ENTIRE push with 400 and the hub mirrored nothing
# (2026-11-13); the mirror is a window, so clipping beats losing the whole update.
function Clip([string]$s, [int]$n) { if ($s.Length -gt $n) { $s.Substring(0, $n) } else { $s } }

function Read-State {
  if (Test-Path $StateFile) {
    try { $s = Get-Content $StateFile -Raw | ConvertFrom-Json -DateKind String; return @{ offset = [long]$s.offset; ack = @($s.ack | ForEach-Object { [long]$_ }); lastOk = "$($s.lastOk)"; lastError = "$($s.lastError)" } } catch {}
  }
  @{ offset = [long]0; ack = @(); lastOk = ''; lastError = '' }
}
function Save-State($s) { [IO.File]::WriteAllText($StateFile, ($s | ConvertTo-Json -Depth 4), $Utf8) }

function Get-Key {
  if (-not (Test-Path $KeyFile)) { throw "agentq-sync: no key. Pipe a super_admin codai key into: agentq-sync.ps1 -SetKey" }
  # Trim: ConvertTo-SecureString rejects the blob with a trailing CRLF ("input string '\r\n' was not in a correct format").
  $sec = (Get-Content $KeyFile -Raw).Trim() | ConvertTo-SecureString
  [Net.NetworkCredential]::new('', $sec).Password
}

function Test-Alive($t) {
  try { $p = Get-Process -Id ([int]$t.pid) -ErrorAction Stop } catch { return $false }
  if ($t.PSObject.Properties['procStart'] -and $t.procStart) {
    try { return ([math]::Abs(($p.StartTime.ToUniversalTime() - (ParseUtc $t.procStart)).TotalSeconds) -lt 3) } catch { return $true }
  }
  $true
}

function Get-Tickets {
  $out = [Collections.Generic.List[object]]::new()
  if (-not (Test-Path $QDir)) { return $out }
  foreach ($d in Get-ChildItem $QDir -Directory) {
    $capFile = Join-Path $d.FullName 'capacity'
    # v3 tickets carry an explicit `held` flag and holders may exceed the base capacity (quick
    # burst, beside-batch, burst overrides). The hub derives roles by position ("first capacity
    # live tickets hold"), so publish holders first (seq) and waiters after (seq + 1e9), and a
    # capacity of max(cap, holders). Full lane/prio columns in the hub: devcloud DC-060.
    $files = @(Get-ChildItem $d.FullName -Filter '*.json' -File)
    $heldCount = @($files | Where-Object { try { $x = Get-Content $_.FullName -Raw | ConvertFrom-Json; $x.PSObject.Properties['v'] -and $x.PSObject.Properties['held'] -and $x.held } catch { $false } }).Count
    foreach ($f in $files) {
      try { $t = Get-Content $f.FullName -Raw | ConvertFrom-Json -DateKind String } catch { continue }
      if (-not $t -or -not $t.PSObject.Properties['resource']) { continue }
      $cap = if (Test-Path $capFile) { [int](Get-Content $capFile -Raw) } elseif ($DefaultCapacity.ContainsKey($t.resource)) { $DefaultCapacity[$t.resource] } else { 1 }
      $seq = [long]$t.seq
      if ($t.PSObject.Properties['v']) {
        $cap = [math]::Max($cap, $heldCount)
        if (-not ($t.PSObject.Properties['held'] -and $t.held)) { $seq += 1000000000 }
      }
      $hb = "$($f.FullName).hb"
      $beat = if (Test-Path $hb) { (Get-Item $hb).LastWriteTimeUtc } else { ParseUtc $t.created }
      $prop = { param($n, $max = 200) if ($t.PSObject.Properties[$n] -and $null -ne $t.$n) { (Clip "$($t.$n)" $max) } else { '' } }
      $lanePrefix = if ($t.PSObject.Properties['lane'] -and $t.lane) { "[$($t.lane)] " } else { '' }
      $out.Add([ordered]@{
          id = (Clip "$($t.id)" 64); resource = (Clip "$($t.resource)" 160); seq = $seq; capacity = [math]::Min(64, [math]::Max(1, $cap))
          pid = [int]$t.pid; session = (& $prop 'session' 200); purpose = (Clip ($lanePrefix + (& $prop 'purpose' 1900)) 2000); cmd = (& $prop 'cmd' 4000); repo = (& $prop 'repo' 300)
          created = (Iso (ParseUtc $t.created)); beat = (Iso $beat); alive = (Test-Alive $t)
        })
    }
  }
  $out
}

function Get-Marks {
  $out = [Collections.Generic.List[object]]::new()
  if (-not (Test-Path $MDir)) { return $out }
  foreach ($f in Get-ChildItem $MDir -Filter '*.json' -File) {
    try { $m = Get-Content $f.FullName -Raw | ConvertFrom-Json -DateKind String } catch { continue }
    if (-not $m -or -not $m.PSObject.Properties['resource']) { continue }
    $out.Add([ordered]@{ resource = (Clip "$($m.resource)" 160); state = $(if ($m.state -eq 'blocked') { 'blocked' } else { 'frozen' }); reason = (Clip "$($m.reason)" 2000); session = (Clip "$($m.session)" 200); at = (Iso (ParseUtc $m.at)) })
  }
  $out
}

# Complete lines appended since $offset (max $MaxLines). Returns lines + the new offset.
# ADR 0001: slot leases (leases/<repo>/<slot>.json + .hb mtime) and release runs (releases/*.json).
# Field names match the gateway agentqPushSchema (codai migration 0137); an older gateway strips them.
function Get-Leases {
  $out = [Collections.Generic.List[object]]::new()
  $dir = Join-Path $Root 'leases'
  foreach ($f in Get-ChildItem $dir -Recurse -Filter '*.json' -File -ErrorAction SilentlyContinue) {
    try { $l = Get-Content $f.FullName -Raw | ConvertFrom-Json -DateKind String } catch { continue }
    $hb = "$($f.FullName).hb"
    $beat = if (Test-Path $hb) { (Get-Item $hb).LastWriteTimeUtc } else { ParseUtc $l.created }
    $alive = Test-Alive ([pscustomobject]@{ pid = [int]$l.pid; procStart = $l.procStart })
    $idle = ([DateTime]::UtcNow - $beat).TotalMinutes
    $stale = ((-not $alive) -and $idle -gt 120) -or $idle -gt 1440
    $out.Add([ordered]@{
        repo = (Clip "$($l.repo)" 80); slot = (Clip "$($l.slot)" 60); role = $(if ("$($l.role)" -in 'task', 'release', 'land', 'pinned') { "$($l.role)" } else { 'task' }); path = (Clip "$($l.path)" 300)
        branch = (Clip "$($l.branch)" 200); purpose = (Clip "$($l.purpose)" 2000); session = (Clip "$($l.session)" 120); pid = [int]$l.pid
        created = (Iso (ParseUtc $l.created)); beat = (Iso $beat); state = $(if ($stale) { 'stale' } else { 'leased' }); alive = [bool]$alive
      })
  }
  $out
}
function Get-Releases {
  $out = [Collections.Generic.List[object]]::new()
  foreach ($f in Get-ChildItem (Join-Path $Root 'releases') -Filter '*.json' -File -ErrorAction SilentlyContinue) {
    try { $r = Get-Content $f.FullName -Raw | ConvertFrom-Json -DateKind String } catch { continue }
    if ([DateTime]::UtcNow - (ParseUtc $r.phaseAt) -gt [TimeSpan]::FromDays(2)) { continue }
    $alive = Test-Alive ([pscustomobject]@{ pid = [int]$r.pid; procStart = $r.procStart })
    $state = "$($r.state)"; if (-not $alive -and $state -in 'running', 'preempting') { $state = 'failed' }
    $out.Add([ordered]@{
        repo = (Clip "$($r.repo)" 80); target = (Clip "$($r.target)" 80); runId = (Clip "$($r.runId)" 64); sha = (Clip "$($r.sha)" 64); ref = (Clip "$($r.ref)" 200); follow = (Clip "$($r.follow)" 200)
        phase = "$($r.phase)".Substring(0, [math]::Min(40, "$($r.phase)".Length)); preemptible = (-not [bool]$r.committed); phaseAt = (Iso (ParseUtc $r.phaseAt)); state = $state
        supersedeSha = (Clip "$($r.supersedeSha)" 64); pendingSha = (Clip "$($r.pendingSha)" 64); session = (Clip "$($r.session)" 120); pid = [int]$r.pid; started = (Iso (ParseUtc $r.started)); alive = [bool]$alive
      })
  }
  $out
}

# A journal that shrank (rotated/recreated) restarts from 0; the server dedupes by line hash.
function Get-NewLines([long]$offset) {
  if (-not (Test-Path $Journal)) { return @{ lines = @(); offset = [long]0 } }
  $fs = [IO.File]::Open($Journal, 'Open', 'Read', 'ReadWrite')
  try {
    if ($offset -gt $fs.Length) { $offset = 0 }
    $fs.Position = $offset
    $buf = [byte[]]::new($fs.Length - $offset)
    $read = 0; while ($read -lt $buf.Length) { $n = $fs.Read($buf, $read, $buf.Length - $read); if ($n -le 0) { break }; $read += $n }
  } finally { $fs.Dispose() }
  $lines = [Collections.Generic.List[string]]::new()
  $pos = 0; $consumed = 0
  while ($lines.Count -lt $MaxLines) {
    $nl = [array]::IndexOf($buf, [byte]10, $pos)
    if ($nl -lt 0 -or $nl -ge $read) { break }
    $line = $Utf8.GetString($buf, $pos, $nl - $pos).Trim()
    if ($line -and $line.Length -le 16000) { $lines.Add($line) }
    $pos = $nl + 1; $consumed = $pos
  }
  @{ lines = $lines.ToArray(); offset = $offset + $consumed }
}

function Write-JournalLine([hashtable]$e) {
  $e.ts = Iso ([DateTime]::UtcNow)
  $line = ($e | ConvertTo-Json -Compress -Depth 6)
  $m = [Threading.Mutex]::new($false, "Global\agentq-journal$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  try { [void]$m.WaitOne(5000); [IO.File]::AppendAllText($Journal, $line + "`n", $Utf8) }
  finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
}

# Apply one hub op to marks/ exactly like agentq.ps1 Set-Mark. Idempotent (a lost ack re-applies).
function Invoke-Op($op) {
  if (-not (Test-Path $MDir)) { New-Item -ItemType Directory -Force $MDir | Out-Null }
  $f = Join-Path $MDir ((Safe $op.resource) + '.json')
  if ($op.op -eq 'clear') {
    if (Test-Path $f) {
      Remove-Item $f -Force
      Write-JournalLine @{ event = 'unmark'; resource = $op.resource; reason = $op.reason; session = $op.session; hubOp = $op.id }
    }
    return
  }
  $m = [ordered]@{ resource = $op.resource; state = $op.state; reason = $op.reason; session = $op.session; at = (Iso (ParseUtc $op.createdAt)) }
  $cur = if (Test-Path $f) { try { Get-Content $f -Raw | ConvertFrom-Json -DateKind String } catch { $null } } else { $null }
  if ($cur -and $cur.state -eq $m.state -and $cur.reason -eq $m.reason -and $cur.session -eq $m.session) { return }
  [IO.File]::WriteAllText("$f.tmp", ($m | ConvertTo-Json), $Utf8)
  Move-Item "$f.tmp" $f -Force
  Write-JournalLine @{ event = 'mark'; resource = $op.resource; state = $op.state; reason = $op.reason; session = $op.session; hubOp = $op.id }
}

function Invoke-Push {
  $state = Read-State
  $j = Get-NewLines $state.offset
  $body = [ordered]@{
    host = $env:COMPUTERNAME; root = $Root; agentVersion = $Version
    tickets = @(Get-Tickets); marks = @(Get-Marks); leases = @(Get-Leases); releases = @(Get-Releases); jobs = @(Get-Jobs); daemons = @(Get-Daemons); journal = @($j.lines); ackOps = @($state.ack)
  }
  if ($DryRun) {
    "tickets=$($body.tickets.Count) marks=$($body.marks.Count) leases=$($body.leases.Count) releases=$($body.releases.Count) jobs=$($body.jobs.Count) daemons=$($body.daemons.Count) journal=$($body.journal.Count) offset $($state.offset)->$($j.offset) ack=$($body.ackOps.Count)"
    if ($env:AGENTQ_SYNC_DUMP) { [IO.File]::WriteAllText($env:AGENTQ_SYNC_DUMP, ($body | ConvertTo-Json -Depth 6), $Utf8) }
    return
  }
  $json = $body | ConvertTo-Json -Depth 6 -Compress
  try {
    $res = Invoke-RestMethod -Uri "$Base/v1/agentq/sync" -Method Post -ContentType 'application/json; charset=utf-8' `
      -Headers @{ Authorization = "Bearer $(Get-Key)"; 'x-codai-client' = "agentq-sync/$Version" } -Body $Utf8.GetBytes($json) -TimeoutSec 30
  } catch {
    $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
    $state.lastError = "$(Iso ([DateTime]::UtcNow)) HTTP $code $($_.Exception.Message)"
    Save-State $state
    throw "agentq-sync: push failed (HTTP $code)"
  }
  $applied = @()
  foreach ($op in @($res.ops)) {
    if (-not $op) { continue }
    try { Invoke-Op $op; $applied += [long]$op.id } catch { [Console]::Error.WriteLine("agentq-sync: op $($op.id) failed: $_") }
  }
  $state.offset = $j.offset; $state.ack = $applied; $state.lastOk = Iso ([DateTime]::UtcNow); $state.lastError = ''
  Save-State $state
  "ok tickets=$($body.tickets.Count) marks=$($body.marks.Count) journal=$($body.journal.Count)/+$($res.journalInserted) acked=$($res.acked) applied=$($applied.Count)"
  # Backlog (first sync) or freshly applied ops: push again now so the hub sees them.
  if ($j.lines.Count -ge $MaxLines -or $applied.Count -gt 0) { Invoke-Push }
}

if ($SetKey) {
  $k = [Console]::In.ReadToEnd().Trim()
  if ($k -notmatch '^codai_') { throw 'agentq-sync -SetKey: expected a codai_... key on stdin' }
  $dir = Split-Path $KeyFile; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
  [IO.File]::WriteAllText($KeyFile, (ConvertTo-SecureString $k -AsPlainText -Force | ConvertFrom-SecureString))
  "key stored (DPAPI, CurrentUser) in $KeyFile (prefix $($k.Substring(0, 10))...)"
  exit 0
}
if ($Status) {
  $s = Read-State
  "state: offset=$($s.offset) lastOk=$($s.lastOk) lastError=$($s.lastError) pendingAck=$($s.ack.Count)"
  $t = Get-ScheduledTask -TaskName 'agentq-sync' -ErrorAction SilentlyContinue
  if ($t) { "task: $($t.State) -> $($t.Actions[0].Execute) $($t.Actions[0].Arguments)" } else { 'task: not installed' }
  $dn = @(Get-DaemonNames)
  "daemons: $($dn.Count) configured ($($dn -join ', '))"
  $dd = Join-Path $Root 'daemons'
  if (Test-Path -LiteralPath $dd) {
    foreach ($f in Get-ChildItem -LiteralPath $dd -Filter '*.json' -File -ErrorAction SilentlyContinue) {
      try { $rec = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json -AsHashtable -DateKind String } catch { "  $($f.BaseName): unreadable"; continue }
      $age = try { [int](([DateTime]::UtcNow - [DateTime]$rec['at']).TotalMinutes) } catch { -1 }
      "  {0,-16} {1,-5} failStreak {2}  {3}m ago  ({4} lines)" -f "$($rec['name'])", "$($rec['verdict'])", [int]$rec['failStreak'], $age, @($rec['lines']).Count
    }
  } else { '  (no daemon records yet)' }
  exit 0
}
if ($Install) {
  $vbs = 'E:\gh\vmui\scripts\hidden-run.vbs'
  if (-not (Test-Path $vbs)) { throw "missing $vbs (hidden launcher; a bare pwsh task flashes a console)" }
  $pwsh = (Get-Command pwsh).Source
  # Replace whichever model is live, including a -Loop started OUTSIDE the task: an old -Loop keeps the
  # script it loaded at start (a mid-life edit is silently ignored) and would double-push beside the new
  # tick (exactly the git-autosync failure, ADR 0010: the 2026-11-18 loop ran 20 h on stale code).
  try { Stop-ScheduledTask -TaskName 'agentq-sync' -ErrorAction Stop } catch { }
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -eq 'pwsh.exe' -and $_.CommandLine -match 'agentq-sync' -and $_.CommandLine -match '-Loop' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop; "stopped the old long-lived loop (pid $($_.ProcessId))" } catch { } }
  $common = '-NoProfile -ExecutionPolicy Bypass -File ' + "`"$PSCommandPath`""
  if ($InstallLoop) {
    # Long-lived model (kept for anyone who wants warmth): the code is FROZEN at load time.
    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$pwsh`" $common -Loop"
    $trg = @(New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
    $desc = 'agentq -> hub.codai.ro mirror (long-lived -Loop, code frozen at start)'
  } else {
    # One push per tick: the code is always current. IgnoreNew skips a tick whose predecessor still
    # runs (the in-loop mutex + the HTTP timeout bound a normal pass well under the cap); the 5-minute
    # cap ends a wedged push instead of blocking every later tick via IgnoreNew; StartWhenAvailable runs
    # a tick missed to a reboot or sleep. 1 min = the Task Scheduler repetition floor (the old loop
    # slept 15 s, shorter than the scheduler allows).
    $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$pwsh`" $common"
    $trg = @(
      (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
      (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1))
    )
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
    $desc = 'agentq -> hub.codai.ro mirror (one push per 1 min tick)'
  }
  Register-ScheduledTask -TaskName 'agentq-sync' -Action $act -Trigger $trg -Settings $set -Description $desc -Force | Out-Null
  Start-ScheduledTask -TaskName 'agentq-sync'
  "installed + started scheduled task agentq-sync ($desc)"
  exit 0
}
if ($Loop) {
  # One loop per user session.
  $mx = [Threading.Mutex]::new($false, "Global\agentq-sync-loop$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  if (-not $mx.WaitOne(0)) { 'agentq-sync: loop already running'; exit 0 }
  while ($true) {
    Invoke-ProbeTick
    try { Invoke-Push | Out-Null } catch { [Console]::Error.WriteLine("$_") }
    Start-Sleep -Seconds $IntervalSec
  }
}
Invoke-Push
