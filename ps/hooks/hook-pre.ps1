<#
.SYNOPSIS
  Single preToolUse entry: runs guard-tooluse, guard-rules-surface and copilot-signal in ONE process.

.DESCRIPTION
  Why (measured 2026-10-12): VS Code runs every preToolUse hook entry SEQUENTIALLY and starts each
  one as `powershell.exe -NoProfile -Command <cmd>` (extension.js J8a). Four entries = four process
  starts per tool call: p50 6.5 s, p90 13.5 s under load, 1 200+ "Hook command timed out" a day,
  and a timeout fails OPEN.

  Also fixes a silent bypass: `powershell -Command script.ps1` turns a script's `exit 2` into
  process exit 1, which VS Code logs as NonBlockingError and RUNS the tool. guard-rules-surface only
  ever used exit 2, so in VS Code it never blocked (proof: a create_file into ~/.copilot/hooks went
  through with "REFUSED" in Hooks.log). Here every deny in a VS Code payload is a JSON
  permissionDecision=deny on stdout with exit 0, the only form VS Code honours.

  Each child keeps its own file, tests and stdin contract: stdin is replayed per child via
  [Console]::SetIn, and `exit` inside a script called with & only ends that script.
  Other harnesses (no hook_event_name, e.g. Copilot CLI): stderr + exit 2 as before.

  Source of truth: the agentq repository, ps/hooks/hook-pre.ps1 (ADR 0009 stage 0, OQ-010), installed
  by ps/install.ps1. Until 2026-11 this file existed only in the installed folder.

  Cost log (OQ-012): every call appends one line to <coord>/hooks/cost-yyyyMMdd.jsonl
  ({ ts, ms, startMs, tool, deny, session }): ms = time spent in this script, startMs = from the
  creation of this process to the first line of the script (the part a resident daemon would remove).
  `agentq slo` sums it. Best effort: it can neither change a decision nor fail the call.
  AGENTQ_NO_HOOK_COST=1 turns it off.
#>
$ErrorActionPreference = 'Continue'
$hookSw = [Diagnostics.Stopwatch]::StartNew()
$hookStartMs = $null
try { $hookStartMs = [math]::Round(([DateTime]::Now - [Diagnostics.Process]::GetCurrentProcess().StartTime).TotalMilliseconds) } catch { }
$raw = ''
try { $raw = [Console]::In.ReadToEnd() } catch { $raw = '' }
$rawIn = $raw   # the payload exactly as the harness sent it (the AXIOM gate reads its own dialects)
$isVsCode = $raw -match '"hook_event_name"'
# Copilot CLI sends {toolName, toolArgs:"<json string>"}; the guards read tool_input/toolInput only,
# so a CLI `git add -A` was never inspected. Give them a toolInput object (pre-existing gap, 2026-10-12).
if (-not $isVsCode -and $raw -match '"toolArgs"') {
  try {
    $p = $raw | ConvertFrom-Json
    if ($p.toolArgs -is [string] -and -not $p.toolInput) {
      $ti = try { $p.toolArgs | ConvertFrom-Json } catch { $p.toolArgs }
      $p | Add-Member -NotePropertyName toolInput -NotePropertyValue $ti -Force
      $raw = $p | ConvertTo-Json -Compress -Depth 8
    }
  } catch { }
}
$realOut = [Console]::Out
$realErr = [Console]::Error

# One line per call; called right before every exit of this script. Regex, not ConvertFrom-Json: the
# payload can be megabytes (file contents) and only two short fields are needed.
function Write-HookCost([bool]$Denied) {
  if ($env:AGENTQ_NO_HOOK_COST -eq '1') { return }
  try {
    $tool = ''; $sid = ''
    $m = [regex]::Match($rawIn, '"(?:tool_name|toolName)"\s*:\s*"([^"\\]{1,80})"'); if ($m.Success) { $tool = $m.Groups[1].Value }
    $m = [regex]::Match($rawIn, '"(?:session_id|sessionId)"\s*:\s*"([^"\\]{1,80})"'); if ($m.Success) { $sid = $m.Groups[1].Value }
    $coord = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
    $dir = Join-Path $coord 'hooks'
    [void][IO.Directory]::CreateDirectory($dir)
    $now = [DateTime]::UtcNow
    $start = if ($null -ne $hookStartMs) { "$hookStartMs" } else { 'null' }
    $line = '{{"ts":"{0}","ms":{1},"startMs":{2},"tool":"{3}","deny":{4},"session":"{5}"}}' -f $now.ToString('o'), [long]$hookSw.ElapsedMilliseconds, $start, $tool, $(if ($Denied) { 'true' } else { 'false' }), $sid
    $file = Join-Path $dir ("cost-{0}.jsonl" -f $now.ToString('yyyyMMdd'))
    $enc = New-Object Text.UTF8Encoding $false
    for ($try = 0; $try -lt 3; $try++) {
      try { [IO.File]::AppendAllText($file, $line + "`n", $enc); break } catch { Start-Sleep -Milliseconds 15 }
    }
  } catch { }
}

function Invoke-Child([string]$Name) {
  $path = Join-Path $PSScriptRoot $Name
  $errW = [IO.StringWriter]::new()
  [Console]::SetIn([IO.StringReader]::new($raw))
  [Console]::SetError($errW)
  $global:LASTEXITCODE = 0
  $out = ''
  try { $out = (& $path 2>&1 | ForEach-Object { "$_" }) -join "`n" } catch { $errW.WriteLine("$Name crashed: $($_.Exception.Message)") }
  finally { [Console]::SetError($realErr); [Console]::SetOut($realOut) }
  [pscustomobject]@{ Rc = [int]$LASTEXITCODE; Out = "$out"; Err = $errW.ToString().TrimEnd() }
}

function Deny([string]$Reason, [string]$Json) {
  Write-HookCost $true
  if ($isVsCode) {
    if (-not $Json) {
      $Json = @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } } | ConvertTo-Json -Compress -Depth 4
    }
    $realOut.WriteLine($Json); $realOut.Flush()
    if ($Reason) { $realErr.WriteLine($Reason) }
    exit 0
  }
  $realErr.WriteLine($Reason)
  exit 2
}

# S-1219 (2026-10-14): AXIOM for repos WITHOUT their own .axiom/gate-profile.json (those run the
# AXIOM hook from .github/hooks, or further down when the repo registers none - see $axOwnRun).
# Uses ~/.axiom/gate-profile.json. Runs BEFORE the guards so every
# call is recorded in <repo>/.axiom/decisions.jsonl, including the ones a guard denies (the parity
# replay needs those). Observe-only while $axiomEnforce is $false: its answer is ignored. Cutover
# (>= 2026-10-21, cutover-check CUTOVER_READY=True): set $axiomEnforce = $true. Enforces only RULE
# verdicts (house/git/coord/blind/command) = the retired guard's scope, never path containment.
$axiomEnforce = $false
$axOwnRun = $false
$axiomCmd = Join-Path $env:APPDATA 'npm\axiom.cmd'
if (Test-Path $axiomCmd) {
  $axDir = $null; try { $axDir = "$(($raw | ConvertFrom-Json).cwd)" } catch { }
  if (-not $axDir) { $axDir = (Get-Location).Path }
  $ownAxiom = $false
  for ($d = $axDir; $d; $d = Split-Path -Parent $d) {
    if (Test-Path -LiteralPath (Join-Path $d '.axiom\gate-profile.json')) { $ownAxiom = $d -ne $HOME; break }
    if (Test-Path -LiteralPath (Join-Path $d '.git')) { break }
  }
  # 2026-11-10: a repo WITH its own profile got the gate from a second hook entry
  # (.github/hooks/axiom-gate.json) = one more powershell.exe start on EVERY tool call (median 1.6 s
  # under load on top of this hook's 2.2 s). When the checkout registers no such entry, the gate runs
  # in this process instead (below, after the guards). The repo file decides per checkout, so a
  # checkout that still has the entry is not judged twice and one without it is never left unjudged.
  if ($ownAxiom) {
    $axRepoHook = $false
    foreach ($hf in @(Get-ChildItem -LiteralPath (Join-Path $d '.github\hooks') -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      try { if ([IO.File]::ReadAllText($hf.FullName) -match '(?is)"preToolUse"\s*:\s*\[[^\]]*axiom') { $axRepoHook = $true; break } } catch { }
    }
    $axOwnRun = -not $axRepoHook
  }
  if (-not $ownAxiom) {
    $axOut = ''
    try { $axOut = (($raw | & $axiomCmd gate --stdin --format auto 2>$null) | ForEach-Object { "$_" }) -join "`n" } catch { }
    if ($axiomEnforce -and $axOut -match '"permissionDecision"\s*:\s*"deny"' -and $axOut -match '"code"\s*:\s*"(house|git|coord|blind|command)\.') {
      $axWhy = 'AXIOM gate deny'; try { $axWhy = "$(($axOut | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason)" } catch { }
      Deny $axWhy (($axOut -split "`n" | Where-Object { $_ -match '"permissionDecision"' } | Select-Object -First 1))
    }
  }
}

$warnings = [System.Collections.Generic.List[string]]::new()
foreach ($child in 'guard-tooluse.ps1', 'guard-rules-surface.ps1') {
  $r = Invoke-Child $child
  $json = ($r.Out -split "`n" | Where-Object { $_ -match '"permissionDecision"\s*:\s*"deny"' } | Select-Object -First 1)
  if ($json) { Deny $r.Err $json }
  if ($r.Rc -eq 2) { Deny $r.Err $null }
  if ($r.Err) { $warnings.Add($r.Err) }
}
# Allowed: physical signal (never blocks, never fails the call).
$null = Invoke-Child 'copilot-signal.ps1'
# Repo with its own AXIOM profile and no gate hook of its own: the gate runs here with the flags the
# repo hook used, and its answer goes to the harness unchanged (deny, or additionalContext in warn
# mode). AFTER the guards on purpose: if the gate hangs, the hook timeout fails open and only the
# gate's verdict is lost, never a guard deny. A call a guard denied is not sent to the gate.
if ($axOwnRun) {
  $OutputEncoding = [Console]::InputEncoding   # PS 5.1 pipes ASCII by default: a non-ASCII path would reach the gate as '?'
  $axOut = ''; $axRc = 0
  try { $axOut = (($rawIn | & $axiomCmd gate --stdin --fail-open --format auto 2>$null) | ForEach-Object { "$_" }) -join "`n"; $axRc = [int]$LASTEXITCODE } catch { $axOut = '' }
  if ($isVsCode) {
    $axDeny = ($axOut -split "`n" | Where-Object { $_ -match '"permissionDecision"\s*:\s*"deny"' } | Select-Object -First 1)
    if ($axDeny) {
      $axWhy = 'AXIOM gate deny'; try { $axWhy = "$(($axDeny | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason)" } catch { }
      Deny $axWhy $axDeny
    }
  }
  if ($axOut.Trim()) { $realOut.WriteLine($axOut); $realOut.Flush() }
  if (-not $isVsCode -and $axRc -ne 0) {
    if ($warnings.Count) { $realErr.WriteLine(($warnings -join "`n")) }
    Write-HookCost $true
    exit $axRc
  }
}
if ($warnings.Count) { $realErr.WriteLine(($warnings -join "`n")) }
Write-HookCost $false
exit 0
