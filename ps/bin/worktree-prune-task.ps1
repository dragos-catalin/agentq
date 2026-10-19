# copilot-worktree-prune (ADR 0001): expire stale leases (backup first), then prune unleased
# disposable slots and migrate legacy (non-standard) worktrees/orphans. Leased slots are never touched.
$log = Join-Path $env:USERPROFILE '.codai\worktree-prune.log'
"=== $(Get-Date -Format o)" | Add-Content $log
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'agentq.ps1') sweep *>> $log
& (Join-Path $PSScriptRoot 'worktree.ps1') prune -All *>> $log
& (Join-Path $PSScriptRoot 'worktree.ps1') migrate -All -OlderThanHours 24 *>> $log
# ADR 0003 W1-6: the job registry grew to 2382 files in 7 days (nothing pruned it).
& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'jobs.ps1') prune -Days 7 *>> $log
# ADR 0006: keep the SQLite journal/jobs index current (incremental; never fatal).
try { & node (Join-Path $PSScriptRoot 'agentq-store.mjs') sync 2>&1 | Out-Null } catch { }
