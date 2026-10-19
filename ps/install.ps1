<#
  Install the ps/ tooling into ~/.copilot (the live location every hook and agent uses).
  Runs every test suite against THIS checkout first; refuses to install on red. Keeps a timestamped
  backup of each file it replaces in ~/.copilot/.backup/<ts>/. -Check = report drift only.
#>
param([switch]$Check, [switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$map = [ordered]@{
  'bin\agentq.ps1' = 'bin\agentq.ps1'; 'bin\agentq-v2.ps1' = 'bin\agentq-v2.ps1'; 'bin\agentq-config.json' = 'bin\agentq-config.json'
  'bin\worktree.ps1' = 'bin\worktree.ps1'; 'bin\worktree-prune-task.ps1' = 'bin\worktree-prune-task.ps1'; 'bin\agentq-sync.ps1' = 'bin\agentq-sync.ps1'
  'hooks\deploy-clean.ps1' = 'hooks\deploy-clean.ps1'; 'hooks\run-build.ps1' = 'hooks\run-build.ps1'; 'hooks\guard-tooluse.ps1' = 'hooks\guard-tooluse.ps1'
  'tests\test-agentq.ps1' = 'bin\test-agentq.ps1'; 'tests\test-agentq-v2.ps1' = 'bin\test-agentq-v2.ps1'; 'tests\test-agentq-v3.ps1' = 'bin\test-agentq-v3.ps1'
  'tests\test-worktree-v2.ps1' = 'hooks\test-worktree-v2.ps1'; 'tests\test-guard-v2.ps1' = 'hooks\test-guard-v2.ps1'
  'tests\test-land-changelog.ps1' = 'bin\test-land-changelog.ps1'
  'bin\repo-migrate.ps1' = 'bin\repo-migrate.ps1'; 'tests\test-repo-migrate.ps1' = 'bin\test-repo-migrate.ps1'
  # background jobs: bounded wait + registry (mirrored by agentq-sync)
  'bin\agentq-jobs-lib.ps1' = 'bin\agentq-jobs-lib.ps1'; 'bin\wait-job.ps1' = 'bin\wait-job.ps1'; 'bin\job-start.ps1' = 'bin\job-start.ps1'
  'bin\job-run.ps1' = 'bin\job-run.ps1'; 'bin\jobs.ps1' = 'bin\jobs.ps1'; 'tests\test-jobs.ps1' = 'bin\test-jobs.ps1'
  # devcloud F2: cloud placement client + its tests
  # shared-clone fast-forward + park (scheduled task git-autosync)
  'bin\git-autosync.ps1' = 'bin\git-autosync.ps1'; 'tests\test-git-autosync.ps1' = 'bin\test-git-autosync.ps1'; 'tests\test-guard-shared.ps1' = 'hooks\test-guard-shared.ps1'
  'bin\agentq-cloud.ps1' = 'bin\agentq-cloud.ps1'; 'tests\test-agentq-cloud.ps1' = 'bin\test-agentq-cloud.ps1'; 'tests\test-guard-cloud.ps1' = 'hooks\test-guard-cloud.ps1'
  # S18-08/09 (vitals ADR-0038): orphan terminal reaper, adaptive machine cap + agent registry tests
  'bin\reap-terminals.ps1' = 'bin\reap-terminals.ps1'; 'tests\test-agentq-adaptive.ps1' = 'bin\test-agentq-adaptive.ps1'
  # 2026-10-18: VS Code chat-terminal associations, so the reaper never interrupts an agent
  'bin\vscode-chat-terminals.mjs' = 'bin\vscode-chat-terminals.mjs'; 'tests\test-reap-terminals.ps1' = 'bin\test-reap-terminals.ps1'
  # ADR 0003 wave 1: publish, lease activity + notices + slot prep, PowerShell entry hardening
  'tests\test-agentq-publish.ps1' = 'bin\test-agentq-publish.ps1'; 'tests\test-agentq-lease3.ps1' = 'bin\test-agentq-lease3.ps1'; 'tests\test-agentq-args.ps1' = 'bin\test-agentq-args.ps1'
  # ADR 0003 W2-4 job objects + W4-4 SLO report
  'bin\agentq-jobobject-lib.ps1' = 'bin\agentq-jobobject-lib.ps1'; 'bin\agentq-jobobject.ps1' = 'bin\agentq-jobobject.ps1'; 'bin\agentq-slo.mjs' = 'bin\agentq-slo.mjs'; 'bin\agentq-store.mjs' = 'bin\agentq-store.mjs'; 'tests\test-store.mjs' = 'bin\test-store.mjs'; 'bin\agentq-flakes.mjs' = 'bin\agentq-flakes.mjs'; 'tests\test-flakes.mjs' = 'bin\test-flakes.mjs'; 'tests\test-land-flakes.ps1' = 'bin\test-land-flakes.ps1'; 'tests\test-agentq-claims.ps1' = 'bin\test-agentq-claims.ps1'; 'tests\test-land-batch.ps1' = 'bin\test-land-batch.ps1'; 'tests\fake-gate.ps1' = 'bin\fake-gate.ps1'
  'tests\test-jobobject.ps1' = 'bin\test-jobobject.ps1'; 'tests\test-land-finalize.ps1' = 'bin\test-land-finalize.ps1'; 'tests\test-land-reclaim.ps1' = 'bin\test-land-reclaim.ps1'; 'tests\test-land-precheck.ps1' = 'bin\test-land-precheck.ps1'
  # 2026-10-18: Ctrl+C + exit before any force-kill of a terminal
  'bin\console-signal.ps1' = 'bin\console-signal.ps1'
  # 2026-10-18: stop a stuck command, keep the terminal (Ctrl+C -> Y -> Ctrl+Break -> kill children)
  'bin\term-interrupt.ps1' = 'bin\term-interrupt.ps1'; 'tests\test-term-interrupt.ps1' = 'bin\test-term-interrupt.ps1'
  # ADR 0007 (2026-10-19): git-first workspace + devbox teams (were ad-hoc copies in ~/.codai/{git,devbox})
  'bin\git-publish.ps1' = 'bin\git-publish.ps1'; 'bin\git-wip-snapshot.ps1' = 'bin\git-wip-snapshot.ps1'
  'bin\devsync.ps1' = 'bin\devsync.ps1'; 'bin\devbox-bootstrap.ps1' = 'bin\devbox-bootstrap.ps1'; 'bin\devbox-team-sync.ps1' = 'bin\devbox-team-sync.ps1'
  'bin\devbox-teams.py' = 'bin\devbox-teams.py'; 'devbox\devbox-root.sh' = 'bin\devbox-root.sh'; 'devbox\devbox-user.sh' = 'bin\devbox-user.sh'
  'tests\test-devbox-tools.ps1' = 'bin\test-devbox-tools.ps1'; 'tests\test-devbox-teams.py' = 'bin\test-devbox-teams.py'
}
$dst = Join-Path $env:USERPROFILE '.copilot'
$drift = @()
foreach ($k in $map.Keys) {
  $a = Join-Path $src $k; $b = Join-Path $dst $map[$k]
  if (-not (Test-Path $b) -or (Get-FileHash $a).Hash -ne (Get-FileHash $b).Hash) { $drift += $k }
}
if ($Check) { if ($drift) { "DRIFT: $($drift -join ', ')"; exit 1 }; 'in sync'; exit 0 }
if (-not $SkipTests) {
  & pwsh -NoProfile -File (Join-Path $src 'tests\run-all.ps1')
  if ($LASTEXITCODE) { throw 'install: tests are red - not installing' }
}
$bk = Join-Path $dst ".backup\$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
foreach ($k in $drift) {
  $a = Join-Path $src $k; $b = Join-Path $dst $map[$k]
  if (Test-Path $b) { $t = Join-Path $bk $map[$k]; New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null; Copy-Item $b $t }
  # atomic replace: a hook firing mid-copy must never see half a file
  Copy-Item $a "$b.new" -Force; Move-Item "$b.new" $b -Force
  "installed $($map[$k])"
}
# legacy test that encoded the retired ad-hoc naming
$old = Join-Path $dst 'hooks\test-worktree-tools.ps1'
if (Test-Path $old) { New-Item -ItemType Directory -Force (Join-Path $bk 'hooks') | Out-Null; Move-Item $old (Join-Path $bk 'hooks\test-worktree-tools.ps1') -Force; 'retired hooks\test-worktree-tools.ps1 (superseded by test-worktree-v2.ps1)' }
# ADR 0007: the WIP snapshot task runs the agentq copy (was ~/.codai/git/wip-all.ps1)
$wipTask = Get-ScheduledTask -TaskName 'codai-git-wip-snapshot' -ErrorAction SilentlyContinue
if ($wipTask -and "$($wipTask.Actions[0].Arguments)" -notmatch 'git-wip-snapshot\.ps1') {
  # hidden-run.vbs (wscript, window style 0): -WindowStyle Hidden still flashes a console under an
  # interactive token (owner complaint 2026-10-19).
  $wipArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $dst 'bin\git-wip-snapshot.ps1')`" -All"
  $vbs = 'E:\gh\vmui\scripts\hidden-run.vbs'
  $a = if (Test-Path $vbs) { New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`" `"$((Get-Command pwsh).Source)`" $wipArgs" } else { New-ScheduledTaskAction -Execute 'pwsh.exe' -Argument "-WindowStyle Hidden $wipArgs" }
  Set-ScheduledTask -TaskName 'codai-git-wip-snapshot' -Action $a | Out-Null
  'task codai-git-wip-snapshot -> bin\git-wip-snapshot.ps1 -All'
}
"install: $($drift.Count) file(s); backup in $bk"
