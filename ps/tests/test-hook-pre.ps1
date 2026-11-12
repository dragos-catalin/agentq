# Tests for hook-pre.ps1 (single preToolUse dispatcher), spawned EXACTLY as VS Code does it:
# powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -Command <script>  (extension.js J8a).
# Asserts guard-tooluse AND guard-rules-surface decisions survive the dispatcher in both dialects, that
# the AXIOM gate runs in-process exactly when a repo has its own profile and no gate hook of its own,
# and (ADR 0009 stage 0) that the cost log and the chat keep-alive work without changing a decision.
# Hermetic: every cwd is a throwaway repo under %TEMP% and the agentq state folder is a temp one.
#
# Two layouts:
#  * installed (this file next to hook-pre.ps1 in ~/.copilot/hooks, or -Hook <path>): the real sibling
#    guards are used. This is the parity suite to run before and after any hook change.
#  * repository / CI (-Hooks <repo>/ps/hooks, the default from ps/tests): the repository does not carry
#    the rules-surface guard or the signal script (they belong to the machine's trust surface), so the
#    dispatcher and guard-tooluse.ps1 are staged in a temp folder with a stand-in rules-surface guard that
#    denies the same two paths these cases use, with the same contract (stderr + exit 2).
# The AXIOM cases need the `axiom` command; without it they are reported as SKIP.
# Exit 1 on any failure.
param([string]$Hook, [string]$Hooks)
$fail = 0
$stage = $null
$installedHook = Join-Path $PSScriptRoot 'hook-pre.ps1'
if (-not $Hook) {
  if ($Hooks) { $Hook = Join-Path $Hooks 'hook-pre.ps1' }
  elseif (Test-Path -LiteralPath $installedHook) { $Hook = $installedHook }
  else { $Hook = Join-Path $PSScriptRoot '..\hooks\hook-pre.ps1' }
}
$Hook = (Resolve-Path -LiteralPath $Hook).Path
$hookDir = Split-Path -Parent $Hook
if (-not (Test-Path -LiteralPath (Join-Path $hookDir 'guard-rules-surface.ps1'))) {
  $stage = Join-Path $env:TEMP ("hook-pre-stage-{0}" -f [guid]::NewGuid().ToString('N'))
  $null = New-Item -ItemType Directory -Force -Path $stage
  Copy-Item -LiteralPath $Hook, (Join-Path $hookDir 'guard-tooluse.ps1') -Destination $stage
  $standIn = @'
# Stand-in for the machine's rules-surface guard (test only): same contract, two protected folders.
$raw = ''; try { $raw = [Console]::In.ReadToEnd() } catch { }
if ($raw -match '(?i)\.copilot[\\/]+hooks[\\/]|\.claude[\\/]+rules[\\/]') {
  [Console]::Error.WriteLine('REFUSED by rule codai.floor.self-modify-trust-surface (stand-in guard): agents may not modify the trust surface.')
  exit 2
}
exit 0
'@
  [IO.File]::WriteAllText((Join-Path $stage 'guard-rules-surface.ps1'), $standIn)
  [IO.File]::WriteAllText((Join-Path $stage 'copilot-signal.ps1'), "exit 0`n")
  $Hook = Join-Path $stage 'hook-pre.ps1'
  Write-Host "  layout: repository (staged in $stage with a stand-in rules-surface guard)"
} else { Write-Host "  layout: installed ($hookDir)" }
$hook = $Hook
$hasAxiom = Test-Path -LiteralPath (Join-Path $env:APPDATA 'npm\axiom.cmd')
$coord = Join-Path $env:TEMP ("hook-pre-coord-{0}" -f [guid]::NewGuid().ToString('N'))
$oldHome = $env:AGENTQ_HOME; $oldWt = $env:CODAI_WT_ROOT
$env:AGENTQ_HOME = $coord
function Invoke-Hook([hashtable]$p) {
  $tmp = Join-Path $env:TEMP ("hook-pre-in-{0}.json" -f [guid]::NewGuid().ToString('N'))
  [IO.File]::WriteAllText($tmp, ($p | ConvertTo-Json -Compress -Depth 6), [Text.UTF8Encoding]::new($false))
  # stdout is read as raw UTF-8 bytes: that is what the harness receives
  $psi = [Diagnostics.ProcessStartInfo]::new('cmd.exe', "/d /c `"powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -Command $hook < `"$tmp`" 2>NUL`"")
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $pr = [Diagnostics.Process]::Start($psi); $o = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  [pscustomobject]@{ Out = $o; Rc = $pr.ExitCode }
}
function Get-Decision($r) { if ($r.Out -match '"permissionDecision":"deny"') { 'deny-json' } elseif ($r.Rc -ne 0) { 'deny-exit' } elseif ($r.Out -match '"additionalContext"') { 'allow-context' } else { 'allow' } }
function Case($name, [hashtable]$p, [string]$expect, [string]$match) {
  $r = Invoke-Hook $p
  $got = Get-Decision $r
  $why = if ($got -ne $expect) { "expected $expect, got $got rc=$($r.Rc)" } elseif ($match -and $r.Out -notmatch $match) { "stdout does not match /$match/" } else { '' }
  if ($why) { Write-Host "  FAIL  $name ($why)"; $script:fail++ } else { Write-Host "  ok    $name" }
}
function Ok([bool]$c, [string]$name, [string]$detail = '') { if ($c) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name $detail"; $script:fail++ } }
# Throwaway repos. `Profile` = the repo's own AXIOM gate profile (none = the user-level one applies);
# `RepoHook` = the repo registers the gate as its own preToolUse hook (then hook-pre must NOT run it).
$fxRoot = Join-Path $env:TEMP ("hook-pre-fx-{0}" -f [guid]::NewGuid().ToString('N'))
function New-Repo([string]$name, [string]$profileJson, [switch]$RepoHook) {
  $root = Join-Path $fxRoot $name
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $root '.git'), (Join-Path $root '.axiom'), (Join-Path $root 'blocked')
  if ($profileJson) { [IO.File]::WriteAllText((Join-Path $root '.axiom\gate-profile.json'), $profileJson) }
  if ($RepoHook) {
    $null = New-Item -ItemType Directory -Force -Path (Join-Path $root '.github\hooks')
    [IO.File]::WriteAllText((Join-Path $root '.github\hooks\axiom-gate.json'), '{"version":1,"hooks":{"preToolUse":[{"type":"command","powershell":"axiom.cmd gate --stdin --fail-open --format auto; exit $LASTEXITCODE","timeoutSec":15}]}}')
  }
  $root
}
function Gate-Wrote([string]$root) { @(Get-ChildItem (Join-Path $root '.axiom') -Force | Where-Object { $_.Name -ne 'gate-profile.json' }).Count -gt 0 }
function Cost-Lines { @(Get-ChildItem -LiteralPath (Join-Path $coord 'hooks') -Filter 'cost-*.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName } | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json }) }
try {
  $plain = New-Repo 'plain' '{"deny":["blocked/**"]}' -RepoHook     # the repo's own hook runs the gate
  $own = New-Repo 'own' '{"deny":["blocked/**"]}'                   # own profile, no repo hook: hook-pre runs the gate
  $warn = New-Repo 'warn' '{"deny":["blocked/**"],"mode":"warn"}'
  $forcePush = 'git push' + ' --force origin main'
  $addAll = 'git add' + ' -A'
  $surface = "$env:USERPROFILE\.copilot\hooks\zz-test.json"

  # --- guards (no gate involved: the repo registers its own gate hook) ---
  $vs = @{ hook_event_name = 'PreToolUse'; session_id = 'test-hook-pre'; cwd = $plain }
  Case 'VS Code read_file is allowed' ($vs + @{ tool_name = 'read_file'; tool_input = @{ filePath = "$plain\README.md" } }) 'allow'
  Case 'VS Code benign terminal command is allowed' ($vs + @{ tool_name = 'run_in_terminal'; tool_input = @{ command = 'git status' } }) 'allow'
  Case 'VS Code soft guard rule (stage everything) only warns since 2026-10-19: allowed' ($vs + @{ tool_name = 'run_in_terminal'; tool_input = @{ command = $addAll } }) 'allow'
  Case 'VS Code HARD guard rule (force push) arrives as JSON + exit 0' ($vs + @{ tool_name = 'run_in_terminal'; tool_input = @{ command = $forcePush } }) 'deny-json' 'Force-push'
  Case 'VS Code guard-rules-surface deny arrives as JSON + exit 0' ($vs + @{ tool_name = 'create_file'; tool_input = @{ filePath = $surface; content = '{}' } }) 'deny-json'
  Case 'VS Code ordinary repo write is allowed' ($vs + @{ tool_name = 'create_file'; tool_input = @{ filePath = "$plain\x.txt"; content = 'x' } }) 'allow'
  Case 'CLI toolArgs string is inspected: soft rule allowed' @{ toolName = 'bash'; toolArgs = (@{ command = $addAll } | ConvertTo-Json -Compress); cwd = $plain } 'allow'
  Case 'CLI toolArgs string is inspected: HARD rule denied by exit code' @{ toolName = 'bash'; toolArgs = (@{ command = $forcePush } | ConvertTo-Json -Compress); cwd = $plain } 'deny-exit'
  Case 'CLI rules-surface write is denied' @{ toolName = 'str_replace'; toolArgs = (@{ path = "$env:USERPROFILE\.claude\rules\zz.md"; old_str = 'a'; new_str = 'b' } | ConvertTo-Json -Compress); cwd = $plain } 'deny-exit'
  Case 'malformed payload is allowed (fail open, no crash)' @{ junk = 1 } 'allow'

  # --- AXIOM gate in-process (repo with its own profile) ---
  if ($hasAxiom) {
    Case 'repo registers its own gate hook: hook-pre does not run the gate' ($vs + @{ tool_name = 'create_file'; tool_input = @{ filePath = "$plain\blocked\x.txt"; content = 'x' } }) 'allow'
    if (Gate-Wrote $plain) { Write-Host '  FAIL  repo registers its own gate hook: the gate ran anyway (it left files in .axiom)'; $fail++ } else { Write-Host '  ok    ... and the gate left nothing in that repo' }
    $vo = @{ hook_event_name = 'PreToolUse'; session_id = 'test-hook-pre'; cwd = $own }
    Case 'own profile, no repo hook: gate deny arrives as JSON + exit 0' ($vo + @{ tool_name = 'create_file'; tool_input = @{ filePath = "$own\blocked\x.txt"; content = 'x' } }) 'deny-json' 'AXIOM GATE DENY path\.deny'
    Case 'own profile, no repo hook: a write the profile allows is allowed' ($vo + @{ tool_name = 'create_file'; tool_input = @{ filePath = "$own\ok.txt"; content = 'x' } }) 'allow'
    Case 'own profile, no repo hook: read tools are not judged' ($vo + @{ tool_name = 'read_file'; tool_input = @{ filePath = "$own\blocked\x.txt" } }) 'allow'
    Case 'own profile, no repo hook: a HARD guard deny still wins' ($vo + @{ tool_name = 'run_in_terminal'; tool_input = @{ command = $forcePush } }) 'deny-json' 'Force-push'
    Case 'own profile, no repo hook: rules-surface deny still wins' ($vo + @{ tool_name = 'create_file'; tool_input = @{ filePath = $surface; content = '{}' } }) 'deny-json' 'self-modify-trust-surface'
    Case 'own profile, no repo hook, CLI dialect: the gate answer is passed on' @{ toolName = 'create'; toolArgs = (@{ path = "$own\blocked\y.txt"; file_text = 'x' } | ConvertTo-Json -Compress); cwd = $own } 'deny-json' 'path\.deny'
    $vw = @{ hook_event_name = 'PreToolUse'; session_id = 'test-hook-pre'; cwd = $warn }
    Case 'warn-mode profile: allowed, the warning reaches the model as additionalContext' ($vw + @{ tool_name = 'create_file'; tool_input = @{ filePath = "$warn\blocked\x.txt"; content = 'x' } }) 'allow-context' 'AXIOM GATE WARN path\.deny'
    $ro = "$([char]0x219)$([char]0x21B)$([char]0x103)"   # s-comma, t-comma, a-breve: outside ASCII and outside the OEM code page
    Case 'non-ASCII path reaches the gate and comes back byte for byte' ($vw + @{ tool_name = 'create_file'; tool_input = @{ filePath = "$warn\blocked\$ro.txt"; content = 'x' } }) 'allow-context' ([regex]::Escape("blocked/$ro.txt"))
  } else { Write-Host '  SKIP  9 AXIOM gate cases (the axiom command is not installed on this machine)' }

  # --- cost log (ADR 0009 stage 0, OQ-012): one line per call, never changes a decision ---
  $cl = @(Cost-Lines)
  $allowLine = $cl | Where-Object { $_.tool -eq 'read_file' -and -not $_.deny } | Select-Object -First 1
  $denyLine = $cl | Where-Object { $_.tool -eq 'run_in_terminal' -and $_.deny } | Select-Object -First 1
  Ok ($cl.Count -ge 10) 'cost log: one line per hook call so far' "lines=$($cl.Count)"
  Ok ($allowLine -and $allowLine.ms -ge 0 -and $allowLine.session -eq 'test-hook-pre' -and $allowLine.ts) 'cost log: an allowed call has ts, ms, tool, session and deny=false' ($allowLine | ConvertTo-Json -Compress)
  Ok ($allowLine -and $allowLine.startMs -ge 0) 'cost log: startMs (process start to script start) is recorded' ($allowLine | ConvertTo-Json -Compress)
  Ok ([bool]$denyLine) 'cost log: a denied call is logged with deny=true'
  Ok (@($cl | Where-Object { $_.tool -eq 'bash' -and $_.deny }).Count -ge 1) 'cost log: the CLI dialect (exit-code deny) is logged too'
  $n0 = $cl.Count
  $probe = @(
    @{ name = 'allow'; p = ($vs + @{ tool_name = 'read_file'; tool_input = @{ filePath = "$plain\README.md" } }) },
    @{ name = 'hard deny'; p = ($vs + @{ tool_name = 'run_in_terminal'; tool_input = @{ command = $forcePush } }) },
    @{ name = 'rules-surface deny'; p = ($vs + @{ tool_name = 'create_file'; tool_input = @{ filePath = $surface; content = '{}' } }) },
    @{ name = 'CLI deny'; p = @{ toolName = 'bash'; toolArgs = (@{ command = $forcePush } | ConvertTo-Json -Compress); cwd = $plain } }
  )
  $with = @($probe | ForEach-Object { $r = Invoke-Hook $_.p; "$(Get-Decision $r)|$($r.Rc)|$($r.Out.Trim())" })
  $env:AGENTQ_NO_HOOK_COST = '1'
  $without = @($probe | ForEach-Object { $r = Invoke-Hook $_.p; "$(Get-Decision $r)|$($r.Rc)|$($r.Out.Trim())" })
  Remove-Item Env:AGENTQ_NO_HOOK_COST
  Ok ((Compare-Object $with $without).Count -eq 0) 'cost log on vs off: decision, exit code and stdout are identical for allow / hard deny / rules-surface deny / CLI deny' (($with + '---' + $without) -join "`n")
  Ok (@(Cost-Lines).Count -eq $n0 + $probe.Count) 'AGENTQ_NO_HOOK_COST=1 writes no line (and with it on, exactly one per call)' "now=$(@(Cost-Lines).Count) expected=$($n0 + $probe.Count)"
  # an unwritable log location must not fail or change the call
  $blocked = Join-Path $env:TEMP ("hook-pre-nodir-{0}" -f [guid]::NewGuid().ToString('N'))
  [IO.File]::WriteAllText($blocked, 'a file where the state folder should be')
  $env:AGENTQ_HOME = $blocked
  Case 'cost log cannot be written (state folder is a file): the call is still allowed' ($vs + @{ tool_name = 'read_file'; tool_input = @{ filePath = "$plain\README.md" } }) 'allow'
  Case 'cost log cannot be written: a HARD deny still arrives' ($vs + @{ tool_name = 'run_in_terminal'; tool_input = @{ command = $forcePush } }) 'deny-json' 'Force-push'
  $env:AGENTQ_HOME = $coord
  Remove-Item $blocked -Force -ErrorAction SilentlyContinue

  # --- chat keep-alive through the dispatcher (OQ-001): a chat that works in a leased slot is bound to it ---
  $wt = Join-Path $fxRoot 'wt'; $env:CODAI_WT_ROOT = $wt
  $slot = Join-Path $wt 'repo\task-1'
  $null = New-Item -ItemType Directory -Force -Path $slot, (Join-Path $coord 'leases\repo')
  $leaseFile = Join-Path $coord 'leases\repo\task-1.json'
  [IO.File]::WriteAllText($leaseFile, (@{ leaseId = 'abc12345'; repo = 'repo'; slot = 'task-1'; role = 'task'; path = $slot; session = 's'; purpose = 'p' } | ConvertTo-Json -Compress))
  [IO.File]::WriteAllText("$leaseFile.hb", '')
  Case 'chat keep-alive: an edit inside a leased slot is allowed as before' (@{ hook_event_name = 'PreToolUse'; session_id = 'chat-x'; cwd = $plain; tool_name = 'replace_string_in_file'; tool_input = @{ filePath = "$slot\a.txt"; oldString = 'a'; newString = 'b' } }) 'allow'
  Ok ((Test-Path "$leaseFile.chat") -and (Get-Content "$leaseFile.chat" -Raw) -match 'chat-x') 'chat keep-alive: the chat is bound to the lease'
  [IO.File]::SetLastWriteTimeUtc("$leaseFile.chat", [DateTime]::UtcNow.AddHours(-2))
  Case 'chat keep-alive: a later unrelated call of that chat is allowed as before' (@{ hook_event_name = 'PreToolUse'; session_id = 'chat-x'; cwd = $plain; tool_name = 'run_in_terminal'; tool_input = @{ command = 'git status' } }) 'allow'
  Ok (([DateTime]::UtcNow - (Get-Item "$leaseFile.chat").LastWriteTimeUtc).TotalMinutes -lt 2) 'chat keep-alive: ... and it refreshed the lease'
  [IO.File]::SetLastWriteTimeUtc("$leaseFile.chat", [DateTime]::UtcNow.AddHours(-2))
  Case 'chat keep-alive: a DENIED call of that chat is still denied' (@{ hook_event_name = 'PreToolUse'; session_id = 'chat-x'; cwd = $plain; tool_name = 'run_in_terminal'; tool_input = @{ command = $forcePush } }) 'deny-json' 'Force-push'
  Ok (([DateTime]::UtcNow - (Get-Item "$leaseFile.chat").LastWriteTimeUtc).TotalMinutes -lt 2) 'chat keep-alive: ... and it still counts as activity of the chat'
}
finally {
  Remove-Item $fxRoot -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $coord -Recurse -Force -ErrorAction SilentlyContinue
  if ($stage) { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
  if ($null -ne $oldHome) { $env:AGENTQ_HOME = $oldHome } else { Remove-Item Env:AGENTQ_HOME -ErrorAction SilentlyContinue }
  if ($null -ne $oldWt) { $env:CODAI_WT_ROOT = $oldWt } else { Remove-Item Env:CODAI_WT_ROOT -ErrorAction SilentlyContinue }
}
if ($fail) { Write-Host "$fail failure(s)"; exit 1 }
Write-Host 'all hook-pre cases passed'
exit 0
