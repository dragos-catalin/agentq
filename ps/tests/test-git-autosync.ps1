param([string]$Tool)
# Scenario tests for git-autosync.ps1 on throwaway repos under %TEMP%.
$ErrorActionPreference = 'Stop'
$tool = if ($Tool) { $Tool } else { Join-Path $PSScriptRoot 'git-autosync.ps1' }
$root = Join-Path ([IO.Path]::GetTempPath()) ("gas-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $root | Out-Null
$env:GIT_AUTOSYNC_LOG = Join-Path $root 'autosync.log'
$env:GIT_AUTOSYNC_PARK = Join-Path $root 'parked'
$env:GIT_AUTOSYNC_NO_NOTE = '1'
$env:GIT_AUTOSYNC_MUTEX = 'Local\gas-test-' + [guid]::NewGuid().ToString('N')
$env:GIT_CONFIG_COUNT = '1'; $env:GIT_CONFIG_KEY_0 = 'core.safecrlf'; $env:GIT_CONFIG_VALUE_0 = 'false'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
$fail = 0
function Ok([bool]$c, [string]$m) { if ($c) { "PASS $m" } else { "FAIL $m"; $script:fail++ } }
function W([string]$f, [string]$t) { [IO.File]::WriteAllText($f, $t) }
function Fresh {
  $o = Join-Path $root ("o" + [guid]::NewGuid().ToString('N').Substring(0, 6)); git init -q --bare -b main $o
  $a = "$o-a"; git clone -q $o $a 2>$null; W "$a\x.txt" "1`n"; W "$a\y.txt" "y`n"
  git -C $a add -A; git -C $a commit -qm base; git -C $a push -q origin main 2>$null
  $b = "$o-b"; git clone -q $o $b 2>$null   # b = the "worktree" that pushes
  @{ o = $o; a = $a; b = $b }
}
function Push-B($r, [string]$file, [string]$text) { W "$($r.b)\$file" $text; git -C $r.b add -A; git -C $r.b commit -qm "b $file"; git -C $r.b push -q origin main 2>$null }
function Run($r, [string[]]$x = @()) { & pwsh -NoProfile -File $tool -Repo $r.a -ReplayRepos '*' @x *> $null; $LASTEXITCODE }
function Age($f) { (Get-Item $f).LastWriteTime = (Get-Date).AddHours(-10) }
function Backups($r) { @(git -C $r.o for-each-ref --format='%(refname)' refs/heads/backup/shared-clone) }

# 1 behind only, unrelated dirty edit survives
$r = Fresh; Push-B $r 'x.txt' "2`n"; W "$($r.a)\y.txt" "local`n"
Ok ((Run $r) -eq 0) '1 exit 0'; Ok ((git -C $r.a rev-parse HEAD) -eq (git -C $r.a rev-parse origin/main)) '1 at origin'
Ok (((Get-Content "$($r.a)\x.txt" -Raw) -replace "`r", '') -eq "2`n") '1 incoming file updated'; Ok ((Get-Content "$($r.a)\y.txt" -Raw) -eq "local`n") '1 dirty edit kept'

# 2 duplicate local commit (same patch pushed from worktree) + dirty == upstream
$r = Fresh; W "$($r.a)\x.txt" "dup`n"; git -C $r.a commit -qam 'dup local'; Push-B $r 'x.txt' "dup`n"; Push-B $r 'y.txt' "y2`n"; W "$($r.a)\y.txt" "y2`n"
Ok ((Run $r) -eq 0) '2 exit 0'; Ok ((git -C $r.a rev-parse HEAD) -eq (git -C $r.a rev-parse origin/main)) '2 at origin'
Ok (-not (git -C $r.a status --porcelain)) '2 tree clean'

# 3 real unpushed commit (agentq push deferred) -> replayed onto origin, pushed, clone moved; dirty edit kept
$r = Fresh; W "$($r.a)\y.txt" "mine`n"; git -C $r.a commit -qam 'mine'; Push-B $r 'x.txt' "3`n"; W "$($r.a)\z.txt" "wip`n"; git -C $r.a add z.txt
Ok ((Run $r) -eq 0) '3 published'; git -C $r.a fetch -q
Ok ((git -C $r.a rev-parse HEAD) -eq (git -C $r.a rev-parse origin/main)) '3 at origin'
Ok ((git -C $r.a log origin/main --format=%s) -contains 'mine') '3 commit on origin'
Ok (((git -C $r.a show origin/main:x.txt) -join '') -eq '3') '3 upstream change kept'
Ok ((git -C $r.a diff --cached --name-only) -eq 'z.txt') '3 staged wip kept'

# 3b unpushed commit that conflicts with upstream -> refuse, nothing moves
$r = Fresh; W "$($r.a)\x.txt" "mine`n"; git -C $r.a commit -qam 'mine'; $h = git -C $r.a rev-parse HEAD; Push-B $r 'x.txt' "theirs`n"
Ok ((Run $r) -eq 3) '3b refused'; Ok ((git -C $r.a rev-parse HEAD) -eq $h) '3b HEAD unchanged'

# 4 local edit collides with incoming, edited recently -> refuse (idle gate), edit intact
$r = Fresh; Push-B $r 'x.txt' "theirs`n"; W "$($r.a)\x.txt" "ours`n"; $h = git -C $r.a rev-parse HEAD
Ok ((Run $r) -eq 3) '4 refused'; Ok ((Get-Content "$($r.a)\x.txt" -Raw) -eq "ours`n") '4 edit intact'; Ok ((git -C $r.a rev-parse HEAD) -eq $h) '4 HEAD unchanged'

# 4p same conflict, idle 10 h -> parked: backup branch pushed with the edit, copy + manifest, upstream taken
$r = Fresh; Push-B $r 'x.txt' "theirs`n"; W "$($r.a)\x.txt" "ours`n"; Age "$($r.a)\x.txt"
Ok ((Run $r) -eq 0) '4p exit 0'; Ok ((git -C $r.a rev-parse HEAD) -eq (git -C $r.a rev-parse origin/main)) '4p at origin'
Ok (((Get-Content "$($r.a)\x.txt" -Raw) -replace "`r", '') -eq "theirs`n") '4p took upstream'
$bk = @(Backups $r); Ok ($bk.Count -eq 1) '4p backup branch on origin'
Ok ($bk.Count -eq 1 -and ((git -C $r.o show "$($bk[0]):x.txt") -join '') -eq 'ours') '4p backup holds the edit'
$pf = @(Get-ChildItem -Recurse -File $env:GIT_AUTOSYNC_PARK -Filter x.txt | Where-Object { $_.FullName -like "*$(Split-Path $r.a -Leaf)*" })
Ok ($pf.Count -eq 1 -and (Get-Content $pf[0].FullName -Raw) -eq "ours`n") '4p parked copy'
Ok ($pf.Count -eq 1 -and (Test-Path (Join-Path $pf[0].DirectoryName 'MANIFEST.tsv'))) '4p manifest'

# 4m conflicting-path edit that merges cleanly -> merged result kept uncommitted, no park, even if fresh
$r = Fresh; W "$($r.a)\m.txt" "a`nb`nc`nd`ne`n"; git -C $r.a add m.txt; git -C $r.a commit -qm m; git -C $r.a push -q origin main 2>$null; git -C $r.b pull -q 2>$null
Push-B $r 'm.txt' "A`nb`nc`nd`ne`n"; W "$($r.a)\m.txt" "a`nb`nc`nd`nE`n"
Ok ((Run $r) -eq 0) '4m exit 0'; Ok ((git -C $r.a rev-parse HEAD) -eq (git -C $r.a rev-parse origin/main)) '4m at origin'
Ok (((Get-Content "$($r.a)\m.txt" -Raw) -replace "`r", '') -eq "A`nb`nc`nd`nE`n") '4m merged both'
Ok (@(Backups $r).Count -eq 1) '4m backup branch on origin'

# 4s local change already contained upstream (landed later in a bigger commit) -> superseded, no park dir
$r = Fresh; Push-B $r 'x.txt' "1`nmine`nmore`n"; W "$($r.a)\x.txt" "1`nmine`n"
Ok ((Run $r) -eq 0) '4s exit 0'; Ok (((Get-Content "$($r.a)\x.txt" -Raw) -replace "`r", '') -eq "1`nmine`nmore`n") '4s took upstream'
Ok (-not (git -C $r.a status --porcelain)) '4s tree clean'

# 4x local delete vs upstream modify, idle -> parked (restored from upstream), backup present
$r = Fresh; Push-B $r 'x.txt' "up`n"; Remove-Item "$($r.a)\x.txt"
Ok ((Run $r -x '-ParkNow') -eq 0) '4x exit 0'; Ok (((Get-Content "$($r.a)\x.txt" -Raw) -replace "`r", '') -eq "up`n") '4x restored upstream'

# 4n dirty edit at a path upstream RENAMED away (rename detection hid it -> read-tree "not uptodate") -> parked, moved
$r = Fresh; W "$($r.a)\old.txt" "l1`nl2`nl3`nl4`nl5`nl6`n"; git -C $r.a add old.txt; git -C $r.a commit -qm o; git -C $r.a push -q origin main 2>$null; git -C $r.b pull -q 2>$null
git -C $r.b mv old.txt new.txt; W "$($r.b)\new.txt" "l1`nl2`nl3`nl4`nl5`nl6`nl7`n"; git -C $r.b add -A; git -C $r.b commit -qm mv; git -C $r.b push -q origin main 2>$null
W "$($r.a)\old.txt" "l1`nl2`nmine`nl4`nl5`nl6`n"; Age "$($r.a)\old.txt"
Ok ((Run $r) -eq 0) '4n exit 0'; Ok ((git -C $r.a rev-parse HEAD) -eq (git -C $r.a rev-parse origin/main)) '4n at origin'
Ok (@(Backups $r).Count -eq 1) '4n backup branch on origin'

# 4r unpushed commit in a NON-replay repo -> refused, nothing pushed
$r = Fresh; W "$($r.a)\y.txt" "mine`n"; git -C $r.a commit -qam 'mine'; Push-B $r 'x.txt' "r`n"; $h = git -C $r.a rev-parse HEAD
& pwsh -NoProfile -File $tool -Repo $r.a -ReplayRepos 'codai' *> $null
Ok ($LASTEXITCODE -eq 3) '4r refused'; Ok ((git -C $r.a rev-parse HEAD) -eq $h) '4r HEAD unchanged'
Ok (-not ((git -C $r.o log main --format=%s) -contains 'mine')) '4r not pushed'

# 4b stale copy of an INTERMEDIATE upstream version -> superseded, moved, old blob kept
$r = Fresh; Push-B $r 'x.txt' "v1`n"; W "$($r.a)\x.txt" "v1`n"; Push-B $r 'x.txt' "v2`n"; $old = (git -C $r.a hash-object x.txt)
Ok ((Run $r) -eq 0) '4b exit 0'; Ok ((git -C $r.a rev-parse HEAD) -eq (git -C $r.a rev-parse origin/main)) '4b at origin'
Ok (((Get-Content "$($r.a)\x.txt" -Raw) -replace "`r", '') -eq "v2`n") '4b took upstream'; Ok (-not (git -C $r.a status --porcelain)) '4b tree clean'
Ok ((git -C $r.a cat-file -t $old) -eq 'blob') '4b old blob kept'

# 4c dirty edit that matches NO upstream version -> still refused
$r = Fresh; Push-B $r 'x.txt' "v1`n"; Push-B $r 'x.txt' "v2`n"; W "$($r.a)\x.txt" "mine`n"; $h = git -C $r.a rev-parse HEAD
Ok ((Run $r) -eq 3) '4c refused'; Ok ((Get-Content "$($r.a)\x.txt" -Raw) -eq "mine`n") '4c edit intact'; Ok ((git -C $r.a rev-parse HEAD) -eq $h) '4c HEAD unchanged'

# 4d UNTRACKED copy of an upstream-added file (older version) -> removed, moved
$r = Fresh; Push-B $r 'n.txt' "n1`n"; W "$($r.a)\n.txt" "n1`n"; Push-B $r 'n.txt' "n2`n"
Ok ((Run $r) -eq 0) '4d exit 0'; Ok ((git -C $r.a rev-parse HEAD) -eq (git -C $r.a rev-parse origin/main)) '4d at origin'
Ok (((Get-Content "$($r.a)\n.txt" -Raw) -replace "`r", '') -eq "n2`n") '4d took upstream'; Ok (-not (git -C $r.a status --porcelain)) '4d tree clean'

# 4e UNTRACKED file with unique content at an upstream-added path -> refused, file intact
$r = Fresh; Push-B $r 'n.txt' "theirs`n"; W "$($r.a)\n.txt" "mine`n"; $h = git -C $r.a rev-parse HEAD
Ok ((Run $r) -eq 3) '4e refused'; Ok ((Get-Content "$($r.a)\n.txt" -Raw) -eq "mine`n") '4e file intact'; Ok ((git -C $r.a rev-parse HEAD) -eq $h) '4e HEAD unchanged'

# 4f staged whitespace-only reflow (aborted commit, prettier), worktree == HEAD, upstream changes file -> moved
$r = Fresh; W "$($r.a)\t.md" "a  |  b`n"; git -C $r.a add t.md; git -C $r.a commit -qm 'tbl'; git -C $r.a push -q origin main 2>$null; git -C $r.b pull -q 2>$null
W "$($r.a)\t.md" "a | b`n"; git -C $r.a add t.md; W "$($r.a)\t.md" "a  |  b`n"; Push-B $r 't.md' "a  |  b`nnew`n"
Ok ((Run $r) -eq 0) '4f exit 0'; Ok ((git -C $r.a rev-parse HEAD) -eq (git -C $r.a rev-parse origin/main)) '4f at origin'
Ok (((Get-Content "$($r.a)\t.md" -Raw) -replace "`r", '') -eq "a  |  b`nnew`n") '4f took upstream'; Ok (-not (git -C $r.a status --porcelain)) '4f tree clean'

# 4g staged change with REAL content (not whitespace-only) -> still refused
$r = Fresh; W "$($r.a)\t.md" "a  |  b`n"; git -C $r.a add t.md; git -C $r.a commit -qm 'tbl'; git -C $r.a push -q origin main 2>$null; git -C $r.b pull -q 2>$null
Push-B $r 't.md' "theirs`n"; W "$($r.a)\t.md" "real`n"; git -C $r.a add t.md; W "$($r.a)\t.md" "a  |  b`n"; $h = git -C $r.a rev-parse HEAD
Ok ((Run $r) -eq 3) '4g refused'; Ok ((git -C $r.a rev-parse HEAD) -eq $h) '4g HEAD unchanged'; Ok (((git -C $r.a show :t.md) -join '') -eq 'real') '4g staged kept'

# 5 staged unrelated change stays staged
$r = Fresh; Push-B $r 'x.txt' "5`n"; W "$($r.a)\y.txt" "staged`n"; git -C $r.a add y.txt
Ok ((Run $r) -eq 0) '5 exit 0'; Ok ((git -C $r.a diff --cached --name-only) -eq 'y.txt') '5 still staged'

# 6 merge in progress -> skip
$r = Fresh; Push-B $r 'x.txt' "6`n"; W "$($r.a)\.git\MERGE_HEAD" (git -C $r.a rev-parse HEAD); $h = git -C $r.a rev-parse HEAD
Ok ((Run $r) -eq 3) '6 skipped'; Ok ((git -C $r.a rev-parse HEAD) -eq $h) '6 HEAD unchanged'

Remove-Item -Recurse -Force $root
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
