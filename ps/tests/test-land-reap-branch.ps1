# `agentq land` reaps the SOURCE remote branch once it PUSHED its content to the target - but only an
# auto-generated `publish/*` topic, never a human-named branch, never the target, never the branch a
# working slot is on. A failed delete is journaled and never fails the land. `agentq publish -Land` is
# covered by the same rule (its reap happens inside Invoke-Land). Isolated in %TEMP%; bare repo = origin.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqreapb-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_NO_ADMISSION = '1'
$env:AGENTQ_SESSION = 'test-RB'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function RemoteHas([string]$branch) { [bool]"$((git -C $repo ls-remote origin "refs/heads/$branch") -split "\s+" | Select-Object -First 1)".Trim() }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'; Set-Content (Join-Path $repo 'x.txt') 'a0'
git -C $repo add a.txt x.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
function NewTopic([string]$name) { git -C $tw fetch -q origin; git -C $tw checkout -q -B $name origin/dev 2>$null }
function TopicCommit([string]$file, [string]$text, [string]$msg) { Set-Content (Join-Path $tw $file) $text; git -C $tw add $file; git -C $tw commit -qm $msg; git -C $tw push -q origin "HEAD:refs/heads/$(git -C $tw rev-parse --abbrev-ref HEAD)" 2>$null }
Push-Location $repo
try {
  # --- 1. reaps an auto-generated publish/* branch after a SUCCESSFUL land ---------------------
  NewTopic 'publish/auto-1'
  TopicCommit 'p1.txt' '1' 'auto change'
  $o = AQ land -Branch publish/auto-1 -Onto dev -Purpose 'auto'
  Check 'reap: land exit 0' ($code -eq 0) $o
  Check 'reap: branch deleted on origin' (-not (RemoteHas 'publish/auto-1')) $o
  Check 'reap: prints the reap line' ($o -match 'reaped publish/auto-1 \(landed into dev\)') $o
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'land-reap' -and $_.branch -eq 'publish/auto-1' })
  Check 'reap: journaled land-reap' ($j.Count -eq 1) ($j | ConvertTo-Json -Compress)

  # --- 2. does NOT reap a human-named branch -----------------------------------------------------
  NewTopic 'feature-human'
  TopicCommit 'p2.txt' '2' 'human change'
  $o = AQ land -Branch feature-human -Onto dev -Purpose 'human'
  Check 'human: land exit 0' ($code -eq 0) $o
  Check 'human: branch kept on origin' (RemoteHas 'feature-human') $o
  Check 'human: prints the skip line' ($o -match 'kept feature-human: not auto-generated') $o

  # --- 3. does NOT reap when the land FAILED (the pre-gate fails -> exit 6) -----------------------
  NewTopic 'publish/fail-1'
  TopicCommit 'p3.txt' '3' 'fail change'
  $o = AQ land -Branch publish/fail-1 -Onto dev -Purpose 'fail' -Gate 'exit 1'
  Check 'fail: land exit 6' ($code -eq 6) $o
  Check 'fail: branch kept on origin' (RemoteHas 'publish/fail-1') $o
  Check 'fail: no reap line' (-not ($o -match 'reaped publish/fail-1')) $o

  # --- 4. does NOT reap the branch the working slot is on ----------------------------------------
  NewTopic 'publish/on-slot'
  TopicCommit 'p4.txt' '4' 'slot change'
  # Free the branch from the topic worktree first: git refuses to check out in $repo a branch that is
  # already checked out in $tw, and the silent failure would leave $repo on `dev` (2026-11-24).
  git -C $tw checkout -q --detach origin/dev 2>$null
  git -C $repo fetch -q origin
  git -C $repo checkout -q -B publish/on-slot origin/publish/on-slot 2>$null
  Check 'slot: repo is on the topic' ((git -C $repo rev-parse --abbrev-ref HEAD) -eq 'publish/on-slot')
  $o = AQ land -Branch publish/on-slot -Onto dev -Purpose 'onslot'
  Check 'slot: land exit 0' ($code -eq 0) $o
  Check 'slot: branch kept on origin' (RemoteHas 'publish/on-slot') $o
  Check 'slot: prints the skip line' ($o -match 'kept publish/on-slot: a working slot is on it') $o
  git -C $repo checkout -q dev 2>$null

  # --- 5. a failing delete does NOT fail the land ------------------------------------------------
  # A pre-receive hook that rejects EVERY ref deletion makes the reap's `push --delete` fail; the land
  # itself (a non-delete push to dev) still succeeds.
  $hookDir = Join-Path $bare 'hooks'; New-Item -ItemType Directory -Force $hookDir | Out-Null
  $hook = "#!/bin/sh`nrc=0`nwhile read old new ref; do`n  if [ `"`$new`" = `"0000000000000000000000000000000000000000`" ]; then`n    echo `"deletes are disabled`" >&2`n    rc=1`n  fi`ndone`nexit `$rc`n"
  [IO.File]::WriteAllText((Join-Path $hookDir 'pre-receive'), $hook, [Text.UTF8Encoding]::new($false))
  NewTopic 'publish/nodel'
  TopicCommit 'p5.txt' '5' 'nodel change'
  $o = AQ land -Branch publish/nodel -Onto dev -Purpose 'nodel'
  Check 'nodel: land exit 0 despite delete failure' ($code -eq 0) $o
  Check 'nodel: branch kept on origin' (RemoteHas 'publish/nodel') $o
  Check 'nodel: prints the delete-failed line' ($o -match 'kept publish/nodel: delete failed') $o
  $jf = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'land-reap-failed' -and $_.branch -eq 'publish/nodel' })
  Check 'nodel: journaled land-reap-failed' ($jf.Count -eq 1) ($jf | ConvertTo-Json -Compress)
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION', 'AGENTQ_NO_ADMISSION') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
