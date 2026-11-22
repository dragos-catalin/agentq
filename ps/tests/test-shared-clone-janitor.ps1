param([string]$Tool, [string]$Agentq)
# Scenario tests for shared-clone-janitor.ps1 on throwaway repos under %TEMP%.
# No network and no real repo: every scenario builds its own bare origin + clone, and the log, the backup
# root, the coord root (journal + agentq queues), the agentq config and AGENTQ_HOME are all redirected
# into the scratch dir - nothing here can touch ~/.codai or a real shared clone.
#
# It exercises the REAL agentq publish (-Apply scenarios), because that is the sanctioned fallback the
# janitor shells out to; the publish child inherits the scratch AGENTQ_HOME / AGENTQ_CONFIG set below.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3
# Next to the test (the installed ~/.copilot/bin copy), else ../bin (the repo, run with no -Tool).
$tool = if ($Tool) { $Tool }
  elseif (Test-Path (Join-Path $PSScriptRoot 'shared-clone-janitor.ps1')) { Join-Path $PSScriptRoot 'shared-clone-janitor.ps1' }
  else { Join-Path (Split-Path $PSScriptRoot -Parent) 'bin\shared-clone-janitor.ps1' }
$agentq = if ($Agentq) { $Agentq } else { Join-Path $HOME '.copilot\bin\agentq.ps1' }
if (-not (Test-Path -LiteralPath $tool)) { throw "test: tool not found: $tool" }
if (-not (Test-Path -LiteralPath $agentq)) { throw "test: agentq not found: $agentq" }
$root = Join-Path ([IO.Path]::GetTempPath()) ("scj-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $root | Out-Null

$env:SHARED_CLONE_JANITOR_LOG = Join-Path $root 'janitor.log'
$env:SHARED_CLONE_JANITOR_BACKUP = Join-Path $root 'backups'
$env:SHARED_CLONE_JANITOR_COORD = Join-Path $root 'coord'
$env:SHARED_CLONE_JANITOR_AGENTQ = $agentq
$env:AGENTQ_HOME = Join-Path $root 'coord'
$env:AGENTQ_CONFIG = Join-Path $root 'agentq-config.json'
# A stale expectation left by the shell that runs the tests must not leak into the publish child.
Remove-Item Env:\AGENTQ_EXPECT_REPO -ErrorAction SilentlyContinue
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'
$env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
$fail = 0
function Ok([bool]$c, [string]$m) { if ($c) { "PASS $m" } else { "FAIL $m"; $script:fail++ } }
function OkText([string]$text, [string]$pat, [string]$m) { Ok ($text -match $pat) $m }
function W([string]$f, [string]$t) { [IO.File]::WriteAllText($f, $t) }
function Age([string]$f, [int]$h = 10) { (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddHours(-$h) }

# The janitor decides from the CONFIG (sharedCloneModeRepos), never from a flag, so every scenario
# writes its own config first. `refuse` is what makes a repo a janitor target.
function Write-Cfg([hashtable]$modes, [string[]]$repos) {
  $doc = [ordered]@{
    sharedCloneMode      = 'warn'
    sharedCloneModeRepos = $modes
    autosync             = [ordered]@{ daemons = @('git-autosync'); repos = @($repos) }
  }
  W $env:AGENTQ_CONFIG ($doc | ConvertTo-Json -Depth 5)
}
# A bare origin + a clone whose PARENT holds the `.wt\<leaf>` slots dir the janitor requires.
function New-Repo([string]$leaf, [switch]$NoSlots) {
  $o = Join-Path $root "$leaf-origin.git"
  git init -q --bare -b main $o
  $a = Join-Path $root $leaf
  git init -q -b main $a
  W (Join-Path $a 'base.txt') "base`nkeep`n"
  git -C $a add base.txt; git -C $a commit -qm base
  git -C $a remote add origin $o; git -C $a push -q -u origin main
  $a = (Resolve-Path -LiteralPath $a).Path
  if (-not $NoSlots) { New-Item -ItemType Directory -Force (Join-Path (Split-Path $a -Parent) ('.wt' + [IO.Path]::DirectorySeparatorChar + $leaf)) | Out-Null }
  @{ o = $o; a = $a; leaf = $leaf }
}
# One run, both the exit code and the (merged stdout+stderr) text: the second run would see a tree the
# first one already acted on.
function RunJ([string[]]$x) {
  $out = @(& pwsh -NoProfile -ExecutionPolicy Bypass -File $tool @x 2>&1 | ForEach-Object { "$_" })
  @{ code = $LASTEXITCODE; text = ($out -join "`n") }
}
# The unary comma matters: a function that emits an empty @() actually returns $null (the pipeline drops
# an empty array), so `(Dirty $r).Count` would throw under StrictMode. `,@(...)` keeps it an array.
function Dirty([string]$p) { ,@(git -C $p -c core.quotepath=off status --porcelain -uall 2>$null | ForEach-Object { "$_" }) }
function PublishRefs([string]$o) { ,@(git -C $o for-each-ref --format='%(refname)' refs/heads/publish 2>$null | ForEach-Object { "$_" }) }
function InRef([string]$p, [string]$ref, [string]$file) { (@(& git -C $p show "${ref}:${file}" 2>$null) -join "`n") }
function Stashes([string]$p) { ,@(git -C $p stash list 2>$null | ForEach-Object { "$_" }) }
function Backups([string]$leaf) { ,@(Get-ChildItem -LiteralPath (Join-Path $env:SHARED_CLONE_JANITOR_BACKUP $leaf) -Recurse -Filter manifest.json -ErrorAction SilentlyContinue) }
function JEvents([string]$name) {
  $f = Join-Path $root 'coord\journal.jsonl'
  if (-not (Test-Path -LiteralPath $f)) { return ,@() }
  ,@(Get-Content -LiteralPath $f | Where-Object { $_ -and $_.Trim() } |
    ForEach-Object { ConvertFrom-Json -AsHashtable $_ } |
    # ContainsKey first: under StrictMode a hashtable property access on a missing key throws, and
    # agentq's own journal lines (same file) carry neither `tool` nor `repo`.
    Where-Object { $_.ContainsKey('tool') -and $_.ContainsKey('repo') -and $_.tool -eq 'shared-clone-janitor' -and $_.repo -eq $name } |
    ForEach-Object { "$($_.event)" })
}

# ---- A: the hand fix, automated: publish the debris, then clean exactly those paths
$a = New-Repo 'scj-a'
Write-Cfg @{ 'scj-a' = 'refuse' } @($a.a)
W (Join-Path $a.a 'base.txt') "edited-by-nobody`n"
Age (Join-Path $a.a 'base.txt')
$r = RunJ @('-Repo', $a.a, '-Apply', '-LiveWriterSec', '0')
Ok ($r.code -eq 0) 'A exit 0 when it acted'
Ok ((Dirty $a.a).Count -eq 0) 'A worktree clean after the clean step'
$refs = PublishRefs $a.o
Ok ($refs.Count -eq 1) "A exactly one publish topic on origin (got $($refs.Count))"
# The topic lives on the bare origin (the clone only has it as refs/remotes/origin/...).
if ($refs.Count -eq 1) { Ok ((InRef $a.o $refs[0] 'base.txt') -eq 'edited-by-nobody') 'A the topic holds the salvaged content' }
$st = Stashes $a.a
Ok ($st.Count -eq 1) 'A exactly one stash'
if ($st.Count -eq 1) { OkText $st[0] 'shared-clone-janitor scj-a' 'A the stash message names the repo and the session' }
$bk = Backups 'scj-a'
Ok ($bk.Count -eq 1) 'A one backup manifest'
if ($bk.Count -eq 1) {
  $dir = Split-Path $bk[0].FullName -Parent
  $man = Get-Content -LiteralPath $bk[0].FullName -Raw | ConvertFrom-Json
  Ok (($man.count -eq 1) -and ($man.paths[0].path -eq 'base.txt')) 'A the manifest lists the dirty path'
  Ok ((Get-Content -LiteralPath (Join-Path $dir 'base.txt') -Raw) -eq "edited-by-nobody`n") 'A the backup holds the content as it was'
}
$ev = JEvents 'scj-a'
Ok ($ev -contains 'backup' -and $ev -contains 'published' -and $ev -contains 'cleaned') "A journaled backup+published+cleaned (got $($ev -join ','))"
OkText (Get-Content -LiteralPath $env:SHARED_CLONE_JANITOR_LOG -Raw) 'published 1 path\(s\) as origin/publish/' 'A the log line records the publish'

# ---- B: a path written seconds ago belongs to a live writer -> skip, touch nothing
$b = New-Repo 'scj-b'
Write-Cfg @{ 'scj-b' = 'refuse' } @($b.a)
W (Join-Path $b.a 'base.txt') "someone-just-saved-this`n"
$r = RunJ @('-Repo', $b.a, '-Apply')
Ok ($r.code -eq 3) 'B exit 3 for a skip'
OkText $r.text 'a live writer' 'B the reason names the live writer'
Ok ((Dirty $b.a).Count -eq 1) 'B the tree was left alone'
Ok ((PublishRefs $b.o).Count -eq 0) 'B nothing was published'
Ok ((Backups 'scj-b').Count -eq 0) 'B no backup was taken before the gate'

# ---- C: the default (and -WhatIf) is a dry run
$c = New-Repo 'scj-c'
Write-Cfg @{ 'scj-c' = 'refuse' } @($c.a)
W (Join-Path $c.a 'base.txt') "dry-run-must-not-touch-this`n"
Age (Join-Path $c.a 'base.txt')
$r = RunJ @('-Repo', $c.a, '-LiveWriterSec', '0')
Ok ($r.code -eq 3) 'C exit 3: a dry run that would have acted'
OkText $r.text 'dry run: nothing was touched' 'C it says nothing was touched'
OkText $r.text 'would run' 'C the plan says what it would run'
OkText $r.text 'would run:  pwsh .* publish' 'C the plan shows the publish command'
Ok ((Dirty $c.a).Count -eq 1) 'C the tree is still dirty'
Ok ((PublishRefs $c.o).Count -eq 0) 'C nothing was published'
Ok ((Backups 'scj-c').Count -eq 0) 'C no backup in a dry run'
$r = RunJ @('-Repo', $c.a, '-LiveWriterSec', '0', '-WhatIf')
Ok ($r.code -eq 3) 'C -WhatIf behaves exactly like the default'

# ---- D: a large dirty set is a live agent, not debris
$d = New-Repo 'scj-d'
Write-Cfg @{ 'scj-d' = 'refuse' } @($d.a)
1..3 | ForEach-Object { W (Join-Path $d.a "f$_.txt") "x$_`n"; Age (Join-Path $d.a "f$_.txt") }
$r = RunJ @('-Repo', $d.a, '-Apply', '-LiveWriterSec', '0', '-MaxFiles', '2')
Ok ($r.code -eq 3) 'D exit 3'
OkText $r.text 'too-many' 'D the reason names too-many'
Ok ((Dirty $d.a).Count -eq 3) 'D all three paths are still dirty'
Ok ((PublishRefs $d.o).Count -eq 0) 'D nothing was published'

# ---- E: a linked worktree (a leased slot) is exactly where agents are supposed to be dirty
$e = New-Repo 'scj-e'
Write-Cfg @{ 'scj-e' = 'refuse' } @($e.a)
$slot = Join-Path $root 'scj-e-slot'
git -C $e.a worktree add -q --detach $slot HEAD
W (Join-Path $slot 'base.txt') "a slot edit`n"
$r = RunJ @('-Repo', $slot, '-Apply', '-LiveWriterSec', '0')
Ok ($r.code -eq 3) 'E exit 3'
OkText $r.text 'linked worktree' 'E the reason names the linked worktree'
Ok ((Dirty $slot).Count -eq 1) 'E the slot keeps its edit'
Ok ((PublishRefs $e.o).Count -eq 0) 'E nothing was published'

# ---- F: an active agentq commit/land ticket means another tool owns this repo right now
$f = New-Repo 'scj-f'
Write-Cfg @{ 'scj-f' = 'refuse' } @($f.a)
W (Join-Path $f.a 'base.txt') "old-enough-to-janitor`n"
Age (Join-Path $f.a 'base.txt')
$q = Join-Path $env:AGENTQ_HOME 'queues\commit_scj-f'
New-Item -ItemType Directory -Force $q | Out-Null
W (Join-Path $q 't1.json') '{"resource":"commit:scj-f","pid":1}'
$r = RunJ @('-Repo', $f.a, '-Apply', '-LiveWriterSec', '0')
Ok ($r.code -eq 3) 'F exit 3'
OkText $r.text 'commit ticket active' 'F the reason names the active ticket'
Ok ((Dirty $f.a).Count -eq 1) 'F untouched while the ticket is held'
Remove-Item -Recurse -Force $q
$r = RunJ @('-Repo', $f.a, '-Apply', '-LiveWriterSec', '0', '-MaxFiles', '0')
Ok ($r.code -eq 3) 'F with the ticket gone the next gate (too-many) decides'
OkText $r.text 'too-many' 'F the ticket gate was the only reason before'

# ---- G: only `refuse` repos are janitor targets
$g = New-Repo 'scj-g'
Write-Cfg @{ 'scj-g' = 'warn' } @($g.a)
W (Join-Path $g.a 'base.txt') "warn-mode-is-not-a-target`n"
Age (Join-Path $g.a 'base.txt')
$r = RunJ @('-Repo', $g.a, '-Apply', '-LiveWriterSec', '0')
Ok ($r.code -eq 3) 'G exit 3'
OkText $r.text "is 'warn', not 'refuse'" 'G the reason quotes the mode'
Ok ((Dirty $g.a).Count -eq 1) 'G untouched'

# ---- H: the steady state is silent and exit 0
$h = New-Repo 'scj-h'
Write-Cfg @{ 'scj-h' = 'refuse' } @($h.a)
$r = RunJ @('-Repo', $h.a, '-LiveWriterSec', '0')
Ok ($r.code -eq 0) 'H exit 0 for a clean repo'
OkText $r.text 'clean: nothing uncommitted' 'H it says clean'
Ok ((Dirty $h.a).Count -eq 0) 'H the repo it reported clean really is clean'

# ---- I: a repo without a slots dir is not slot-managed -> not ours
$i = New-Repo 'scj-i' -NoSlots
Write-Cfg @{ 'scj-i' = 'refuse' } @($i.a)
W (Join-Path $i.a 'base.txt') "no-slots-here`n"
Age (Join-Path $i.a 'base.txt')
$r = RunJ @('-Repo', $i.a, '-Apply', '-LiveWriterSec', '0')
Ok ($r.code -eq 3) 'I exit 3'
OkText $r.text 'no slots dir' 'I the reason names the missing slots dir'
Ok ((Dirty $i.a).Count -eq 1) 'I untouched'

# ---- J: agentq refuses a publish that would undo work landed after our base -> tree kept, backup kept
$j = New-Repo 'scj-j'
Write-Cfg @{ 'scj-j' = 'refuse' } @($j.a)
W (Join-Path $j.a 'base.txt') "base`n"            # drops 'keep': a change relative to our own HEAD
Age (Join-Path $j.a 'base.txt')
$peer = Join-Path $root 'scj-j-peer'
git clone -q $j.o $peer 2>$null
W (Join-Path $peer 'base.txt') "base`nkeep`nC`n"  # someone else lands on top of our base
git -C $peer add base.txt; git -C $peer commit -qm peer; git -C $peer push -q origin main
$r = RunJ @('-Repo', $j.a, '-Apply', '-LiveWriterSec', '0')
Ok ($r.code -eq 3) 'J exit 3 (skipped, not an error)'
OkText $r.text 'publish REFUSED by agentq \(exit 5\)' 'J it reports agentq own refusal'
OkText $r.text 'nothing was stashed' 'J it says the clean step was skipped'
Ok (((Get-Content -LiteralPath (Join-Path $j.a 'base.txt') -Raw)) -eq "base`n") 'J the tree keeps its file'
Ok ((PublishRefs $j.o).Count -eq 0) 'J nothing was pushed'
Ok ((Backups 'scj-j').Count -eq 1) 'J the pre-publish backup is kept'
Ok ((JEvents 'scj-j') -contains 'publish-refused') 'J journaled publish-refused'
Ok ((JEvents 'scj-j') -notcontains 'cleaned') 'J never journaled cleaned'

Remove-Item -Recurse -Force $root
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
