# The shared-clone commit guard (Assert-SharedCloneWriteAllowed in agentq.ps1): with
# `sharedCloneModeRepos: { repo: refuse }` it must refuse a commit in the repo's MAIN working tree and
# must NEVER refuse one in a linked worktree - a leased slot is a linked worktree and is exactly where
# `agentq commit` / `agentq land` run (2026-11-19: every commit in a slot was refused as
# "E:\gh\codai is the SHARED clone" because the decision keyed on path arithmetic over
# `--git-common-dir`, whose parent is the main clone for EVERY worktree of the repo).
#
# Throwaway repo + LINKED worktrees under %TEMP%, isolated AGENTQ_HOME / AGENTQ_CONFIG. No network,
# no real repo touched. Run: pwsh -NoProfile -File ps\tests\test-agentq-shared-commit.ps1 [-Aq <agentq.ps1>]
param([string]$Aq)
$ErrorActionPreference = 'Stop'
if (-not $Aq) { $Aq = Join-Path (Split-Path $PSScriptRoot) 'bin\agentq.ps1' }
if (-not (Test-Path -LiteralPath $Aq)) { Write-Host "FAIL shared-commit: agentq.ps1 not found at $Aq"; exit 1 }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aq-shared-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_NO_ADMISSION = '1'
$env:AGENTQ_CONFIG = Join-Path $tmp 'cfg.json'
Remove-Item Env:AGENTQ_SHARED_CLONE_COMMIT_OK -ErrorAction SilentlyContinue
@{
  machineCap = 2; quickBurst = 1; agingMin = 5; idleYieldMin = 5; idleCpuSec = 10; minFreeCommitGB = 0
  sharedCloneMode = 'warn'
  sharedCloneModeRepos = @{ repo = 'refuse'; repo2 = 'refuse' }
} | ConvertTo-Json | Set-Content $env:AGENTQ_CONFIG

$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail"; $script:fail++ }
}
function New-Repo([string]$path) {
  New-Item -ItemType Directory -Force $path | Out-Null
  git -C $path init -q -b main; git -C $path config user.email t@t; git -C $path config user.name t
  Set-Content (Join-Path $path 'base.txt') 'b'; git -C $path add base.txt; git -C $path commit -qm init
}
# Commit one scratch file in $dir the way an agent would; returns the child's exit code and output.
function Invoke-Commit([string]$dir, [string]$file, [string]$msg) {
  Set-Content -LiteralPath (Join-Path $dir $file) 'x'
  Push-Location $dir
  try {
    $o = @(& pwsh -NoProfile -File $Aq commit -Purpose 'shared-guard test' -Message $msg -Paths $file -NoPush 2>&1 | ForEach-Object { "$_" })
    @{ code = $LASTEXITCODE; out = ($o -join "`n") }
  } finally { Pop-Location }
}

# repo = a repo that HAS slots (the guard's .wt\<repo> root exists) -> protected
$repo = Join-Path $tmp 'repo'
New-Repo $repo
New-Item -ItemType Directory -Force (Join-Path $tmp '.wt\repo') | Out-Null
$slot = Join-Path $tmp '.wt\repo\task-1'      # exactly the shape `agentq lease` produces
git -C $repo worktree add -q $slot -b topic 2>$null
$away = Join-Path $tmp 'away-wt'              # a linked worktree OUTSIDE the managed root
git -C $repo worktree add -q $away -b away 2>$null

Check 'setup: main worktree, slot and away are three distinct tops' (
  ((git -C $repo rev-parse --show-toplevel) -ne (git -C $slot rev-parse --show-toplevel)) -and
  ((git -C $slot rev-parse --show-toplevel) -ne (git -C $away rev-parse --show-toplevel))) ''
Check 'setup: all three share ONE git-common-dir (the trap that made every slot look shared)' (
  @(@($repo, $slot, $away) | ForEach-Object { (git -C $_ rev-parse --path-format=absolute --git-common-dir).Trim().ToLowerInvariant() } | Sort-Object -Unique).Count -eq 1) ''

# 1. the MAIN working tree is refused, nothing committed, nothing staged, and it is journaled
$commitsBefore = @(git -C $repo log --oneline).Count
$r = Invoke-Commit $repo 'main.txt' 'test: main refused'
Check '1 main worktree refused (exit 3)' ($r.code -eq 3) "exit $($r.code): $($r.out)"
Check '1 refusal names the shared clone' ($r.out -match 'is the SHARED clone') $r.out
Check '1 refusal committed nothing' (@(git -C $repo log --oneline).Count -eq $commitsBefore)
Check '1 refusal staged nothing' (-not (@(git -C $repo diff --cached --name-only) -contains 'main.txt'))
$j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -ErrorAction SilentlyContinue | ForEach-Object { $_ | ConvertFrom-Json })
Check '1 refusal journaled as shared-clone-refused' (@($j | Where-Object { $_.event -eq 'shared-clone-refused' -and $_.verb -eq 'commit' }).Count -ge 1)

# 2. the leased slot (a LINKED worktree) is allowed - this is the 2026-11-19 regression
$r = Invoke-Commit $slot 'slot.txt' 'test: slot allowed'
Check '2 slot commit allowed (exit 0)' ($r.code -eq 0) "exit $($r.code): $($r.out)"
Check '2 slot commit did not print the refusal' ($r.out -notmatch 'is the SHARED clone') $r.out
Check '2 slot commit actually landed the file' ((@(git -C $slot show --name-only --format= HEAD)) -contains 'slot.txt')
Check '2 slot commit left the main worktree untouched' (@(git -C $repo log --oneline).Count -eq $commitsBefore)

# 3. a linked worktree outside the managed .wt root is allowed too: the rule is "not the main tree"
$r = Invoke-Commit $away 'away.txt' 'test: away allowed'
Check '3 linked worktree outside the slots root allowed (exit 0)' ($r.code -eq 0) "exit $($r.code): $($r.out)"
Check '3 away commit landed the file' ((@(git -C $away show --name-only --format= HEAD)) -contains 'away.txt')

# 4. the documented opt-out still lets a deliberate one-off through in the main worktree
$env:AGENTQ_SHARED_CLONE_COMMIT_OK = '1'
$env:AGENTQ_SHARED_CLONE_REASON = 'test one-off'
$r = Invoke-Commit $repo 'once.txt' 'test: deliberate one-off'
Remove-Item Env:AGENTQ_SHARED_CLONE_COMMIT_OK, Env:AGENTQ_SHARED_CLONE_REASON
Check '4 AGENTQ_SHARED_CLONE_COMMIT_OK=1 allows the main worktree (exit 0)' ($r.code -eq 0) "exit $($r.code): $($r.out)"
Check '4 one-off landed the file' ((@(git -C $repo show --name-only --format= HEAD)) -contains 'once.txt')

# 5. a repo marked refuse but with NO slots root is not protected (nothing to protect) - and the SAME
#    config entry DOES refuse once the slots root exists, proving case 1 is the slots rule, not the mode
$repo2 = Join-Path $tmp 'repo2'
New-Repo $repo2
$r = Invoke-Commit $repo2 'noslots.txt' 'test: no slots root'
Check '5 main tree with no .wt root allowed (exit 0)' ($r.code -eq 0) "exit $($r.code): $($r.out)"
New-Item -ItemType Directory -Force (Join-Path $tmp '.wt\repo2') | Out-Null
$r = Invoke-Commit $repo2 'withslots.txt' 'test: slots root present'
Check '5 same repo refused once the .wt root exists (exit 3)' ($r.code -eq 3) "exit $($r.code): $($r.out)"

foreach ($w in @($slot, $away)) { git -C $repo worktree remove --force $w 2>$null }
cmd /c rmdir /s /q "`"$tmp`"" 2>$null
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
