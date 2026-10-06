<#
agentq-sync — mirror ~/.codai/coord to hub.codai.ro and bring hub marks back.

Every tick: POST /v1/agentq/sync on the codai gateway with this machine's live tickets,
current marks, the journal lines appended since the last accepted push, and the ids of
hub mark ops applied locally. The response lists hub ops not yet applied; each one is
written into marks/ in agentq.ps1 Set-Mark's exact shape (+ a journal line), so
`agentq run/acquire/commit` and the guard hook honour a freeze set in the hub.

Auth: a codai API key whose owner is super_admin, stored DPAPI-encrypted (CurrentUser)
in ~/.codai/agentq-sync.key. Never printed.

  agentq-sync.ps1 -SetKey              read the key from STDIN (pipe it; never echo it)
  agentq-sync.ps1 -Once [-DryRun]      one push (DryRun: print the payload summary, no POST)
  agentq-sync.ps1 -Loop [-IntervalSec 15]
  agentq-sync.ps1 -Install             scheduled task 'agentq-sync' at logon (wscript hidden, no console)
  agentq-sync.ps1 -Status              state file + task state

Env: AGENTQ_HOME (like agentq.ps1), AGENTQ_SYNC_URL (default https://ai.codai.ro),
AGENTQ_SYNC_STATE (default ~/.codai/agentq-sync.state.json).
#>
param(
  [switch]$Once, [switch]$Loop, [switch]$Install, [switch]$SetKey, [switch]$Status, [switch]$DryRun,
  [int]$IntervalSec = 15, [string]$Url
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$Version = '1'
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

function Iso([datetime]$d) { $d.ToUniversalTime().ToString('o') }
function ParseUtc($s) { if ($s -is [datetime]) { return $s.ToUniversalTime() }; [DateTimeOffset]::Parse("$s", [Globalization.CultureInfo]::InvariantCulture).UtcDateTime }
function Safe([string]$s) { ($s -replace '[^A-Za-z0-9._-]', '_') }

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
    foreach ($f in Get-ChildItem $d.FullName -Filter '*.json' -File) {
      try { $t = Get-Content $f.FullName -Raw | ConvertFrom-Json -DateKind String } catch { continue }
      if (-not $t -or -not $t.PSObject.Properties['resource']) { continue }
      $cap = if (Test-Path $capFile) { [int](Get-Content $capFile -Raw) } elseif ($DefaultCapacity.ContainsKey($t.resource)) { $DefaultCapacity[$t.resource] } else { 1 }
      $hb = "$($f.FullName).hb"
      $beat = if (Test-Path $hb) { (Get-Item $hb).LastWriteTimeUtc } else { ParseUtc $t.created }
      $prop = { param($n) if ($t.PSObject.Properties[$n] -and $null -ne $t.$n) { "$($t.$n)" } else { '' } }
      $out.Add([ordered]@{
          id = "$($t.id)"; resource = "$($t.resource)"; seq = [long]$t.seq; capacity = [math]::Max(1, $cap)
          pid = [int]$t.pid; session = (& $prop 'session'); purpose = (& $prop 'purpose'); cmd = (& $prop 'cmd'); repo = (& $prop 'repo')
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
    $out.Add([ordered]@{ resource = "$($m.resource)"; state = $(if ($m.state -eq 'blocked') { 'blocked' } else { 'frozen' }); reason = "$($m.reason)"; session = "$($m.session)"; at = (Iso (ParseUtc $m.at)) })
  }
  $out
}

# Complete lines appended since $offset (max $MaxLines). Returns lines + the new offset.
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
  $m = [Threading.Mutex]::new($false, 'Global\agentq-journal')
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
    tickets = @(Get-Tickets); marks = @(Get-Marks); journal = @($j.lines); ackOps = @($state.ack)
  }
  if ($DryRun) {
    "tickets=$($body.tickets.Count) marks=$($body.marks.Count) journal=$($body.journal.Count) offset $($state.offset)->$($j.offset) ack=$($body.ackOps.Count)"
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
  exit 0
}
if ($Install) {
  $vbs = 'E:\gh\vmui\scripts\hidden-run.vbs'
  if (-not (Test-Path $vbs)) { throw "missing $vbs (hidden launcher; a bare pwsh task flashes a console)" }
  $pwsh = (Get-Command pwsh).Source
  $act = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$pwsh`" -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Loop"
  $trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
  Register-ScheduledTask -TaskName 'agentq-sync' -Action $act -Trigger $trg -Settings $set -Description 'agentq -> hub.codai.ro mirror' -Force | Out-Null
  Start-ScheduledTask -TaskName 'agentq-sync'
  'installed + started scheduled task agentq-sync'
  exit 0
}
if ($Loop) {
  # One loop per user session.
  $mx = [Threading.Mutex]::new($false, 'Global\agentq-sync-loop')
  if (-not $mx.WaitOne(0)) { 'agentq-sync: loop already running'; exit 0 }
  while ($true) {
    try { Invoke-Push | Out-Null } catch { [Console]::Error.WriteLine("$_") }
    Start-Sleep -Seconds $IntervalSec
  }
}
Invoke-Push
