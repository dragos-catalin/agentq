<#
test-autosync-wip.ps1 - proves the autosync untracked-capture fix (and its absence before it).

The gap: a brand-new untracked file that upstream neither adds nor changes was neither captured nor
refused before a fast-forward, so nothing recorded it anywhere. This suite builds the exact incident
shape in a scratch origin+clone, runs the REAL git-autosync.ps1 (isolated env: its own state, status,
coord, log, park root and mutex) and asserts:
  1. -WhatIf says the clone holds untracked-only work;
  2. the move still happens, the untracked file SURVIVES, and
  3. a refs/backup/snapshot/<clone>/<ts> ref exists whose `show <ref>:<path>` still returns the exact
     bytes after `git gc --prune=now`;
  4. MUTATION: the same fixture run against the pre-edit copy (.prefix.bak) creates NO such ref -
     i.e. the fix is load-bearing, not decorative.
#>
param([string]$SuiteLog = '')

$fail = 0; $pass = 0
function Step([string]$s) { $l = '[{0}] {1}' -f (Get-Date -Format HH:mm:ss.fff), $s; if ($SuiteLog) { try { Add-Content -LiteralPath $SuiteLog -Value $l } catch { } } }
function Ok([string]$what) { $script:pass++; "PASS  $what"; Step "PASS $what" }
function Bad([string]$what, [string]$why) { $script:fail++; "FAIL  $what`n        $why"; Step "FAIL $what :: $why" }

function Git([string]$dir, [string[]]$a) { & git.exe -C $dir --no-optional-locks @a 2>&1 | ForEach-Object { "$_" } }
function GitOne([string]$dir, [string[]]$a) { $o = @(Git $dir $a | Where-Object { $_ -and $_ -notmatch '^(fatal|error|usage|warning)' }); if ($o.Count) { $o[0].Trim() } else { $null } }
function StatusText([string]$dir) { (@(Git $dir @('-c', 'core.quotepath=off', 'status', '--porcelain', '--untracked-files=all')) -join "`n") }

$base = Join-Path $env:TEMP ("autosync-wip-suite-" + [guid]::NewGuid().ToString('N'))
$noteContent = "# note`nline two`nline three (no trailing newline)"
# Run the copy this repo owns; fall back to the installed one when the suite is run from a scratch tree.
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$binHere = Join-Path $repoRoot 'ps\bin\git-autosync.ps1'
$newScript = if (Test-Path -LiteralPath $binHere) { $binHere } else { Join-Path $env:USERPROFILE '.copilot\bin\git-autosync.ps1' }
# The pre-fix baseline comes from THIS repo's history - the parent of the commit that introduced
# Save-LocalSnapshot - so the mutation control never depends on a local *.prefix.bak backup that only the
# machine that wrote the fix happens to have (and cannot silently degrade to a vacuous PASS).
$oldScript = $null
try {
  $fixSha = @(& git.exe -C $repoRoot log -1 --format=%H -S 'Save-LocalSnapshot' -- ps/bin/git-autosync.ps1 2>&1 | Where-Object { "$_" -match '^[0-9a-f]{40}$' })[0]
  if ($fixSha) {
    $tmp = Join-Path $env:TEMP ("autosync-wip-baseline-" + [guid]::NewGuid().ToString('N') + '.ps1')
    & git.exe -C $repoRoot show "${fixSha}^:ps/bin/git-autosync.ps1" > $tmp 2>$null
    if ((Test-Path -LiteralPath $tmp) -and ((Get-Item -LiteralPath $tmp).Length -gt 1000)) { $oldScript = $tmp }
  }
} catch { }

function New-Fixture([string]$root) {
  $origin = Join-Path $root 'origin.git'
  $clone = Join-Path $root 'demo-clone'
  $pub = Join-Path $root 'publisher'
  & git.exe init -q --bare --initial-branch=main $origin 2>&1 | Out-Null
  & git.exe clone -q $origin $clone 2>&1 | Out-Null
  foreach ($d in $clone, $pub) { & git.exe -C $d config user.name 'wip-suite' 2>&1 | Out-Null; & git.exe -C $d config user.email 'wip@suite.local' 2>&1 | Out-Null; & git.exe -C $d config core.autocrlf false 2>&1 | Out-Null; & git.exe -C $d config status.showUntrackedFiles all 2>&1 | Out-Null }
  [IO.File]::WriteAllText((Join-Path $clone 'README.md'), "# seed`n", [Text.UTF8Encoding]::new($false))
  Git $clone @('add', 'README.md') | Out-Null
  Git $clone @('commit', '-q', '-m', 'seed') | Out-Null
  Git $clone @('push', '-q', '-u', 'origin', 'main') | Out-Null
  & git.exe clone -q $origin $pub 2>&1 | Out-Null
  foreach ($d in $clone, $pub) { & git.exe -C $d config user.name 'wip-suite' 2>&1 | Out-Null; & git.exe -C $d config user.email 'wip@suite.local' 2>&1 | Out-Null }
  New-Item -ItemType Directory -Force (Join-Path $pub 'docs') | Out-Null
  [IO.File]::WriteAllText((Join-Path $pub 'docs\upstream.md'), "# upstream`n", [Text.UTF8Encoding]::new($false))
  Git $pub @('add', '-A') | Out-Null
  Git $pub @('commit', '-q', '-m', 'upstream change') | Out-Null
  Git $pub @('push', '-q', 'origin', 'main') | Out-Null
  # The incident shape: a new file that upstream neither adds nor changes.
  New-Item -ItemType Directory -Force (Join-Path $clone 'docs') | Out-Null
  [IO.File]::WriteAllText((Join-Path $clone 'docs\new-note.md'), $noteContent, [Text.UTF8Encoding]::new($false))
  # A working copy where `git add` PRINTS A WARNING on stderr (CRLF vs a committed-in-worktree attribute).
  # With $ErrorActionPreference='Stop' such a warning used to be reported as a failed capture and the repo
  # got no ref at all (real clone 2026-11-26) - keep this case in the fixture for ever.
  [IO.File]::WriteAllText((Join-Path $clone '.gitattributes'), "*.sh text eol=lf`n", [Text.UTF8Encoding]::new($false))
  New-Item -ItemType Directory -Force (Join-Path $clone 'tools') | Out-Null
  [IO.File]::WriteAllText((Join-Path $clone 'tools\crlf-warning.sh'), "#!/bin/sh`r`necho hi`r`n", [Text.UTF8Encoding]::new($false))
  [pscustomobject]@{ root = $root; origin = $origin; clone = $clone; pub = $pub }
}

function Invoke-Autosync([string]$script, [string]$root, [string[]]$extra, [string]$tag) {
  # Isolate EVERY artifact the script writes, so a scratch run cannot touch the live daemon's state,
  # status map, journal, park root, coord root or mutex.
  $env:GIT_AUTOSYNC_STATE = Join-Path $root 'state.json'
  $env:GIT_AUTOSYNC_STATUS = Join-Path $root 'status.json'
  $env:GIT_AUTOSYNC_COORD = Join-Path $root 'coord'
  $env:GIT_AUTOSYNC_REFUSE_STATE = Join-Path $root 'refuse.json'
  $env:GIT_AUTOSYNC_LOG = Join-Path $root 'autosync.log'
  $env:GIT_AUTOSYNC_PARK = Join-Path $root 'parked'
  $env:GIT_AUTOSYNC_LAND_DIR = Join-Path $root 'land'
  $env:GIT_AUTOSYNC_MUTEX = 'Global\gas-wip-suite-' + [guid]::NewGuid().ToString('N')
  $env:GIT_AUTOSYNC_OWNER_CHECK = 'off'
  $env:GIT_AUTOSYNC_NO_NOTE = '1'
  $cfg = Join-Path $root 'agentq-config.json'
  if (-not (Test-Path $cfg)) { [IO.File]::WriteAllText($cfg, '{}', [Text.UTF8Encoding]::new($false)) }
  $env:AGENTQ_CONFIG = $cfg
  New-Item -ItemType Directory -Force (Join-Path $root 'coord') | Out-Null
  $o = Join-Path $root "run-$tag.out"; $e = Join-Path $root "run-$tag.err"
  $argv = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $script, '-Repo', (Join-Path $root 'demo-clone')) + $extra
  Step "run $tag :: $script $($extra -join ' ')"
  $p = Start-Process pwsh -ArgumentList $argv -RedirectStandardOutput $o -RedirectStandardError $e -PassThru -Wait
  $out = if (Test-Path $o) { (@(Get-Content -LiteralPath $o) -join "`n") } else { '' }
  $err = if (Test-Path $e) { (@(Get-Content -LiteralPath $e) -join "`n") } else { '' }
  foreach ($ln in @($out -split "`n" | Where-Object { $_ })) { Step "  out| $ln" }
  foreach ($ln in @($err -split "`n" | Where-Object { $_ })) { Step "  err| $ln" }
  [pscustomobject]@{ rc = $p.ExitCode; out = $out; err = $err }
}

function SnapRefs([string]$clone) { @(Git $clone @('for-each-ref', '--format=%(refname)', 'refs/backup/snapshot/') | Where-Object { $_ -like 'refs/backup/snapshot/*' }) }
function LastRef([object]$refs) { $a = @($refs); if ($a.Count) { "$($a[-1])".Trim() } else { $null } }

try {
  New-Item -ItemType Directory -Force $base | Out-Null
  Step "suite start; scratch=$base; new=$newScript; old=$oldScript"
  if (-not (Test-Path $newScript)) { throw "missing $newScript" }

  $fx = New-Fixture $base
  $pre = StatusText $fx.clone
  if ($pre -match 'new-note\.md' -and $pre -match '^\?\?') { Ok 'precondition: the new file is untracked and the clone is behind' } else { Bad 'precondition: untracked file present' "status=`n$pre" }

  # --- 1. -WhatIf reports the uncaptured untracked work (read-only) -------------------------------
  $wi = Invoke-Autosync $newScript $base @('-WhatIf') 'whatif'
  if ($wi.out -match 'untracked file\(s\) exist only in this clone') { Ok '-WhatIf names the untracked-only work it would capture' } else { Bad '-WhatIf names the untracked-only work' "out=$($wi.out)" }
  if ($wi.out -match 'would move') { Ok '-WhatIf would move (the fix does not block the sync)' } else { Bad '-WhatIf would move' "out=$($wi.out)" }
  $afterWi = StatusText $fx.clone
  if ($afterWi -eq $pre) { Ok '-WhatIf left the clone untouched' } else { Bad '-WhatIf left the clone untouched' "before=`n$pre`nafter=`n$afterWi" }

  # --- 2. the real pass --------------------------------------------------------------------------
  $run = Invoke-Autosync $newScript $base @() 'real'
  if ($run.rc -eq 0) { Ok 'the pass exits 0' } else { Bad 'the pass exits 0' "rc=$($run.rc) err=$($run.err)" }
  $branchTip = GitOne $fx.clone @('rev-parse', 'HEAD')
  $upTip = GitOne $fx.clone @('rev-parse', 'origin/main')
  if ($branchTip -and $upTip -and $branchTip -eq $upTip) { Ok "the clone fast-forwarded to upstream ($($upTip.Substring(0,8)))" } else { Bad 'the clone fast-forwarded' "head=$branchTip up=$upTip" }
  if ($run.out -match 'captured as refs/backup/snapshot/demo-clone/') { Ok 'the move reports the snapshot ref it wrote' } else { Bad 'the move reports the snapshot ref' "out=$($run.out)" }
  $notePath = Join-Path $fx.clone 'docs\new-note.md'
  if ((Test-Path $notePath) -and ((Get-Content -LiteralPath $notePath -Raw) -eq $noteContent)) { Ok 'the untracked file survives the move, byte-identical' } else { Bad 'the untracked file survives the move' "exists=$(Test-Path $notePath)" }
  if ($run.out -match 'add -A failed') { Bad 'a stderr WARNING is not reported as a failed capture' "out=$($run.out)" } else { Ok 'no git stderr warning was mistaken for a failed capture' }

  # --- 3. the capture is real and durable --------------------------------------------------------
  # @() at the CALL site: a function returning a one-element array hands back a bare STRING, and
  # $string[-1] is its last CHARACTER (this cost a whole run: the ref read as "7").
  $refs = @(SnapRefs $fx.clone)
  Step "snapshot refs: $($refs -join ', ')"
  if ($refs.Count -ge 1) { Ok "a snapshot ref exists: $(LastRef $refs)" } else { Bad 'a snapshot ref was created' 'none found' }
  $gc = Git $fx.clone @('gc', '--prune=now', '--quiet')
  Step "git gc --prune=now -> $($gc -join ' ')"
  $ref = LastRef $refs
  $shown = if ($ref) { (@(Git $fx.clone @('show', "$($ref):docs/new-note.md")) -join "`n") } else { $null }
  if ($ref -and $shown -eq $noteContent) { Ok 'git show <ref>:docs/new-note.md returns the exact content after gc --prune=now' } else { Bad 'git show <ref>:<path> after gc' "ref=$ref shown=<$shown>" }
  # a -WhatIf after the move must still be honest about a dirty clone
  $after = StatusText $fx.clone
  if ($after -match 'new-note\.md') { Ok 'the untracked file is still untracked after the move' } else { Bad 'still untracked after the move' "status=`n$after" }

  # --- 4. MUTATION: the pre-fix copy must NOT create the ref -------------------------------------
  if (-not $oldScript) {
    # The baseline now comes from HISTORY (the parent of the commit that introduced Save-LocalSnapshot), so
    # it needs that file's full log. A shallow checkout (actions/checkout defaults to fetch-depth: 1) makes
    # `git log -S` find nothing and the control cannot run - a FAIL, never a silent skip, but it has to SAY
    # why: the message used to blame a missing *.prefix.bak, which stopped being the source when the
    # baseline moved out of a machine-local backup. This is exactly what was red on the CI runner
    # 2026-11-27 ('MUTATION: pre-edit copy available' with nothing else to go on).
    $shallow = (GitOne $repoRoot @('rev-parse', '--is-shallow-repository')) -ceq 'true'
    $why = if ($shallow) {
      "this checkout is SHALLOW ($repoRoot): the mutation baseline needs full history of ps/bin/git-autosync.ps1 - set fetch-depth: 0 for this job"
    } else {
      "no commit touching ps/bin/git-autosync.ps1 with 'Save-LocalSnapshot' in $repoRoot (git log -S), and no *.prefix.bak in $bakDir"
    }
    Bad 'MUTATION: pre-edit copy available' $why
  } else {
    $b2 = Join-Path $base 'mutation'
    New-Item -ItemType Directory -Force $b2 | Out-Null
    # pwsh -File refuses a name without a .ps1 extension, so the control must be a real copy (running
    # the .bak directly exits 64 without executing: a vacuous PASS).
    $oldCopy = Join-Path $b2 'old-autosync.ps1'
    Copy-Item -LiteralPath $oldScript -Destination $oldCopy -Force
    $fx2 = New-Fixture $b2
    $m = Invoke-Autosync $oldCopy $b2 @() 'mutation'
    $mRefs = @(SnapRefs $fx2.clone)
    $mNote = Test-Path (Join-Path $fx2.clone 'docs\new-note.md')
    $mTip = GitOne $fx2.clone @('rev-parse', 'HEAD'); $mUp = GitOne $fx2.clone @('rev-parse', 'origin/main')
    if ($m.rc -eq 0 -and $mTip -and $mTip -eq $mUp) { Ok 'MUTATION control: the pre-fix copy ran and moved the same fixture' } else { Bad 'MUTATION control: the pre-fix copy ran' "rc=$($m.rc) head=$mTip up=$mUp err=$($m.err)" }
    if ($mRefs.Count -eq 0) { Ok 'MUTATION: the pre-fix copy created NO snapshot ref (the gap was real, the fix is load-bearing)' } else { Bad 'MUTATION: pre-fix copy created no ref' "refs=$($mRefs -join ', ')" }
    if ($m.out -notmatch 'untracked file\(s\) exist only in this clone') { Ok 'MUTATION: the pre-fix copy never mentioned the untracked work' } else { Bad 'MUTATION: pre-fix copy never mentioned it' "out=$($m.out)" }
    Step "mutation rc=$($m.rc) head=$mTip up=$mUp refs=$($mRefs.Count) notePresent=$mNote out=$($m.out -replace "`n", ' | ')"
    if ($m.rc -eq 0 -and (-not $mNote)) { Step 'NOTE: the pre-fix copy also lost the untracked file' }
  }
} catch {
  Bad 'suite ran to completion' "$_"
} finally {
  if ($fail -gt 0) { "scratch kept for forensics: $base"; Step "scratch kept: $base" } else { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
}
"autosync-wip suite: $pass passed, $fail failed"
if ($SuiteLog) { Step "autosync-wip suite: $pass passed, $fail failed" }
if ($fail -gt 0) { exit 1 }
exit 0
