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
  ({ ts, ms, startMs, tool, verb, deny, session }): ms = time spent in this script, startMs = from the call
  reaching this process to the first line of the script (the part a resident daemon removes). On the
  resident path the daemon runs this script IN-PROCESS, so the process start is server UPTIME, not this
  call (2026-11-25: startMs 82 425 070 ms == the server's uptime while ms stayed ~800, and `agentq slo`
  read it as 318 162 h/day). A host must therefore (a) set CODAI_HOOK_RESIDENT=1 so the in-process case
  is detectable and (b) pass the request receipt time as CODAI_HOOK_REQUEST_MS (epoch ms); without a
  number the field is null, not a lie - NEVER the host's uptime. A host parses this file ONCE at
  startup, so a change here reaches the resident path only after the host is replaced (install.ps1 now
  restarts it; that staleness is why the defect outlived the first fix attempt).
  `agentq slo` sums it. Best effort: it can neither change a decision nor fail the call.
  AGENTQ_NO_HOOK_COST=1 turns it off.

  `verb` (round 4, 2026-11-28): the ledger named only the VS Code TOOL, so a day file could hold
  10 463 run_in_terminal rows and still not answer "what does one `status` cost beside one `land`".
  The verb the command runs is now recorded for the tools that carry a command (the others' payloads
  are not scanned). It is an empty string when that command runs no agentq, and the field is ALWAYS
  present so every parser sees one shape.
#>
$ErrorActionPreference = 'Continue'
$hookSw = [Diagnostics.Stopwatch]::StartNew()
$hookStartMs = $null
try {
  # Hosted (the resident server runs this script in ITS process) or fresh? Two independent signals,
  # because one alone has been wrong before: the host sets CODAI_HOOK_RESIDENT=1, and its command line
  # names the script that hosts the guard. Under the classic path (a fresh `powershell.exe -File
  # hook-pre.ps1` per call) both are false and the process start IS the call's arrival; under a host
  # both are true, so a process-start value would be the HOST'S UPTIME, not this call.
  $resident = ($env:CODAI_HOOK_RESIDENT -eq '1') -or ([Environment]::CommandLine -match 'resident-server')
  $reqMs = $env:CODAI_HOOK_REQUEST_MS
  if ($reqMs -and $reqMs -match '^\d{10,}$') {
    # The host passes the request's receipt time; that, not the process, is the call's arrival.
    $hookStartMs = [math]::Round(([DateTime]::Now - [DateTimeOffset]::FromUnixTimeMilliseconds([long]$reqMs).LocalDateTime).TotalMilliseconds)
  } elseif (-not $resident) {
    # A fresh process per call: its creation IS the moment the call arrived - but ONLY while it is
    # still fresh. A warm pwsh that is neither the resident host nor a per-call spawn (a terminal
    # running this script by hand) would otherwise record ITS UPTIME as startMs: 2026-11-26 wrote
    # values of 83-104 million ms (23-29 h) whenever a long-lived process reached line 1, which is
    # what made `agentq slo`'s hook cost unphysical. Fail closed: a number under 5 min is a spawn,
    # anything older is not a measurement of this call. The bound is overridable ONLY so a test can
    # squeeze it to a millisecond and force the stale branch against a real (fresh) process;
    # production never sets it.
    $maxAge = 300000
    if ($env:CODAI_HOOK_MAX_AGE_MS -match '^\d+$') { $maxAge = [int]$env:CODAI_HOOK_MAX_AGE_MS }
    $age = [math]::Round(([DateTime]::Now - [Diagnostics.Process]::GetCurrentProcess().StartTime).TotalMilliseconds)
    if ($age -ge 0 -and $age -lt $maxAge) { $hookStartMs = $age } else { $hookStartMs = $null }
  }
  # else: hosted with no receipt time -> leave $null. The contract is explicit above: without a number
  # the field is null, not a lie. Never fall back to the host's uptime.
} catch { }
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

# F1/F2 (2026-11-23): the tool name and session drive two decisions below. Read them with a REGEX,
# exactly like Write-HookCost does - a full ConvertFrom-Json of a megabyte apply_patch payload with
# embedded file text costs ~88 ms as the process's first JSON parse (measured 2026-11-23), and the
# tool name is a short field that never needs it.
$toolName = ''; $sessId = ''
$mT = [regex]::Match($rawIn, '"(?:tool_name|toolName)"\s*:\s*"([^"\\]{1,80})"'); if ($mT.Success) { $toolName = $mT.Groups[1].Value }
$mS = [regex]::Match($rawIn, '"(?:session_id|sessionId)"\s*:\s*"([^"\\]{1,80})"'); if ($mS.Success) { $sessId = $mS.Groups[1].Value }
# F1: the tools that can only READ. The AXIOM gate is path/command based, so it can never deny one of
# them (the gate's own answer to read_file on a denied path is empty - pinned by the F1 case in
# ps\tests\test-hook-pre.ps1, and by "read tools are not judged"). Running it for a read is observe-only work on the
# critical path of every call, and its node cold start measures ~108 ms here. An ALLOW list on purpose:
# terminal tools, edits, unknown names and a malformed payload (no tool name) all keep the gate.
$gateReadOnly = '^(read_file|read_notebook_cell_output|copilot_getNotebookSummary|grep_search|file_search|list_dir|semantic_search|get_errors|memory|session_store_sql|fetch_webpage|codai_web_search|codai_web_fetch|vscode_websearchforcopilot_webSearch|read_page|screenshot_page|terminal_last_command|terminal_selection|vscode_listCodeUsages|resolve_memory_file_uri|get_task_output|find-skills|who-owns-file)$'
$runGate = $toolName -notmatch $gateReadOnly

# ROUND 4 (2026-11-28): only a tool that RUNS A COMMAND can name an agentq verb - the other payloads
# (a megabyte apply_patch, a screenshot) are not worth scanning for one. These are the command-carrying
# tool names across the harnesses seen here: VS Code's run_in_terminal, Claude Code's Bash, and the
# generic shell names. An ALLOW list on purpose, like $gateReadOnly above: an unknown name is not
# scanned rather than guessed at.
$cmdTools = '^(run_in_terminal|Bash|bash|sh|shell|execute|execute_command|run_command|terminal)$'
# The verb is the word the launcher runs: `agentq.ps1 since`, `"…\agentq.ps1" land`,
# `node dist/cli.mjs log`. Anything after a flag (`agentq.ps1 -Purpose x land`) does not match, which
# is deliberate: an empty verb is honest, a guessed one would not be. Bounded to 24 characters and to
# [A-Za-z0-9-], so the value can never carry a quote or a backslash into the JSON line.
$verbRe = [regex]::new('(?<![A-Za-z0-9])(?:agentq(?:-v2)?\.ps1|cli\.mjs)\\?"?\s{1,4}([A-Za-z][A-Za-z0-9-]{0,23})', 'IgnoreCase')

# One line per call; called right before every exit of this script. Regex, not ConvertFrom-Json: the
# payload can be megabytes (file contents) and only two short fields are needed.
function Write-HookCost([bool]$Denied) {
  if ($env:AGENTQ_NO_HOOK_COST -eq '1') { return }
  try {
    $tool = ''; $sid = ''
    $m = [regex]::Match($rawIn, '"(?:tool_name|toolName)"\s*:\s*"([^"\\]{1,80})"'); if ($m.Success) { $tool = $m.Groups[1].Value }
    $m = [regex]::Match($rawIn, '"(?:session_id|sessionId)"\s*:\s*"([^"\\]{1,80})"'); if ($m.Success) { $sid = $m.Groups[1].Value }
    # The VERB (round 4): `tool` alone could not answer what an agentq call costs - a day of this file
    # held 10 463 run_in_terminal rows and no verb. Regex on the raw payload and no spawn: the metric of
    # this round IS the spawn count, so instrumentation that spawns would erase its own measurement.
    $verb = ''
    if ($tool -match $cmdTools) { $v = $verbRe.Match($rawIn); if ($v.Success) { $verb = $v.Groups[1].Value.ToLowerInvariant() } }
    $coord = if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }
    $dir = Join-Path $coord 'hooks'
    [void][IO.Directory]::CreateDirectory($dir)
    $now = [DateTime]::UtcNow
    $start = if ($null -ne $hookStartMs) { "$hookStartMs" } else { 'null' }
    $line = '{{"ts":"{0}","ms":{1},"startMs":{2},"tool":"{3}","verb":"{4}","deny":{5},"session":"{6}"}}' -f $now.ToString('o'), [long]$hookSw.ElapsedMilliseconds, $start, $tool, $verb, $(if ($Denied) { 'true' } else { 'false' }), $sid
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
if ($runGate -and (Test-Path $axiomCmd)) {
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
  if ($axiomEnforce -and -not $ownAxiom) {
    # Observe-only: while $axiomEnforce is $false the verdict below is discarded, but the node
    # process's cold start (~108 ms measured here) is still paid on EVERY call that can change state -
    # most calls. Skip the spawn until enforcement is on; the cutover re-enables it and the
    # decisions.jsonl record it leaves. A repo judged by its OWN profile is NOT this branch: it is
    # $axOwnRun below, which enforces regardless of $axiomEnforce and is set above, outside this gate.
    $axOut = ''
    try { $axOut = (($raw | & $axiomCmd gate --stdin --format auto 2>$null) | ForEach-Object { "$_" }) -join "`n" } catch { }
    if ($axiomEnforce -and $axOut -match '"permissionDecision"\s*:\s*"deny"' -and $axOut -match '"code"\s*:\s*"(house|git|coord|blind|command)\.') {
      $axWhy = 'AXIOM gate deny'; try { $axWhy = "$(($axOut | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason)" } catch { }
      Deny $axWhy (($axOut -split "`n" | Where-Object { $_ -match '"permissionDecision"' } | Select-Object -First 1))
    }
  }
}

$warnings = [System.Collections.Generic.List[string]]::new()
foreach ($child in 'guard-tooluse.ps1', 'guard-rules-surface.ps1', 'guard-dev-vm.ps1') {
  $r = Invoke-Child $child
  $json = ($r.Out -split "`n" | Where-Object { $_ -match '"permissionDecision"\s*:\s*"deny"' } | Select-Object -First 1)
  if ($json) { Deny $r.Err $json }
  if ($r.Rc -eq 2) { Deny $r.Err $null }
  if ($r.Err) { $warnings.Add($r.Err) }
}
# Allowed: physical signal (never blocks, never fails the call).
# F2 (2026-11-23): the signal script has work ONLY for askQuestions (POST an ask) or to cancel a live
# ask (DELETE, its preToolUse branch when this session still has an ask mark). For every other tool it
# re-reads stdin and re-parses the whole payload - a megabyte apply_patch diff included - to decide
# nothing, and that is on the critical path of every call. Run it only when there is something to
# signal. The mark path is byte-for-byte the one the child itself tests, so an active ask is still
# cancelled and a malformed payload (empty session) still reaches it, unchanged.
$askMark = Join-Path $HOME ('.codai\signal-ask\' + ($sessId -replace '[^A-Za-z0-9_-]', '') + '.ask')
if ($toolName -match 'askQuestions' -or (Test-Path -LiteralPath $askMark)) { $null = Invoke-Child 'copilot-signal.ps1' }
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
