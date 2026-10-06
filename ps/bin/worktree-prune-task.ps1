# copilot-worktree-prune (ADR 0001): expire stale leases (backup first), then prune unleased
# disposable slots and migrate legacy (non-standard) worktrees/orphans. Leased slots are never touched.
$log = Join-Path $env:USERPROFILE '.codai\worktree-prune.log'
"=== $(Get-Date -Format o)" | Add-Content $log
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'agentq.ps1') sweep *>> $log
& (Join-Path $PSScriptRoot 'worktree.ps1') prune -All *>> $log
& (Join-Path $PSScriptRoot 'worktree.ps1') migrate -All -OlderThanHours 24 *>> $log
