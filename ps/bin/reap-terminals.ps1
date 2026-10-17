<#
reap-terminals — close idle shells that AI agents opened and nobody closed (S18-08, 2026-10-17).

Measured 2026-10-17: 468 pwsh processes, 409 of them VS Code terminals (shellIntegration.ps1)
left behind by agent run_in_terminal calls = 27 GB private memory. Nothing ever closed them.

A shell is reaped only when ALL hold:
  - it is pwsh/powershell whose parent is a VS Code / Code - Insiders process and whose command
    line carries shellIntegration.ps1 (an integrated terminal, not a script run by an agent),
  - it is older than -MinAgeHours (default 3),
  - it has NO live child process (nothing is running in it),
  - it burned < -MaxCpuSec CPU seconds across a -SampleSec window (default 1 s over 20 s),
  - it does not hold an agentq ticket or lease (pid not in any queues/*.json or leases/*/*.json).
Newest -KeepNewest idle terminals per VS Code window are kept (default 4), so a person's own open
terminals survive. -WhatIf lists without killing. Every kill is journaled (event reap-terminal).

  reap-terminals.ps1 [-WhatIf] [-MinAgeHours 3] [-KeepNewest 4] [-Json]
EXIT 0 ok, 2 usage.
#>
param([switch]$WhatIf, [double]$MinAgeHours = 3, [int]$KeepNewest = 4, [double]$MaxCpuSec = 1, [int]$SampleSec = 20, [switch]$Json)
$ErrorActionPreference = 'Stop'
$Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
$Journal = Join-Path $Root 'journal.jsonl'

$all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate, PrivatePageCount)
$byId = @{}; $kids = @{}
foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p; $pp = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($pp)) { $kids[$pp] = 0 }; $kids[$pp]++ }

# pids agentq knows about (holders, waiters, lease owners) are never touched
$agentqPids = @{}
foreach ($f in @(Get-ChildItem (Join-Path $Root 'queues') -Recurse -Filter '*.json' -ErrorAction SilentlyContinue) + @(Get-ChildItem (Join-Path $Root 'leases') -Recurse -Filter '*.json' -ErrorAction SilentlyContinue)) {
  try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; if ($j.pid) { $agentqPids[[int]$j.pid] = $true } } catch {}
}
$now = Get-Date
$cand = @(foreach ($p in $all) {
  if ($p.Name -notin 'pwsh.exe', 'powershell.exe') { continue }
  if ("$($p.CommandLine)" -notmatch 'shellIntegration\.ps1') { continue }
  $par = $byId[[int]$p.ParentProcessId]
  if (-not $par -or $par.Name -notmatch '^Code( - Insiders)?\.exe$|^VSCodium') { continue }
  if (($now - $p.CreationDate).TotalHours -lt $MinAgeHours) { continue }
  if ($kids.ContainsKey([int]$p.ProcessId)) { continue }
  if ($agentqPids.ContainsKey([int]$p.ProcessId)) { continue }
  $p
})
# CPU sample: idle shells burn nothing
$t0 = @{}; foreach ($p in $cand) { try { $t0[[int]$p.ProcessId] = (Get-Process -Id $p.ProcessId -ErrorAction Stop).TotalProcessorTime.TotalSeconds } catch {} }
if ($cand.Count) { Start-Sleep -Seconds $SampleSec }
$kids2 = @{}; foreach ($p in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId)) { $kids2[[int]$p.ParentProcessId] = $true }
$skip = [ordered]@{ gone = 0; recycled = 0; busy = 0; child = 0 }
$idle = @(foreach ($p in $cand) {
  $id = [int]$p.ProcessId
  if (-not $t0.ContainsKey($id)) { $skip.gone++; continue }
  try { $gp = Get-Process -Id $id -ErrorAction Stop } catch { $skip.gone++; continue }
  # CIM CreationDate is microsecond-rounded, .NET StartTime is ticks: compare within 2 s
  if ([math]::Abs(($gp.StartTime - $p.CreationDate).TotalSeconds) -gt 2) { $skip.recycled++; continue }
  if (($gp.TotalProcessorTime.TotalSeconds - $t0[$id]) -ge $MaxCpuSec) { $skip.busy++; continue }
  if ($kids2.ContainsKey($id)) { $skip.child++; continue }
  [pscustomobject]@{ pid = $id; parent = [int]$p.ParentProcessId; created = $p.CreationDate; ageH = [math]::Round(($now - $p.CreationDate).TotalHours, 1); privMB = [math]::Round($p.PrivatePageCount / 1MB) }
})
# keep the newest N idle terminals per parent window
$reap = @($idle | Group-Object parent | ForEach-Object { $_.Group | Sort-Object created -Descending | Select-Object -Skip $KeepNewest })
$killed = 0; $freedMB = 0
foreach ($r in $reap) {
  if ($WhatIf) { continue }
  try {
    Stop-Process -Id $r.pid -Force -ErrorAction Stop; $killed++; $freedMB += $r.privMB
    $line = @{ ts = [DateTime]::UtcNow.ToString('o'); session = 'reap-terminals'; event = 'reap-terminal'; pid = $r.pid; ageH = $r.ageH; privMB = $r.privMB } | ConvertTo-Json -Compress
    $m = [Threading.Mutex]::new($false, 'Global\agentq-journal')
    try { try { [void]$m.WaitOne(5000) } catch [Threading.AbandonedMutexException] {}; [IO.File]::AppendAllText($Journal, $line + "`n", [Text.UTF8Encoding]::new($false)) } finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
  } catch {}
}
$terms = @($all | Where-Object { $_.Name -in 'pwsh.exe', 'powershell.exe' -and "$($_.CommandLine)" -match 'shellIntegration\.ps1' })
# registry hygiene: agents/<session>.json entries untouched for a week are pruned
$regDir = Join-Path $Root 'agents'
if (Test-Path $regDir) { Get-ChildItem -LiteralPath $regDir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue }
$sum = [ordered]@{ terminals = $terms.Count; terminalsMB = [int](($terms | Measure-Object PrivatePageCount -Sum).Sum / 1MB); candidates = $cand.Count; idle = $idle.Count
  skipped = ($skip.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '; reapable = $reap.Count; reapableMB = [int](($reap | Measure-Object privMB -Sum).Sum); killed = $killed; freedMB = $freedMB; whatIf = [bool]$WhatIf }
if ($Json) { $sum | ConvertTo-Json -Compress } else { $sum.GetEnumerator() | ForEach-Object { '{0,-11} {1}' -f $_.Key, $_.Value } }
exit 0
