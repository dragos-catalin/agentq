# guard-tooluse.ps1 ADR 0001 rules: leased-slot delete blocks, raw worktree add/remove blocks, lease
# renewal on touch. Then MUTATION tests: each rule is disabled in a copy of the guard and the
# matching block case must start to PASS through (proves the test actually exercises that rule).
param(
  [string]$Guard = (Join-Path $PSScriptRoot '..\hooks\guard-tooluse.ps1'),
  [string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1')
)
$ErrorActionPreference = 'Stop'
$Guard = (Resolve-Path $Guard).Path
$fx = Join-Path $env:TEMP ('gv2-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:CODAI_WT_ROOT = "$fx\.wt"; $env:AGENTQ_HOME = "$fx\coord"
New-Item -ItemType Directory -Force "$fx\coord\leases\brivio", "$fx\.wt\brivio\task-2", "$fx\.wt\brivio\task-3" | Out-Null
$slot = "$fx\.wt\brivio\task-2"
@{ leaseId = 'L1'; repo = 'brivio'; slot = 'task-2'; path = $slot; session = 'other-agent'; purpose = 'live work' } | ConvertTo-Json | Set-Content "$fx\coord\leases\brivio\task-2.json"
Set-Content "$fx\coord\leases\brivio\task-2.json.hb" ''
$fails = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS $n" } else { Write-Host "FAIL $n $d" -ForegroundColor Red; $script:fails++ } }
# Returns $true when the guard BLOCKS (VS Code dialect: JSON deny on stdout, exit 0).
function Blocks([string]$g, [string]$command, [string]$tool = 'run_in_terminal') {
  $p = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; tool_input = @{ command = $command } } | ConvertTo-Json -Compress
  $out = ($p | pwsh -NoProfile -File $g 2>$null) -join ''
  $out -match '"permissionDecision":"deny"'
}
$cases = [ordered]@{
  'rm leased slot'                  = @{ cmd = "Remove-Item -Recurse -Force '$slot'"; block = $true; rule = 'lease-delete' }
  'rmdir /s leased slot'            = @{ cmd = "cmd /c rmdir /s /q `"$slot`""; block = $true; rule = 'lease-delete' }
  'rm -rf parent of leased slot'    = @{ cmd = "Remove-Item -Recurse -Force '$fx\.wt\brivio'"; block = $true; rule = 'lease-delete' }
  'delete file inside slot allowed' = @{ cmd = "Remove-Item '$slot\src\a.ts'"; block = $false; rule = '' }
  'rm leased slot trailing slash'   = @{ cmd = "Remove-Item -Recurse '$slot\'"; block = $true; rule = 'lease-delete' }
  'rm unleased slot allowed'        = @{ cmd = "Remove-Item -Recurse -Force '$fx\.wt\brivio\task-3'"; block = $false; rule = '' }
  'worktree.ps1 prune allowed'      = @{ cmd = "pwsh -NoProfile -File C:\x\worktree.ps1 prune -All"; block = $false; rule = '' }
  'raw worktree add (even in .wt)'  = @{ cmd = "git -C E:\gh\brivio worktree add $fx\.wt\brivio\x HEAD"; block = $true; rule = 'raw-add' }
  'raw worktree remove'             = @{ cmd = "git -C E:\gh\brivio worktree remove $fx\.wt\brivio\task-3"; block = $true; rule = 'raw-remove' }
  'raw worktree move'               = @{ cmd = "git worktree move a b"; block = $true; rule = 'raw-remove' }
  'agentq lease allowed'            = @{ cmd = "pwsh -NoProfile -File C:\x\agentq.ps1 lease -Purpose x"; block = $false; rule = '' }
  'read inside leased slot allowed' = @{ cmd = "Get-Content '$slot\a.txt'"; block = $false; rule = '' }
}
foreach ($k in $cases.Keys) { $c = $cases[$k]; Check "guard: $k" ((Blocks $Guard $c.cmd) -eq $c.block) $c.cmd }

# renewal: touching the slot refreshes its heartbeat
[IO.File]::SetLastWriteTimeUtc("$fx\coord\leases\brivio\task-2.json.hb", [DateTime]::UtcNow.AddHours(-5))
$null = Blocks $Guard "Get-Content '$slot\a.txt'"
$age = ([DateTime]::UtcNow - (Get-Item "$fx\coord\leases\brivio\task-2.json.hb").LastWriteTimeUtc).TotalMinutes
Check 'guard renews lease heartbeat when a tool call touches the slot' ($age -lt 1) "age ${age} min"
$p = @{ hook_event_name = 'PreToolUse'; tool_name = 'read_file'; tool_input = @{ filePath = "$slot\a.txt" } } | ConvertTo-Json -Compress
[IO.File]::SetLastWriteTimeUtc("$fx\coord\leases\brivio\task-2.json.hb", [DateTime]::UtcNow.AddHours(-5))
$null = $p | pwsh -NoProfile -File $Guard 2>$null
$age = ([DateTime]::UtcNow - (Get-Item "$fx\coord\leases\brivio\task-2.json.hb").LastWriteTimeUtc).TotalMinutes
Check 'guard renews lease on a file-path tool (read_file)' ($age -lt 1) "age ${age} min"

# mutation tests: disable one rule -> its block cases must flip to allowed
$src = [IO.File]::ReadAllText($Guard)
$mutations = [ordered]@{
  'lease-delete' = @('if ($hitsSlot -or $hitsParent) {', 'if ($false) {')
  'raw-add'      = @("if (`$cmd -match '\bgit\b[^;|&]*\bworktree\s+add\b' -and `$cmd -notmatch '(?i)(worktree|agentq|deploy-clean)\.ps1') {", 'if ($false) {')
  'raw-remove'   = @("if (`$cmd -match '\bgit\b[^;|&]*\bworktree\s+(remove|move)\b' -and", 'if ($false -and')
}
foreach ($m in $mutations.Keys) {
  $from, $to = $mutations[$m]
  $n = ([regex]::Matches($src, [regex]::Escape($from))).Count
  if ($n -lt 1) { Check "mutation $m anchor present" $false "anchor not found"; continue }
  $mut = "$fx\guard-mut-$m.ps1"
  [IO.File]::WriteAllText($mut, $src.Replace($from, $to))
  # the mutated guard must reference lib\ beside it like the real one
  if (Test-Path (Join-Path (Split-Path $Guard) 'lib')) { Copy-Item (Join-Path (Split-Path $Guard) 'lib') "$fx\lib" -Recurse -Force -ErrorAction SilentlyContinue }
  $killed = $true
  foreach ($k in $cases.Keys) { $c = $cases[$k]; if ($c.rule -eq $m -and (Blocks $mut $c.cmd)) { $killed = $false } }
  Check "mutation '$m' is caught by the tests (rule disabled -> its cases stop blocking)" $killed
}
Remove-Item Env:CODAI_WT_ROOT, Env:AGENTQ_HOME -ErrorAction SilentlyContinue
cmd /c rmdir /s /q "`"$fx`"" 2>$null
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
