# Liveness tests for ps/bin/clean-build-artifacts.ps1 - the single most destructive scheduled task on
# this machine. The gate that keeps it from deleting a live slot's build output must:
#   (1) cross-check BOTH signals - the `agentq status -All -Json` lease LIST and the per-slot lease
#       FILES - and skip a slot EITHER one marks in use;
#   (2) FAIL SAFE: when neither signal is usable (an unreadable/empty coord dir), the run must say
#       `live NOT DETERMINED` and skip slot-rooted candidates - never read the empty scan as "nothing
#       is in use".
# Temp fixtures only. The live E:\gh fleet is never walked or touched.
param([string]$Tool = (Join-Path $PSScriptRoot '..\bin\clean-build-artifacts.ps1'))
$ErrorActionPreference = 'Stop'
$Tool = (Resolve-Path $Tool).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('cbafix-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name`n$detail" -ForegroundColor Red; $script:fail++ }
}
# An idle, deletable-looking directory: a file back-dated two days so the idle gate is not what saves it.
function New-Idle([string]$path) {
  New-Item -ItemType Directory -Force $path | Out-Null
  $f = Join-Path $path 'blob.bin'
  [IO.File]::WriteAllBytes($f, [byte[]]::new(8192))
  [IO.File]::SetLastWriteTimeUtc($f, [DateTime]::UtcNow.AddDays(-2))
  [IO.Directory]::SetLastWriteTimeUtc($path, [DateTime]::UtcNow.AddDays(-2))
}
function Run-Cleaner([object[]]$extra) {
  $argv = @('-NoProfile', '-File', $Tool) + $extra
  $out = @(& pwsh @argv 2>&1 | ForEach-Object { "$_" })
  $script:code = $LASTEXITCODE
  ($out -join "`n")
}

try {
  # ===== (A) BOTH signals are cross-checked: a slot marked by EITHER survives; an unmarked one is deleted
  $rootA = Join-Path $tmp 'A'
  $slotRootA = Join-Path $rootA '.wt'
  $slotFile = Join-Path $slotRootA 'repo\task-1'   # in the LEASE FILE only, absent from the list
  $slotList = Join-Path $slotRootA 'repo\task-2'   # in the LEASE LIST only, no lease file on disk
  $controlA = Join-Path $rootA 'work\.turbo'       # neither signal marks it -> deletable
  New-Idle (Join-Path $slotFile '.turbo')
  New-Idle (Join-Path $slotList '.turbo')
  New-Idle $controlA
  $coordA = Join-Path $tmp 'coordA'
  New-Item -ItemType Directory -Force (Join-Path $coordA 'leases\repo') | Out-Null
  [IO.File]::WriteAllText((Join-Path $coordA 'leases\repo\task-1.json'), (@{ repo = 'repo'; slot = 'task-1'; path = $slotFile; pid = $PID } | ConvertTo-Json -Compress))
  $statusA = (@{ leases = @(@{ repo = 'repo'; slot = 'task-2'; path = $slotList }) } | ConvertTo-Json -Compress)
  $outA = Run-Cleaner @('-Roots', $rootA, '-SlotRoots', $slotRootA, '-CoordDir', $coordA, '-StatusJson', $statusA, '-Log', (Join-Path $tmp 'a.log'), '-MinGB', '0', '-MinIdleHours', '0')
  Check 'A exit 0' ($script:code -eq 0) "code=$($script:code)`n$outA"
  Check 'A slot marked by the LEASE FILE survives (signal 2)' (Test-Path (Join-Path $slotFile '.turbo')) $outA
  Check 'A slot marked by the LEASE LIST survives (signal 1)' (Test-Path (Join-Path $slotList '.turbo')) $outA
  Check 'A in-use skips are reported, not merely omitted' ($outA -match 'SKIP in-use \(skip\)') $outA
  Check 'A the lease-file slot names its signal' ($outA -match 'in use: live lease file') $outA
  Check 'A the lease-list slot names its signal' ($outA -match 'in use: agentq lease list') $outA
  Check 'A an unmarked output is still deleted' (-not (Test-Path $controlA)) $outA

  # ===== (B) an unreadable/empty coord dir + an unusable list is NOT "nothing in use"
  $rootB = Join-Path $tmp 'B'
  $slotRootB = Join-Path $rootB '.wt'
  $slotB = Join-Path $slotRootB 'repo\task-1'
  $controlB = Join-Path $rootB 'work\.turbo'
  New-Idle (Join-Path $slotB '.turbo')
  New-Idle $controlB
  $coordB = Join-Path $tmp 'coordB'; New-Item -ItemType Directory -Force $coordB | Out-Null   # EMPTY
  $outB = Run-Cleaner @('-Roots', $rootB, '-SlotRoots', $slotRootB, '-CoordDir', $coordB, '-StatusJson', '', '-Log', (Join-Path $tmp 'b.log'), '-MinGB', '0', '-MinIdleHours', '0')
  Check 'B exit 0' ($script:code -eq 0) "code=$($script:code)`n$outB"
  Check 'B an empty coord dir says live NOT DETERMINED' ($outB -match 'live NOT DETERMINED') $outB
  Check 'B the slot-rooted output SURVIVES when liveness is not determined' (Test-Path (Join-Path $slotB '.turbo')) $outB
  Check 'B the not-determined skip is reported' ($outB -match 'SKIP not-determined \(skip\)') $outB
  Check 'B repo working-tree output is still cleaned (no refuse-all)' (-not (Test-Path $controlB)) $outB

  # ===== (C) a missing coord dir (not merely empty) is also not determined
  $rootC = Join-Path $tmp 'C'; $slotRootC = Join-Path $rootC '.wt'; $slotC = Join-Path $slotRootC 'repo\task-1'
  New-Idle (Join-Path $slotC '.turbo')
  $outC = Run-Cleaner @('-Roots', $rootC, '-SlotRoots', $slotRootC, '-CoordDir', (Join-Path $tmp 'no-such-coord'), '-StatusJson', 'not json', '-Log', (Join-Path $tmp 'c.log'), '-MinGB', '0', '-MinIdleHours', '0')
  Check 'C a missing coord dir says live NOT DETERMINED' ($outC -match 'live NOT DETERMINED') $outC
  Check 'C the slot-rooted output survives' (Test-Path (Join-Path $slotC '.turbo')) $outC
} finally {
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
