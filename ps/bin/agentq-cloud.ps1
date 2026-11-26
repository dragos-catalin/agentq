<#
agentq-cloud — run one command on a devcloud warm workspace (DC-037). Job contract: spec/job.md (v1).

  agentq-cloud.ps1 -Ws codai -Purpose 'why' [-Lane gate] [-TimeoutMin 60] [-Repo <dir>] [-NoPatch] -- pnpm --filter @codai/common typecheck
  agentq-cloud.ps1 -Ws codai -Status          VM state + heartbeat + known shas
  agentq-cloud.ps1 -Ws codai -Suspend         suspend now (the agent also does it after idle-min)
  agentq-cloud.ps1 -Ws codai -StaleClaimMin 3 [-NoHeal]   recycle a wedged workspace, see HEAL

WHAT TRAVELS (git delta, never the whole tree)
  base  = HEAD of the local repo. The workspace publishes the shas it has (ws/<ws>/repos/<repo>.json);
          the newest one that is an ancestor of HEAD is the bundle prerequisite, so only the commits it
          lacks travel (`git bundle create <id> <known>..HEAD`). No usable known sha -> full HEAD bundle.
  patch = working tree vs HEAD, untracked included, built in a TEMP index (GIT_INDEX_FILE) so the
          shared index is never touched: read-tree HEAD; add -A; diff --cached --binary HEAD.
FLOW  resume VM if SUSPENDED/TERMINATED -> upload bundle/patch -> queue spec (written LAST) ->
      stream jobs/<id>/log -> result.json -> exit with the remote exit code.
HEAL  nobody claimed the job and the workspace heartbeat has not moved since the submission: the runner
  wedged across a suspend (a resume does NOT re-run the startup script, so the VM keeps the frozen
  process, looks RUNNING and never reads the queue - ws-vitals-win, 2026-11-25, five jobs, an hour).
  A reset re-runs the boot script and starts a fresh agent. The heartbeat is the evidence, never the VM
  state: it fires when the heartbeat is older than the submission (precise) or has been silent for the
  whole wait (robust to a clock skew between this machine and the workspace), and the 3 min wait is only
  a floor - the heartbeat comparison is what makes the reset safe.
  The heal is REPEATED and BOUNDED (3 attempts) with a doubling backoff (StaleClaimMin, 2x, 4x), and the
  deadline is extended to reach each attempt: a one-shot guard let a SECOND failure die at the deadline
  with "no result before deadline" (38 in the journal). -NoHeal runs exactly as before, with no heals.
  It is PAUSED while any OTHER job is in flight on the workspace. The runner writes ws/<ws>/busy for the
  whole duration of every job (job, host, at, timeoutSec, until) and clears it when the job ends; a
  client honours that before it ever touches the VM. The old heal only asked whether the CALLER's own job
  had been claimed, so a reset rebooted the whole VM out from under a peer's build (ws-codai,
  2026-11-26: a peer build killed mid-run). A marker whose own deadline (until) has already passed is a
  wedge, not a live peer, and only then may a reset proceed - the marker cannot protect a dead run.
JOURNAL  cloud-queued / cloud-done / cloud-fail in ~/.codai/coord/journal.jsonl with holdSec,
      waitSec (queue -> claimed, includes resume), lane, kind=cloud, resource cloud:<ws>, so
      `agentq metrics` shows cloud runs beside local ones.
EVIDENCE  a run that reached the workspace also leaves VERSIONED evidence in the TARGET repo, never only
      in the job bucket and a terminal buffer: the whole log as runs/<id>.log plus ONE row in the repo's
      own run journal (docs/RUNS.md or RUNS.md - an existing file only, following that table's columns,
      idempotent by job id; .gitignore is never edited). A repo without that file, or without a markdown
      table in it, gets the log and a printed notice instead of a file its conventions never asked for.
EXIT  remote exit code; 3 = timed out waiting after submit; 4 = workspace unavailable, NOTHING
  submitted (agentq falls back to local and skips this workspace until cloud-down/<ws>.json
  expires); 2 = usage.
#>
$Ws = 'codai'; $Purpose = $null; $Lane = 'gate'; $TimeoutMin = 60; $RepoArg = $null; $NoPatch = $false
$Status = $false; $Suspend = $false; $Json = $false; $Project = $null; $Zone = $null; $CtlProject = 'dragos-devcloud'; $NoInstall = $false
$StaleClaimMin = 3; $NoHeal = $false
$argv = @($args); $Rest = @()
$dd = [array]::IndexOf($argv, '--')
if ($dd -ge 0) { $Rest = @($argv | Select-Object -Skip ($dd + 1)); $argv = @($argv | Select-Object -First $dd) }
for ($i = 0; $i -lt $argv.Count; $i++) {
  $a = "$($argv[$i])"; $n = $a.TrimStart('-').ToLowerInvariant()
  $val = { if ($i + 1 -ge $argv.Count) { throw "agentq-cloud: $a needs a value" }; $script:i++; "$($argv[$script:i])" }
  switch ($n) {
    'ws' { $Ws = & $val } 'purpose' { $Purpose = & $val } 'lane' { $Lane = (& $val).ToLowerInvariant() }
    'timeoutmin' { $TimeoutMin = [int](& $val) } 'repo' { $RepoArg = & $val } 'nopatch' { $NoPatch = $true }
    'noinstall' { $NoInstall = $true } 'status' { $Status = $true } 'suspend' { $Suspend = $true } 'json' { $Json = $true }
    'staleclaimmin' { $StaleClaimMin = [int](& $val) } 'noheal' { $NoHeal = $true }
    'project' { $Project = & $val } 'zone' { $Zone = & $val } 'ctlproject' { $CtlProject = & $val }
    default { [Console]::Error.WriteLine("agentq-cloud: unknown argument '$a' (put the command after --)"); exit 2 }
  }
}
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

# Workspace registry: where each warm workspace lives (VM project/zone). Control plane = $CtlProject.
# Built-ins + config `cloudRegistry` ({ "<ws>": { "project": "..", "zone": ".." } }) so a new
# workspace needs no code change. vitals-win (DC-063) = Windows Server 2025 for Windows-only gates.
$Registry = @{ codai = @{ project = 'codai-training'; zone = 'europe-west4-a' }; 'vitals-win' = @{ project = 'codai-training'; zone = 'europe-west4-a' } }
try {
  $cfgPath = if ($env:AGENTQ_CONFIG) { $env:AGENTQ_CONFIG } else { Join-Path $PSScriptRoot 'agentq-config.json' }
  if (Test-Path -LiteralPath $cfgPath) {
    $cr = (Get-Content -LiteralPath $cfgPath -Raw | ConvertFrom-Json).PSObject.Properties['cloudRegistry']
    if ($cr -and $cr.Value) { foreach ($p in $cr.Value.PSObject.Properties) { $Registry[$p.Name] = @{ project = "$($p.Value.project)"; zone = "$($p.Value.zone)" } } }
  }
} catch { [Console]::Error.WriteLine("agentq-cloud: cloudRegistry ignored ($($_.Exception.Message))") }
if (-not $Registry.ContainsKey($Ws) -and -not ($Project -and $Zone)) { [Console]::Error.WriteLine("agentq-cloud: unknown workspace '$Ws' (known: $($Registry.Keys -join ', '); or pass -Project/-Zone)"); exit 2 }
if (-not $Project) { $Project = $Registry[$Ws].project }
if (-not $Zone) { $Zone = $Registry[$Ws].zone }
$Vm = "ws-$Ws"; $Bucket = "gs://$CtlProject-devcloud-jobs"
$Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
$Journal = Join-Path $Root 'journal.jsonl'
$Session = foreach ($v in $env:AGENTQ_SESSION, $env:COPILOT_SESSION_ID, $env:COPILOT_AGENT_SESSION_ID, $env:CLAUDE_SESSION_ID, $env:CODEX_SESSION_ID) { if ($v) { $v; break } }
if (-not $Session) { $Session = "term-$(try { (Get-Process -Id $PID).Parent.Id } catch { 0 })" }

function Out-Line([string]$s) { [Console]::Out.WriteLine($s) }
function Write-Journal([hashtable]$e) {
  $e.ts = [DateTime]::UtcNow.ToString('o'); $e.session = $Session
  $line = $e | ConvertTo-Json -Compress -Depth 6
  $m = [Threading.Mutex]::new($false, "Global\agentq-journal$(if ($env:AGENTQ_HOME) { '-' + ($env:AGENTQ_HOME.ToLowerInvariant() -replace '[^a-z0-9]', '_') })")
  try { try { [void]$m.WaitOne(5000) } catch [Threading.AbandonedMutexException] {}; [IO.File]::AppendAllText($Journal, $line + "`n", [Text.UTF8Encoding]::new($false)) }
  finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
}
# ---- evidence in the target repo (the run's own log, in the repo, forever) ----------------------
# A gate result lived only in gs://<ctl>-devcloud-jobs/jobs/<id>/log and in a terminal buffer, so it was
# an assertion rather than evidence: it could not be cited afterwards and it was not in the tree the run
# was about. These helpers put it where the repo keeps results - runs/<id>.log plus ONE row in the
# repo's own run journal - and are deliberately SELF-CONTAINED (no caller's script scope): the suite
# tests/test-cloud-evidence.ps1 extracts these definitions from THIS file by AST and drives them
# directly, so a rename or a reference to something outside them fails the suite.
function Get-RunJournalRowField {
  # StrictMode-proof field read: a missing field must read as empty, never throw.
  param($Row, [string]$Name)
  $p = $Row.PSObject.Properties[$Name]
  if ($p) { "$($p.Value)" } else { '' }
}
function Get-RunJournalTable([string]$Path) {
  # The FIRST markdown table of the file. Its header cells are the columns the row must follow; the shape
  # in use here is `| date | job id | region | expected cost | actual | state | purpose |`
  # (arc-prize-2027, hadamard-next). Last = the file index of that table's last row, because the new row
  # goes there and never at end-of-file: a repo may keep prose or a second table below the first one.
  $raw = [IO.File]::ReadAllText($Path)
  $lines = @($raw -split "`r?`n")
  for ($i = 0; $i + 1 -lt $lines.Count; $i++) {
    $h = $lines[$i].Trim()
    if ($h -notmatch '^\|.*\|$') { continue }
    if ($lines[$i + 1].Trim() -notmatch '^\|[\s:\-|]+\|$') { continue }
    $cols = @($h.Trim('|') -split '\|' | ForEach-Object { $_.Trim() })
    if ($cols.Count -lt 2) { continue }
    $last = $i + 1
    while ($last + 1 -lt $lines.Count -and $lines[$last + 1].Trim() -match '^\|') { $last++ }
    return [pscustomobject]@{ Header = $i; Last = $last; Columns = $cols; Lines = $lines; Raw = $raw }
  }
  $null
}
function ConvertTo-RunJournalValue([string]$Column, $Row) {
  # One cell per column NAME, by keyword: the repo's header decides the order and the wording, this
  # decides only the content. An unmatched column stays empty rather than being filled with an invention;
  # whatever the columns left out is appended to the last cell by New-RunJournalRow.
  $n = "$Column".ToLowerInvariant()
  if ($n -match '\bdate\b|\bwhen\b|\bday\b') { return (Get-RunJournalRowField $Row 'Date') }
  if ($n -match '\bjob\b|\bid\b') { return (Get-RunJournalRowField $Row 'Job') }
  if ($n -match '\bregion\b|\bhost\b|\bmachine\b|\bvm\b|\bwhere\b|\btarget\b|\bzone\b|\bproject\b') { return (Get-RunJournalRowField $Row 'Region') }
  if ($n -match '\bcost\b|\beur\b|\bprice\b|\bspend\b|\bbudget\b|\bbill\b|\bactual\b|\bexpected\b') { return (Get-RunJournalRowField $Row 'Cost') }
  if ($n -match '\bstate\b|\bstatus\b|\bexit\b|\bresult\b|\boutcome\b|\bverdict\b|\bcode\b') { return (Get-RunJournalRowField $Row 'State') }
  if ($n -match '\bpurpose\b|\bwhat\b|\bwhy\b|\bdesc\w*\b|\bnote\w*\b|\bcomm\w*\b|\blog\b|\bevid\w*\b|\bartefact\w*\b|\bartifact\w*\b') { return (Get-RunJournalRowField $Row 'Purpose') }
  ''
}
function New-RunJournalRow($Table, $Row) {
  $cells = @(@($Table.Columns) | ForEach-Object { ConvertTo-RunJournalValue $_ $Row })
  # The contract, whatever the header says: a row that does not name the job cannot be deduplicated and a
  # row without the log path is not evidence. Anything the columns left out is appended to the last cell,
  # so an unfamiliar header still yields a usable row.
  $facts = @()
  $fp = $Row.PSObject.Properties['Facts']
  if ($fp) { $facts = @($fp.Value) }
  $missing = @($facts | Where-Object { $_ -and -not (($cells -join ' ').Contains("$_")) })
  if ($missing.Count) {
    $last = "$($cells[$cells.Count - 1])"
    $cells[$cells.Count - 1] = $(if ($last) { $last + '; ' } else { '' }) + ($missing -join '; ')
  }
  # a pipe or a newline in a value would break the row open, so both are written the way a markdown table
  # reads them back
  $cells = @($cells | ForEach-Object { ("$_" -replace '\r?\n', ' ' -replace '\s{2,}', ' ').Trim() -replace '\|', '\|' })
  '| ' + ($cells -join ' | ') + ' |'
}
function Add-RunJournalRow([string]$Path, [string]$JobId, [string]$RowText) {
  $t = Get-RunJournalTable $Path
  if (-not $t) { return [pscustomobject]@{ Added = $false; Reason = "no markdown table in $Path" } }
  $lines = @($t.Lines)
  for ($i = $t.Header; $i -le $t.Last; $i++) { if ($lines[$i].Contains($JobId)) { return [pscustomobject]@{ Added = $false; Reason = "job $JobId is already rowed in $Path" } } }
  $tail = @()
  if ($t.Last + 1 -lt $lines.Count) { $tail = @($lines[($t.Last + 1)..($lines.Count - 1)]) }
  $out = @($lines[0..$t.Last]) + @($RowText) + $tail
  # the file's own line endings and BOM are kept: a rewritten journal must not show up as a whole-file
  # diff next to the one row it gained
  $eol = if ($t.Raw.Contains("`r`n")) { "`r`n" } else { "`n" }
  $bytes = [IO.File]::ReadAllBytes($Path)
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
  [IO.File]::WriteAllText($Path, (@($out) -join $eol), (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $bom))
  [pscustomobject]@{ Added = $true; Reason = '' }
}
function Save-CloudEvidence {
  # After a run that reached the workspace: the whole log as runs/<id>.log and one row in the repo's run
  # journal. Never a file the repo did not ask for, never fatal to the run (the caller wraps it), and
  # idempotent by job id - a re-run of the same gate must not grow the journal.
  param(
    [Parameter(Mandatory = $true)][string]$RepoDir,
    [Parameter(Mandatory = $true)][string]$JobId,
    [string]$Log = '', [int]$ExitCode = 0, [double]$TotalSec = 0, [string]$Purpose = '',
    [string]$Lane = '', [string]$Region = '', [string]$Command = '', [string]$Date = ''
  )
  if (-not (Test-Path -LiteralPath $RepoDir)) { throw "cloud evidence: $RepoDir does not exist" }
  if (-not $JobId) { throw 'cloud evidence: a job id is required' }
  $rel = "runs/$JobId.log"
  $runsDir = Join-Path $RepoDir 'runs'
  if (-not (Test-Path -LiteralPath $runsDir)) { New-Item -ItemType Directory -Force -Path $runsDir | Out-Null }
  $logPath = Join-Path $runsDir "$JobId.log"
  $text = "$Log"
  if (-not $text.Trim()) { $text = "# no log object was streamed for job $JobId`n" }
  [IO.File]::WriteAllText($logPath, $text, (New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false))
  $res = [pscustomobject]@{ job = $JobId; logPath = $logPath; logRelative = $rel; logBytes = ([IO.FileInfo]$logPath).Length
    logWritten = $true; runsIgnored = $false; journalPath = ''; journalRow = ''; journalAdded = $false; journalSkipped = '' }
  # `runs/` being ignored is REPORTED, never fixed: an agent must not edit a repo's .gitignore, and
  # evidence nobody commits is evidence nobody can cite.
  if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
    $prevEap = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; & git -C $RepoDir check-ignore -q -- $rel 2>$null; $res.runsIgnored = ($LASTEXITCODE -eq 0) }
    finally { $ErrorActionPreference = $prevEap }
  }
  $journal = ''
  foreach ($cand in @((Join-Path $RepoDir 'docs\RUNS.md'), (Join-Path $RepoDir 'RUNS.md'))) { if (Test-Path -LiteralPath $cand) { $journal = $cand; break } }
  if (-not $journal) { $res.journalSkipped = 'no docs\RUNS.md or RUNS.md in this repo - no journal row appended'; return $res }
  $res.journalPath = $journal
  $t = Get-RunJournalTable $journal
  if (-not $t) { $res.journalSkipped = "no markdown table in $journal"; return $res }
  if (-not $Date) { $Date = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
  $total = ([math]::Round($TotalSec, 1)).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
  $state = if ($ExitCode -lt 0) { 'CLIENT-FAIL' } elseif ($ExitCode -eq 0) { 'DONE' } else { 'FAILED' }
  $why = "$Purpose"
  if ($Lane) { $why += " (lane $Lane)" }
  if ("$Command".Trim()) { $why += '; `' + "$Command".Trim() + '`' }
  $why += "; log $rel"
  $row = [pscustomobject]@{ Date = $Date; Job = $JobId
    Region = $(if ($Region) { $Region } else { 'unknown' })
    Cost = '0 EUR marginal (fleet workspace VM, already up)'
    State = '{0}, exit {1}, total {2} s' -f $state, $ExitCode, $total
    Purpose = $why.Trim()
    Facts = @($JobId, "log $rel", "exit $ExitCode", "total $total s") }
  $res.journalRow = New-RunJournalRow $t $row
  $add = Add-RunJournalRow $journal $JobId $res.journalRow
  $res.journalAdded = $add.Added
  $res.journalSkipped = $add.Reason
  $res
}
# ---- heal policy (pure: ps/tests/test-agentq-cloud-heal.ps1 drives these directly) ----------------
function Get-HealBackoffMin {
  # The wait, in minutes, before the (HealsDone+1)th heal: the first interval, then double (3, 6, 12 with
  # the default -StaleClaimMin 3). A heal is not a retry loop - the doubling is what keeps a genuinely
  # slow workspace from being reset every three minutes while still eventually healing a wedged one.
  param([int]$HealsDone = 0, [double]$FirstMin = 3)
  if ($FirstMin -le 0) { return 0 }
  [double]($FirstMin * [math]::Pow(2, [math]::Max(0, $HealsDone)))
}
function Test-CloudPeerBusy {
  # True when ANOTHER job is in flight on this workspace. The runner publishes ws/<ws>/busy while it runs
  # a job ({job, host, at, timeoutSec, until}); a marker that names THIS job is not a peer, and a marker
  # whose own deadline (until, or at+timeoutSec) has passed is not a live peer either - a run that outlived
  # the timeout it was given is a wedge, and only then may a reset proceed. THIS is the guard that stops
  # one client from rebooting the VM out from under a peer's run: the old heal only ever asked whether the
  # CALLER's own job had been claimed, so a reset killed a peer's build (ws-codai, 2026-11-26).
  param([object]$Marker = $null, [string]$SelfJobId = '', [object]$Now = $null, [double]$GraceMin = 5)
  if ($null -eq $Marker) { return $false }
  if ($Marker -is [string]) { if (-not "$Marker".Trim()) { return $false }; try { $Marker = ($Marker | ConvertFrom-Json) } catch { return $false } }
  if ($null -eq $Marker) { return $false }
  if ($Marker -is [System.Collections.IDictionary]) { $Marker = [pscustomobject]$Marker }   # a dictionary/hashtable marker reads like the JSON one
  $job = ''
  if ($Marker.PSObject.Properties['job']) { $job = "$($Marker.job)" }
  if ($SelfJobId -and $job -eq $SelfJobId) { return $false }
  $until = $null
  if ($Marker.PSObject.Properties['until'] -and $Marker.until) { try { $until = ([DateTime]$Marker.until).ToUniversalTime() } catch { $until = $null } }
  if (-not $until) {
    $at = $null
    if ($Marker.PSObject.Properties['at'] -and $Marker.at) { try { $at = ([DateTime]$Marker.at).ToUniversalTime() } catch { $at = $null } }
    $ts = 0
    if ($Marker.PSObject.Properties['timeoutSec'] -and $Marker.timeoutSec) { $ts = [int]$Marker.timeoutSec }
    if ($at -and $ts -gt 0) { $until = $at.AddSeconds($ts) }
    elseif ($at) { $until = $at.AddMinutes([math]::Max($GraceMin, 1)) }
  }
  if (-not $until) { return $false }   # no readable time at all: not evidence of a peer, so it never blocks a heal
  if (-not $Now) { $Now = [DateTime]::UtcNow }
  return (([DateTime]$Now).ToUniversalTime() -lt $until.AddMinutes([math]::Max($GraceMin, 0)))
}
function Get-CloudHealDecision {
  # The ONE place that decides whether this client may reset/resume the workspace while its OWN job is
  # still unclaimed. Pure: it reads only the evidence it is handed, so the whole policy (repeated bounded
  # backoff, peer-in-flight guard, attempt cap) is provable offline. action:
  #   none      - nothing to do (heal disabled, already claimed, heartbeat live, or no VM action)
  #   wait      - the backoff for this attempt has not elapsed
  #   cap       - the heal budget is spent: the workspace is NEVER reset again
  #   skip-peer - ANOTHER job is in flight: NEVER reset, keep waiting (journaled as cloud-heal-skipped)
  #   act       - stale and idle: the caller reads the VM state and resets/resumes
  param(
    [bool]$NoHeal = $false, [bool]$Claimed = $false,
    [int]$HealCount = 0, [int]$HealMax = 3,
    [double]$SinceCursorMin = 0, [double]$FirstIntervalMin = 3,
    [object]$HeartbeatAgeSec = $null, [bool]$HeartbeatOlderThanQueue = $false,
    [bool]$PeerBusy = $false
  )
  if ($NoHeal) { return @{ action = 'none'; reason = 'heal disabled (-NoHeal)' } }
  if ($Claimed) { return @{ action = 'none'; reason = 'the job was claimed' } }
  if ($HealMax -le 0 -or $HealCount -ge $HealMax) { return @{ action = 'cap'; reason = ('heal budget spent ({0}/{1})' -f $HealCount, $HealMax) } }
  $due = Get-HealBackoffMin -HealsDone $HealCount -FirstMin $FirstIntervalMin
  if ($SinceCursorMin -lt $due) { return @{ action = 'wait'; intervalMin = $due; reason = ('backoff not elapsed: {0:N1}m < {1:N1}m' -f $SinceCursorMin, $due) } }
  $hb = $null
  if ($null -ne $HeartbeatAgeSec -and "$HeartbeatAgeSec" -ne '') { $hb = [double]$HeartbeatAgeSec }
  $stale = $HeartbeatOlderThanQueue -or ($null -ne $hb -and $hb -gt ($FirstIntervalMin * 60))
  if (-not $stale) { return @{ action = 'none'; intervalMin = $due; reason = 'the heartbeat is live' } }
  if ($PeerBusy) { return @{ action = 'skip-peer'; intervalMin = $due; reason = 'another job is in flight on this workspace' } }
  return @{ action = 'act'; intervalMin = $due; reason = 'the workspace is stale and idle' }
}
# Transport: GCS JSON API + Compute REST with ONE gcloud access token. A gcloud process costs
# 4-5 s on this machine (measured 2026-10-12), and a job made ~15 of them (83 s "upload").
$script:Tok = $null; $script:TokAt = [DateTime]::MinValue
# The token is cached DPAPI-encrypted (CurrentUser) for 40 min: `gcloud auth print-access-token`
# alone costs ~4 s. Never printed; the file is unreadable to other users.
$TokFile = Join-Path $Root 'cloud-token.dpapi'
function Get-Token {
  if ($script:Tok -and ([DateTime]::UtcNow - $script:TokAt).TotalMinutes -lt 40) { return $script:Tok }
  try {
    if ((Test-Path -LiteralPath $TokFile) -and ([DateTime]::UtcNow - (Get-Item -LiteralPath $TokFile).LastWriteTimeUtc).TotalMinutes -lt 40) {
      $script:Tok = [Net.NetworkCredential]::new('', ((Get-Content -LiteralPath $TokFile -Raw).Trim() | ConvertTo-SecureString)).Password
      $script:TokAt = (Get-Item -LiteralPath $TokFile).LastWriteTimeUtc
      if ($script:Tok) { return $script:Tok }
    }
  } catch {}
  $script:Tok = ((& gcloud auth print-access-token 2>$null) | Out-String).Trim(); $script:TokAt = [DateTime]::UtcNow
  if (-not $script:Tok) { throw 'gcloud auth print-access-token failed (gcloud auth login)' }
  try { [IO.File]::WriteAllText($TokFile, (ConvertTo-SecureString $script:Tok -AsPlainText -Force | ConvertFrom-SecureString)) } catch {}
  $script:Tok
}
$script:Http = [Net.Http.HttpClient]::new(); $script:Http.Timeout = [TimeSpan]::FromMinutes(30)
$BucketName = "$CtlProject-devcloud-jobs"
function Invoke-Api([string]$method, [string]$url, $content = $null) {
  for ($try = 0; $try -lt 2; $try++) {
    $req = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($method), $url)
    $req.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', (Get-Token))
    if ($null -ne $content) { $req.Content = $content }
    $r = $script:Http.SendAsync($req).GetAwaiter().GetResult()
    $body = $r.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    # 401 = cached token expired/revoked early: drop it and retry once (body-less requests only;
    # an upload stream is already consumed).
    if ([int]$r.StatusCode -eq 401 -and $try -eq 0 -and $null -eq $content) { $script:Tok = $null; Remove-Item -LiteralPath $TokFile -ErrorAction SilentlyContinue; continue }
    if ([int]$r.StatusCode -eq 401) { Remove-Item -LiteralPath $TokFile -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ code = [int]$r.StatusCode; body = $body }
  }
}
function Read-Obj([string]$name) {
  $r = Invoke-Api GET "https://storage.googleapis.com/storage/v1/b/$BucketName/o/$([uri]::EscapeDataString($name))?alt=media"
  if ($r.code -eq 200) { return $r.body }; if ($r.code -eq 404) { return $null }; throw "GCS GET $name -> $($r.code) $($r.body)"
}
function Write-Obj([string]$name, [string]$file, [string]$type = 'application/octet-stream') {
  $fs = [IO.File]::OpenRead($file)
  try {
    $c = [Net.Http.StreamContent]::new($fs); $c.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::Parse($type)
    $r = Invoke-Api POST "https://storage.googleapis.com/upload/storage/v1/b/$BucketName/o?uploadType=media&name=$([uri]::EscapeDataString($name))" $c
    if ($r.code -ne 200) { throw "GCS PUT $name -> $($r.code) $($r.body)" }
  } finally { $fs.Dispose() }
}
$VmUrl = "https://compute.googleapis.com/compute/v1/projects/$Project/zones/$Zone/instances/$Vm"
function Get-VmStatus { $r = Invoke-Api GET "$VmUrl`?fields=status"; if ($r.code -ne 200) { throw "compute GET $Vm -> $($r.code) $($r.body)" }; ($r.body | ConvertFrom-Json).status }
function Invoke-VmOp([string]$op) { $r = Invoke-Api POST "$VmUrl/$op"; if ($r.code -ne 200) { throw "compute $op $Vm -> $($r.code) $($r.body)" } }
function Read-Gcs([string]$uri) { Read-Obj ($uri -replace "^gs://$BucketName/", '') }

# ---- read-only devcloud status (ADR 0050): the surface Vitals calls ------------------------------
# `-Status -Json` prints ONE JSON document on stdout - every workspace in the registry, its VM state,
# heartbeat age and queue depth, plus the list of workspaces whose live state could not be measured.
# Read-only by construction: only `gcloud compute instances describe` and `gcloud storage cat|ls`, never
# a suspend/resume/reset/submit and never a journal write. A figure that cannot be measured is $null,
# NEVER 0: an absent heartbeat and a heartbeat of 0 s are different facts (agentq/vitals AGENTS.md).
# The total function order is fixed (v, at, workspaces, unavailable) so a consumer can pin a schema.
function Get-DevcloudHeartbeat([string]$ws) {
  # No object -> $null (the caller records it in `unavailable`); a present but unparseable object is
  # also $null, because a heartbeat nobody can read is a heartbeat nobody has.
  $raw = ''
  try { $raw = @(& gcloud storage cat "$Bucket/ws/$ws/heartbeat" 2>$null) -join "`n" } catch { $raw = '' }
  if (-not "$raw".Trim()) { return $null }
  try { return ($raw | ConvertFrom-Json) } catch { return $null }
}
function Get-DevcloudQueueDepth([string]$ws) {
  # One object per queued job; the count is a real measurement, so an empty queue is 0. A listing that
  # fails is $null (not measured), never 0 - the same rule the heartbeat follows.
  try { return [int]@(& gcloud storage ls "$Bucket/ws/$ws/queue/" 2>$null | Where-Object { $_ -and "$_".Trim() }).Count } catch { return $null }
}
function Get-DevcloudWorkspaceRow([string]$ws, [string]$project, [string]$zone) {
  $vm = "ws-$ws"
  $why = @()
  $hb = Get-DevcloudHeartbeat $ws
  if (-not $hb) { $why += "no heartbeat at ws/$ws/heartbeat (the agent publishes one every 30 s)" }

  # VM state, read-only. A describe that fails (unknown ws, no permission) leaves the state UNKNOWN and
  # is reported in `unavailable` rather than being guessed from the heartbeat.
  $vst = ''
  try {
    $vj = @(& gcloud compute instances describe $vm --project $project --zone $zone --format=json 2>$null) -join "`n"
    if ("$vj".Trim()) { $vst = [string](($vj | ConvertFrom-Json).status) } else { $why += "VM $vm was not described in $project/$zone" }
  } catch { $why += "VM describe failed: $($_.Exception.Message)" }

  $heartbeatAt = $null; $heartbeatAgeSec = $null; $idleSec = $null
  if ($hb) {
    if ($hb.PSObject.Properties['at'] -and $hb.at) {
      # ConvertFrom-Json turns an ISO-8601 string into [DateTime] here (PowerShell 7); ToUniversalTime
      # makes the age independent of this machine's zone (the same cast the human `-Status` path uses).
      $hbDt = [DateTime]$hb.at
      $heartbeatAt = $hbDt.ToUniversalTime().ToString('o')
      $heartbeatAgeSec = [int][math]::Round(([DateTime]::UtcNow - $hbDt.ToUniversalTime()).TotalSeconds)
    }
    if ($hb.PSObject.Properties['idleSec'] -and $null -ne $hb.idleSec) { $idleSec = [int]$hb.idleSec }
  }

  # The VM tells the coarse truth (suspended/stopped); the heartbeat tells idle vs busy while it runs.
  # `suspending` may come from either side (the runner writes it before it calls instances.suspend).
  $hbState = if ($hb -and $hb.PSObject.Properties['state']) { [string]$hb.state } else { '' }
  $state = 'unknown'
  if ($vst -eq 'TERMINATED') { $state = 'stopped' }
  elseif ($vst -eq 'SUSPENDED') { $state = 'suspended' }
  elseif ($vst -eq 'SUSPENDING') { $state = 'suspending' }
  elseif ($hbState -in @('idle', 'busy', 'suspending')) { $state = $hbState }

  $row = [ordered]@{ ws = $ws; vm = $vm; project = $project; zone = $zone; state = $state
    heartbeatAt = $heartbeatAt; heartbeatAgeSec = $heartbeatAgeSec; idleSec = $idleSec; queueDepth = (Get-DevcloudQueueDepth $ws) }
  [pscustomobject]@{ row = $row; why = @($why) }
}
function Get-DevcloudStatusDoc {
  $doc = [ordered]@{ v = 1; at = [DateTime]::UtcNow.ToString('o'); workspaces = @(); unavailable = @() }
  foreach ($name in @($Registry.Keys | Sort-Object)) {
    $r = Get-DevcloudWorkspaceRow -ws $name -project $Registry[$name].project -zone $Registry[$name].zone
    $doc.workspaces += $r.row
    if (@($r.why).Count) { $doc.unavailable += [ordered]@{ ws = $name; why = (@($r.why) -join '; ') } }
  }
  $doc
}

if ($Status) {
  # `-Status -Json` is the read-only machine surface Vitals calls (ADR 0050): stdout is the JSON and
  # nothing else. The block below it is the human table `-Status` has always printed, unchanged.
  if ($Json) { Out-Line ((Get-DevcloudStatusDoc) | ConvertTo-Json -Depth 6); exit 0 }
  & gcloud compute instances describe $Vm --project $Project --zone $Zone --format='table(name,status,machineType.basename(),lastStartTimestamp,lastSuspendedTimestamp)' 2>&1 | ForEach-Object { Out-Line "$_" }
  $hbRaw = Read-Gcs "$Bucket/ws/$Ws/heartbeat"
  Out-Line "heartbeat: $hbRaw".TrimEnd()
  # The one-line diagnosis this cost an hour to reach by hand: RUNNING + a heartbeat that stopped moving
  # means the agent is wedged, not idle, and the queue will never be read.
  try {
    $hb = $hbRaw | ConvertFrom-Json
    $vst = Get-VmStatus
    if ($hb.PSObject.Properties['at'] -and $vst -eq 'RUNNING') {
      # ConvertFrom-Json turns an ISO-8601 string into [DateTime] here (PowerShell 7), so cast rather
      # than re-stringifying: "$($hb.at)" would be formatted for the local culture and fail to parse.
      $hbAge = [math]::Round(([DateTime]::UtcNow - ([DateTime]$hb.at).ToUniversalTime()).TotalSeconds)
      # 30 s is the heartbeat cadence and 300 s is ten missed beats: below that the agent may just be
      # between ticks, so the middle band reports what it sees instead of advising a reset.
      if ($hbAge -gt 300) { Out-Line "agent: STALE ${hbAge}s (heartbeat state '$($hb.state)') - reset it: gcloud compute instances reset $Vm --zone $Zone --project $Project" }
      elseif ($hbAge -gt 90) { Out-Line "agent: quiet ${hbAge}s (heartbeat state '$($hb.state)'; it beats every 30 s) - read again in a minute, then: gcloud compute instances reset $Vm --zone $Zone --project $Project" }
      else { Out-Line "agent: ok (${hbAge}s ago, state '$($hb.state)')" }
    } elseif ($vst -ne 'RUNNING') { Out-Line "agent: n/a ($Vm is $vst)" }
  } catch { Out-Line "agent: unknown ($($_.Exception.Message))" }
  & gcloud storage ls "$Bucket/ws/$Ws/queue/" 2>$null | ForEach-Object { Out-Line "queued: $_" }
  exit 0
}
if ($Suspend) { Invoke-VmOp suspend; Out-Line "suspend requested for $Vm"; exit 0 }
if (-not $Rest.Count) { [Console]::Error.WriteLine('agentq-cloud: no command (put it after --)'); exit 2 }
if (-not $Purpose -or $Purpose.Length -lt 3) { [Console]::Error.WriteLine('agentq-cloud: -Purpose is required'); exit 2 }

# ---- repo + delta ---------------------------------------------------------------------------
$repoDir = if ($RepoArg) { $RepoArg } else { (Get-Location).Path }
$top = (& git -C $repoDir rev-parse --show-toplevel 2>$null); if (-not $top) { [Console]::Error.WriteLine("agentq-cloud: $repoDir is not a git repo"); exit 2 }
$top = $top -replace '/', '\'
$common = (& git -C $top rev-parse --path-format=absolute --git-common-dir)
$repoName = (Split-Path (Split-Path $common -Parent) -Leaf).ToLowerInvariant()
$head = (& git -C $top rev-parse HEAD).Trim()
$id = '{0}-{1}' -f [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
$tmp = Join-Path ([IO.Path]::GetTempPath()) "agentq-cloud-$id"; New-Item -ItemType Directory -Force $tmp | Out-Null
$cmd = ($Rest | ForEach-Object { $s = "$_"; if ($s -match '^[\w@./:=,+-]+$') { $s } else { "'" + ($s -replace "'", "'\''") + "'" } }) -join ' '
$t0 = [DateTime]::UtcNow
$prevEap = $ErrorActionPreference
$submitted = $false
# Circuit breaker (2026-10-17): ws-codai was deleted and every hook paid ~5 s of gcloud plus a
# failed commit before anyone noticed. A failure before the queue entry exists records
# cloud-down/<ws>.json; agentq reads it and places runs locally until it expires.
$DownDir = Join-Path $Root 'cloud-down'; $DownFile = Join-Path $DownDir "$Ws.json"
$DownMin = if ($env:AGENTQ_CLOUD_DOWN_MIN) { [int]$env:AGENTQ_CLOUD_DOWN_MIN } else { 15 }
try {
  # 1. resume first (runs in parallel with delta building)
  $st = Get-VmStatus; $resumeFrom = $st; $resumeAt = $null
  if ($st -eq 'SUSPENDED') { Invoke-VmOp resume; $resumeAt = [DateTime]::UtcNow; Out-Line "[agentq-cloud] resuming $Vm (was SUSPENDED)" }
  elseif ($st -eq 'TERMINATED') { Invoke-VmOp start; $resumeAt = [DateTime]::UtcNow; Out-Line "[agentq-cloud] starting $Vm (was TERMINATED)" }
  elseif ($st -eq 'SUSPENDING') { Out-Line "[agentq-cloud] $Vm is SUSPENDING; will resume when it settles" }

  # 2. bundle: newest known sha that is an ancestor of HEAD
  $known = @(); $kj = Read-Gcs "$Bucket/ws/$Ws/repos/$repoName.json"
  if ($kj) { try { $known = @(($kj | ConvertFrom-Json).shas) } catch {} }
  $base = $null
  foreach ($k in $known) { & git -C $top merge-base --is-ancestor $k $head 2>$null; if ($LASTEXITCODE -eq 0) { $base = $k; break } }
  $hasBundle = $base -ne $head
  if ($hasBundle) {
    $bf = Join-Path $tmp 'bundle'
    $ErrorActionPreference = 'Continue'
    if ($base) { & git -C $top bundle create -q $bf HEAD "^$base" 2>&1 | Out-Null } else { & git -C $top bundle create -q $bf HEAD 2>&1 | Out-Null }
    $rc = $LASTEXITCODE; $ErrorActionPreference = $prevEap
    if ($rc) { throw "git bundle create failed (rc $rc)" }
    Out-Line ("[agentq-cloud] bundle {0} ({1:N1} MB, base {2})" -f $(if ($base) { "$($base.Substring(0,9))..$($head.Substring(0,9))" } else { "full $($head.Substring(0,9))" }), ((Get-Item $bf).Length / 1MB), $(if ($base) { 'known' } else { 'none' }))
  } else { Out-Line "[agentq-cloud] workspace already has $($head.Substring(0,9)), no bundle" }

  # 3. patch: working tree vs HEAD incl. untracked, in a temp index (shared index untouched)
  $hasPatch = $false
  if (-not $NoPatch) {
    $pf = Join-Path $tmp 'patch'; $ix = Join-Path $tmp 'index'
    $oldIx = $env:GIT_INDEX_FILE; $env:GIT_INDEX_FILE = $ix
    $ErrorActionPreference = 'Continue'
    try {
      # seed from the real index (read only, copied): its stat cache makes `add -A` 5x faster;
      # read-tree HEAD then resets the entries so staged-vs-unstaged does not matter.
      $realIx = Join-Path ((& git -C $top rev-parse --absolute-git-dir) -replace '/', '\') 'index'
      if (Test-Path -LiteralPath $realIx) { [IO.File]::Copy($realIx, $ix, $true) }
      & git -C $top read-tree HEAD 2>&1 | Out-Null
      & git -C $top add -A 2>&1 | Out-Null
      & git -C $top diff --cached --binary --no-color --no-ext-diff --output=$pf HEAD 2>&1 | Out-Null
      $rc = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prevEap; if ($null -ne $oldIx) { $env:GIT_INDEX_FILE = $oldIx } else { Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue } }
    if ($rc) { throw "git diff for the patch failed (rc $rc)" }
    $hasPatch = (Test-Path $pf) -and (Get-Item $pf).Length -gt 0
    Out-Line ("[agentq-cloud] patch {0}" -f $(if ($hasPatch) { '{0:N1} KB' -f ((Get-Item $pf).Length / 1KB) } else { 'none (clean tree)' }))
  }

  # 4. upload artefacts, then the queue entry LAST (the agent may claim it the moment it lands)
  if ($hasBundle) { Write-Obj "jobs/$id/bundle" (Join-Path $tmp 'bundle') }
  if ($hasPatch) { Write-Obj "jobs/$id/patch" (Join-Path $tmp 'patch') }
  # argv: Windows workspaces quote for PowerShell from the raw tokens (cmd is POSIX-quoted for bash).
  $spec = [ordered]@{ v = 1; id = $id; repo = $repoName; sha = $head; bundle = $hasBundle; patch = $hasPatch; cmd = $cmd; argv = @($Rest | ForEach-Object { "$_" })
    timeoutSec = $TimeoutMin * 60; lane = $Lane; purpose = $Purpose; session = $Session; noInstall = $NoInstall
    submittedAt = [DateTime]::UtcNow.ToString('o'); client = $env:COMPUTERNAME }
  $sf = Join-Path $tmp 'spec.json'; [IO.File]::WriteAllText($sf, ($spec | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  Write-Obj "ws/$Ws/queue/$id.json" $sf 'application/json'
  $submitted = $true
  Remove-Item -LiteralPath $DownFile -ErrorAction SilentlyContinue
  $queuedAt = [DateTime]::UtcNow
  $submitSec = [math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 1)
  Write-Journal @{ event = 'cloud-queued'; resource = "cloud:$Ws"; repo = $repoName; purpose = $Purpose; lane = $Lane; kind = 'cloud'; id = $id; command = $cmd; sha = $head; submitSec = $submitSec }
  Out-Line "[agentq-cloud] queued $id on $Vm ($Project/$Zone) in ${submitSec}s: $cmd"

  # 5. a SUSPENDING vm cannot be resumed until it is SUSPENDED
  if ($st -eq 'SUSPENDING') {
    $until = [DateTime]::UtcNow.AddMinutes(5)
    while ((Get-VmStatus) -eq 'SUSPENDING' -and [DateTime]::UtcNow -lt $until) { Start-Sleep 5 }
    if ((Get-VmStatus) -eq 'SUSPENDED') { Invoke-VmOp resume; $resumeAt = [DateTime]::UtcNow; Out-Line "[agentq-cloud] resuming $Vm" }
  }

  # 6. stream the log until result.json exists
  $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMin + 15)
  $hardDeadline = $queuedAt.AddMinutes($TimeoutMin + 135)   # a ceiling on every deadline extension below
  $printed = 0; $claimedAt = $null; $runningAt = $null; $result = $null
  # Repeated, BOUNDED, backed-off heal. The old one-shot $healedAt guard meant a SECOND failure was never
  # healed and the run died at the deadline with "no result before deadline" (38 in the journal). Each
  # attempt is (a) taken only when the workspace is stale, idle AND no peer job is in flight, (b) counted,
  # and (c) paced by a doubling backoff. The cursor is reset after every EVALUATED attempt (heal or skip),
  # so the evidence is read at most once per interval rather than on every 1.5 s tick.
  $HealMax = 3
  $healCount = 0
  $healCursor = $queuedAt
  $skippedPeers = @{}
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($resumeAt -and -not $runningAt) { if ((Get-VmStatus) -eq 'RUNNING') { $runningAt = [DateTime]::UtcNow; Out-Line ("[agentq-cloud] {0} RUNNING after {1:N0}s" -f $Vm, ($runningAt - $resumeAt).TotalSeconds) } }
    if (-not $claimedAt) { if (Read-Gcs "$Bucket/jobs/$id/claimed") { $claimedAt = [DateTime]::UtcNow } }
    # Cheap pre-filter: no evidence is read (no GCS, no compute) until this attempt's backoff has elapsed.
    $sinceCursor = ([DateTime]::UtcNow - $healCursor).TotalMinutes
    if (-not $claimedAt -and -not $NoHeal -and $healCount -lt $HealMax -and $sinceCursor -ge (Get-HealBackoffMin -HealsDone $healCount -FirstMin $StaleClaimMin)) {
      $sinceQueue = ([DateTime]::UtcNow - $queuedAt).TotalMinutes
      $hbAt = $null
      try { $hb = (Read-Gcs "$Bucket/ws/$Ws/heartbeat") | ConvertFrom-Json; if ($hb.PSObject.Properties['at']) { $hbAt = ([DateTime]$hb.at).ToUniversalTime() } } catch { $hbAt = $null }
      $hbAge = if ($hbAt) { [math]::Round(([DateTime]::UtcNow - $hbAt).TotalSeconds) } else { $null }
      # Older than the submission is the precise test; silent for the whole wait is the same thing seen
      # from the workspace's clock, so the OR survives a skew between it and this machine.
      # ws/<ws>/busy is written by the runner while it runs ANY job; honour it before touching the VM.
      $busyRaw = $null
      try { $busyRaw = Read-Gcs "$Bucket/ws/$Ws/busy" } catch { $busyRaw = $null }
      $peerBusy = Test-CloudPeerBusy -Marker $busyRaw -SelfJobId $id -Now ([DateTime]::UtcNow)
      $dec = Get-CloudHealDecision -NoHeal $false -Claimed $false -HealCount $healCount -HealMax $HealMax `
        -SinceCursorMin $sinceCursor -FirstIntervalMin $StaleClaimMin `
        -HeartbeatAgeSec $hbAge -HeartbeatOlderThanQueue ([bool]($hbAt -and $hbAt -lt $queuedAt)) -PeerBusy $peerBusy
      $healCursor = [DateTime]::UtcNow   # an evaluated attempt: the next one waits a full backoff
      switch ($dec.action) {
        'act' {
          $vst = Get-VmStatus
          $act = if ($vst -eq 'RUNNING') { 'reset' } elseif ($vst -eq 'SUSPENDED') { 'resume' } else { $null }
          if ($act) {
            Invoke-VmOp $act
            $healCount++
            Out-Line ("[agentq-cloud] unclaimed after {0:N0} min and the heartbeat is {1}s old ($Vm $vst) - heal #{2}/{3}: {4} {5}, waiting" -f $sinceQueue, $hbAge, $healCount, $HealMax, $act, $Vm)
            Write-Journal @{ event = 'cloud-heal'; resource = "cloud:$Ws"; repo = $repoName; purpose = $Purpose; lane = $Lane; kind = 'cloud'; id = $id; attempt = $healCount; maxAttempts = $HealMax; vmState = $vst; heartbeatAgeSec = $hbAge; action = $act }
          } else { Out-Line ("[agentq-cloud] unclaimed after {0:N0} min and the heartbeat is {1}s old but $Vm is $vst - leaving it alone" -f $sinceQueue, $hbAge) }
        }
        'skip-peer' {
          # NEVER reset a workspace a peer is running on. Journal once per peer job and keep waiting; the
          # peer marker carries its own deadline, so this clears itself when that run's timeout passes.
          $peerJob = ''
          if ($busyRaw) { try { $bp = $busyRaw | ConvertFrom-Json; if ($bp.PSObject.Properties['job']) { $peerJob = "$($bp.job)" } } catch {} }
          $peerKey = if ($peerJob) { $peerJob } else { 'unknown' }
          if (-not $skippedPeers.ContainsKey($peerKey)) {
            $skippedPeers[$peerKey] = [DateTime]::UtcNow
            Out-Line ("[agentq-cloud] unclaimed after {0:N0} min but another job ({1}) is in flight on $Vm - NOT resetting, waiting" -f $sinceQueue, $peerKey)
            Write-Journal @{ event = 'cloud-heal-skipped'; resource = "cloud:$Ws"; repo = $repoName; purpose = $Purpose; lane = $Lane; kind = 'cloud'; id = $id; peerJob = $peerKey; heartbeatAgeSec = $hbAge; reason = 'peer job in flight' }
          }
        }
      }
      # Extend the deadline so this attempt's next backoff (plus one stale window) can be reached, instead
      # of the old flat +10 min - bounded by $hardDeadline so a stuck run still ends on its own.
      $want = [DateTime]::UtcNow.AddMinutes((Get-HealBackoffMin -HealsDone $healCount -FirstMin $StaleClaimMin) + $StaleClaimMin)
      if ($want -gt $hardDeadline) { $want = $hardDeadline }
      if ($deadline -lt $want) { $deadline = $want }
    }
    $logTxt = Read-Gcs "$Bucket/jobs/$id/log"
    if ($logTxt -and $logTxt.Length -gt $printed) { [Console]::Out.Write($logTxt.Substring($printed)); $printed = $logTxt.Length; if (-not $claimedAt) { $claimedAt = [DateTime]::UtcNow } }
    $r = Read-Gcs "$Bucket/jobs/$id/result.json"
    if ($r) {
      $result = $r | ConvertFrom-Json
      $logTxt = Read-Gcs "$Bucket/jobs/$id/log"; if ($logTxt -and $logTxt.Length -gt $printed) { [Console]::Out.Write($logTxt.Substring($printed)) }
      break
    }
    Start-Sleep -Milliseconds 1500
  }
  $end = [DateTime]::UtcNow
  if (-not $result) {
    Write-Journal @{ event = 'cloud-fail'; resource = "cloud:$Ws"; repo = $repoName; purpose = $Purpose; lane = $Lane; kind = 'cloud'; id = $id; reason = 'no result before deadline'; holdSec = [math]::Round(($end - $t0).TotalSeconds, 1); waitSec = 0 }
    # A run with no result still owes the repo its evidence: whatever log had been streamed, so a wedged
    # run is a dated artefact rather than a story (exit 3 = timed out waiting after submit).
    try {
      $ev = Save-CloudEvidence -RepoDir $top -JobId $id -Log $logTxt -ExitCode 3 -TotalSec (($end - $t0).TotalSeconds) -Purpose $Purpose -Lane $Lane -Region "$Vm, $Project $Zone" -Command $cmd
      Out-Line ("[agentq-cloud] evidence {0} ({1} bytes) -> {2}" -f $ev.logRelative, $ev.logBytes, $(if ($ev.journalAdded) { "$($ev.journalPath) (row appended)" } else { $ev.journalSkipped }))
    } catch { [Console]::Error.WriteLine("agentq-cloud: evidence not written ($($_.Exception.Message))") }
    [Console]::Error.WriteLine("agentq-cloud: no result for $id within $($TimeoutMin + 15) min (log: $Bucket/jobs/$id/log)"); exit 3
  }
  $claimRef = if ($claimedAt) { $claimedAt } else { $end }
  $waitSec = [math]::Round(($claimRef - $queuedAt).TotalSeconds, 1)
  $resumeSec = if ($resumeAt -and $runningAt) { [math]::Round(($runningAt - $resumeAt).TotalSeconds, 1) } else { $null }
  $ev = if ([int]$result.exit -eq 0) { 'cloud-done' } else { 'cloud-fail' }
  $j = @{ event = $ev; resource = "cloud:$Ws"; repo = $repoName; purpose = $Purpose; lane = $Lane; kind = 'cloud'; id = $id; command = $cmd
    exit = [int]$result.exit; waitSec = $waitSec; submitSec = $submitSec; holdSec = [double]$result.durSec; durSec = [math]::Round(($end - $t0).TotalSeconds, 1)
    phases = $(if ($result.PSObject.Properties['phases']) { $result.phases } else { @{} }); host = $(if ($result.PSObject.Properties['host']) { $result.host } else { '' }); resumeFrom = $resumeFrom }
  if ($null -ne $resumeSec) { $j.resumeSec = $resumeSec }
  Write-Journal $j
  $ph = $result.PSObject.Properties['phases']; $ph = if ($ph) { $ph.Value } else { $null }
  $P = { param($n) if ($ph -and $ph.PSObject.Properties[$n]) { $ph.$n } else { '-' } }
  Out-Line ("[agentq-cloud] {0} exit={1} total {2:N1}s (upload {3:N1}s, queue->claim {4:N1}s{5}, remote {6:N1}s: sync {7} install {8} run {9})" -f $id, $result.exit, ($end - $t0).TotalSeconds, $submitSec, $waitSec, $(if ($null -ne $resumeSec) { ", resume ${resumeSec}s" } else { '' }), $result.durSec, (& $P 'sync'), (& $P 'install'), (& $P 'run'))
  # Versioned evidence, in the target repo. Never fatal: a repo that cannot take it must not turn a green
  # run red, and the journal row is skipped (loudly) rather than the file being invented.
  try {
    $ev = Save-CloudEvidence -RepoDir $top -JobId $id -Log $logTxt -ExitCode ([int]$result.exit) -TotalSec (($end - $t0).TotalSeconds) -Purpose $Purpose -Lane $Lane -Region "$Vm, $Project $Zone" -Command $cmd
    Out-Line ("[agentq-cloud] evidence {0} ({1} bytes) -> {2}" -f $ev.logRelative, $ev.logBytes, $(if ($ev.journalAdded) { "$($ev.journalPath) (row appended)" } else { $ev.journalSkipped }))
    if ($ev.runsIgnored) { Out-Line "[agentq-cloud] $($ev.logRelative) is gitignored - the log stays local (no .gitignore edit made)" }
  } catch { [Console]::Error.WriteLine("agentq-cloud: evidence not written ($($_.Exception.Message))") }
  exit ([int]$result.exit)
} catch {
  $ErrorActionPreference = $prevEap
  $reason = "$($_.Exception.Message)".Substring(0, [math]::Min(300, "$($_.Exception.Message)".Length))
  Write-Journal @{ event = 'cloud-fail'; resource = "cloud:$Ws"; purpose = $Purpose; lane = $Lane; kind = 'cloud'; id = $id; reason = $reason; submitted = $submitted }
  [Console]::Error.WriteLine("agentq-cloud: $($_.Exception.Message)")
  # Submitted, then the client side died (network, a stream that never came back): the run DID happen on
  # the workspace, so its evidence still belongs in the repo - with what this terminal knew, and a pointer
  # to the canonical log object. NOT submitted is not a cloud run, and writes no evidence.
  if ($submitted) {
    try {
      $partial = Get-Variable -Name logTxt -ValueOnly -ErrorAction SilentlyContinue
      if (-not $partial) { $partial = "# no log was streamed for job $id - read gs://$CtlProject-devcloud-jobs/jobs/$id/log`n" }
      $ev = Save-CloudEvidence -RepoDir $top -JobId $id -Log $partial -ExitCode -1 -TotalSec ([math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 1)) -Purpose $Purpose -Lane $Lane -Region "$Vm, $Project $Zone" -Command $cmd
      Out-Line ("[agentq-cloud] evidence {0} ({1} bytes) -> {2}" -f $ev.logRelative, $ev.logBytes, $(if ($ev.journalAdded) { "$($ev.journalPath) (row appended)" } else { $ev.journalSkipped }))
    } catch { [Console]::Error.WriteLine("agentq-cloud: evidence not written ($($_.Exception.Message))") }
  }
  if (-not $submitted) {
    try {
      New-Item -ItemType Directory -Force $DownDir | Out-Null
      $dm = if ($reason -match '-> 404|was not found') { [math]::Max($DownMin, 120) } else { $DownMin }
      $d = [ordered]@{ ws = $Ws; since = [DateTime]::UtcNow.ToString('o'); until = [DateTime]::UtcNow.AddMinutes($dm).ToString('o'); reason = $reason }
      [IO.File]::WriteAllText("$DownFile.tmp", ($d | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false)); Move-Item -Force "$DownFile.tmp" $DownFile
    } catch {}
    exit 4
  }
  exit 3
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
