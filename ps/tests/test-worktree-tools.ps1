<#
  Regression test for ~/.copilot/bin/worktree.ps1 and deploy-clean.ps1 pool placement.
  Fixture: throwaway repo + bare remote in %TEMP%, CODAI_WT_ROOT redirected there.
  Usage: test-worktree-tools.ps1 [-Tool <worktree.ps1>] [-Deploy <deploy-clean.ps1>]
#>
param(
  [string]$Tool = "$env:USERPROFILE\.copilot\bin\worktree.ps1",
  [string]$Deploy = "$env:USERPROFILE\.copilot\hooks\deploy-clean.ps1"
)
$ErrorActionPreference = 'Stop'
$fx = Join-Path $env:TEMP ('wt-fx-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fails = @()
function Check([string]$name, [bool]$ok) { if ($ok) { Write-Host "  ok   $name" } else { Write-Host "  FAIL $name" -ForegroundColor Red; $script:fails += $name } }
try {
  New-Item -ItemType Directory -Force "$fx\remote.git", "$fx\repo" | Out-Null
  git -C "$fx\remote.git" init -q --bare
  git -C "$fx\repo" init -q -b main; git -C "$fx\repo" config user.email t@t; git -C "$fx\repo" config user.name t
  'x' | Set-Content "$fx\repo\a.txt"; git -C "$fx\repo" add a.txt; git -C "$fx\repo" commit -q -m init
  git -C "$fx\repo" remote add origin "$fx\remote.git"; git -C "$fx\repo" push -q -u origin main 2>$null
  $env:CODAI_WT_ROOT = "$fx\.wt"

  # new -> lands under <root>\<repo>\<name>
  $p = (pwsh -NoProfile -File $Tool new -Repo "$fx\repo" -Name probe -NoEnvCopy | Select-Object -Last 1)
  Check 'new places worktree under CODAI_WT_ROOT\repo\name' ((Test-Path "$fx\.wt\repo\probe\a.txt") -and $p -like "*\.wt\repo\probe")

  # new from INSIDE a worktree still keys on the main repo name (no chains)
  pwsh -NoProfile -File $Tool new -Repo "$fx\.wt\repo\probe" -Name nested -NoEnvCopy | Out-Null
  Check 'new from inside a worktree uses main repo name' (Test-Path "$fx\.wt\repo\nested\a.txt")

  # dirty worktree is kept by prune even with -OlderThanHours 0
  'dirty' | Add-Content "$fx\.wt\repo\probe\a.txt"
  pwsh -NoProfile -File $Tool prune -Repo "$fx\repo" -OlderThanHours 0 | Out-Null
  Check 'prune keeps a dirty worktree' (Test-Path "$fx\.wt\repo\probe\a.txt")
  Check 'prune removes a clean pushed idle worktree' (-not (Test-Path "$fx\.wt\repo\nested"))

  # unpushed commit is kept
  git -C "$fx\.wt\repo\probe" -c user.email=t@t -c user.name=t commit -q -am wip
  pwsh -NoProfile -File $Tool prune -Repo "$fx\repo" -OlderThanHours 0 | Out-Null
  Check 'prune keeps a worktree with unpushed commits' (Test-Path "$fx\.wt\repo\probe\a.txt")

  # remove refuses unpushed
  $null = pwsh -NoProfile -File $Tool remove -Repo "$fx\repo" -Path "$fx\.wt\repo\probe" 2>&1
  Check 'remove refuses unpushed work' (Test-Path "$fx\.wt\repo\probe\a.txt")

  # junction safety: a junction inside a removed worktree must not delete its target
  New-Item -ItemType Directory -Force "$fx\keep" | Out-Null; 'precious' | Set-Content "$fx\keep\f.txt"
  pwsh -NoProfile -File $Tool new -Repo "$fx\repo" -Name junc -NoEnvCopy | Out-Null
  cmd /c mklink /J "$fx\.wt\repo\junc\node_modules" "$fx\keep" | Out-Null
  # untracked junction would block; ignore it like a real node_modules
  'node_modules' | Set-Content "$fx\.wt\repo\junc\.git-info-exclude-dummy"
  Add-Content -Path (Join-Path (git -C "$fx\.wt\repo\junc" rev-parse --path-format=absolute --git-dir) 'info\exclude') -Value "node_modules`n.git-info-exclude-dummy" -ErrorAction SilentlyContinue
  if (-not (Test-Path (Join-Path (git -C "$fx\repo" rev-parse --path-format=absolute --git-common-dir) 'info'))) { New-Item -ItemType Directory (Join-Path (git -C "$fx\repo" rev-parse --path-format=absolute --git-common-dir) 'info') | Out-Null }
  Add-Content -Path (Join-Path (git -C "$fx\repo" rev-parse --path-format=absolute --git-common-dir) 'info\exclude') -Value "node_modules`n.git-info-exclude-dummy"
  pwsh -NoProfile -File $Tool remove -Repo "$fx\repo" -Path "$fx\.wt\repo\junc" -Force | Out-Null
  Check 'remove deleted the worktree' (-not (Test-Path "$fx\.wt\repo\junc"))
  Check 'remove did NOT delete the junction target' (Test-Path "$fx\keep\f.txt")

  # deploy-clean: pool slot under CODAI_WT_ROOT\repo\deploy-1, also when run from inside a worktree
  if (Test-Path $Deploy) {
    pwsh -NoProfile -File $Deploy -Root "$fx\.wt\repo\probe" -Ref main -NoEnvCopy -NoInstall -Command 'Get-Location | Out-Null' | Out-Null
    Check 'deploy-clean uses <root>\<repo>\deploy-1 even from inside a worktree' (Test-Path "$fx\.wt\repo\deploy-1\a.txt")
    Check 'deploy-clean did not create a sibling *-deploy-wt' (-not (Get-ChildItem "$fx\.wt\repo" -Directory | Where-Object Name -like '*deploy-wt*'))
  }
} finally {
  Remove-Item Env:CODAI_WT_ROOT -ErrorAction SilentlyContinue
  if (Test-Path "$fx\.wt") { cmd /c rmdir /s /q "`"$fx\.wt`"" }
  cmd /c rmdir /s /q "`"$fx`"" 2>$null
}
if ($fails) { Write-Host "worktree tools: $($fails.Count) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'worktree tools OK'
