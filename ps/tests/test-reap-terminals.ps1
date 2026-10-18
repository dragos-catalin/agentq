# Behavioural tests for reap-terminals.ps1 with real processes: a stand-in "ptyHost" (pwsh) starts
# idle child "terminals" (pwsh with a unique marker on the command line). Association data comes
# from REAP_TERMINALS_ASSOC_FILE so no VS Code state is read. Nothing outside this test is killed:
# the marker and host name only match processes this script started.
param([string]$Tool = (Join-Path (Split-Path $PSScriptRoot) 'bin\reap-terminals.ps1'))
$ErrorActionPreference = 'Stop'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('reapt-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$mark = 'reapmark' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; New-Item -ItemType Directory -Force $env:AGENTQ_HOME | Out-Null
$env:REAP_TERMINALS_SHELL_MARK = $mark
$env:REAP_TERMINALS_HOST_NAME = '^pwsh\.exe$'
$assoc = Join-Path $tmp 'assoc.txt'
$env:REAP_TERMINALS_ASSOC_FILE = $assoc

# host: starts N idle terminals and waits; writes their pids
function Start-Host([int]$n, [string]$body = 'Start-Sleep 600') {
  $pidFile = Join-Path $tmp ("pids-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
  $script = @"
`$ps = 1..$n | ForEach-Object { Start-Process pwsh -ArgumentList '-NoProfile','-NoLogo','-Command','$body # $mark' -WindowStyle Hidden -PassThru }
(`$ps | ForEach-Object Id) -join ',' | Set-Content '$pidFile'
`$done = @{}
for (`$i = 0; `$i -lt 1200; `$i++) {
  foreach (`$p in `$ps) { if (`$p.HasExited -and -not `$done[`$p.Id]) { `$done[`$p.Id] = 1; Add-Content '$pidFile.codes' ('{0}={1}' -f `$p.Id, `$p.ExitCode) } }
  Start-Sleep -Milliseconds 250
}
"@
  $h = Start-Process pwsh -ArgumentList '-NoProfile', '-Command', $script -WindowStyle Hidden -PassThru
  for ($i = 0; $i -lt 60 -and -not (Test-Path $pidFile); $i++) { Start-Sleep -Milliseconds 500 }
  Start-Sleep 1
  [pscustomobject]@{ Host = $h; Pids = @((Get-Content $pidFile -Raw).Trim() -split ',' | ForEach-Object { [int]$_ }) }
}
function Alive([int]$id) { [bool](Get-Process -Id $id -ErrorAction SilentlyContinue) }
function Run([string[]]$extra) { & pwsh -NoProfile -File $Tool -SampleSec 1 -KeepNewest 0 -GraceSec 6 @extra 2>&1 | Out-String }
function Reaps([int]$id) { @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ConvertFrom-Json | Where-Object { $_.pid -eq $id }) }
# exit code the stand-in host saw for a terminal ($null until it noticed the exit)
function ExitCode([int]$id) { foreach ($f in Get-ChildItem $tmp -Filter '*.codes') { foreach ($l in Get-Content $f.FullName) { if ($l -match "^$id=(-?\d+)$") { return [long]$Matches[1] } } }; $null }

try {
  # 0. interrupt first: a shell that honours Ctrl+C closes itself and is journaled graceful; one that
  # ignores Ctrl+C and never reads `exit` is force-killed only after the grace period.
  $h = Start-Host 1
  # SetConsoleCtrlHandler(NULL, TRUE) = this process ignores Ctrl+C; the busy loop never reads `exit`
  $deafPs1 = Join-Path $tmp 'deaf.ps1'
  $deafReady = Join-Path $tmp 'deaf.ready'
  Set-Content -LiteralPath $deafPs1 -Value (@'
$t = Add-Type -PassThru -Name D -Namespace R -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool SetConsoleCtrlHandler(System.IntPtr h, bool a);'
[void]$t::SetConsoleCtrlHandler([IntPtr]::Zero, $true)
Set-Content -LiteralPath 'READY' -Value 1
while ($true) { Start-Sleep -Milliseconds 200 }
'@).Replace('READY', $deafReady)
  $deaf = Start-Host 1 "& $deafPs1"
  for ($i = 0; $i -lt 60 -and -not (Test-Path $deafReady); $i++) { Start-Sleep -Milliseconds 500 }
  Set-Content -LiteralPath $assoc -Value '#read 1'
  $t = Get-Date
  $out = Run @('-SoftCap', '0', '-PressureMinAgeMin', '0', '-MinAgeHours', '100')
  $took = ((Get-Date) - $t).TotalSeconds
  for ($i = 0; $i -lt 8 -and $null -eq (ExitCode $h.Pids[0]); $i++) { Start-Sleep -Milliseconds 250 }
  $code = ExitCode $h.Pids[0]
  # Stop-Process -Force = TerminateProcess(-1); anything else means the shell ended itself
  Check 'an interruptible terminal closes itself and is journaled graceful' ((-not (Alive $h.Pids[0])) -and (Reaps $h.Pids[0]).how -eq 'graceful' -and $null -ne $code -and $code -ne -1) "code=$code $(Reaps $h.Pids[0] | ConvertTo-Json -Compress)"
  Check 'a terminal ignoring the interrupt is force-killed and journaled forced' ((-not (Alive $deaf.Pids[0])) -and (Reaps $deaf.Pids[0]).how -eq 'forced') "ready=$(Test-Path $deafReady) $(Reaps $deaf.Pids[0] | ConvertTo-Json -Compress)"
  Check 'the force-kill waits for the grace period' ($took -ge 6) "took $took s"
  foreach ($x in $h, $deaf) { Stop-Process -Id $x.Host.Id -Force -ErrorAction SilentlyContinue }

  # 1. pressure mode: plain idle terminals are reaped, chat-associated ones (fg and bg) survive.
  $h = Start-Host 6
  $fg = $h.Pids[0]; $bg = $h.Pids[1]; $plain = $h.Pids[2..5]
  @("$fg fg", "$bg bg", '#read 1') | Set-Content $assoc
  $out = Run @('-SoftCap', '1', '-PressureMinAgeMin', '0', '-CriticalCap', '1000', '-MinAgeHours', '100')
  Start-Sleep 1
  Check 'chat foreground terminal is never reaped' (Alive $fg) $out
  Check 'chat background terminal survives below the critical cap' (Alive $bg) $out
  Check 'plain idle terminals are reaped under pressure' (@($plain | Where-Object { Alive $_ }).Count -eq 0) (($plain | ForEach-Object { "$_=$(Alive $_)" }) -join ' ')
  Check 'summary reports protected chat terminals' ($out -match 'chatProtected\s+2') $out

  # 2. at the critical cap a chat BACKGROUND terminal may go; a chat foreground one still never.
  $out = Run @('-SoftCap', '0', '-PressureMinAgeMin', '0', '-CriticalCap', '2', '-CriticalLow', '1', '-CriticalMinAgeMin', '0', '-MinAgeHours', '100')
  Start-Sleep 1
  Check 'chat background terminal is reaped at the critical cap' (-not (Alive $bg)) $out
  Check 'chat foreground terminal survives even at the critical cap' (Alive $fg) $out
  Stop-Process -Id $h.Host.Id -Force -ErrorAction SilentlyContinue; Stop-Process -Id $fg -Force -ErrorAction SilentlyContinue

  # 2b. hysteresis: crossing the critical cap trims chat background terminals down to CriticalLow
  # in one batch (oldest first), not to one under the cap, so the alerts come rarely.
  $h = Start-Host 5
  ($h.Pids | ForEach-Object { "$_ bg" }) + '#read 1' | Set-Content $assoc
  $out = Run @('-SoftCap', '0', '-PressureMinAgeMin', '0', '-CriticalCap', '5', '-CriticalLow', '2', '-CriticalMinAgeMin', '0', '-MinAgeHours', '100')
  Start-Sleep 1
  Check 'critical cap trims chat background terminals down to CriticalLow in one batch' (@($h.Pids | Where-Object { Alive $_ }).Count -eq 2) (($h.Pids | ForEach-Object { "$_=$(Alive $_)" }) -join ' ')
  Stop-Process -Id $h.Host.Id -Force -ErrorAction SilentlyContinue
  $h.Pids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }

  # 3. association list unreadable: no young terminal is reaped under pressure (3 h rule only).
  $h = Start-Host 3
  Set-Content -LiteralPath $assoc -Value '' -NoNewline
  $out = Run @('-SoftCap', '0', '-PressureMinAgeMin', '0', '-MinAgeHours', '100')
  Start-Sleep 1
  Check 'unreadable association list means no pressure reaping' (@($h.Pids | Where-Object { Alive $_ }).Count -eq 3) $out
  Check 'summary says the association list was not read' ($out -match 'assocRead\s+False') $out
  Stop-Process -Id $h.Host.Id -Force -ErrorAction SilentlyContinue
  $h.Pids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }
} finally {
  Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" | Where-Object { $_.CommandLine -match $mark } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
exit $fail
