<#
agentq-cloud — run one command on a devcloud warm workspace (DC-037). Job contract: spec/job.md (v1).

  agentq-cloud.ps1 -Ws codai -Purpose 'why' [-Lane gate] [-TimeoutMin 60] [-Repo <dir>] [-NoPatch] -- pnpm --filter @codai/common typecheck
  agentq-cloud.ps1 -Ws codai -Status          VM state + heartbeat + known shas
  agentq-cloud.ps1 -Ws codai -Suspend         suspend now (the agent also does it after idle-min)

WHAT TRAVELS (git delta, never the whole tree)
  base  = HEAD of the local repo. The workspace publishes the shas it has (ws/<ws>/repos/<repo>.json);
          the newest one that is an ancestor of HEAD is the bundle prerequisite, so only the commits it
          lacks travel (`git bundle create <id> <known>..HEAD`). No usable known sha -> full HEAD bundle.
  patch = working tree vs HEAD, untracked included, built in a TEMP index (GIT_INDEX_FILE) so the
          shared index is never touched: read-tree HEAD; add -A; diff --cached --binary HEAD.
FLOW  resume VM if SUSPENDED/TERMINATED -> upload bundle/patch -> queue spec (written LAST) ->
      stream jobs/<id>/log -> result.json -> exit with the remote exit code.
JOURNAL  cloud-queued / cloud-done / cloud-fail in ~/.codai/coord/journal.jsonl with holdSec,
      waitSec (queue -> claimed, includes resume), lane, kind=cloud, resource cloud:<ws>, so
      `agentq metrics` shows cloud runs beside local ones.
EXIT  remote exit code; 3 = could not submit / timed out waiting; 2 = usage.
#>
$Ws = 'codai'; $Purpose = $null; $Lane = 'gate'; $TimeoutMin = 60; $RepoArg = $null; $NoPatch = $false
$Status = $false; $Suspend = $false; $Project = $null; $Zone = $null; $CtlProject = 'dragos-devcloud'; $NoInstall = $false
$argv = @($args); $Rest = @()
$dd = [array]::IndexOf($argv, '--')
if ($dd -ge 0) { $Rest = @($argv | Select-Object -Skip ($dd + 1)); $argv = @($argv | Select-Object -First $dd) }
for ($i = 0; $i -lt $argv.Count; $i++) {
  $a = "$($argv[$i])"; $n = $a.TrimStart('-').ToLowerInvariant()
  $val = { if ($i + 1 -ge $argv.Count) { throw "agentq-cloud: $a needs a value" }; $script:i++; "$($argv[$script:i])" }
  switch ($n) {
    'ws' { $Ws = & $val } 'purpose' { $Purpose = & $val } 'lane' { $Lane = (& $val).ToLowerInvariant() }
    'timeoutmin' { $TimeoutMin = [int](& $val) } 'repo' { $RepoArg = & $val } 'nopatch' { $NoPatch = $true }
    'noinstall' { $NoInstall = $true } 'status' { $Status = $true } 'suspend' { $Suspend = $true }
    'project' { $Project = & $val } 'zone' { $Zone = & $val } 'ctlproject' { $CtlProject = & $val }
    default { [Console]::Error.WriteLine("agentq-cloud: unknown argument '$a' (put the command after --)"); exit 2 }
  }
}
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

# Workspace registry: where each warm workspace lives (VM project/zone). Control plane = $CtlProject.
$Registry = @{ codai = @{ project = 'codai-training'; zone = 'europe-west4-a' } }
if (-not $Registry.ContainsKey($Ws) -and -not ($Project -and $Zone)) { [Console]::Error.WriteLine("agentq-cloud: unknown workspace '$Ws' (known: $($Registry.Keys -join ', '); or pass -Project/-Zone)"); exit 2 }
if (-not $Project) { $Project = $Registry[$Ws].project }
if (-not $Zone) { $Zone = $Registry[$Ws].zone }
$Vm = "ws-$Ws"; $Bucket = "gs://$CtlProject-devcloud-jobs"
$Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
$Journal = Join-Path $Root 'journal.jsonl'
$Session = foreach ($v in $env:AGENTQ_SESSION, $env:COPILOT_SESSION_ID, $env:CLAUDE_SESSION_ID) { if ($v) { $v; break } }
if (-not $Session) { $Session = "term-$(try { (Get-Process -Id $PID).Parent.Id } catch { 0 })" }

function Out-Line([string]$s) { [Console]::Out.WriteLine($s) }
function Write-Journal([hashtable]$e) {
  $e.ts = [DateTime]::UtcNow.ToString('o'); $e.session = $Session
  $line = $e | ConvertTo-Json -Compress -Depth 6
  $m = [Threading.Mutex]::new($false, 'Global\agentq-journal')
  try { try { [void]$m.WaitOne(5000) } catch [Threading.AbandonedMutexException] {}; [IO.File]::AppendAllText($Journal, $line + "`n", [Text.UTF8Encoding]::new($false)) }
  finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
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

if ($Status) {
  & gcloud compute instances describe $Vm --project $Project --zone $Zone --format='table(name,status,machineType.basename(),lastStartTimestamp,lastSuspendedTimestamp)' 2>&1 | ForEach-Object { Out-Line "$_" }
  Out-Line "heartbeat: $((Read-Gcs "$Bucket/ws/$Ws/heartbeat"))".TrimEnd()
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
  $spec = [ordered]@{ v = 1; id = $id; repo = $repoName; sha = $head; bundle = $hasBundle; patch = $hasPatch; cmd = $cmd
    timeoutSec = $TimeoutMin * 60; lane = $Lane; purpose = $Purpose; session = $Session; noInstall = $NoInstall
    submittedAt = [DateTime]::UtcNow.ToString('o'); client = $env:COMPUTERNAME }
  $sf = Join-Path $tmp 'spec.json'; [IO.File]::WriteAllText($sf, ($spec | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
  Write-Obj "ws/$Ws/queue/$id.json" $sf 'application/json'
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
  $printed = 0; $claimedAt = $null; $runningAt = $null; $result = $null
  while ([DateTime]::UtcNow -lt $deadline) {
    if ($resumeAt -and -not $runningAt) { if ((Get-VmStatus) -eq 'RUNNING') { $runningAt = [DateTime]::UtcNow; Out-Line ("[agentq-cloud] {0} RUNNING after {1:N0}s" -f $Vm, ($runningAt - $resumeAt).TotalSeconds) } }
    if (-not $claimedAt) { if (Read-Gcs "$Bucket/jobs/$id/claimed") { $claimedAt = [DateTime]::UtcNow } }
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
    [Console]::Error.WriteLine("agentq-cloud: no result for $id within $($TimeoutMin + 15) min (log: $Bucket/jobs/$id/log)"); exit 3
  }
  $claimRef = if ($claimedAt) { $claimedAt } else { $end }
  $waitSec = [math]::Round(($claimRef - $queuedAt).TotalSeconds, 1)
  $resumeSec = if ($resumeAt -and $runningAt) { [math]::Round(($runningAt - $resumeAt).TotalSeconds, 1) } else { $null }
  $ev = if ([int]$result.exit -eq 0) { 'cloud-done' } else { 'cloud-fail' }
  $j = @{ event = $ev; resource = "cloud:$Ws"; repo = $repoName; purpose = $Purpose; lane = $Lane; kind = 'cloud'; id = $id; command = $cmd
    exit = [int]$result.exit; waitSec = $waitSec; submitSec = $submitSec; holdSec = [double]$result.durSec; durSec = [math]::Round(($end - $t0).TotalSeconds, 1)
    phases = $result.phases; host = $result.host; resumeFrom = $resumeFrom }
  if ($null -ne $resumeSec) { $j.resumeSec = $resumeSec }
  Write-Journal $j
  Out-Line ("[agentq-cloud] {0} exit={1} total {2:N1}s (upload {3:N1}s, queue->claim {4:N1}s{5}, remote {6:N1}s: sync {7} install {8} run {9})" -f $id, $result.exit, ($end - $t0).TotalSeconds, $submitSec, $waitSec, $(if ($null -ne $resumeSec) { ", resume ${resumeSec}s" } else { '' }), $result.durSec, $result.phases.sync, $result.phases.install, $result.phases.run)
  exit ([int]$result.exit)
} catch {
  $ErrorActionPreference = $prevEap
  Write-Journal @{ event = 'cloud-fail'; resource = "cloud:$Ws"; purpose = $Purpose; lane = $Lane; kind = 'cloud'; id = $id; reason = "$($_.Exception.Message)".Substring(0, [math]::Min(300, "$($_.Exception.Message)".Length)) }
  [Console]::Error.WriteLine("agentq-cloud: $($_.Exception.Message)"); exit 3
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
