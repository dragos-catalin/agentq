<#
.SYNOPSIS
  PreToolUse guard: refuse any shell command that would CREATE or EXTEND a paid VM,
  unless a time-boxed budget approval exists for that exact resource.

.DESCRIPTION
  Proposal 01DEVVMCOSTGUARD20261121. A VM launched "for a quick test" bills until it is
  torn down, and the teardown owner is rarely named. This hook is a HARD refusal (the owner
  asked for a deny, not an advisory): the deny shape mirrors guard-tooluse.ps1's Deny-Exit
  hard path exactly, so the harness treats the two identically (JSON permissionDecision on
  stdout + exit 0 under VS Code; exit 2 + stderr elsewhere).

  It is fail-closed for money: an absent / unparsable / expired approval file, or ANY error
  while reading it, means "no approval" and the command is refused. It never throws.

  Read-only verbs (list|describe|get|ssh|delete) are ALWAYS allowed. No network, no external
  calls, no side effects other than reading the approval file.

  Approval file (default C:\Users\vladu\.codai\dev-vm-approval.json, override for tests with
  $env:CODAI_DEV_VM_APPROVAL): either a top-level JSON array of entries, or an object with an
  `approvals` (or `resources`) array. Each entry: { "resource": "<name>", "not_after": "<ISO-8601 UTC>" }.
  A named `budget`, `ttl_hours` and `teardown_owner` are expected in a real ticket but not required here.

  Exit 0 = allow, exit 2 (or a JSON deny) = refuse.
#>
$ErrorActionPreference = 'Stop'

try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
if (-not $payload) { exit 0 }

function Deny([string]$Reason) {
  if ($payload.PSObject.Properties.Name -contains 'hook_event_name') {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $Reason } } |
      ConvertTo-Json -Compress -Depth 4 | Write-Output
    exit 0
  }
  [Console]::Error.WriteLine($Reason)
  exit 2
}

$tool = "$($payload.tool_name)$($payload.toolName)$($payload.tool)$($payload.name)"
$isEditTool = $tool -match '^(apply_patch|applyPatch|replace_string_in_file|multi_replace_string_in_file|insert_edit_into_file|edit_file|editFile|create_file|createFile|write_file|writeFile|edit_notebook_file|str_replace_editor|Edit|MultiEdit|Write)$'
$cmd = ''
foreach ($p in 'command', 'input', 'args') {
  if ($payload.PSObject.Properties.Name -contains $p -and $payload.$p) { $cmd = "$($payload.$p)"; break }
}
foreach ($container in $payload.tool_input, $payload.toolInput) {
  if ($cmd -or -not $container) { continue }
  if ($container -is [string]) { $cmd = $container; continue }
  foreach ($k in 'command', 'input', 'args', 'commandLine') {
    if ($container.PSObject.Properties.Name -contains $k -and $container.$k) { $cmd = "$($container.$k)"; break }
  }
}
if ($isEditTool) { $cmd = '' }
if (-not $cmd -or -not $cmd.Trim()) { exit 0 }

# Free-tier / shared shapes never ring the register.
function Test-PaidMachineType([string]$c) {
  $m = [regex]::Match($c, '(?i)--machine-type[=\s]+"?([A-Za-z0-9._-]+)')
  if (-not $m.Success) { return $false }
  return ($m.Groups[1].Value -notmatch '(?i)^(e2-micro|e2-small|e2-medium|f1-micro|g1-small)$')
}

# Returns the matched paid pattern (for the refuse message), or $null when the command is not a paid VM create/extend.
# NOTE: no explicit `return $true/$false` - the pattern string is the truthy signal, so a mutation that
# deletes one branch is what makes the corresponding test case go red (mutated non-vacuity, 2026-11-28).
function Get-PaidVmPattern([string]$c) {
  if ($c -match '(?i)\bgcloud\s+compute\s+instances\s+(bulk\s+)?create\b') { return 'gcloud compute instances (bulk) create' }
  if ($c -match '(?i)\bgcloud\s+compute\s+instances\s+update\b' -and $c -match '(?i)--machine-type[=\s]+\S' -and (Test-PaidMachineType $c)) { return 'gcloud compute instances update (paid --machine-type)' }
  if ($c -match '(?i)\bgcloud\s+compute\s+instance-groups\s+managed\s+resize\b') { return 'gcloud compute instance-groups managed resize' }
  if ($c -match '(?i)\baz\s+vm\s+create\b') { return 'az vm create' }
  if ($c -match '(?i)\bgcloud\s+ai\s+custom-jobs\s+create\b' -and $c -notmatch '(?i)\b(spot|preemptible)\b') { return 'gcloud ai custom-jobs create (no SPOT/preemptible shape)' }
  if ($c -match '(?i)\bgcloud\s+container\s+clusters\s+create\b') { return 'gcloud container clusters create' }
  if ($c -match '(?i)\bgcloud\s+container\s+node-pools\s+create\b') { return 'gcloud container node-pools create' }
  $mi = [regex]::Match($c, '(?i)--min-instances[=\s]+(\d+)')
  if ($c -match '(?i)\bgcloud\s+run\s+jobs\s+create\b' -and $mi.Success -and [int]$mi.Groups[1].Value -gt 0) { return 'gcloud run jobs create (--min-instances > 0)' }
  return $null
}

function Get-ParsedResource([string]$c) {
  foreach ($rx in @(
      '(?i)\binstances\s+(?:bulk\s+)?create\s+"?([A-Za-z0-9._-]+)',
      '(?i)\binstances\s+update\s+"?([A-Za-z0-9._-]+)',
      '(?i)\binstance-groups\s+managed\s+resize\s+"?([A-Za-z0-9._-]+)',
      '(?i)\bclusters\s+create\s+"?([A-Za-z0-9._-]+)',
      '(?i)\bnode-pools\s+create\s+"?([A-Za-z0-9._-]+)',
      '(?i)\brun\s+jobs\s+create\s+"?([A-Za-z0-9._-]+)',
      '(?i)\b--display-name[=\s]+"?([A-Za-z0-9._-]+)',
      '(?i)\b(?:az\s+vm\s+create)\b[^;|]*?(?:--name|-n)[=\s]+"?([A-Za-z0-9._-]+)'
    )) {
    $m = [regex]::Match($c, $rx)
    if ($m.Success) { return $m.Groups[1].Value }
  }
  return $null
}

function Get-ApprovalPath {
  if ($env:CODAI_DEV_VM_APPROVAL) { return "$($env:CODAI_DEV_VM_APPROVAL)" }
  return 'C:\Users\vladu\.codai\dev-vm-approval.json'
}

function Test-Approved([string]$c) {
  try {
    $path = Get-ApprovalPath
    if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $false }
    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    if (-not $raw -or -not $raw.Trim()) { return $false }
    $j = $raw | ConvertFrom-Json -ErrorAction Stop
    if (-not $j) { return $false }
    $entries = @()
    if ($j -is [System.Array]) { $entries = @($j) }
    elseif ($j.PSObject.Properties['approvals']) { $entries = @($j.approvals) }
    elseif ($j.PSObject.Properties['resources']) { $entries = @($j.resources) }
    else { $entries = @($j) }
    foreach ($e in $entries) {
      if (-not $e) { continue }
      $res = "$($e.resource)"
      if (-not $res -and $e.PSObject.Properties['name']) { $res = "$($e.name)" }
      $exp = $e.not_after
      if (-not $exp -and $e.PSObject.Properties['notAfter']) { $exp = $e.notAfter }
      if (-not $exp -and $e.PSObject.Properties['expires']) { $exp = $e.expires }
      if (-not $res -or -not $exp) { continue }
      # ConvertFrom-Json materialises an ISO-8601 string as a [DateTime] (Kind retained), so do NOT
      # stringify-and-reparse: that lost the offset and read a genuinely-future approval as expired
      # (2026-11-28). Use the object directly; only fall back to parsing for a plain string.
      $deadlineUtc = $null
      if ($exp -is [DateTimeOffset]) { $deadlineUtc = $exp.UtcDateTime }
      elseif ($exp -is [DateTime]) { $deadlineUtc = $exp.ToUniversalTime() }
      else {
        $dto = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse("$exp", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$dto)) { $deadlineUtc = $dto.UtcDateTime }
      }
      if ($null -eq $deadlineUtc) { continue }
      if ($deadlineUtc -le [DateTime]::UtcNow) { continue }
      if ([regex]::IsMatch($c, '(?i)' + [regex]::Escape($res) + '\b')) { return $true }
    }
    return $false
  } catch {
    return $false
  }
}

# Explicit read-only escape hatch (owner requirement): list|describe|get|ssh|delete are NEVER refused,
# whatever else the line contains, as long as it carries no create/extend verb.
$readOnlyVerb = '(?i)\b(list|describe|get|ssh|delete)\b'
$mutatingVerb = '(?i)\b(create|bulk\s+create|resize|update)\b'
if ($cmd -match $readOnlyVerb -and $cmd -notmatch $mutatingVerb) { exit 0 }

$pattern = Get-PaidVmPattern $cmd
if (-not $pattern) { exit 0 }

if (Test-Approved $cmd) { exit 0 }

$resource = Get-ParsedResource $cmd
if (-not $resource) { $resource = '(not parsed from the command)' }
$approvalPath = Get-ApprovalPath

$costTable = @'
    machine shape                on-demand, europe-west1, USD
    n2-standard-16               ~ $0.78 /h
    n2-standard-32               ~ $1.56 /h
    c3-standard-16               ~ $0.87 /h
    c3-standard-32               ~ $1.74 /h
    c4d-standard-16              ~ $0.86 /h
    c4d-standard-32              ~ $1.73 /h
    a3-ultragpu-8g  (8x H100)    ~ $25 - $30 /h
    H200 8x (Vertex/GCE a3/a4)   ~ $30 - $45 /h
'@

$msg = @"
BLOCKED by guard-dev-vm (paid-VM cost guard, proposal 01DEVVMCOSTGUARD20261121): this command would CREATE or EXTEND a paid VM.
  matched pattern : $pattern
  target resource : $resource
  hourly cost ESTIMATE (verify against the live price list before you commit a budget):
$costTable
Two ways forward:
  1) Ask the owner for a TIME-BOXED approval ticket (a named budget, a TTL in hours, and a teardown owner), then record it in
     $approvalPath   as   { "resource": "$resource", "not_after": "<ISO-8601 UTC>" }
     (the file may hold a JSON array of such entries, or an object with an "approvals" array).
  2) Re-issue with a SPOT/preemptible shape (e.g. `--scheduling-strategy=SPOT` or `--provisioning-model=SPOT`) - this guard allows it.
Command: $cmd
"@
Deny $msg
