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

PRESSURE MODE (2026-10-18). One VS Code ptyHost process owns every integrated terminal of a window,
and it costs ~14 MB per terminal. At ~190 terminals it reached 2.6 GB and crashed (exit 0x80000003,
2.6 GB crashpad dumps at each crash, 2026-10-16 20:42 / 10-17 07:25 / 10-18 05:03): every terminal
died at once, agents' running commands hung, and VS Code relaunched 167 shells in the same minute,
so the count was back at the crash line immediately. Agents open terminals far faster than the
3 h age limit retires them. When a ptyHost carries more than -SoftCap terminals, idle ones are
reaped from -PressureMinAgeMin instead (same idle tests), down to -SoftCap.

AGENT TERMINALS (2026-10-18). Pressure mode then killed 507 terminals in a day, and 82 of them were
terminals VS Code still associated with an agent's chat (`chat.terminalSessions` in the workspace
state). Killing one makes VS Code post "terminal exited" into that chat and interrupts the agent -
the "agents freeze until I stop them and say continue" symptom. VS Code disposes those terminals
itself when the command or the chat ends. So a chat-associated terminal is never reaped, with one
exception: when a ptyHost is at -CriticalCap (near the ~190-terminal crash), background ones idle
for -CriticalMinAgeMin are reaped, oldest first, in one batch down to -CriticalLow. If the association list
cannot be read at all, nothing young is reaped (only the 3 h rule applies).

  reap-terminals.ps1 [-WhatIf] [-MinAgeHours 3] [-KeepNewest 4] [-SoftCap 80] [-PressureMinAgeMin 20]
                     [-CriticalCap 150] [-CriticalLow 120] [-CriticalMinAgeMin 30] [-Json]
EXIT 0 ok, 2 usage.
#>
param([switch]$WhatIf, [double]$MinAgeHours = 3, [int]$KeepNewest = 4, [double]$MaxCpuSec = 1, [int]$SampleSec = 20,
  [int]$SoftCap = 80, [double]$PressureMinAgeMin = 20, [int]$CriticalCap = 150, [int]$CriticalLow = 120, [double]$CriticalMinAgeMin = 30,
  [string]$AssocTool = (Join-Path $PSScriptRoot 'vscode-chat-terminals.mjs'), [switch]$Json)
$ErrorActionPreference = 'Stop'
$Root = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
$Journal = Join-Path $Root 'journal.jsonl'
# Test seams: tests run real pwsh "terminals" under a stand-in host, with their own marker.
$ShellMark = if ($env:REAP_TERMINALS_SHELL_MARK) { $env:REAP_TERMINALS_SHELL_MARK } else { 'shellIntegration\.ps1' }
$HostName = if ($env:REAP_TERMINALS_HOST_NAME) { $env:REAP_TERMINALS_HOST_NAME } else { '^Code( - Insiders)?\.exe$|^VSCodium' }

$all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate, PrivatePageCount)
$byId = @{}; $kids = @{}
# conhost.exe is a console host, not work running in the shell, so it never counts as a child.
foreach ($p in $all) { $byId[[int]$p.ProcessId] = $p; if ($p.Name -eq 'conhost.exe') { continue }; $pp = [int]$p.ParentProcessId; if (-not $kids.ContainsKey($pp)) { $kids[$pp] = 0 }; $kids[$pp]++ }

# pids agentq knows about (holders, waiters, lease owners) are never touched
$agentqPids = @{}
foreach ($f in @(Get-ChildItem (Join-Path $Root 'queues') -Recurse -Filter '*.json' -ErrorAction SilentlyContinue) + @(Get-ChildItem (Join-Path $Root 'leases') -Recurse -Filter '*.json' -ErrorAction SilentlyContinue)) {
  try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; if ($j.pid) { $agentqPids[[int]$j.pid] = $true } } catch {}
}
$now = Get-Date
# terminals VS Code tracks for an agent chat: pid -> 'fg' | 'bg'
$chatPid = @{}; $assocOk = $false
if ($env:REAP_TERMINALS_ASSOC_FILE) { $assocLines = @(Get-Content -LiteralPath $env:REAP_TERMINALS_ASSOC_FILE -ErrorAction SilentlyContinue) }
else { $assocLines = @(try { & node $AssocTool 2>$null } catch { @() }) }
foreach ($l in $assocLines) {
  if ($l -match '^(\d+) (fg|bg)$') { $chatPid[[int]$Matches[1]] = $Matches[2] }
  elseif ($l -match '^#read (\d+)$' -and [int]$Matches[1] -gt 0) { $assocOk = $true }
}
# terminals per ptyHost: the parent of an integrated-terminal shell IS the ptyHost process
$perHost = @{}
foreach ($p in $all) {
  if ($p.Name -in 'pwsh.exe', 'powershell.exe' -and "$($p.CommandLine)" -match $ShellMark) {
    $pp = [int]$p.ParentProcessId; if (-not $perHost.ContainsKey($pp)) { $perHost[$pp] = 0 }; $perHost[$pp]++
  }
}
$pressured = @($perHost.Keys | Where-Object { $perHost[$_] -gt $SoftCap })
$critical = @($perHost.Keys | Where-Object { $perHost[$_] -ge $CriticalCap })
$skipChat = 0
$cand = @(foreach ($p in $all) {
  if ($p.Name -notin 'pwsh.exe', 'powershell.exe') { continue }
  if ("$($p.CommandLine)" -notmatch $ShellMark) { continue }
  $par = $byId[[int]$p.ParentProcessId]
  if (-not $par -or $par.Name -notmatch $HostName) { continue }
  $id = [int]$p.ProcessId; $host_ = [int]$p.ParentProcessId
  if ($chatPid.ContainsKey($id)) {
    # an agent's terminal: only a background one, only at the crash line, only after an hour idle
    if (-not ($chatPid[$id] -eq 'bg' -and $host_ -in $critical)) { $skipChat++; continue }
    $minH = $CriticalMinAgeMin / 60
  } elseif ($host_ -in $pressured -and $assocOk) { $minH = $PressureMinAgeMin / 60 }
  else { $minH = $MinAgeHours }
  if (($now - $p.CreationDate).TotalHours -lt $minH) { continue }
  if ($kids.ContainsKey($id)) { continue }
  if ($agentqPids.ContainsKey($id)) { continue }
  $p
})
# CPU sample: idle shells burn nothing
$t0 = @{}; foreach ($p in $cand) { try { $t0[[int]$p.ProcessId] = (Get-Process -Id $p.ProcessId -ErrorAction Stop).TotalProcessorTime.TotalSeconds } catch {} }
if ($cand.Count) { Start-Sleep -Seconds $SampleSec }
$kids2 = @{}; foreach ($p in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name)) { if ($p.Name -ne 'conhost.exe') { $kids2[[int]$p.ParentProcessId] = $true } }
$skip = [ordered]@{ gone = 0; recycled = 0; busy = 0; child = 0 }
$idle = @(foreach ($p in $cand) {
  $id = [int]$p.ProcessId
  if (-not $t0.ContainsKey($id)) { $skip.gone++; continue }
  try { $gp = Get-Process -Id $id -ErrorAction Stop } catch { $skip.gone++; continue }
  # CIM CreationDate is microsecond-rounded, .NET StartTime is ticks: compare within 2 s
  if ([math]::Abs(($gp.StartTime - $p.CreationDate).TotalSeconds) -gt 2) { $skip.recycled++; continue }
  if (($gp.TotalProcessorTime.TotalSeconds - $t0[$id]) -ge $MaxCpuSec) { $skip.busy++; continue }
  if ($kids2.ContainsKey($id)) { $skip.child++; continue }
  [pscustomobject]@{ pid = $id; parent = [int]$p.ParentProcessId; created = $p.CreationDate; ageH = [math]::Round(($now - $p.CreationDate).TotalHours, 2); privMB = [math]::Round($p.PrivatePageCount / 1MB); chat = $chatPid.ContainsKey($id) }
})
# keep the newest N idle terminals per parent window. Under pressure, young (< MinAgeHours) idle
# terminals are taken only until the host is back at SoftCap, oldest first. Chat terminals go in
# one batch down to CriticalLow (hysteresis): each kill raises a VS Code "terminal exited" alert,
# and trimming to just under CriticalCap fired a fresh batch every 10 min as agents opened more.
$reap = @($idle | Group-Object parent | ForEach-Object {
    $sorted = @($_.Group | Sort-Object created -Descending | Select-Object -Skip $KeepNewest)
    $total = [int]$perHost[[int]$_.Name]
    $old = @($sorted | Where-Object { -not $_.chat -and $_.ageH -ge $MinAgeHours })
    $young = @($sorted | Where-Object { -not $_.chat -and $_.ageH -lt $MinAgeHours } | Sort-Object created)
    $excess = [math]::Max(0, $total - $old.Count - $SoftCap)
    $takeYoung = @($young | Select-Object -First $excess)
    $chatBg = @($sorted | Where-Object { $_.chat } | Sort-Object created)
    $critExcess = [math]::Max(0, $total - $old.Count - $takeYoung.Count - $CriticalLow)
    $old
    $takeYoung
    $chatBg | Select-Object -First $critExcess
  })
$killed = 0; $freedMB = 0
foreach ($r in $reap) {
  if ($WhatIf) { continue }
  try {
    Stop-Process -Id $r.pid -Force -ErrorAction Stop; $killed++; $freedMB += $r.privMB
    $line = @{ ts = [DateTime]::UtcNow.ToString('o'); session = 'reap-terminals'; event = 'reap-terminal'; pid = $r.pid; ageH = $r.ageH; privMB = $r.privMB; chat = $r.chat } | ConvertTo-Json -Compress
    $m = [Threading.Mutex]::new($false, 'Global\agentq-journal')
    try { try { [void]$m.WaitOne(5000) } catch [Threading.AbandonedMutexException] {}; [IO.File]::AppendAllText($Journal, $line + "`n", [Text.UTF8Encoding]::new($false)) } finally { try { $m.ReleaseMutex() } catch {}; $m.Dispose() }
  } catch {}
}
$terms = @($all | Where-Object { $_.Name -in 'pwsh.exe', 'powershell.exe' -and "$($_.CommandLine)" -match $ShellMark })
# registry hygiene: agents/<session>.json entries untouched for a week are pruned
$regDir = Join-Path $Root 'agents'
if (Test-Path $regDir) { Get-ChildItem -LiteralPath $regDir -Filter '*.json' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } | Remove-Item -Force -ErrorAction SilentlyContinue }
$sum = [ordered]@{ terminals = $terms.Count; terminalsMB = [int](($terms | Measure-Object PrivatePageCount -Sum).Sum / 1MB)
  pressured = ($pressured | ForEach-Object { "$_=$($perHost[$_])" }) -join ' '; chatTerminals = $chatPid.Count; chatProtected = $skipChat; assocRead = $assocOk
  candidates = $cand.Count; idle = $idle.Count
  skipped = ($skip.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '; reapable = $reap.Count; reapableMB = [int](($reap | Measure-Object privMB -Sum).Sum); killed = $killed; freedMB = $freedMB; whatIf = [bool]$WhatIf }
if ($Json) { $sum | ConvertTo-Json -Compress } else { $sum.GetEnumerator() | ForEach-Object { '{0,-11} {1}' -f $_.Key, $_.Value } }
exit 0
