<#
  Install the ps/ tooling into ~/.copilot (the live location every hook and agent uses).
  Runs every test suite against THIS checkout first; refuses to install on red. Keeps a timestamped
  backup of each file it replaces in ~/.copilot/.backup/<ts>/. -Check = report drift only.

  -Suites a,b   run only these suites (names from tests/run-all.ps1 -List) instead of all of them:
                the full set takes hours on a busy workstation, so a small fix is gated by the suites
                that cover it. -SkipTests installs without any gate (say why in the commit / tracker).
  agentq-config.json is MERGED, never replaced: keys the installed copy already has keep their local
  value (slot counts, workspaces), new keys are added from the checkout (2026-10-19, twice: an install
  silently shrank the live slot caps).
  bin/agentq-install.json records what was installed (source dir, commit, SHA-256 per file);
  `agentq doctor` compares the live files against it.
  AGENTQ_INSTALL_DIR overrides the destination (tests).
#>
param([switch]$Check, [switch]$SkipTests, [string[]]$Suites)
$ErrorActionPreference = 'Stop'
$src = $PSScriptRoot
$cfgKey = 'bin\agentq-config.json'
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
  # ADR 0008 (2026-11-11): post-land hook (agentq-v2.ps1 runs the landed tree's scripts/post-land.ps1 after the push)
  'tests\test-post-land.ps1' = 'bin\test-post-land.ps1'
  # 2026-10-18: Ctrl+C + exit before any force-kill of a terminal
  'bin\console-signal.ps1' = 'bin\console-signal.ps1'
  # 2026-10-18: stop a stuck command, keep the terminal (Ctrl+C -> Y -> Ctrl+Break -> kill children)
  'bin\term-interrupt.ps1' = 'bin\term-interrupt.ps1'; 'tests\test-term-interrupt.ps1' = 'bin\test-term-interrupt.ps1'
  # ADR 0007 (2026-10-19): git-first workspace + devbox teams (were ad-hoc copies in ~/.codai/{git,devbox})
  'bin\git-publish.ps1' = 'bin\git-publish.ps1'; 'bin\git-wip-snapshot.ps1' = 'bin\git-wip-snapshot.ps1'
  'bin\devsync.ps1' = 'bin\devsync.ps1'; 'bin\devbox-bootstrap.ps1' = 'bin\devbox-bootstrap.ps1'; 'bin\devbox-team-sync.ps1' = 'bin\devbox-team-sync.ps1'
  'bin\devbox-teams.py' = 'bin\devbox-teams.py'; 'devbox\devbox-root.sh' = 'bin\devbox-root.sh'; 'devbox\devbox-user.sh' = 'bin\devbox-user.sh'
  'tests\test-devbox-tools.ps1' = 'bin\test-devbox-tools.ps1'; 'tests\test-devbox-teams.py' = 'bin\test-devbox-teams.py'
  # ADR 0009 stage 0 (2026-11): load probe + admission, prune, doctor, chat keep-alive, land pre-gate,
  # read-only status; hook-pre.ps1 now lives in this repository (OQ-010).
  'bin\agentq-probe.ps1' = 'bin\agentq-probe.ps1'; 'bin\agentq-prune.ps1' = 'bin\agentq-prune.ps1'; 'bin\agentq-doctor.ps1' = 'bin\agentq-doctor.ps1'
  'hooks\hook-pre.ps1' = 'hooks\hook-pre.ps1'; 'tests\test-hook-pre.ps1' = 'hooks\test-hook-pre.ps1'
  'tests\test-lease-chat.ps1' = 'bin\test-lease-chat.ps1'; 'tests\test-land-pregate.ps1' = 'bin\test-land-pregate.ps1'
  'tests\test-agentq-admission.ps1' = 'bin\test-agentq-admission.ps1'; 'tests\test-status-readonly.ps1' = 'bin\test-status-readonly.ps1'
  'tests\test-agentq-prune.ps1' = 'bin\test-agentq-prune.ps1'; 'tests\test-agentq-doctor.ps1' = 'bin\test-agentq-doctor.ps1'
  'tests\test-slo.mjs' = 'bin\test-slo.mjs'
}
$dst = if ($env:AGENTQ_INSTALL_DIR) { $env:AGENTQ_INSTALL_DIR } else { Join-Path $env:USERPROFILE '.copilot' }
# Config merge: the installed file keeps every key it has; keys only the checkout has are appended.
# Returns the merged text, or $null when nothing is missing (file left untouched).
function Get-MergedConfig([string]$from, [string]$to) {
  $s = Get-Content -LiteralPath $from -Raw | ConvertFrom-Json -AsHashtable
  $d = Get-Content -LiteralPath $to -Raw | ConvertFrom-Json -AsHashtable
  $add = @($s.Keys | Where-Object { -not $d.ContainsKey($_) })
  if (-not $add.Count) { return $null }
  $o = [ordered]@{}
  foreach ($k in $d.Keys) { $o[$k] = $d[$k] }
  foreach ($k in $add) { $o[$k] = $s[$k] }
  $script:CfgAdded = $add
  ($o | ConvertTo-Json -Depth 8) + "`n"
}
$drift = @()
foreach ($k in $map.Keys) {
  $a = Join-Path $src $k; $b = Join-Path $dst $map[$k]
  if (-not (Test-Path -LiteralPath $a)) { throw "install: $k is in the map but not in this checkout" }
  if ($k -eq $cfgKey -and (Test-Path $b)) { if ($null -ne (Get-MergedConfig $a $b)) { $drift += $k }; continue }
  if (-not (Test-Path $b) -or (Get-FileHash $a).Hash -ne (Get-FileHash $b).Hash) { $drift += $k }
}
if ($Check) { if ($drift) { "DRIFT: $($drift -join ', ')"; exit 1 }; 'in sync'; exit 0 }
if (-not $SkipTests) {
  $ra = @('-NoProfile', '-File', (Join-Path $src 'tests\run-all.ps1'))
  if ($Suites) { $ra += @('-Only', (@($Suites | ForEach-Object { "$_" -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ',')) }
  & pwsh @ra
  if ($LASTEXITCODE) { throw 'install: tests are red - not installing' }
}
$bk = Join-Path $dst ".backup\$((Get-Date).ToString('yyyyMMdd-HHmmss'))"
# Files the destination does not have yet go first: agentq.ps1 dot-sources its companions at start, so a
# new agentq.ps1 must never be live before the new files it loads (an agentq call in that gap would fail).
$drift = @($drift | Where-Object { -not (Test-Path (Join-Path $dst $map[$_])) }) + @($drift | Where-Object { Test-Path (Join-Path $dst $map[$_]) })
foreach ($k in $drift) {
  $a = Join-Path $src $k; $b = Join-Path $dst $map[$k]
  if (Test-Path $b) { $t = Join-Path $bk $map[$k]; New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null; Copy-Item $b $t }
  New-Item -ItemType Directory -Force (Split-Path $b) | Out-Null
  if ($k -eq $cfgKey -and (Test-Path $b)) {
    $merged = Get-MergedConfig $a $b
    if ($null -ne $merged) {
      [IO.File]::WriteAllText("$b.new", $merged, [Text.UTF8Encoding]::new($false)); Move-Item "$b.new" $b -Force
      "merged $($map[$k]): added $($script:CfgAdded -join ', ') (existing keys keep their local value)"
    }
    continue
  }
  # atomic replace: a hook firing mid-copy must never see half a file
  Copy-Item $a "$b.new" -Force; Move-Item "$b.new" $b -Force
  "installed $($map[$k])"
}
# What was installed, for `agentq doctor` (a hand edit of an installed file shows up as a hash mismatch).
$files = [ordered]@{}
foreach ($k in $map.Keys) { if ($k -ne $cfgKey) { $files[$map[$k]] = (Get-FileHash -LiteralPath (Join-Path $dst $map[$k]) -Algorithm SHA256).Hash } }
$sha = "$(& git -C $src rev-parse HEAD 2>$null)".Trim()
$dirty = [bool]@(& git -C $src status --porcelain -- . 2>$null | Where-Object { $_ }).Count
$manifest = [ordered]@{ src = $src; sha = $sha; dirty = $dirty; at = [DateTime]::UtcNow.ToString('o'); files = $files }
$mf = Join-Path $dst 'bin\agentq-install.json'
[IO.File]::WriteAllText("$mf.new", ($manifest | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false)); Move-Item "$mf.new" $mf -Force
if ($env:AGENTQ_INSTALL_DIR) { "install: $($drift.Count) file(s) into $dst; backup in $bk"; exit 0 }
# The sync loop is a long-running process: it keeps running the OLD code until restarted (2026-10-12).
if ($drift | Where-Object { $_ -in 'bin\agentq-sync.ps1', 'bin\agentq-probe.ps1', 'bin\agentq-jobs-lib.ps1' }) {
  try {
    $syncTask = Get-ScheduledTask -TaskName 'agentq-sync' -ErrorAction SilentlyContinue
    if ($syncTask) {
      $needle = (Join-Path $dst 'bin\agentq-sync.ps1').ToLowerInvariant()
      foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { "$($_.CommandLine)".ToLowerInvariant().Contains($needle) -and "$($_.CommandLine)" -match '-Loop\b' })) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
      }
      Start-ScheduledTask -TaskName 'agentq-sync'
      'restarted the agentq-sync loop (it was running the previous code)'
    }
  } catch { "WARNING: could not restart agentq-sync: $($_.Exception.Message) - restart the scheduled task by hand" }
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
