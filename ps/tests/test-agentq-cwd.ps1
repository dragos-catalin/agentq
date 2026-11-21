# Invoke-Run cwd (2026-11-21) - "a brand-new slot starts hollow".
# Prepare-Slot launches its slot-prep install as `agentq run -Resource install -Repo <slot> -- pnpm install`
# from whatever directory the caller happened to be in. Invoke-Run used to run the child as `& $exe @argv`
# in the CALLER's cwd, so the install filled the CALLER's tree, returned 0, and prep recorded ready=true
# for a slot that still had no node_modules. The fix (commit 37fdf67) runs the command at the resolved repo
# root WHEN the caller is OUTSIDE that repo, and keeps the caller's (possibly nested) directory when the
# caller is INSIDE it. This suite pins both halves of that rule plus the temp cleanup:
#   1. launcher OUTSIDE the repo            -> the child's cwd IS the repo root;
#   2. launcher INSIDE a nested subdirectory -> the child's cwd is that SAME subdirectory (no regression
#      for an ordinary in-repo invocation, whose cwd must be preserved);
#   3. the temp directory is removed (a suite that leaks its scratch is a defect too).
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqcwd-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; $env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_SESSION = 'test-cwd'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
# RAM/commit gates off so the run never waits; a fresh AGENTQ_HOME means no other holder competes.
$cfg = Join-Path $tmp 'cfg.json'
'{"taskSlotsPerRepo":3,"taskSlotsMachine":5,"minFreeCommitGB":0,"minFreeGB":0,"machineCapAdaptive":{"minFreeRamGB":0,"minFreeCommitGB":0}}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
# The child is `cmd /c cd`: it prints exactly one line, its own working directory.
function ChildDir([string[]]$lines) {
  $hit = @($lines | Where-Object { $_ -match '^[A-Za-z]:\\' } | Select-Object -First 1)
  if (-not $hit) { return '' }
  "$($hit[0])".Trim().TrimEnd('\')
}
function Norm([string]$p) { "$p".Trim().TrimEnd('\') }
function RunChild([string]$purpose, [string]$repo) {
  $o = @(& pwsh -NoProfile -File $Aq run -Resource install -Purpose $purpose -Repo $repo -- cmd /c cd 2>&1 | ForEach-Object { "$_" })
  $script:code = $LASTEXITCODE
  $o
}

$repo = Join-Path $tmp 'repo'
git init -q -b main $repo 2>$null
[IO.File]::WriteAllText("$repo\a.txt", "a`n"); git -C $repo add -A 2>$null; git -C $repo commit -qm init 2>$null
$elsewhere = Join-Path $tmp 'elsewhere'; New-Item -ItemType Directory -Force $elsewhere | Out-Null
$nested = Join-Path $repo 'deep\sub'; New-Item -ItemType Directory -Force $nested | Out-Null

# 1 ---- launcher OUTSIDE the repo: the child must run at the repo root, NOT in the launcher's directory.
Push-Location $elsewhere
try {
  $out = RunChild 'cwd cell1 outside' $repo
  $got = ChildDir $out
  Check '1 outside: run exited 0' ($script:code -eq 0) "exit=$($script:code) `n$($out -join "`n")"
  Check '1 outside: child cwd IS the repo root' ((Norm $got) -eq (Norm $repo)) "got='$got' want='$(Norm $repo)'"
  Check '1 outside: child cwd is NOT the launcher dir' ((Norm $got) -ne (Norm $elsewhere)) "got='$got' launcher='$(Norm $elsewhere)'"
} finally { Pop-Location }

# 2 ---- launcher INSIDE a nested subdirectory: the child must keep that SAME directory (no regression).
Push-Location $nested
try {
  $out = RunChild 'cwd cell2 inside' $repo
  $got = ChildDir $out
  Check '2 inside: run exited 0' ($script:code -eq 0) "exit=$($script:code) `n$($out -join "`n")"
  Check '2 inside: child cwd IS the nested subdirectory' ((Norm $got) -eq (Norm $nested)) "got='$got' want='$(Norm $nested)'"
  Check '2 inside: child cwd is NOT flattened to the repo root' ((Norm $got) -ne (Norm $repo)) "got='$got' repo='$(Norm $repo)'"
} finally { Pop-Location }

# 3 ---- the scratch directory is removed.
$rmOk = $true
try { Remove-Item -Recurse -Force $tmp -ErrorAction Stop } catch { $rmOk = $false }
Check '3 cleanup removes the temp directory' ($rmOk -and -not (Test-Path $tmp)) "left: $(Test-Path $tmp) tmp=$tmp"

if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
