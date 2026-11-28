# worktree.ps1 + deploy-clean.ps1 under ADR 0001: standard slots only, lease protects from
# prune/remove/migrate, migrate backs up legacy trees before removal, junction safety, release slot
# + supersede loop (deploy-clean -Follow) end to end.
param(
  [string]$Bin = (Join-Path $PSScriptRoot '..\bin'),
  [string]$Hooks = (Join-Path $PSScriptRoot '..\hooks')
)
$ErrorActionPreference = 'Stop'
$Bin = (Resolve-Path $Bin).Path; $Hooks = (Resolve-Path $Hooks).Path
$Tool = Join-Path $Bin 'worktree.ps1'; $Aq = Join-Path $Bin 'agentq.ps1'; $Deploy = Join-Path $Hooks 'deploy-clean.ps1'
$fx = Join-Path $env:TEMP ('wtv2-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:CODAI_WT_ROOT = "$fx\.wt"; $env:AGENTQ_HOME = "$fx\coord"; $env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_SESSION = 'wt-test'; $env:AGENTQ_BIN = $Bin
'{"minFreeCommitGB":0,"taskSlotsPerRepo":8}' | Set-Content "$fx-cfg.json"; $env:AGENTQ_CONFIG = "$fx-cfg.json"
$fails = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS $n" } else { Write-Host "FAIL $n $d" -ForegroundColor Red; $script:fails++ } }
function Run { $o = @(& pwsh -NoProfile @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
# Age a slot so the tool's own idle check (HEAD commit committer date + HEAD/copilot-meta mtimes) sees
# it as >= $days old: an empty commit back-dates the committer date, the mtimes are then set.
function Age-Slot([string]$wt, [int]$days) {
  $old = (Get-Date).ToUniversalTime().AddDays(-$days)
  $env:GIT_COMMITTER_DATE = $old.ToString('o'); $env:GIT_AUTHOR_DATE = $old.ToString('o')
  git -C $wt commit -q --allow-empty -m 'age-slot' 2>$null
  Remove-Item Env:GIT_COMMITTER_DATE, Env:GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
  $gd = (git -C $wt rev-parse --path-format=absolute --git-dir).Replace('/', '\')
  foreach ($n in 'HEAD', 'copilot-meta.json') { $p = Join-Path $gd $n; if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTime = $old.ToLocalTime() } }
}
try {
  New-Item -ItemType Directory -Force "$fx\remote.git", "$fx\repo" | Out-Null
  git -C "$fx\remote.git" init -q --bare -b main
  git -C "$fx\repo" init -q -b main; git -C "$fx\repo" config user.email t@t; git -C "$fx\repo" config user.name t
  'x' | Set-Content "$fx\repo\a.txt"; git -C "$fx\repo" add a.txt; git -C "$fx\repo" commit -q -m init
  git -C "$fx\repo" remote add origin "$fx\remote.git"; git -C "$fx\repo" push -q -u origin main 2>$null
  Push-Location "$fx\repo"

  $o = Run -File $Tool new -Repo "$fx\repo" -Name probe -NoEnvCopy
  Check 'new with ad-hoc name refused' ($code -ne 0 -and $o -match 'not a standard slot') $o
  $o = Run -File $Tool new -Repo "$fx\repo" -Name task-1 -Purpose 'slot via new'
  Check 'new task-1 = leased standard slot' ($code -eq 0 -and (Test-Path "$fx\.wt\repo\task-1\a.txt")) $o
  $lease = Get-Content "$fx\coord\leases\repo\task-1.json" -Raw | ConvertFrom-Json

  # leased slot: prune -OlderThanHours 0, remove -Force, migrate all refuse even when clean+pushed
  $o = Run -File $Tool prune -Repo "$fx\repo" -OlderThanHours 0
  Check 'prune keeps a LEASED clean slot' ((Test-Path "$fx\.wt\repo\task-1\a.txt") -and $o -match 'LEASED') $o
  $o = Run -File $Tool remove -Repo "$fx\repo" -Path "$fx\.wt\repo\task-1" -Force
  Check 'remove -Force refuses a LEASED slot' (Test-Path "$fx\.wt\repo\task-1\a.txt") $o
  # unlease clean -> slot kept for reuse by prune (standard slot, idle < 7 d)
  $o = Run -File $Aq unlease -Repo "$fx\.wt\repo\task-1" -LeaseId $lease.leaseId
  Check 'unlease clean slot (no backup needed)' ($code -eq 0 -and $o -match 'nothing to back up') $o
  $o = Run -File $Tool prune -Repo "$fx\repo" -OlderThanHours 0
  Check 'prune keeps an unleased standard slot (< 7 d idle) for reuse' (Test-Path "$fx\.wt\repo\task-1\a.txt") $o

  # legacy worktrees: dirty one gets backed up then removed; leased paths untouched
  $env:WORKTREE_ALLOW_ADHOC = '1'
  Run -File $Tool new -Repo "$fx\repo" -Name v3-legacy -NoEnvCopy | Out-Null
  Run -File $Tool new -Repo "$fx\repo" -Name junc -NoEnvCopy | Out-Null
  Remove-Item Env:WORKTREE_ALLOW_ADHOC
  'dirty' | Add-Content "$fx\.wt\repo\v3-legacy\a.txt"; 'u' | Set-Content "$fx\.wt\repo\v3-legacy\u.txt"
  New-Item -ItemType Directory -Force "$fx\keep" | Out-Null; 'precious' | Set-Content "$fx\keep\f.txt"
  cmd /c mklink /J "$fx\.wt\repo\junc\node_modules" "$fx\keep" | Out-Null
  Add-Content (Join-Path (git -C "$fx\repo" rev-parse --path-format=absolute --git-common-dir) 'info\exclude') "node_modules"
  # orphan dir with a unique file
  New-Item -ItemType Directory -Force "$fx\.wt\repo\_x-not-orphan", "$fx\.wt\repo\old-orphan" | Out-Null; 'unique' | Set-Content "$fx\.wt\repo\old-orphan\notes.txt"
  (Get-Item "$fx\.wt\repo\old-orphan").LastWriteTime = (Get-Date).AddDays(-2)
  $l2 = Run -File $Aq lease -Repo "$fx\repo" -Slot task-2 -Purpose 'live' -Json
  $o = Run -File $Tool migrate -Repo "$fx\repo" -OlderThanHours 0
  Check 'migrate removed legacy dirty worktree' (-not (Test-Path "$fx\.wt\repo\v3-legacy")) $o
  $ref = ([regex]::Match($o, 'refs/backup/wt/repo/legacy-v3-legacy/\S+')).Value
  Check 'migrate backed it up to origin first' ($ref -and (git -C "$fx\repo" ls-remote origin $ref)) $o
  $sha = ((git -C "$fx\repo" ls-remote origin $ref) -split '\s+')[0]
  Check 'backup holds the dirty + untracked content' ((git --git-dir="$fx\remote.git" show "${sha}:u.txt") -eq 'u')
  Check 'migrate removed junction worktree without touching target' ((-not (Test-Path "$fx\.wt\repo\junc")) -and (Test-Path "$fx\keep\f.txt")) $o
  Check 'migrate archived + removed orphan with unique file' ((-not (Test-Path "$fx\.wt\repo\old-orphan")) -and (Get-ChildItem "$fx\.wt\_bundles" -Filter 'repo-orphan-old-orphan-*.zip')) $o
  Check 'migrate left leased task-2 and standard task-1 alone' ((Test-Path "$fx\.wt\repo\task-2\a.txt") -and (Test-Path "$fx\.wt\repo\task-1\a.txt")) $o
  Check 'migrate ignores _-prefixed dirs' (Test-Path "$fx\.wt\repo\_x-not-orphan")

  # --- parked slots (prune -ParkedIdleDays): an UNLEASED standard slot that still holds unsaved work
  # is backed up in full (ref verified path by path) and removed once idle; every other case is kept ---
  $env:AGENTQ_PARK_ROOT = "$fx\parked"
  foreach ($s in 'task-3', 'task-4', 'task-6', 'task-7') {
    Run -File $Tool new -Repo "$fx\repo" -Name $s -Purpose 'park test' | Out-Null
    $lid = (Get-Content "$fx\coord\leases\repo\$s.json" -Raw | ConvertFrom-Json).leaseId
    Run -File $Aq unlease -Repo "$fx\.wt\repo\$s" -LeaseId $lid | Out-Null   # unleased, but with no work it stays put
  }
  Run -File $Aq lease -Repo "$fx\repo" -Slot task-5 -Purpose 'leased dirty' -Json | Out-Null
  Add-Content "$fx\.wt\repo\task-3\a.txt" 'd3'; 'u3' | Set-Content "$fx\.wt\repo\task-3\untracked3.txt"
  Add-Content "$fx\.wt\repo\task-4\a.txt" 'd4'
  Add-Content "$fx\.wt\repo\task-5\a.txt" 'd5'
  Add-Content "$fx\.wt\repo\task-6\a.txt" 'd6'
  Add-Content "$fx\.wt\repo\task-7\a.txt" 'd7'
  $fsw = [IO.File]::Open("$fx\.wt\repo\task-7\blob.bin", 'Create'); $fsw.SetLength(51MB); $fsw.Dispose()   # >50MB: excluded from the backup -> verify must fail
  $expA3 = git -C "$fx\.wt\repo\task-3" hash-object --path=a.txt -- "$fx\.wt\repo\task-3\a.txt"; $expA3 = "$expA3".Trim()
  $expU3 = git -C "$fx\.wt\repo\task-3" hash-object --path=untracked3.txt -- "$fx\.wt\repo\task-3\untracked3.txt"; $expU3 = "$expU3".Trim()
  # Readiness handshake the process itself performs. The old wait polled Get-CimInstance for the child's
  # CommandLine, which is the SAME facility the park guard uses to see it - so on a runner where CIM is
  # slow or unavailable the fixture proceeded with no live process AND the guard saw none either, and the
  # slot was parked (2026-11-27). The sleeper now proves it is running by writing a marker; the slot path
  # still has to appear in its command line, which is what makes it visible to the guard.
  $marker = "$fx\sleeper-ready.txt"
  @"
param(`$slot, `$marker)
Set-Content -LiteralPath `$marker -Value "pid=`$PID slot=`$slot"
Start-Sleep -Seconds 120
"@ | Set-Content "$fx\sleeper.ps1"
  $sleeper = Start-Process pwsh -ArgumentList '-NoProfile', '-File', "$fx\sleeper.ps1", "$fx\.wt\repo\task-6", $marker -PassThru -WindowStyle Hidden
  $dl = (Get-Date).AddSeconds(30)
  do { Start-Sleep -Milliseconds 250 } while (-not (Test-Path -LiteralPath $marker) -and -not $sleeper.HasExited -and (Get-Date) -lt $dl)
  Check 'park fixture: the sleeper is up before prune runs' ((Test-Path -LiteralPath $marker) -and -not $sleeper.HasExited) ((Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue))
  foreach ($s in 'task-3', 'task-5', 'task-6', 'task-7') { Age-Slot "$fx\.wt\repo\$s" 5 }
  $o = Run -File $Tool prune -Repo "$fx\repo" -OlderThanHours 0 -ParkedIdleDays 3
  $ref3 = ([regex]::Match($o, 'refs/backup/wt/repo/task-3/\S+')).Value
  $gotA3 = git -C "$fx\repo" rev-parse --verify -q "${ref3}:a.txt"; $gotA3 = "$gotA3".Trim()
  $gotU3 = git -C "$fx\repo" rev-parse --verify -q "${ref3}:untracked3.txt"; $gotU3 = "$gotU3".Trim()
  Check 'park: dirty unleased slot idle > bound backed up (ref verifies) then removed' ((-not (Test-Path "$fx\.wt\repo\task-3")) -and $ref3 -and $gotA3 -eq $expA3 -and $gotU3 -eq $expU3) $o
  Check 'park: a thin bundle was written under ~/.codai/parked' ($o -match 'bundle=' -and (Get-ChildItem "$env:AGENTQ_PARK_ROOT\repo\task-3\bundles" -Filter '*.bundle' -ErrorAction SilentlyContinue)) $o
  Check 'park: same slot idle < bound is kept' (Test-Path "$fx\.wt\repo\task-4\a.txt") $o
  Check 'park: LEASED dirty slot is never removed' (Test-Path "$fx\.wt\repo\task-5\a.txt") $o
  # Two ways this can pass, and both must: the guard finds the live process, OR it cannot read the process
  # table at all - in which case it refuses to park (fail closed) and the slot stays. What must never
  # happen is the slot being removed, which is what the assertion pins.
  Check 'park: slot with a live process is never removed' ((Test-Path "$fx\.wt\repo\task-6\a.txt") -and ($o -match 'task-6')) ($o + "`n--- sleeper marker: " + (Get-Content -LiteralPath $marker -Raw -ErrorAction SilentlyContinue))
  Check 'park: backup-verify failure keeps the slot' ((Test-Path "$fx\.wt\repo\task-7\a.txt") -and $o -match 'backup not proven: verify failed for blob\.bin') $o
  Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue

  # deploy-clean: release slot, release run, follow loop with supersede
  $out = Run -File $Deploy -Root "$fx\repo" -NoEnvCopy -NoInstall -Target web -Command 'Write-Host "DEPLOYING $env:DEPLOY_SHA in $env:DEPLOY_WORKTREE"'
  Check 'deploy-clean runs in <root>\<repo>\release' ($code -eq 0 -and $out -match [regex]::Escape("in $fx\.wt\repo\release")) $out
  Check 'release slot lease released after run' (-not (Test-Path "$fx\coord\leases\repo\release.json"))
  Check 'no deploy-N pool dirs created' (-not (Get-ChildItem "$fx\.wt\repo" -Directory | Where-Object Name -like 'deploy-*'))
  # supersede: the command lands a new commit during its safe phase -> exits 4 at the next checkpoint
  $script = "$fx\fake-release.ps1"
  @"
param()
`$aq = '$Aq'
Write-Host "RUN `$env:DEPLOY_SHA"
& pwsh -NoProfile -File `$aq release-phase -Phase preflight; if (`$LASTEXITCODE -eq 4) { exit 4 }
if (-not (Test-Path '$fx\landed.flag')) {
  New-Item '$fx\landed.flag' | Out-Null
  'v2' | Set-Content '$fx\repo\b.txt'; git -C '$fx\repo' add b.txt; git -C '$fx\repo' commit -q -m 'land during release'; git -C '$fx\repo' push -q origin main 2>`$null
  & pwsh -NoProfile -File `$aq notify-landing -Repo '$fx\repo' -Branch main | Write-Host
}
& pwsh -NoProfile -File `$aq release-phase -Phase build; if (`$LASTEXITCODE -eq 4) { exit 4 }
& pwsh -NoProfile -File `$aq release-phase -Phase prod -Unsafe; if (`$LASTEXITCODE -eq 4) { exit 4 }
Write-Host "SHIPPED `$env:DEPLOY_SHA"
"@ | Set-Content $script
$out = Run -File $Deploy -Root "$fx\repo" -NoEnvCopy -NoInstall -Target web -Command "pwsh -NoProfile -File '$script'"
  $tip = (git -C "$fx\repo" rev-parse HEAD).Trim()
  Check 'supersede: first run stopped, second run shipped the new tip' ($code -eq 0 -and $out -match 'superseded' -and $out -match "SHIPPED $tip" -and @([regex]::Matches($out, 'SHIPPED')).Count -eq 1) $out
  $j = @(Get-Content "$fx\coord\journal.jsonl" | ForEach-Object { $_ | ConvertFrom-Json } | ForEach-Object event)
  Check 'journal: release-preempt + release-superseded + 2x release-begin' (($j -contains 'release-preempt') -and ($j -contains 'release-superseded') -and @($j | Where-Object { $_ -eq 'release-begin' }).Count -ge 3)
  Pop-Location
} finally {
  if ($sleeper) { Stop-Process -Id $sleeper.Id -Force -ErrorAction SilentlyContinue }
  foreach ($v in 'CODAI_WT_ROOT', 'AGENTQ_HOME', 'AGENTQ_SESSION', 'AGENTQ_BIN', 'AGENTQ_CONFIG', 'WORKTREE_ALLOW_ADHOC', 'AGENTQ_PARK_ROOT') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$fx`"" 2>$null; Remove-Item "$fx-cfg.json" -ErrorAction SilentlyContinue
}
if ($fails) { Write-Host "$fails FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
