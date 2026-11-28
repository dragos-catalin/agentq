# guard-dev-vm.ps1: refuse any command that would CREATE/EXTEND a paid VM unless a time-boxed
# approval exists for that exact resource (proposal 01DEVVMCOSTGUARD20261121). Covers the deny/allow
# gate itself (no-approval / valid / expired / unparsable), the read-only escape hatch, the SPOT
# custom-jobs allow, one case per paid pattern, the both-dialect deny shape, and the refuse message.
# Modeled on test-deploy-guard.ps1. Approval path is overridden with $env:CODAI_DEV_VM_APPROVAL so the
# real machine file is never read.
[CmdletBinding()]
param([string]$Guard = (Join-Path $PSScriptRoot '..\hooks\guard-dev-vm.ps1'))
$ErrorActionPreference = 'Stop'
$Guard = (Resolve-Path $Guard).Path
$pass = 0; $fail = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { $script:pass++; Write-Host "PASS $n" } else { $script:fail++; Write-Host "FAIL $n $d" } }
function Call([string]$command, [switch]$NoVsCode) {
  $p = @{ tool_name = 'run_in_terminal'; tool_input = @{ command = $command } }
  if (-not $NoVsCode) { $p.hook_event_name = 'PreToolUse' }
  $j = $p | ConvertTo-Json -Compress -Depth 5
  $out = ($j | pwsh -NoProfile -File $Guard 2>$null)
  $code = $LASTEXITCODE
  $deny = $false
  try { if ((($out | Out-String) | ConvertFrom-Json).hookSpecificOutput.permissionDecision -eq 'deny') { $deny = $true } } catch { }
  [pscustomobject]@{ code = $code; deny = $deny; raw = ($out -join "`n") }
}
function IsDeny($r) { return ($r.deny -or $r.code -eq 2) }

$root = Join-Path ([IO.Path]::GetTempPath()) ('devvm-guard-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null
$approval = Join-Path $root 'approval.json'
$env:CODAI_DEV_VM_APPROVAL = $approval
try {
  $createVm1 = 'gcloud compute instances create vm-1 --machine-type n2-standard-16 --zone europe-west1-b'
  $createVm2 = 'gcloud compute instances create vm-2 --machine-type n2-standard-16 --zone europe-west1-b'

  # --- no-approval: deny -----------------------------------------------------
  Remove-Item $approval -ErrorAction SilentlyContinue
  $r = Call $createVm1
  Check 'no approval: paid create is DENIED' (IsDeny $r) "deny=$($r.deny) code=$($r.code)"
  Check 'the refusal message carries the cost estimate' (($r.raw -match 'ESTIMATE') -and ($r.raw -match 'n2-standard-16')) $r.raw
  Check 'the refusal message names the two ways forward' (($r.raw -match '(?i)approval ticket') -and ($r.raw -match '(?i)SPOT')) $r.raw
  $reason = $null
  try { $reason = (($r.raw | ConvertFrom-Json).hookSpecificOutput.permissionDecisionReason) } catch { }
  Check 'the refusal message quotes the approval path' ([bool]$reason -and $reason.Contains($approval)) $r.raw

  # --- valid approval: allow (target resource matches) ------------------------
  (@{ approvals = @(@{ resource = 'vm-1'; not_after = ([DateTime]::UtcNow.AddHours(2)).ToString('o') }) } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $approval
  $r = Call $createVm1
  Check 'valid approval for the resource: ALLOWED' (-not (IsDeny $r)) "deny=$($r.deny) code=$($r.code)"
  $r = Call $createVm2
  Check 'approval for vm-1 does NOT cover vm-2: DENIED' (IsDeny $r) "deny=$($r.deny) code=$($r.code)"

  # --- expired approval: deny -------------------------------------------------
  (@{ approvals = @(@{ resource = 'vm-1'; not_after = ([DateTime]::UtcNow.AddHours(-2)).ToString('o') }) } | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $approval
  $r = Call $createVm1
  Check 'expired approval: DENIED' (IsDeny $r) "deny=$($r.deny) code=$($r.code)"

  # --- unparsable approval: deny (fail closed) --------------------------------
  Set-Content -LiteralPath $approval -Value '{ this is not json'
  $r = Call $createVm1
  Check 'unparsable approval file: DENIED' (IsDeny $r) "deny=$($r.deny) code=$($r.code)"

  # --- read-only verbs: ALWAYS allow (prove with no approval file present) -----
  Remove-Item $approval -ErrorAction SilentlyContinue
  foreach ($c in @(
      'gcloud compute instances list',
      'gcloud compute instances describe vm-1 --zone europe-west1-b',
      'gcloud compute instances ssh vm-1 --zone europe-west1-b -- command',
      'gcloud compute instances delete vm-1 --zone europe-west1-b'
    )) {
    $r = Call $c
    Check "read-only allowed: $c" (-not (IsDeny $r)) "deny=$($r.deny) code=$($r.code)"
  }

  # --- SPOT custom-jobs: allow ------------------------------------------------
  $r = Call 'gcloud ai custom-jobs create --display-name job-1 --region us-central1 --worker-pool-spec=machine-type=n2-standard-16,replica-count=1 --scheduling-strategy=SPOT'
  Check 'SPOT custom-jobs create is ALLOWED' (-not (IsDeny $r)) "deny=$($r.deny) code=$($r.code)"

  # --- one case per paid pattern: deny ----------------------------------------
  $paid = @(
    'gcloud compute instances create vm-1 --machine-type n2-standard-16',
    'gcloud compute instances bulk create --pattern vm-# --predefined-names=vm-1',
    'gcloud compute instances update vm-1 --machine-type n2-standard-16',
    'gcloud compute instance-groups managed resize mig-1 --size 10',
    'az vm create -g rg -n vm-2 --image UbuntuLTS --size Standard_D2s_v3',
    'gcloud ai custom-jobs create --display-name job-2 --region us-central1',
    'gcloud container clusters create cluster-1 --zone europe-west1-b',
    'gcloud container node-pools create pool-1 --cluster cluster-1',
    'gcloud run jobs create job-3 --image gcr.io/x/y --min-instances 3'
  )
  foreach ($c in $paid) { $r = Call $c; Check "paid pattern DENIED: $c" (IsDeny $r) "deny=$($r.deny) code=$($r.code)" }

  # --- near-misses that must stay ALLOWED -------------------------------------
  foreach ($c in @(
      'gcloud run jobs create job-4 --image gcr.io/x/y --min-instances 0',
      'gcloud compute instances update vm-1 --labels=env=dev',
      'git status'
    )) {
    $r = Call $c
    Check "not a paid create/extend, ALLOWED: $c" (-not (IsDeny $r)) "deny=$($r.deny) code=$($r.code)"
  }

  # --- non-VS Code dialect: a deny is exit 2 ----------------------------------
  $r = Call $createVm1 -NoVsCode
  Check 'non-VS Code harness: deny returns exit 2' ($r.code -eq 2) "code=$($r.code)"
} finally {
  Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue
  Remove-Item Env:CODAI_DEV_VM_APPROVAL -ErrorAction SilentlyContinue
}

Write-Host "PASS $pass FAIL $fail"
if ($fail) { exit 1 } else { exit 0 }
