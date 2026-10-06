$log = Join-Path $env:USERPROFILE '.codai\worktree-prune.log'
"=== $(Get-Date -Format o)" | Add-Content $log
& (Join-Path $PSScriptRoot 'worktree.ps1') prune -All *>> $log
& (Join-Path $PSScriptRoot 'worktree.ps1') relocate -All -OlderThanHours 3 *>> $log
