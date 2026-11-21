# Second build RESOURCE for script-only builds (2026-11-21): `run-build.ps1 -Class web|scripts`.
#
# Why a RESOURCE and not a lane: `ps/hooks/run-build.ps1` hardcoded `-Resource build`, whose per-repo
# queue has capacity 1, so a 5-second prettier/eslint run waited behind a multi-minute web build. A
# lane is priority only -- two tickets on `build:<repo>` still serialise at capacity 1 -- so `scripts`
# gets its OWN resource name `build:<repo>:scripts`. No agentq change is needed for that: agentq's
# Resolve-Resource returns a 2+-colon string literally and Get-Capacity falls back to 1 for an
# unknown resource (agentq.ps1 ~:422 / ~:509). This suite pins the run-build side of that contract:
#   1. `web` (the default) is UNCHANGED: resource `build`, the given -Lane, `build.lock`, and a mutex
#      with no `-scripts` suffix;
#   2. `scripts` -> resource `build:<repo>:scripts`, lane `quick` (even if -Lane says otherwise), its
#      own lock file and its own mutex;
#   3. the allow-list is the ONLY thing making two classes in one worktree safe, so it must refuse
#      anything that is not `node ...` / `pnpm exec prettier|eslint|oxlint ...`;
#   4. `-Class` reaches BOTH `agentq run` (-Resource / -Lane) and the script's own self re-exec.
#
# It drives the REAL script, never a copy, and takes NO ticket: the mapping is read through `-Plan`
# (print and exit), and the `agentq run` argv is observed with a FAKE agentq at
# `$env:USERPROFILE\.copilot\bin\agentq.ps1` that records its argv and runs nothing. Queueing a real
# `build:*` ticket here would block other agents -- and a scripts ticket also takes `build:machine`,
# because agentq's Expand-Resources adds it to every `build:*`.
# Exit 1 on any failure.
param([string]$RunBuild = (Join-Path $PSScriptRoot '..\hooks\run-build.ps1'))
$ErrorActionPreference = 'Stop'
$RunBuild = (Resolve-Path -LiteralPath $RunBuild).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aqbc-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }

# A throwaway repo: the resource leaf IS the repo name, so it must be known and unique. `git init` is
# enough (the leaf comes from `rev-parse --git-common-dir`, which needs no commit).
$leaf = 'aqbc-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$repo = Join-Path $tmp $leaf
git init -q -b main $repo 2>$null
[IO.File]::WriteAllText("$repo\a.txt", "a`n")

# -Plan prints the class mapping and exits: no ticket, no lock, no build.
function Plan([string[]]$more) {
  $o = @(& pwsh -NoProfile -File $RunBuild -Plan -Root $repo @more 2>&1 | ForEach-Object { "$_" })
  $script:code = $LASTEXITCODE
  $o -join "`n"
}

# A fake agentq records the argv run-build asked `agentq run` for, and runs nothing at all.
$up = Join-Path $tmp 'up'
New-Item -ItemType Directory -Force (Join-Path $up '.copilot\bin') | Out-Null
$fakeOut = Join-Path $tmp 'aq-args.txt'
[IO.File]::WriteAllText((Join-Path $up '.copilot\bin\agentq.ps1'), @'
if ($env:FAKE_AQ_OUT) { [IO.File]::WriteAllText($env:FAKE_AQ_OUT, ($args -join ' ')) }
exit 0
'@)
# The suite must not depend on the OUTER environment: a suite run from inside a build ticket carries
# AGENTQ_HELD=build:... , which makes run-build skip the re-exec and would fail case 4 for the wrong
# reason. Cleared for the child only.
$oldUp = $env:USERPROFILE; $oldHeld = $env:AGENTQ_HELD; $oldNoAq = $env:RUN_BUILD_NO_AGENTQ
$env:FAKE_AQ_OUT = $fakeOut
function Queued([string[]]$more) {
  Remove-Item -LiteralPath $fakeOut -Force -ErrorAction SilentlyContinue
  $env:USERPROFILE = $up; Remove-Item Env:AGENTQ_HELD -ErrorAction SilentlyContinue; Remove-Item Env:RUN_BUILD_NO_AGENTQ -ErrorAction SilentlyContinue
  $o = @(& pwsh -NoProfile -File $RunBuild -Root $repo @more 2>&1 | ForEach-Object { "$_" })
  $script:code = $LASTEXITCODE
  $env:USERPROFILE = $oldUp
  $o -join "`n"
}
function FakeArgs { if (Test-Path -LiteralPath $fakeOut) { (Get-Content -LiteralPath $fakeOut -Raw).Trim() } else { '' } }

try {
  # ---- 1. web (the default) is UNCHANGED ---------------------------------------------------------
  $o = Plan @('-Command', 'pnpm build')
  Check '1 web: exits 0' ($script:code -eq 0) $o
  Check '1 web: resource is exactly build' ($o -match 'class=web\s+resource=build(\s|$)') $o
  Check '1 web: lane stays the -Lane default (gate)' ($o -match 'lane=gate(\s|$)') $o
  Check '1 web: lock file is build.lock' ($o -match 'lock=\S*\\build\.lock(\s|$)') $o
  Check '1 web: the mutex carries no -scripts suffix' (-not ($o -match 'mutex=\S*-scripts')) $o
  $o = Plan @('-Command', 'pnpm build', '-Lane', 'heavy')
  Check '1 web: -Lane is still honoured' ($o -match 'lane=heavy(\s|$)') $o

  # ---- 2. scripts: a second resource, the quick lane, its own lock and mutex ----------------------
  $o = Plan @('-Class', 'scripts', '-Command', 'node --version')
  Check '2 scripts: exits 0 for an allowed command' ($script:code -eq 0) $o
  # ${leaf}: a bare `$leaf:scripts` is parsed as a scope/drive-qualified variable name, not `$leaf`
  # followed by a colon, so the regex would silently be built around an empty value.
  Check '2 scripts: resource is build:<repo>:scripts' ($o -match "class=scripts\s+resource=build:${leaf}:scripts(\s|$)") $o
  Check '2 scripts: lane is quick' ($o -match 'lane=quick(\s|$)') $o
  Check '2 scripts: own lock file (build-scripts.lock)' ($o -match 'lock=\S*\\build-scripts\.lock(\s|$)') $o
  Check '2 scripts: own mutex (...-scripts)' ($o -match 'mutex=\S*-scripts(\s|$)') $o
  $o = Plan @('-Class', 'scripts', '-Command', 'node --version', '-Lane', 'heavy')
  Check '2 scripts: the class pins lane=quick over an explicit -Lane heavy' ($script:code -eq 0 -and $o -match 'lane=quick(\s|$)') $o
  Check '2 scripts: ... and the resource is unchanged by -Lane' ($o -match "resource=build:${leaf}:scripts(\s|$)") $o

  # ---- 3. the allow-list: the only thing making concurrency in one worktree safe -----------------
  $o = Plan @('-Class', 'scripts', '-Command', 'pnpm exec eslint .')
  Check '3 scripts allows pnpm exec eslint' ($script:code -eq 0) $o
  $o = Plan @('-Class', 'scripts', '-Command', 'pnpm exec oxlint --version')
  Check '3 scripts allows pnpm exec oxlint' ($script:code -eq 0) $o
  $o = Plan @('-Class', 'scripts', '-Command', 'pnpm exec prettier --check .')
  Check '3 scripts allows pnpm exec prettier' ($script:code -eq 0) $o
  $o = Plan @('-Class', 'scripts', '-Command', 'pnpm build')
  Check '3 scripts REFUSES pnpm build (exit 2, message says REFUSES)' ($script:code -eq 2 -and $o -match 'REFUSES') $o
  $o = Plan @('-Class', 'scripts', '-Command', 'pnpm typecheck')
  Check '3 scripts REFUSES pnpm typecheck (tsc writes *.tsbuildinfo)' ($script:code -eq 2) $o
  $o = Plan @('-Class', 'scripts', '-Command', 'pnpm lint')
  Check '3 scripts REFUSES `pnpm lint` (only the three pnpm exec forms are allowed)' ($script:code -eq 2) $o
  $o = Plan @('-Class', 'scripts', '-Command', 'nodemon --version')
  Check '3 scripts refuses a command that merely STARTS with the letters node' ($script:code -eq 2) $o
  $o = Plan @('-Class', 'scripts', '-Command', 'pnpm exec vitest run')
  Check '3 scripts refuses another pnpm exec subcommand' ($script:code -eq 2) $o
  # ... and the refusal must not fire for web: a web build is exactly what `pnpm build` is for.
  $o = Plan @('-Command', 'pnpm build')
  Check '3 web is NOT affected by the scripts allow-list' ($script:code -eq 0) $o

  # ---- 4. -Class reaches the queue AND the self re-exec (fake agentq: no ticket is taken) --------
  $o = Queued @('-Class', 'scripts', '-Command', 'node --version')
  $aq = FakeArgs
  Check '4 re-exec: scripts hands agentq the scripts resource' ($script:code -eq 0 -and $aq -match "-Resource build:${leaf}:scripts(\s|$)") "exit=$($script:code) aq='$aq' $o"
  Check '4 re-exec: scripts queues in the quick lane' ($aq -match '-Lane quick(\s|$)') $aq
  Check '4 re-exec: -Class scripts is carried into the SELF re-exec' ($aq -match '-Class scripts(\s|$)') $aq
  Check '4 re-exec: the inner call still waits (-Wait), so the outer owns the log' ($aq -match '(^|\s)-Wait(\s|$)') $aq
  $o = Queued @('-Command', 'pnpm build')
  $aq = FakeArgs
  Check '4 re-exec: web still asks agentq for `-Resource build`' ($script:code -eq 0 -and $aq -match '-Resource build(\s|$)') "exit=$($script:code) aq='$aq'"
  Check '4 re-exec: web is NOT on the scripts resource' (-not ($aq -match ':scripts')) $aq
  Check '4 re-exec: web carries -Class web explicitly' ($aq -match '-Class web(\s|$)') $aq
  Check '4 re-exec: web keeps the given lane' ($aq -match '-Lane gate(\s|$)') $aq

  # ---- 5. a bad -Class is rejected by the binder before anything can run -------------------------
  $o = Plan @('-Class', 'bogus', '-Command', 'node --version')
  Check '5 an unknown -Class is rejected' ($script:code -ne 0 -and $o -match 'bogus') "exit=$($script:code) $o"
} finally {
  $env:USERPROFILE = $oldUp
  if ($oldHeld) { $env:AGENTQ_HELD = $oldHeld } else { Remove-Item Env:AGENTQ_HELD -ErrorAction SilentlyContinue }
  if ($oldNoAq) { $env:RUN_BUILD_NO_AGENTQ = $oldNoAq } else { Remove-Item Env:RUN_BUILD_NO_AGENTQ -ErrorAction SilentlyContinue }
  Remove-Item Env:FAKE_AQ_OUT -ErrorAction SilentlyContinue
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
