<#
jobs — inspect and manage background jobs registered by job-start.ps1.

  jobs.ps1 list [-All] [-Json]   id, label, state, runtime, expected, last-output age, log
                                 (finished jobs older than 24 h hidden unless -All)
  jobs.ps1 show <id> [-Tail 30]  registry json + computed state + log tail
  jobs.ps1 kill <id>             taskkill /T /F the job's process tree; state killed
  jobs.ps1 prune [-Days 7]       delete finished/dead/killed entries older than -Days
  jobs.ps1 orphans [-Kill]       report pwsh/node/cmd processes running .copilot-tmp scripts or
                                 run-build/agentq whose ancestry has no live VS Code / copilot
                                 process, plus DEAD registry jobs. Reports only; -Kill kills the trees.

States: running | suspect (runtime > 2x expected, or log silent > 5 min) | done | failed | killed |
dead (process gone/recycled without an EXIT marker).
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
. (Join-Path $PSScriptRoot 'agentq-jobs-lib.ps1')

$Verb = 'list'; $Target = $null; $All = $false; $Json = $false; $Kill = $false; $Days = 7; $Tail = 30
$argv = @($args); $i = 0
if ($argv.Count -and "$($argv[0])" -notlike '-*') { $Verb = "$($argv[0])".ToLowerInvariant(); $i = 1 }
while ($i -lt $argv.Count) {
  $a = "$($argv[$i])"
  switch ($a.TrimStart('-').ToLowerInvariant()) {
    'all' { $All = $true }
    'json' { $Json = $true }
    'kill' { $Kill = $true }
    'days' { $i++; $Days = [double]$argv[$i] }
    'tail' { $i++; $Tail = [int]$argv[$i] }
    'id' { $i++; $Target = "$($argv[$i])" }
    default { if ($a -notlike '-*' -and -not $Target) { $Target = $a } else { throw "jobs: unknown argument '$a'" } }
  }
  $i++
}

function Show-List {
  $cut = [DateTime]::UtcNow.AddHours(-24)
  $views = @(foreach ($j in Get-AllJobs) {
      $v = Get-JobView $j
      $end = ConvertTo-JobUtc $j['endedAt']; $st = ConvertTo-JobUtc $j['startedAt']
      $ref = if ($end) { $end } else { $st }
      if (-not $All -and $v.state -notin 'running', 'suspect', 'starting', 'dead' -and $ref -and $ref -lt $cut) { continue }
      $v
    })
  if ($Json) { ConvertTo-Json -InputObject @($views) -Depth 4; return }
  if (-not $views.Count) { 'no jobs' + $(if (-not $All) { ' (finished > 24 h hidden; -All shows them)' }); return }
  $views | ForEach-Object {
    [pscustomobject]@{
      id = $_.id; label = $_.label; state = $_.state.ToUpperInvariant() + $(if ($null -ne $_.exitCode -and $_.state -ne 'running') { "($($_.exitCode))" })
      runMin = $_.runtimeMin; expMin = $_.expectedMin; quietMin = $_.lastOutputAgeMin; log = $_.log
    }
  } | Format-Table -AutoSize | Out-String -Width 260
}

function Get-Target {
  if (-not $Target) { throw "jobs ${Verb}: job id required" }
  $j = Read-Job $Target
  if (-not $j) { [Console]::Error.WriteLine("jobs: no job '$Target' in $(Get-JobDir)"); exit 2 }
  $j
}

function Show-Job {
  $j = Get-Target
  $v = Get-JobView $j
  if ($Json) { [ordered]@{ job = $j; view = $v; tail = @(Read-JobTail "$($j['log'])" $Tail) } | ConvertTo-Json -Depth 5; return }
  $j | ConvertTo-Json -Depth 5
  "computed: state=$($v.state) runtime=$($v.runtimeMin)m expected=$($v.expectedMin)m lastOutput=$($v.lastOutputAgeMin)m ago"
  "--- tail $Tail ($($j['log']))"
  Read-JobTail "$($j['log'])" $Tail | ForEach-Object { "  $_" }
}

function Stop-Tree([int]$procId) {
  $out = & taskkill.exe /T /F /PID $procId 2>&1
  @($out | ForEach-Object { "$_" })
}

function Invoke-Kill {
  $j = Get-Target
  $procId = [int]$j['pid']
  if (Test-JobPidAlive $procId $j['pidStart']) { Stop-Tree $procId | ForEach-Object { "  $_" } }
  else { "pid $procId is not running (or was recycled); marking killed" }
  Update-Job $j['id'] @{ state = 'killed'; endedAt = (Get-JobIso ([DateTime]::UtcNow)) }
  try { [IO.File]::AppendAllText("$($j['log'])", "KILLED by jobs.ps1 kill at $(Get-JobIso ([DateTime]::UtcNow))`n") } catch { }
  "killed $($j['id'])"
}

function Invoke-Prune {
  $cut = [DateTime]::UtcNow.AddDays(-$Days); $n = 0
  foreach ($j in Get-AllJobs) {
    $v = Get-JobView $j
    if ($v.state -in 'running', 'suspect', 'starting') { continue }
    $end = ConvertTo-JobUtc $j['endedAt']; $st = ConvertTo-JobUtc $j['startedAt']
    $ref = if ($end) { $end } else { $st }
    if ($ref -and $ref -lt $cut) { Remove-Item -LiteralPath (Get-JobFile $j['id']) -Force; $n++ }
  }
  "pruned $n job(s) finished before $(Get-JobIso $cut)"
}

function Invoke-Orphans {
  $t = Get-JobProcTable
  $hostRx = '^(Code - Insiders|Code|copilot|copilot-language-server|claude)(\.exe)?$'
  $isTarget = { param($p) "$($p.Name)" -match '^(pwsh|powershell|node|cmd)\.exe$' -and "$($p.CommandLine)" -match '\.copilot-tmp|run-build|agentq|job-run\.ps1' }
  $rows = @()
  $reported = @{}
  # runners of registered jobs are managed (and shown) via the registry rows below
  $jobPids = @{}; foreach ($j in Get-AllJobs) { if ([int]$j['pid'] -gt 0) { $jobPids[[int]$j['pid']] = 1 } }
  foreach ($p in $t.byId.Values) {
    if ($p.ProcessId -eq $PID) { continue }
    if ($jobPids.ContainsKey([int]$p.ProcessId)) { continue }
    if (-not (& $isTarget $p)) { continue }
    # topmost target in its chain only (do not list every child of one orphan)
    $par = $t.byId[[int]$p.ParentProcessId]
    if ($par -and (& $isTarget $par)) { continue }
    $hasHost = $false; $seen = @{}; $cur = $p
    while ($cur -and -not $seen.ContainsKey([int]$cur.ProcessId)) {
      $seen[[int]$cur.ProcessId] = 1
      if ("$($cur.Name)" -match $hostRx) { $hasHost = $true; break }
      # Task Scheduler children (svchost ancestry) are daemons by design, not orphans
      if ("$($cur.Name)" -eq 'svchost.exe') { $hasHost = $true; break }
      $nxt = $t.byId[[int]$cur.ParentProcessId]
      # a recycled parent pid is newer than the child: not the real parent
      if ($nxt -and $nxt.CreationDate -and $cur.CreationDate -and $nxt.CreationDate -gt $cur.CreationDate) { break }
      $cur = $nxt
    }
    if ($hasHost) { continue }
    # scheduled tasks / wscript launchers are legitimately host-less: skip known daemons
    if ("$($p.CommandLine)" -match 'agentq-sync\.ps1|git-autosync|worktree-prune-task') { continue }
    $cl = "$($p.CommandLine)"; if ($cl.Length -gt 160) { $cl = $cl.Substring(0, 160) + '...' }
    $rows += [pscustomobject]@{ kind = 'process'; pid = [int]$p.ProcessId; name = $p.Name; started = "$($p.CreationDate)"; what = $cl }
    $reported[[int]$p.ProcessId] = 1
  }
  foreach ($j in Get-AllJobs) {
    $v = Get-JobView $j
    if ($v.state -eq 'dead') { $rows += [pscustomobject]@{ kind = 'job-dead'; pid = [int]$j['pid']; name = $j['id']; started = "$($j['startedAt'])"; what = "$($j['label']) -> $($j['log'])" } }
    elseif ($v.state -in 'running', 'suspect' -and -not (Test-JobPidAlive ([int]$j['ownerPid']) $null)) {
      $rows += [pscustomobject]@{ kind = 'job-ownerless'; pid = [int]$j['pid']; name = $j['id']; started = "$($j['startedAt'])"; what = "$($j['label']) (owner pid $($j['ownerPid']) gone; still $($v.state))" }
    }
  }
  if ($Json) { ConvertTo-Json -InputObject @($rows) -Depth 3; return }
  if (-not $rows.Count) { 'no orphans'; return }
  $rows | Format-Table -AutoSize | Out-String -Width 260
  if ($Kill) {
    foreach ($r in $rows | Where-Object kind -eq 'process') { "kill $($r.pid):"; Stop-Tree $r.pid | ForEach-Object { "  $_" } }
    foreach ($r in $rows | Where-Object kind -eq 'job-dead') { Update-Job $r.name @{ state = 'dead'; endedAt = (Get-JobIso ([DateTime]::UtcNow)) } }
  } else { 'report only; re-run with -Kill to kill the listed process trees (check each first)' }
}

switch ($Verb) {
  'list' { Show-List }
  'show' { Show-Job }
  'kill' { Invoke-Kill }
  'prune' { Invoke-Prune }
  'orphans' { Invoke-Orphans }
  default { [Console]::Error.WriteLine("jobs: unknown verb '$Verb' (list|show|kill|prune|orphans)"); exit 2 }
}
