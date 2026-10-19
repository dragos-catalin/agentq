# ADR 0007: git-first + devbox tools moved into agentq. Local fixtures only (bare remotes in TEMP, no GitHub,
# no ssh): git-publish / git-wip-snapshot / devsync plan / devbox-team-sync mapping / agentq workspace +
# system store. The planner of devbox-teams has its own suite (test-devbox-teams.py).
param([string]$Bin = (Join-Path $PSScriptRoot '..\bin'))
$ErrorActionPreference = 'Stop'
$Bin = (Resolve-Path $Bin).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aqdbx-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; $env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_SESSION = 'test-dbx'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
Remove-Item Env:AGENTQ_SYSTEM_HOME -ErrorAction SilentlyContinue
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function NewRepo([string]$name) {
  $bare = Join-Path $tmp "$name.git"; git init -q --bare -b main $bare
  $r = Join-Path $tmp $name; git init -q -b main $r
  [IO.File]::WriteAllText((Join-Path $r 'a.txt'), "a`n"); git -C $r add -A; git -C $r commit -qm init
  git -C $r remote add origin $bare; git -C $r push -q origin main 2>$null
  $r
}
try {
  # ---- git-publish
  $r = NewRepo 'pub'
  [IO.File]::WriteAllText((Join-Path $r 'a.txt'), "changed`n")
  [IO.File]::WriteAllText((Join-Path $r 'new.txt'), "new`n")
  New-Item -ItemType Directory -Force (Join-Path $r 'node_modules\x') | Out-Null
  [IO.File]::WriteAllText((Join-Path $r 'node_modules\x\i.js'), "junk`n")
  $headBefore = (git -C $r rev-parse HEAD).Trim(); $statusBefore = @(git -C $r status --porcelain) -join '|'
  $o = & pwsh -NoProfile -File (Join-Path $Bin 'git-publish.ps1') -Path $r -Branch 'wip/snap-test' -WtRoot (Join-Path $tmp 'nowt') 2>&1 | Out-String
  $snap = git -C (Join-Path $tmp 'pub.git') rev-parse --verify -q 'refs/heads/wip/snap-test'
  Check 'publish: snapshot branch pushed' ([bool]$snap) $o
  $files = if ($snap) { @(git -C (Join-Path $tmp 'pub.git') ls-tree -r --name-only $snap) } else { @() }
  Check 'publish: snapshot has the uncommitted files' (($files -contains 'new.txt') -and ((git -C (Join-Path $tmp 'pub.git') show "${snap}:a.txt") -eq 'changed'))
  Check 'publish: node_modules never committed' (-not ($files | Where-Object { $_ -like 'node_modules/*' }))
  Check 'publish: HEAD untouched' ((git -C $r rev-parse HEAD).Trim() -eq $headBefore)
  Check 'publish: .gitignore baseline + secrets un-ignore last' ((Get-Content (Join-Path $r '.gitignore') | Select-Object -Last 1) -eq '!secrets/**/*.enc')
  $o2 = & pwsh -NoProfile -File (Join-Path $Bin 'git-publish.ps1') -Path $r -Branch 'wip/snap-test' -WtRoot (Join-Path $tmp 'nowt') 2>&1 | Out-String
  $snap2 = git -C (Join-Path $tmp 'pub.git') rev-parse --verify -q 'refs/heads/wip/snap-test'
  Check 'publish: rerun fast-forwards (snapshot 1 is an ancestor)' ($snap2 -and ((git -C (Join-Path $tmp 'pub.git') merge-base --is-ancestor $snap $snap2) -or $LASTEXITCODE -eq 0)) $o2
  # secrets without an age key: refused, never committed in clear
  $r2 = NewRepo 'pubsec'
  [IO.File]::WriteAllText((Join-Path $r2 '.env'), "DEMO=1`n")   # detected by file name, content irrelevant
  $o3 = & pwsh -NoProfile -File (Join-Path $Bin 'git-publish.ps1') -Path $r2 -AgeKeyFile (Join-Path $tmp 'nokey.txt') -WtRoot (Join-Path $tmp 'nowt') 2>&1 | Out-String
  Check 'publish: .env without age key is refused' (($o3 -match 'no age key') -and -not (git -C (Join-Path $tmp 'pubsec.git') for-each-ref --format='%(refname)' 'refs/heads/wip')) $o3
  # active shared clone refused
  New-Item -ItemType Directory -Force (Join-Path $tmp 'wt2\pub') | Out-Null
  $o4 = & pwsh -NoProfile -File (Join-Path $Bin 'git-publish.ps1') -Path $r -WtRoot (Join-Path $tmp 'wt2') 2>&1 | Out-String
  Check 'publish: active shared clone refused' ($o4 -match 'ACTIVE shared clone') $o4

  # ---- git-wip-snapshot
  $w = NewRepo 'wip'
  [IO.File]::WriteAllText((Join-Path $w 'a.txt'), "wip`n")
  $idxBefore = (Get-FileHash (Join-Path $w '.git\index')).Hash
  $o = & pwsh -NoProfile -File (Join-Path $Bin 'git-wip-snapshot.ps1') -Repo $w -HostName 'testhost' -AgeKeyFile (Join-Path $tmp 'nokey.txt') 2>&1 | Out-String
  $ref = git -C (Join-Path $tmp 'wip.git') rev-parse --verify -q 'refs/wip/testhost/main/latest'
  Check 'wip: ref pushed to private (non-GitHub) origin' ([bool]$ref) $o
  Check 'wip: index untouched' ((Get-FileHash (Join-Path $w '.git\index')).Hash -eq $idxBefore)
  Check 'wip: worktree change captured' ($ref -and (git -C (Join-Path $tmp 'wip.git') show "${ref}:a.txt") -eq 'wip')
  $o = & pwsh -NoProfile -File (Join-Path $Bin 'git-wip-snapshot.ps1') -Repo $w -HostName 'testhost' -AgeKeyFile (Join-Path $tmp 'nokey.txt') 2>&1 | Out-String
  Check 'wip: unchanged tree not pushed again' ($o -match 'unchanged') $o

  # ---- devsync plan: no .git, group-only modes
  $plan = @(& pwsh -NoProfile -File (Join-Path $Bin 'devsync.ps1') plan -Project codai -LocalRoot $tmp -RemoteHost h 2>&1 | ForEach-Object { "$_" })
  $pj = $plan -join ' '
  Check 'devsync: .git and node_modules ignored' (($pj -match '--ignore \.git ') -and ($pj -match '--ignore node_modules')) $pj
  Check 'devsync: remote files group-only (0660/2770)' (($pj -match 'default-file-mode-beta 0660') -and ($pj -match 'default-directory-mode-beta 2770')) $pj
  Check 'devsync: remote path /work/<repo>' ($pj -match 'h:/work/codai') $pj

  # ---- devbox-team-sync mapping (recorded hub snapshot, no HTTP)
  $snapFile = Join-Path $tmp 'hub.json'
  $hub = @{
    environments = @(
      @{ id = 'e1'; name = 'devbox:ws-devbox:codai'; state = 'pending'; ownerUserId = 'own' },
      @{ id = 'e2'; name = 'devbox:ws-devbox:axiom'; state = 'pending'; ownerUserId = 'own' },
      @{ id = 'e3'; name = 'unrelated env'; state = 'running'; ownerUserId = 'own' })
    members = @{
      e1 = @(@{ user_id = 'own'; role = 'owner'; linux_username = 'u-11111111' }, @{ user_id = 'ana'; role = 'developer'; linux_username = 'u-0f1d2c3e' }, @{ user_id = 'vic'; role = 'viewer'; linux_username = $null })
      e2 = @(@{ user_id = 'own'; role = 'owner'; linux_username = 'u-11111111' })
    }
    ca = @('ssh-ed25519 ' + ('A' * 68) + ' codai')
  }
  [IO.File]::WriteAllText($snapFile, ($hub | ConvertTo-Json -Depth 6))
  $dj = & pwsh -NoProfile -File (Join-Path $Bin 'devbox-team-sync.ps1') -FromFile $snapFile -DesiredOnly 2>&1 | Out-String
  $d = $dj | ConvertFrom-Json -AsHashtable
  Check 'team-sync: one repo per devbox env, unrelated env ignored' (($d.repos.Keys | Sort-Object) -join ',' -eq 'axiom,codai') $dj
  Check 'team-sync: env owner -> dev, member -> u-<8hex>' ((@($d.repos.codai.members | ForEach-Object { "$($_.linux):$($_.role)" }) -join ',') -eq 'dev:owner,u-0f1d2c3e:developer') $dj
  Check 'team-sync: no Linux account -> skipped' (-not ($dj -match 'vic')) $dj
  Check 'team-sync: CA key carried, no hub key in output' (($d.ca_keys.Count -eq 1) -and -not ($dj -match 'codai_[A-Za-z0-9]{8}|Bearer')) $dj
  # the desired state is accepted by devbox-teams' own validator
  $py = Join-Path $Bin 'devbox-teams.py'
  $vf = Join-Path $tmp 'v.py'
  [IO.File]::WriteAllText($vf, "import importlib.util,sys,json`nspec=importlib.util.spec_from_file_location('d',sys.argv[1]);m=importlib.util.module_from_spec(spec);sys.modules['d']=m;spec.loader.exec_module(m)`nm.validate(json.load(open(sys.argv[2])));print('VALID')`n")
  $df = Join-Path $tmp 'd.json'; [IO.File]::WriteAllText($df, $dj)
  $v = & python $vf $py $df 2>&1 | Out-String
  Check 'team-sync: desired state passes devbox-teams validate' ($v -match 'VALID') $v

  # a suspended devbox is a skip (exit 0, logged), never an ssh attempt or a failing task
  $lg = Join-Path $tmp 'ts.log'
  $env:DEVBOX_TEAMS_STATUS = 'SUSPENDED'
  $so = & pwsh -NoProfile -File (Join-Path $Bin 'devbox-team-sync.ps1') -FromFile $snapFile -Log $lg 2>&1 | Out-String
  $src = $LASTEXITCODE
  Remove-Item Env:DEVBOX_TEAMS_STATUS
  Check 'team-sync: suspended devbox -> exit 0 + SKIP, no ssh' (($src -eq 0) -and ($so -match 'SKIP: ws-devbox is SUSPENDED') -and -not ($so -match 'scp|ssh')) "rc=$src $so"
  Check 'team-sync: skip is logged' ((Get-Content $lg -Raw) -match ' skip repos=2 status=SUSPENDED') (Get-Content $lg -Raw)
  # ---- agentq workspace verb (single store) + system store routing
  $Aq = Join-Path $Bin 'agentq.ps1'
  $o = & pwsh -NoProfile -File $Aq workspace take -Name codai -Purpose 'test take' 2>&1 | Out-String
  Check 'workspace: take' ($o -match 'workspace codai active at') $o
  $env:AGENTQ_CLIENT_HOST = 'otherpc'
  $o = & pwsh -NoProfile -File $Aq workspace take -Name codai -Purpose 'second' 2>&1 | Out-String; $rc = $LASTEXITCODE
  Check 'workspace: second holder refused (exit 3)' ($rc -eq 3 -and $o -match 'ACTIVE at') "rc=$rc $o"
  $o = & pwsh -NoProfile -File $Aq workspace release -Name codai 2>&1 | Out-String; $rc = $LASTEXITCODE
  Check 'workspace: non-holder cannot release' ($rc -eq 3) "rc=$rc $o"
  Remove-Item Env:AGENTQ_CLIENT_HOST
  $o = & pwsh -NoProfile -File $Aq workspace list 2>&1 | Out-String
  Check 'workspace: list shows holder' ($o -match 'codai' -and $o -match 'test take') $o
  $o = & pwsh -NoProfile -File $Aq workspace release -Name codai 2>&1 | Out-String
  Check 'workspace: holder releases' ($o -match 'released') $o
  # system store: queues/journal go to AGENTQ_SYSTEM_HOME, the user store keeps only private state
  $sys = Join-Path $tmp 'sys'; New-Item -ItemType Directory -Force (Join-Path $sys 'journal.d') | Out-Null
  [IO.File]::WriteAllText((Join-Path $sys 'journal.d\sysrepo.jsonl'), '')
  $env:AGENTQ_SYSTEM_HOME = $sys
  $sr = NewRepo 'sysrepo'
  Push-Location $sr
  try { $o = & pwsh -NoProfile -File $Aq run -Resource build -Purpose 'sys store run' -MinFreeGB 0 '--' git status 2>&1 | Out-String } finally { Pop-Location }
  $repoJ = Get-Content (Join-Path $sys 'journal.d\sysrepo.jsonl') -Raw
  Check 'system: repo events in journal.d/<repo>.jsonl' ($repoJ -match 'sys store run') $o
  Check 'system: queue dirs in the system store' (Test-Path (Join-Path $sys 'queues\build_sysrepo'))
  Check 'system: nothing repo-scoped in the user store' (-not (Test-Path (Join-Path $env:AGENTQ_HOME 'queues\build_sysrepo')))
  $o = & pwsh -NoProfile -File $Aq log -Repo $sr -Last 20 2>&1 | Out-String
  Check 'system: log reads the repo journal' ($o -match 'sys store run') $o
  Remove-Item Env:AGENTQ_SYSTEM_HOME
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
