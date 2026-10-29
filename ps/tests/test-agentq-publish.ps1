# Behavioural tests for `agentq publish` (ADR 0003 W1-2): commit -Paths onto the CURRENT origin tip in a
# throwaway index, never touching the caller's index/worktree; revert guard; topic verify; -Land.
# Isolated: AGENTQ_HOME, CODAI_WT_ROOT and AGENTQ_CONFIG point into %TEMP%; a bare repo = origin.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqpub-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'
$env:AGENTQ_SESSION = 'test-pub'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function W([string]$f, [string]$t) { [IO.File]::WriteAllText($f, $t) }

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'; $other = Join-Path $tmp 'other'
git init -q --bare -b main $bare
git init -q -b main $repo
W "$repo\a.txt" "a1`na2`na3`n"; W "$repo\b.txt" "b`n"; W "$repo\keep.txt" "k`n"
git -C $repo add -A; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin main 2>$null
git clone -q $bare $other 2>$null
Push-Location $repo
try {
  # 1 basic: edit a.txt; someone else lands b.txt meanwhile; publish puts ONLY a.txt on top of the new tip
  W "$other\b.txt" "b2`n"; git -C $other commit -qam 'other b'; git -C $other push -q origin main 2>$null
  W "$repo\a.txt" "a1`na2-mine`na3`n"
  W "$repo\keep.txt" "dirty-not-published`n"
  git -C $repo add keep.txt
  $idxBefore = (Get-FileHash (Join-Path $repo '.git\index')).Hash
  $o = AQ publish -Paths a.txt -Message 'feat: mine' -Purpose 'test basic' -Onto main
  Check '1 exit 0' ($code -eq 0) $o
  $topic = ([regex]::Match($o, 'pushed origin/(\S+) =')).Groups[1].Value
  Check '1 topic pushed' ([bool]$topic) $o
  git -C $repo fetch -q origin
  $tsha = "$(git -C $repo rev-parse "origin/$topic" 2>$null)".Trim()
  Check '1 parent = current tip (has other b)' ($tsha -and ((git -C $repo show "$($tsha):b.txt") -join '') -eq 'b2')
  Check '1 a.txt = mine' ($tsha -and ((git -C $repo show "$($tsha):a.txt") -join "`n") -match 'a2-mine')
  Check '1 keep.txt not published' ($tsha -and ((git -C $repo show "$($tsha):keep.txt") -join '') -eq 'k')
  Check '1 caller index untouched' ((Get-FileHash (Join-Path $repo '.git\index')).Hash -eq $idxBefore)
  Check '1 caller HEAD untouched' ((git -C $repo rev-parse HEAD) -ne $tsha)
  Check '1 trailers' ($tsha -and ((git -C $repo log -1 --format=%B $tsha) -join "`n") -match 'Agent-Purpose: test basic')
  git -C $repo reset -q -- keep.txt

  # 2 revert guard: origin changed a.txt after my base (added a line); my disk copy lacks it -> refused (exit 5)
  git -C $other pull -q 2>$null; W "$other\a.txt" "a0-landed`na1`na2`na3`n"; git -C $other commit -qam 'land a0'; git -C $other push -q origin main 2>$null
  W "$repo\a.txt" "a1`na2-again`na3`n"
  $o = AQ publish -Paths a.txt -Message 'feat: again' -Purpose 'test guard' -Onto main
  Check '2 refused exit 5' ($code -eq 5) $o
  Check '2 reason names the file' ($o -match 'a\.txt') $o
  $o = AQ publish -Paths a.txt -Message 'feat: again' -Purpose 'test guard force' -Onto main -Force -NoPush
  Check '2 -Force overrides' ($code -eq 0 -and $o -match 'publish: [0-9a-f]{12}') $o

  # 3 nothing to publish: disk == tip for the path
  git -C $repo fetch -q origin; W "$repo\b.txt" "b2`n"
  $o = AQ publish -Paths b.txt -Message 'chore: noop' -Purpose 'test noop' -Onto main
  Check '3 nothing to publish' ($code -eq 0 -and $o -match 'nothing to publish') $o

  # 4 deletion of a file nobody changed since base -> published as a delete
  git -C $repo checkout -q -f -B main origin/main 2>$null
  Remove-Item "$repo\keep.txt"
  $o = AQ publish -Paths keep.txt -Message 'chore: rm keep' -Purpose 'test delete' -Onto main -NoPush
  Check '4 delete exit 0' ($code -eq 0) $o
  $sha4 = ([regex]::Match($o, 'publish: ([0-9a-f]{12})')).Groups[1].Value
  Check '4 keep.txt gone in commit' ([bool]$sha4 -and -not (git -C $repo rev-parse --verify -q "$($sha4):keep.txt" 2>$null))
  git -C $repo checkout -q -- keep.txt 2>$null

  # 5 CRLF on disk with .gitattributes text=auto -> stored LF (same blob a normal commit would store)
  W "$repo\.gitattributes" "* text=auto`n"; git -C $repo add .gitattributes; git -C $repo commit -qm attrs; git -C $repo push -q origin main 2>$null
  W "$repo\c.txt" "x`r`ny`r`n"
  $o = AQ publish -Paths c.txt -Message 'feat: c' -Purpose 'test eol' -Onto main -NoPush
  $sha5 = ([regex]::Match($o, 'publish: ([0-9a-f]{12})')).Groups[1].Value
  $raw = if ($sha5) { [string](git -C $repo cat-file -p "$($sha5):c.txt" | Out-String) } else { '' }
  $bytes = if ($sha5) { [Text.Encoding]::UTF8.GetString([byte[]](& cmd /c "git -C `"$repo`" cat-file blob $($sha5):c.txt" | ForEach-Object { [Text.Encoding]::UTF8.GetBytes("$_`n") } | ForEach-Object { $_ })) } else { '' }
  $blob = if ($sha5) { "$(git -C $repo rev-parse "$($sha5):c.txt")".Trim() } else { '' }
  $expect = "$(git -C $repo hash-object --path c.txt c.txt)".Trim()
  Check '5 blob == what git add would store' ($code -eq 0 -and $sha5 -and $blob -eq $expect) "$o blob=$blob expect=$expect"

  # 6 -Land: publishes and lands onto origin/main, topic deleted afterwards
  git -C $repo fetch -q origin; git -C $repo checkout -q -f -B main origin/main 2>$null
  W "$repo\d.txt" "d`n"
  $o = AQ publish -Paths d.txt -Message 'feat: d' -Purpose 'test land' -Onto main -Land
  git -C $repo fetch -q --prune origin
  Check '6 landed' ($code -eq 0 -and ((git -C $repo show origin/main:d.txt) -join '') -eq 'd') $o
  Check '6 publish topic removed' (@(git -C $repo for-each-ref --format='%(refname)' 'refs/remotes/origin/publish/').Count -eq 1) ((git -C $repo for-each-ref --format='%(refname)' 'refs/remotes/origin/publish/') -join ',')

  # 8 land: a pre-push hook that fails ONCE on an infra pattern is retried and lands (W2-3);
  #   a real failure (AssertionError) is not retried
  $hooks = Join-Path $bare 'hooks'
  $flagF = Join-Path $tmp 'flaked.flag'
  $hook = "#!/bin/sh`nread o n r; [ `"`$r`" = refs/heads/main ] || exit 0`nif [ ! -f '$($flagF -replace '\\','/')' ]; then touch '$($flagF -replace '\\','/')'; echo 'Error: Failed to start forks worker for test files'; exit 1; fi`nexit 0`n"
  [IO.File]::WriteAllText((Join-Path $hooks 'pre-receive'), $hook)
  git -C $repo fetch -q origin; git -C $repo checkout -q -f -B main origin/main 2>$null
  W "$repo\e.txt" "e`n"
  $o = AQ publish -Paths e.txt -Message 'feat: e' -Purpose 'test flake' -Onto main -Land
  git -C $repo fetch -q origin
  Check '8 infra flake retried and landed' ($code -eq 0 -and ((git -C $repo show origin/main:e.txt) -join '') -eq 'e') $o
  [IO.File]::WriteAllText((Join-Path $hooks 'pre-receive'), "#!/bin/sh`nread o n r; [ `"`$r`" = refs/heads/main ] || exit 0`necho 'AssertionError: expected 1 to be 2'; echo 'Failed to start forks worker'; exit 1`n")
  W "$repo\f.txt" "f`n"
  $o = AQ publish -Paths f.txt -Message 'feat: f' -Purpose 'test real fail' -Onto main -Land
  Check '8 real failure not retried (exit 7)' ($code -eq 7) $o
  Remove-Item (Join-Path $hooks 'pre-receive')
  $j8 = Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -Raw
  Check '8 flake journaled once' (([regex]::Matches($j8, '"event":"flake"')).Count -eq 1)

  # 7 journal has publish + publish-refused
  # 9 batched publish: 150 new files + a path with spaces + a non-ASCII path + a delete + an exec-bit file,
  #   all in ONE publish; content, modes and deletion must be exact, and it must not scale per path.
  git -C $repo fetch -q origin; git -C $repo checkout -q -f -B main origin/main 2>$null
  New-Item -ItemType Directory -Force "$repo\many", "$repo\sp ace" | Out-Null
  W "$repo\x.sh" "#!/bin/sh`n"; git -C $repo add x.sh; git -C $repo update-index --chmod=+x x.sh
  git -C $repo commit -qm 'exec'; git -C $repo push -q origin main 2>$null
  $many = 1..150 | ForEach-Object { "many/f$_.txt" }
  foreach ($m in $many) { W "$repo\$m" "$m`n" }
  W "$repo\sp ace\a b.txt" "spaced`n"
  W "$repo\many\ăîșț.txt" "diacritice`n"
  W "$repo\x.sh" "#!/bin/sh`necho 2`n"
  Remove-Item "$repo\d.txt"
  $plist9 = @($many) + @('sp ace/a b.txt', 'many/ăîșț.txt', 'x.sh', 'd.txt')
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $o = AQ publish -Paths ($plist9 -join ',') -Message 'feat: many' -Purpose 'test batch' -Onto main -NoPush
  $sw.Stop()
  $sha9 = ([regex]::Match($o, 'publish: ([0-9a-f]{12})')).Groups[1].Value
  Check '9 exit 0' ($code -eq 0 -and [bool]$sha9) $o
  $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
  $names9 = if ($sha9) { @(git -C $repo -c core.quotepath=off ls-tree -r --name-only $sha9) } else { @() }
  [Console]::OutputEncoding = $prevEnc
  Write-Host "INFO 9 publish of $($plist9.Count) paths took $([int]$sw.Elapsed.TotalSeconds) s"
  Check '9 all 150 files present' (@($many | Where-Object { $names9 -contains $_ }).Count -eq 150)
  Check '9 file content exact' ($sha9 -and ((git -C $repo show "$($sha9):many/f77.txt") -join '') -eq 'many/f77.txt')
  Check '9 path with spaces' ($names9 -contains 'sp ace/a b.txt')
  Check '9 non-ASCII path' ($names9 -contains 'many/ăîșț.txt') (($names9 | Where-Object { $_ -match 'diac|many/[^f]' }) -join ',')
  Check '9 deletion applied' ($names9 -notcontains 'd.txt')
  $mode9 = if ($sha9) { ("$(git -C $repo ls-tree $sha9 -- x.sh)" -split '\s+')[0] } else { '' }
  Check '9 exec bit kept' ($mode9 -eq '100755') $mode9
  # Measured 2026-10-28 on a loaded box: per-path code 3638 s, batched 134 s (incl. fetch + process start).
  Check '9 154 paths batched, not per path (< 600 s; per-path code took 3638 s)' ($sw.Elapsed.TotalSeconds -lt 600) "$([int]$sw.Elapsed.TotalSeconds) s"

  # 7 journal has publish + publish-refused
  $j = Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') -Raw
  Check '7 journal publish' ($j -match '"event":"publish"')
  Check '7 journal publish-refused' ($j -match '"event":"publish-refused"')
} finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
