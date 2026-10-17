# devcloud warm workspace bootstrap, Windows (DC-063). Metadata key windows-startup-script-ps1: the GCE agent
# runs this as SYSTEM under Windows PowerShell 5.1 on EVERY boot (not on resume: a resumed VM keeps its
# processes, so the agent simply carries on). Idempotent.
# Image: devcloud-ci-win-desktop (DC-051: git, node 24, pnpm 12 native, pwsh 7, rustup msvc, VS Build Tools,
# Windows SDK, WebView2). Rust versions from a repo's rust-toolchain.toml install on the first cargo call.
# The agent runs as a local admin user `dev` (random password per boot) through a scheduled task, like the
# JIT CI runner (ci-controller/runner-startup.ps1), not as SYSTEM: user-profile paths (pnpm store, %TEMP%,
# WebView2 user data) then behave as on a developer machine.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$D = 'C:\devcloud'
New-Item -ItemType Directory -Force $D | Out-Null
function Say([string]$m) { $l = "$(Get-Date -Format o) $m"; Write-Output $l; Add-Content -Path "$D\startup.log" -Value $l -Encoding ascii }
function MetaAttr([string]$k, [string]$d = '') {
  try { (Invoke-RestMethod -Headers @{ 'Metadata-Flavor' = 'Google' } -Uri "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$k" -TimeoutSec 10).ToString() } catch { $d }
}
$task = 'devcloud-agent'
try {
  $work = MetaAttr 'devcloud-work' 'C:\work'
  New-Item -ItemType Directory -Force $work | Out-Null
  # Suspend needs hibernation off in the guest (GCE suspend docs, "Enable suspend operations on Windows").
  & powercfg.exe /hibernate off
  # Dev-machine parity attempt (DC-063): enable raw IOCTL_DISK_PERFORMANCE counters. MEASURED: not enough on
  # GCE - the boot disk still reports bytes_read 0 after -Y and a reboot (vitals-win
  # the_system_volume_reports_activity_counters stays red); kept because it is harmless and right on Server.
  & diskperf.exe -Y | Out-Null
  try { Add-MpPreference -ExclusionPath $work, 'C:\cargo', 'C:\rustup', 'C:\Users\dev\AppData\Local\pnpm' -ErrorAction Stop } catch { Say "::warn defender: $($_.Exception.Message)" }

  $chars = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'.ToCharArray()
  $pw = -join (1..24 | ForEach-Object { $chars | Get-Random }) + 'a1A!'
  $sec = ConvertTo-SecureString $pw -AsPlainText -Force
  if (Get-LocalUser -Name dev -ErrorAction SilentlyContinue) { Set-LocalUser -Name dev -Password $sec }
  else { New-LocalUser -Name dev -Password $sec -PasswordNeverExpires -AccountNeverExpires -Description 'devcloud workspace agent' | Out-Null }
  if (-not (Get-LocalGroupMember -Group Administrators -Member dev -ErrorAction SilentlyContinue)) { Add-LocalGroupMember -Group Administrators -Member dev }
  & icacls $work /grant 'dev:(OI)(CI)F' /T /Q | Out-Null

  # runner-agent from metadata (always the latest pushed by workspace.ps1); keep the old copy if empty.
  $agent = MetaAttr 'runner-agent' ''
  if ($agent.Length -gt 1000) { [IO.File]::WriteAllText("$D\runner-agent.mjs", $agent, (New-Object Text.UTF8Encoding $false)) }
  if (-not (Test-Path "$D\runner-agent.mjs")) { throw 'runner-agent missing in metadata' }

  # Wrapper = systemd Restart=always: node exits -> restart after 3 s. Log rotates at 20 MB.
  $wrapper = @'
$D = 'C:\devcloud'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
# A profile created by a batch logon has no Start Menu tree, so FOLDERID_Startup does not resolve (vitals-win
# known_folders_resolve). Interactive profiles always have it.
New-Item -ItemType Directory -Force "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" | Out-Null
while ($true) {
  if ((Test-Path "$D\agent.log") -and (Get-Item "$D\agent.log").Length -gt 20MB) { Move-Item -Force "$D\agent.log" "$D\agent.old.log" }
  & 'C:\Program Files\nodejs\node.exe' "$D\runner-agent.mjs" 2>&1 | ForEach-Object { "$_" } | Out-File -FilePath "$D\agent.log" -Append -Encoding utf8
  Add-Content -Path "$D\agent.log" -Value "$(Get-Date -Format o) agent exited rc=$LASTEXITCODE, restarting" -Encoding ascii
  Start-Sleep -Seconds 3
}
'@
  Set-Content -Path "$D\agent-loop.ps1" -Value $wrapper -Encoding ascii
  Get-CimInstance Win32_Process -Filter "Name='node.exe'" | Where-Object { $_.CommandLine -match 'runner-agent\.mjs' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File $D\agent-loop.ps1" -WorkingDirectory $work
  $set = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
  Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
  Register-ScheduledTask -TaskName $task -Action $act -Settings $set -User dev -Password $pw -RunLevel Highest | Out-Null
  $pw = $null; $sec = $null
  Start-ScheduledTask -TaskName $task
  Say "::devcloud-agent started (uptime $([int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds)s)"
  Say 'DEVCLOUD_STARTUP_OK'
} catch {
  Say "::devcloud-startup failed $($_.Exception.Message)"
  exit 1
}
