# A NETWORK git verb must never be awaited without a bound.
# 2026-11-28: `git -C <main> fetch -q origin main` inside `agentq land` sat 10 minutes with the child
# alive and ~0 CPU while the same command from another shell took 2.9 s, and an earlier one sat 55
# minutes - both holding `land:<repo>`, so every other agent waited behind a job whose log was 126
# bytes and could not be told apart from a hung one. git has no transfer timeout, so `Invoke-GitNet`
# (bin/agentq-v2.ps1) bounds it by wall clock, kills the child on expiry and sets $LASTEXITCODE=124.
# This suite proves BOTH halves: the wedge is killed and journaled, and a healthy fetch is untouched.
# The wedge is deterministic - an `ext::` remote whose helper sleeps - so the suite never depends on
# the network. Isolated in %TEMP%.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqgnet-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_NO_PREP = '1'
$env:AGENTQ_SESSION = 'test-G'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
# 5 s bound: the suite would otherwise inherit the 180 s production default and take minutes.
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0,"gitNetTimeoutSec":5}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function JournalLines {
  $f = Get-ChildItem -Path $tmp -Recurse -Filter 'journal.jsonl' -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $f) { return @() }
  @(Get-Content -LiteralPath $f.FullName -ErrorAction SilentlyContinue)
}
# Run an agentq verb with an OUTER bound, so a regression that hangs is a FAIL after a minute instead
# of a suite that never returns (the outer bound is ~12x the inner one).
function AqBounded([string[]]$VerbArgs, [int]$OuterMs) {
  $psi = [Diagnostics.ProcessStartInfo]::new('pwsh')
  foreach ($a in @('-NoProfile', '-File', $Aq) + $VerbArgs) { $psi.ArgumentList.Add($a) }
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.UseShellExecute = $false
  $psi.WorkingDirectory = $repo
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = [Diagnostics.Process]::Start($psi)
  $done = $p.WaitForExit($OuterMs)
  $sw.Stop()
  if (-not $done) { try { $p.Kill($true) } catch { } ; return @{ ms = [int]$sw.ElapsedMilliseconds; hung = $true; out = '' } }
  @{ ms = [int]$sw.ElapsedMilliseconds; hung = $false; out = ($p.StandardOutput.ReadToEnd() + $p.StandardError.ReadToEnd()) }
}

# ---- fixture: a repo that talks to a real origin, then an origin that sleeps forever -------------
$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b main $bare
git init -q -b main $repo
git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
Set-Content (Join-Path $repo 'a.txt') 'a'
git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare
git -C $repo push -q -u origin main 2>$null
$hang = Join-Path $tmp 'hang.ps1'
Set-Content -LiteralPath $hang -Value 'param([string]$IgnoreSlots) ; Start-Sleep -Seconds 600' -Encoding ascii
git -C $repo config protocol.ext.allow always

# ---- 1. the wedge is killed, and it is journaled -------------------------------------------------
git -C $repo remote set-url origin "ext::pwsh -NoProfile -File $hang %S"
$r = AqBounded @('since', '-Hours', '1') 60000
Check 'a wedged network git is killed, not awaited' (-not $r.hung) "agentq since never returned within 60 s (it should fail at the 5 s bound)"
Check 'the wedge costs about the bound, not minutes' (-not $r.hung -and $r.ms -lt 40000) "took $($r.ms) ms"
Check 'the caller kept going after the kill' ([bool]($r.out -match 'live queues')) 'the verb stopped at the fetch instead of carrying on'
$ev = @(JournalLines | Where-Object { $_ -match 'git-net-timeout' })
Check 'the kill is journaled as git-net-timeout' ($ev.Count -ge 1) 'no git-net-timeout line in the journal'
Check 'the journal names the verb it killed' ([bool](@($ev | Where-Object { $_ -match 'fetch' }).Count)) 'the event does not carry the git args'

# ---- 2. control: a healthy fetch is NOT killed and stays fast ------------------------------------
git -C $repo remote set-url origin $bare
$r2 = AqBounded @('since', '-Hours', '1') 60000
Check 'a healthy fetch still completes fast' (-not $r2.hung -and $r2.ms -lt 30000) "took $($r2.ms) ms hung=$($r2.hung)"
$ev2 = @(JournalLines | Where-Object { $_ -match 'git-net-timeout' })
Check 'a healthy fetch is not recorded as a timeout' ($ev2.Count -eq $ev.Count) "timeout events grew from $($ev.Count) to $($ev2.Count)"

# ---- 3. the OTHER half of the same defect: bin/git-autosync.ps1's G / Invoke-GitBounded ----------
# The daemon runs every 15 min x 24 repos, so an unbounded verb there is the same wedge with a
# 15-minute repetition trigger. G is the wrapper every call site uses: a NETWORK verb (first
# non-dash token in fetch|push|ls-remote|clone|pull) goes through Invoke-GitBounded, every LOCAL
# verb must stay byte-identical to `& git ...` because the callers parse ls-tree -r -z, cat-file
# and diff-tree. The two functions are extracted with the AST by NAME, so this never runs the
# daemon's main body and does not break when the file's line numbers move.
$auto = Join-Path $PSScriptRoot '..\bin\git-autosync.ps1'
$auto = (Resolve-Path $auto).Path
$autoAst = [System.Management.Automation.Language.Parser]::ParseFile($auto, [ref]$null, [ref]$null)
$fns = @($autoAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in @('G', 'Invoke-GitBounded') }, $true))
foreach ($fn in $fns) { . ([scriptblock]::Create($fn.Extent.Text)) }
Check 'git-autosync G and Invoke-GitBounded are extractable by AST' ($fns.Count -eq 2) "found $($fns.Count) of 2"

if ($fns.Count -eq 2) {
  # 3a. local verb: verbatim args, verbatim result (the callers parse it).
  $sha = G $repo rev-parse HEAD
  Check 'autosync local verb returns the sha' ("$sha" -match '^[0-9a-f]{40}$') "got '$sha'"
  $sha2 = G $repo -c core.autocrlf=false rev-parse HEAD
  Check 'autosync keeps arguments verbatim (a -c flag before the verb still reaches git)' ("$sha2" -match '^[0-9a-f]{40}$') "got '$sha2'"

  # 3b. network verb: still works, and returns git's lines.
  $ls = @(G $repo ls-remote origin)
  Check 'autosync network verb returns the refs' (@($ls | Where-Object { $_ -match 'refs/heads/main' }).Count -ge 1) "got '$($ls -join '|')'"
  Check 'autosync network verb succeeded' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"

  # 3c. the wedge: killed at the bound, exit 124, and the diagnostic goes to the stderr a job log keeps.
  git -C $repo remote set-url origin "ext::pwsh -NoProfile -File $hang %S"
  $env:AGENTQ_GIT_NET_TIMEOUT_SEC = '5'
  $errSw = [IO.StringWriter]::new(); $origErr = [Console]::Error; [Console]::SetError($errSw)
  try {
    $sw3 = [Diagnostics.Stopwatch]::StartNew()
    $null = G $repo fetch -q
    $sw3.Stop(); $killExit = $LASTEXITCODE
  } finally {
    [Console]::SetError($origErr); Remove-Item Env:\AGENTQ_GIT_NET_TIMEOUT_SEC -ErrorAction SilentlyContinue
  }
  Check 'autosync kills a wedged network verb at the bound' ($sw3.ElapsedMilliseconds -lt 40000) "took $($sw3.ElapsedMilliseconds) ms"
  Check 'autosync reports the kill as exit 124' ($killExit -eq 124) "exit=$killExit"
  Check 'autosync writes the kill diagnostic to stderr' ([bool]("$($errSw.ToString())" -match 'did not finish in 5s')) "stderr='$("$($errSw.ToString())".Trim())'"
  git -C $repo remote set-url origin $bare
  $null = G $repo fetch -q
  Check 'autosync control: a healthy fetch is not killed' ($LASTEXITCODE -eq 0) "exit=$LASTEXITCODE"
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Write-Host "fail=$fail"
exit ([int]($fail -gt 0))
