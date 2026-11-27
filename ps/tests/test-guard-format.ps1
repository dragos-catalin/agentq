# guard-tooluse.ps1 formatter rule (2026-11-24): a formatter run over files the agent did not write
# must not silently apply the tool's DEFAULTS. Denies when the target repo declares no config for
# that formatter; warns about the cross-checkout "mixture tell". Then MUTATION tests: the no-config
# branch is disabled in a copy of the guard and the deny cases must start to pass through.
# PostToolUse auto-format (2026-11-25): the other half - a file CREATED into a repo that owns
# formatter settings is formatted FOR the agent, instead of the agent being refused later.
#
# 2026-11-26 - PARALLEL. As ONE serial process this suite spent ~141 s on a loaded machine, almost
# all of it waiting on ~52 short-lived child PowerShell processes (every case spawns the guard). The
# cases now run as separate WORKER PROCESSES of this same file (`-Group <name>`), each with its own
# temp dir, and the orchestrator aggregates their PASS/FAIL lines. Why workers of THIS file and not
# sibling files: install.ps1 maps exactly ONE file into the installed tree
# (tests\test-guard-format.ps1 -> hooks\test-guard-format.ps1) and the install-wiring gate pins that
# map, so a new sibling file would break the INSTALLED gate while the checkout looked green. Why the
# orchestrator re-enters itself with `-Group`: the case table then lives in exactly ONE place, so a
# shard can never drift from the list it was split from.
# Nothing is weakened: the same cases, the same ids, the same mutation checks - plus a ratchet that
# FAILS if any of the 54 ids a passing run must exercise stops being exercised (a lost case is now a
# RED suite instead of a quieter one).
[CmdletBinding()]
param(
  # '..\hooks\' resolves in BOTH layouts: the repo runs it as ps\tests\..\hooks\guard-tooluse.ps1, the
  # install maps it to hooks\test-guard-format.ps1 next to the guard itself. The bare default (PSScriptRoot)
  # only worked once installed, so a hand-run in the repo died with "Cannot find path ...ps\tests\guard-tooluse.ps1".
  [string]$Guard = (Join-Path $PSScriptRoot '..\hooks\guard-tooluse.ps1'),
  # The hooks run under powershell.exe 5.1 (that is what VS Code spawns), so the suite must be
  # runnable with it too: pwsh 7 accepting a script says nothing about the shell that runs it.
  [string]$Exe = 'pwsh',
  # 'auto' = ORCHESTRATOR: spawn one worker per group and aggregate. A group name = run ONLY that group
  # in THIS process, which is how the orchestrator re-enters itself (see the header).
  [ValidateSet('auto', 'block-1', 'block-2', 'block-3', 'guard-mutation', 'allow-list', 'post')]
  [string]$Group = 'auto',
  # The orchestrator hands every worker its OWN temp dir, so no two workers can share a fixture.
  [string]$WorkDir = '',
  # 0 = one worker per group, all at once; 1 = serial (identical results, for a saturated machine).
  # AGENTQ_GUARD_FORMAT_WORKERS overrides when -Workers is not given.
  [int]$Workers = 0,
  # Print the check ids this suite will exercise, then exit 0. The before/after evidence for a split.
  [switch]$List,
  [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$Guard = (Resolve-Path $Guard).Path
$script:Exe = $Exe
$script:fails = 0
$script:pass = 0
$script:ids = New-Object System.Collections.Generic.List[string]
$script:idFile = ''
# One place that answers "where does this fixture live", because the obvious answer is a trap.
# `[IO.Path]::GetTempPath()` THROWS when TEMP and TMP are both empty - measured 2026-11-27:
#   Exception calling "GetTempPath" with "0" argument(s): "The filename, directory name, or volume
#   label syntax is incorrect. : ''."
# The old code let that escape from a bare `Join-Path ([IO.Path]::GetTempPath()) 'gf-...'`, so no
# fixture root was ever created and every -WorkDir handed to a worker became a RELATIVE path: the
# workers then created their fixtures in the process's CWD. That is how 325 junk directories appeared
# at the codai repo root (had to be quarantined by hand; a full disc walk found them).
# This helper always returns an ABSOLUTE, EXISTING directory, and asserts it - a silently relative
# root is what turns a test fixture into litter, and the assertion is cheaper than finding it twice.
function Get-FixtureRoot([string]$Prefix) {
  $base = $null
  try { $base = [IO.Path]::GetTempPath() } catch { $base = $null }
  if (-not $base -or -not "$base".Trim()) { $base = $env:USERPROFILE }
  if (-not $base -or -not "$base".Trim()) { $base = $env:TEMP }
  if (-not $base -or -not "$base".Trim()) { $base = (Get-Location).ProviderPath }
  if (-not [IO.Path]::IsPathRooted($base)) { $base = Join-Path (Get-Location).ProviderPath $base }
  $d = Join-Path $base ($Prefix + [guid]::NewGuid().ToString('N').Substring(0, 6))
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  if (-not [IO.Path]::IsPathRooted($d)) { throw "fixture root is not absolute: '$d' (base '$base')" }
  return $d
}
# PASS/FAIL is the contract run-all.ps1 counts ('^\s*(PASS|ok)\b' vs '^\s*FAIL\b') - never change it.
function Check([string]$n, [bool]$ok, [string]$d = '') {
  if ($ok) { Write-Host "PASS $n"; $script:pass++ } else { Write-Host "FAIL $n $d" -ForegroundColor Red; $script:fails++ }
  $script:ids.Add($n)
}
# The two ids of the block loop. The spacing (2 and 13 spaces) is the ORIGINAL spacing, kept so the id
# set stays byte-identical to the pre-parallel suite - the before/after evidence depends on it.
function BlockId([bool]$b, [string]$k) { "block=$b  $k" }
function WarnId([string]$k) { "warn             $k" }

function New-Repo([string]$root, [string]$name) {
  $d = Join-Path $root $name
  New-Item -ItemType Directory -Force -Path "$d\src" | Out-Null
  & git -C $d init -q 2>$null | Out-Null
  Set-Content -LiteralPath "$d\src\a.ts" -Value 'export const a = 1;'
  Set-Content -LiteralPath "$d\package.json" -Value '{"name":"fx","devDependencies":{"prettier":"3.6.2","eslint":"9.0.0"},"scripts":{"format":"prettier --write \"**/*.{ts,tsx,md,json}\"","lint:fix":"eslint --fix .","typecheck":"tsc --noEmit"}}'
  return $d
}
# The fixtures, built by the WORKER into its own temp dir (one dir per worker, so nothing is shared):
# cfgless: prettier+eslint declared, NO config anywhere (brivio's shape, measured 40/40 dirty).
# withcfg: same repo, with a root prettier config + an eslint config + a rustfmt config (SOFT class).
# deepcfg: the config lives in the app package, not the repo root (monorepo shape).
function New-Fixtures([string]$root, [string[]]$names) {
  $fx = @{}
  foreach ($n in $names) {
    if ($n -eq 'cfgless') { $fx.cfgless = New-Repo $root 'cfgless' }
    elseif ($n -eq 'withcfg') {
      $d = New-Repo $root 'withcfg'
      Set-Content -LiteralPath "$d\.prettierrc.json" -Value '{}'
      Set-Content -LiteralPath "$d\eslint.config.mjs" -Value 'export default [];'
      Set-Content -LiteralPath "$d\rustfmt.toml" -Value 'max_width = 100'
      $fx.withcfg = $d
    }
    elseif ($n -eq 'deepcfg') {
      $d = New-Repo $root 'deepcfg'
      New-Item -ItemType Directory -Force -Path "$d\apps\web\src" | Out-Null
      Set-Content -LiteralPath "$d\apps\web\.prettierrc.json" -Value '{}'
      Set-Content -LiteralPath "$d\apps\web\src\b.ts" -Value 'export const b = 1;'
      $fx.deepcfg = $d
    }
  }
  return $fx
}

# Returns $true when the guard BLOCKS (VS Code dialect: JSON deny on stdout, exit 0).
function Hook([string]$g, [string]$cwd, [string]$command, [string]$tool = 'run_in_terminal') {
  $p = @{ hook_event_name = 'PreToolUse'; tool_name = $tool; cwd = $cwd; tool_input = @{ command = $command } } | ConvertTo-Json -Compress
  # stderr too: non-blocking advisories reach the agent there (hook-pre collects child stderr and
  # re-emits it on the allow path); the deny JSON is on stdout.
  # Under powershell.exe 5.1 a native command that writes to stderr raises NativeCommandError, and
  # with $ErrorActionPreference='Stop' (set above) that TERMINATES the suite before it reads the
  # verdict - the guard's own message killed the test. Continue for the duration of the call.
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { $out = ($p | & $Exe -NoProfile -File $g 2>&1) -join '' }
  finally { $ErrorActionPreference = $prev }
  return $out
}
function HookDenies([string]$out) { $out -match '"permissionDecision":"deny"' }
function Blocks([string]$g, [string]$cwd, [string]$command) { HookDenies (Hook $g $cwd $command) }
function Warns([string]$g, [string]$cwd, [string]$command) { (Hook $g $cwd $command) -match 'WARNING \(guard-command\)' }

# The case table lives in ONE place; the worker shards are DERIVED from it (Get-BlockShards), so a new
# case can never be dropped by the split. The cwd values are the fixture variables the WORKER assigns
# at script scope before this function is called.
function Get-Cases {
  return [ordered]@{
  # --- the destructive class: formatter WITHOUT the repo's config (defaults) -> deny
  'npx prettier --write (no cfg)'      = @{ cwd = $cfgless; cmd = 'npx prettier --write src/a.ts'; block = $true }
  'pnpm exec prettier --write (no cfg)' = @{ cwd = $cfgless; cmd = 'pnpm exec prettier --write src/a.ts'; block = $true }
  'prettier --write glob (no cfg)'     = @{ cwd = $cfgless; cmd = 'npx prettier --write "src/**/*.ts"'; block = $true }
  'pnpm format (no cfg)'               = @{ cwd = $cfgless; cmd = 'pnpm format'; block = $true }
  'eslint --fix (no cfg)'              = @{ cwd = $cfgless; cmd = 'npx eslint --fix src/a.ts'; block = $true }
  'cli prettier.cmd --write (no cfg)'  = @{ cwd = $cfgless; cmd = '& .\node_modules\.bin\prettier.cmd --write src/a.ts'; block = $true }
  # --- the same invocations where a config EXISTS -> allowed
  'npx prettier --write (cfg)'         = @{ cwd = $withcfg; cmd = 'npx prettier --write src/a.ts'; block = $false }
  'eslint --fix (cfg)'                 = @{ cwd = $withcfg; cmd = 'npx eslint --fix src/a.ts'; block = $false }
  'pnpm format (cfg)'                  = @{ cwd = $withcfg; cmd = 'pnpm format'; block = $false }
  'prettier --write, cfg in app pkg'   = @{ cwd = $deepcfg; cmd = 'npx prettier --write apps/web/src/b.ts'; block = $false }
  # --- non-writing / non-formatter commands are untouched
  'prettier --check (no cfg)'          = @{ cwd = $cfgless; cmd = 'npx prettier --check src/a.ts'; block = $false }
  'pnpm typecheck'                     = @{ cwd = $cfgless; cmd = 'pnpm typecheck'; block = $false }
  'git diff --stat'                     = @{ cwd = $cfgless; cmd = 'git diff --stat'; block = $false }
  'non-formatter codegen'              = @{ cwd = $cfgless; cmd = 'npx drizzle-kit generate'; block = $false }
  # --- clang-format has a universal config convention -> STRICT
  'clang-format -i (no cfg)'           = @{ cwd = $cfgless; cmd = 'clang-format -i src/a.cpp'; block = $true }
  'clang-format --dry-run'             = @{ cwd = $cfgless; cmd = 'clang-format --dry-run --Werror src/a.cpp'; block = $false }
  # --- gofmt/rustfmt/ktlint: no config file at all (or an optional one) and the defaults ARE the
  #     community style, so a refusal would block normal work -> advisory, never a block
  'gofmt -w (no cfg)'                  = @{ cwd = $cfgless; cmd = 'gofmt -w src/main.go'; block = $false; warn = $true }
  'cargo fmt (no rustfmt.toml)'        = @{ cwd = $cfgless; cmd = 'cargo fmt'; block = $false; warn = $true }
  'ktfmt (no cfg)'                     = @{ cwd = $cfgless; cmd = 'ktfmt src/Main.kt'; block = $false; warn = $true }
  # --- check-only runs of the soft class stay silent
  'rustfmt --check'                    = @{ cwd = $cfgless; cmd = 'rustfmt --check src/main.rs'; block = $false }
  'cargo fmt --check'                  = @{ cwd = $cfgless; cmd = 'cargo fmt --check'; block = $false }
  # --- soft class WITH its config: allowed
  'cargo fmt (rustfmt.toml)'           = @{ cwd = $withcfg; cmd = 'cargo fmt'; block = $false }
  # --- cross-checkout "mixture tell" -> warning, not a deny
  'missing path under cfg repo'        = @{ cwd = $withcfg; cmd = 'npx prettier --write apps/hub/lib/session-cost-model.ts'; block = $false; warn = $true }
  # --- Python / Godot / Swift / zig (2026-11-25): recognised, but SOFT - their defaults ARE the
  #     community style, so a refusal would block normal work. Recognising them is what makes the
  #     blast-radius warning and the "mixture tell" fire for them too.
  'ruff format (no cfg)'               = @{ cwd = $cfgless; cmd = 'ruff format src/a.py'; block = $false; warn = $true }
  'black (no cfg)'                     = @{ cwd = $cfgless; cmd = 'black src/a.py'; block = $false; warn = $true }
  'gdformat (no cfg)'                  = @{ cwd = $cfgless; cmd = 'gdformat script.gd'; block = $false; warn = $true }
  'swiftformat (no cfg)'               = @{ cwd = $cfgless; cmd = 'swiftformat Sources/App.swift'; block = $false; warn = $true }
  'zig fmt (no cfg)'                   = @{ cwd = $cfgless; cmd = 'zig fmt src/main.zig'; block = $false; warn = $true }
  # `black` is an ordinary English word: a node script called black must NOT be judged as the tool.
  'node black.mjs is not black'        = @{ cwd = $cfgless; cmd = 'node black.mjs'; block = $false }
  # check-only runs of the Python class stay silent
  'black --check'                      = @{ cwd = $cfgless; cmd = 'black --check src/a.py'; block = $false }
  # --- the COMMAND states the style itself -> the rule does not apply (item 4 of the refusal text)
  'prettier --write --config (no cfg)' = @{ cwd = $cfgless; cmd = 'npx prettier --write --config .prettierrc.custom.json src/a.ts'; block = $false }
  }
}

# Split the block cases in SOURCE ORDER across 3 shards, derived from the table itself so a new case
# can never fall between the shards (the id ratchet catches it if one ever does).
function Get-BlockShards {
  $keys = @((Get-Cases).Keys)
  $per = [int][math]::Ceiling($keys.Count / 3.0)
  $out = [ordered]@{}
  for ($i = 0; $i -lt 3; $i++) {
    $slice = @($keys | Select-Object -Skip ($i * $per) -First $per)
    if ($slice.Count) { $out["block-$($i + 1)"] = $slice }
  }
  return $out
}
function Get-GroupCases([string]$g) {
  $s = Get-BlockShards
  if ($s.Contains($g)) { return $s[$g] }
  return @()
}
function Invoke-BlockGroup([string]$g, [string]$fx) {
  $fxr = New-Fixtures $fx @('cfgless', 'withcfg', 'deepcfg')
  $script:cfgless = $fxr.cfgless; $script:withcfg = $fxr.withcfg; $script:deepcfg = $fxr.deepcfg
  $cases = Get-Cases
  foreach ($k in (Get-GroupCases $g)) {
    $c = $cases[$k]
    # ONE spawn per case: the block verdict and the advisory are read off the SAME output (the
    # pre-parallel suite spawned twice per warn case - same verdict, twice the wait).
    $out = Hook $Guard $c.cwd $c.cmd
    # A BLANK capture is not a verdict. The guard writes its refusal/advisory to stderr and exits 0,
    # so an empty result means the child never ran (or lost its stdin payload - guard-tooluse.ps1:38
    # `catch { Flush-Stderr; exit 0 }` on an unparseable payload), NOT that the rule said nothing.
    # Measured in the cloud land-gate pool on 2026-11-27 under load: ONE case in 54 came back empty
    # and failed the whole gate, while the byte-identical tree passed the two runs either side of it.
    # Re-run it ONCE, and only for a case that MUST produce output (`block` writes the deny JSON on
    # stdout, `warn` the advisory on stderr): a real regression always produces output, so the retry
    # cannot hide one, and the ~15 cases whose CORRECT answer is silence pay no extra spawn.
    if (-not "$out".Trim() -and ($c.block -or $c.warn)) { $out = Hook $Guard $c.cwd $c.cmd }
    $b = HookDenies $out
    Check (BlockId $c.block $k) ($b -eq $c.block) "(got block=$b)"
    if ($c.warn) { Check (WarnId $k) ($out -match 'WARNING \(guard-command\)') ("took: " + ((("$out").Trim() -split '\r?\n' | Where-Object { $_ } | Select-Object -First 1) -join '')) }
  }
}

# ---- mutation: disable the no-config branch; the deny cases must stop blocking ----
function Invoke-GuardMutation([string]$fx) {
  $fxr = New-Fixtures $fx @('cfgless')
  $script:cfgless = $fxr.cfgless
  $cases = Get-Cases
  $mut = Join-Path $fx 'guard-mut.ps1'
  $text = [IO.File]::ReadAllText($Guard)
  $needle = 'if (-not $fmtCfg) {'
  if (([regex]::Matches($text, [regex]::Escape($needle))).Count -ne 1) { Check 'mutation anchor found once' $false }
  else {
    [IO.File]::WriteAllText($mut, $text.Replace($needle, 'if ($false) {'), (New-Object Text.UTF8Encoding $false))
    $worse = 0
    foreach ($k in @('npx prettier --write (no cfg)', 'pnpm format (no cfg)', 'eslint --fix (no cfg)', 'prettier --write glob (no cfg)')) {
      if (Blocks $mut $cfgless $cases[$k].cmd) { $worse++ }
    }
    Check 'mutation: all 4 deny cases pass through with the branch disabled' ($worse -eq 0) "($worse still blocked)"
  }
}

# ---- owner allow-list (2026-11-25) ---------------------------------------------------------------
# ~/.codai/guard/formatter-allow.json is machine-local and read from $HOME, so the case needs its
# OWN home - otherwise it would read (and prove nothing about) the real machine file. The first
# assertion is deliberately the NEGATIVE one: the same invocation, in the same temp home, without
# the file must still block, or a broken repo resolution could pass this section vacuously.
function HookHome([string]$g, [string]$cwd, [string]$command, [string]$fakeHome) {
  $p = @{ hook_event_name = 'PreToolUse'; tool_name = 'run_in_terminal'; cwd = $cwd; tool_input = @{ command = $command } } | ConvertTo-Json -Compress
  $keep = @{ USERPROFILE = $env:USERPROFILE; HOME = $env:HOME; HOMEDRIVE = $env:HOMEDRIVE; HOMEPATH = $env:HOMEPATH }
  $prev = $ErrorActionPreference
  try {
    $ErrorActionPreference = 'Continue'
    $env:USERPROFILE = $fakeHome; $env:HOME = $fakeHome
    $env:HOMEDRIVE = (Split-Path -Qualifier $fakeHome); $env:HOMEPATH = $fakeHome.Substring(2)
    return (($p | & $Exe -NoProfile -File $g 2>&1) -join '')
  } finally {
    $env:USERPROFILE = $keep.USERPROFILE; $env:HOME = $keep.HOME; $env:HOMEDRIVE = $keep.HOMEDRIVE; $env:HOMEPATH = $keep.HOMEPATH
    $ErrorActionPreference = $prev
  }
}
function Invoke-AllowList([string]$fx) {
  $fxr = New-Fixtures $fx @('cfgless')
  $script:cfgless = $fxr.cfgless
  $th = Join-Path $fx 'home'
  New-Item -ItemType Directory -Force -Path (Join-Path $th '.codai\guard') | Out-Null
  $o0 = HookHome $Guard $cfgless 'npx prettier --write src/a.ts' $th
  Check 'allow-list: still blocks with no entry' ($o0 -match '"permissionDecision":"deny"') $o0
  Set-Content -LiteralPath (Join-Path $th '.codai\guard\formatter-allow.json') -Value (@{ repos = @($cfgless) } | ConvertTo-Json)
  $o1 = HookHome $Guard $cfgless 'npx prettier --write src/a.ts' $th
  Check 'allow-list: the deny is suppressed' (-not ($o1 -match '"permissionDecision":"deny"')) $o1
  Check 'allow-list: a NOTE explains why' ($o1 -match 'formatter-allow\.json') $o1
  Check 'allow-list: the decision is audited' (Test-Path -LiteralPath (Join-Path $th '.codai\guard\formatter.jsonl'))
}

# ---- PostToolUse auto-format (2026-11-25) --------------------------------------------------------
# The other half of the rule, and the owner's question: when the repo OWNS the settings, a created
# file is formatted FOR the agent instead of the agent being told off later. Same lib as the guard,
# so the two cannot disagree. A fake formatter (a .cmd shim that appends a marker to its LAST
# argument) proves which file was written without needing the real tool installed.
function Invoke-Post([string]$fx) {
  $fxr = New-Fixtures $fx @('cfgless', 'withcfg')
  $script:cfgless = $fxr.cfgless; $script:withcfg = $fxr.withcfg
  $postHook = Join-Path (Split-Path $Guard -Parent) 'post-create-format.ps1'
if (-not (Test-Path -LiteralPath $postHook)) {
  Check 'post-create-format.ps1 exists next to the guard' $false
} else {
  $shim = "@echo off`r`nsetlocal`r`n:loop`r`nif `"%~1`"==`"`" goto end`r`nset LAST=%~1`r`nshift`r`ngoto loop`r`n:end`r`necho // FORMATTED>>`"%LAST%`"`r`n"
  # $HOME is overridden so the hook's text throttle (<HOME>\.codai\created-format\<sid>) is scoped
  # to the fixture, and the case still shows it is a throttle and not a lost message.
  function PostHook([string]$h, [string]$file, [string]$toolName, [string]$sid, [string]$fakeHome) {
    $pp = @{ tool_name = $toolName; tool_input = @{ filePath = $file }; session_id = $sid } | ConvertTo-Json -Compress -Depth 5
    $keep = @{ USERPROFILE = $env:USERPROFILE; HOME = $env:HOME; HOMEDRIVE = $env:HOMEDRIVE; HOMEPATH = $env:HOMEPATH }
    $prev = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      if ($fakeHome) {
        $env:USERPROFILE = $fakeHome; $env:HOME = $fakeHome
        $env:HOMEDRIVE = (Split-Path -Qualifier $fakeHome); $env:HOMEPATH = $fakeHome.Substring(2)
      }
      return (($pp | & $Exe -NoProfile -File $h 2>&1) -join '')
    } finally {
      $env:USERPROFILE = $keep.USERPROFILE; $env:HOME = $keep.HOME; $env:HOMEDRIVE = $keep.HOMEDRIVE; $env:HOMEPATH = $keep.HOMEPATH
      $ErrorActionPreference = $prev
    }
  }
  foreach ($r in @($cfgless, $withcfg)) {
    New-Item -ItemType Directory -Force -Path "$r\node_modules\.bin" | Out-Null
    Set-Content -LiteralPath "$r\node_modules\.bin\prettier.cmd" -Value $shim -Encoding ascii
  }
  # Its OWN home: the allow-list section above deliberately exempts $cfgless in $th, and reading that
  # file here would make "a config-less repo is left alone" fail for a correct reason (measured).
  $th2 = Join-Path $fx 'home2'
  New-Item -ItemType Directory -Force -Path (Join-Path $th2 '.codai\guard') | Out-Null
  $sid1 = 'pcf-' + [guid]::NewGuid().ToString('N')
  $p1 = Join-Path $withcfg 'src\c1.ts'; Set-Content -LiteralPath $p1 -Value 'export const a=1'
  $r1 = PostHook $postHook $p1 'create_file' $sid1 $th2
  Check 'post: a config-owning repo formats the created file' ((Get-Content -LiteralPath $p1 -Raw) -match 'FORMATTED')
  Check 'post: the agent is told, as PostToolUse JSON' ($r1 -match 'hookEventName":"PostToolUse' -and $r1 -match 'additionalContext' -and $r1 -match 'prettier') $r1
  $p1b = Join-Path $withcfg 'src\c1b.ts'; Set-Content -LiteralPath $p1b -Value 'export const a=1'
  $r1b = PostHook $postHook $p1b 'create_file' $sid1 $th2
  Check 'post: the file is still formatted on the next create' ((Get-Content -LiteralPath $p1b -Raw) -match 'FORMATTED')
  Check 'post: but the text is throttled per session' (-not $r1b.Trim()) $r1b
  $p2 = Join-Path $cfgless 'src\c2.ts'; Set-Content -LiteralPath $p2 -Value 'export const a=1'
  $r2 = PostHook $postHook $p2 'create_file' $sid1 $th2
  Check 'post: a config-less repo is left alone' (-not ((Get-Content -LiteralPath $p2 -Raw) -match 'FORMATTED'))
  Check 'post: and says nothing' (-not $r2.Trim()) $r2
  $p3 = Join-Path $withcfg 'src\c3.ts'; Set-Content -LiteralPath $p3 -Value 'export const a=1'
  $r3 = PostHook $postHook $p3 'apply_patch' $sid1 $th2
  Check 'post: apply_patch is a targeted edit, never touched' (-not ((Get-Content -LiteralPath $p3 -Raw) -match 'FORMATTED'))
  $r4 = ('not json' | & $Exe -NoProfile -File $postHook 2>&1) -join ''
  Check 'post: a garbage payload is silent (fail-open)' (-not $r4.Trim()) $r4
  # mutation: with the ownership test disabled, the config-less repo WOULD be rewritten - which is
  # exactly the incident this pair of hooks exists for. Proves the branch is load-bearing.
  $needle2 = 'if (-not $owns -and -not (Test-FormatterDefaultIsCanonical $cand) -and -not $repAllowsDefaults) { continue }'
  $t2 = [IO.File]::ReadAllText($postHook)
  if (([regex]::Matches($t2, [regex]::Escape($needle2))).Count -ne 1) { Check 'post mutation anchor found once' $false }
  else {
    # The copy must live where the hook expects `lib\` next to it, or it dies on the dot-source and
    # fail-opens - which would make this assertion pass for the wrong reason (measured 2026-11-25).
    $mutDir = Join-Path $fx 'mut'
    New-Item -ItemType Directory -Force -Path (Join-Path $mutDir 'lib') | Out-Null
    Copy-Item -LiteralPath (Join-Path (Split-Path $Guard -Parent) 'lib\FormatterConfig.ps1') -Destination (Join-Path $mutDir 'lib\FormatterConfig.ps1') -Force
    $mut2 = Join-Path $mutDir 'post-create-format.ps1'
    [IO.File]::WriteAllText($mut2, $t2.Replace($needle2, '$null = $null'), (New-Object Text.UTF8Encoding $false))
    $p4 = Join-Path $cfgless 'src\c4.ts'; Set-Content -LiteralPath $p4 -Value 'export const a=1'
    $null = PostHook $mut2 $p4 'create_file' $sid1 $th2
    Check 'post mutation: without the ownership test a config-less repo WOULD be rewritten' ((Get-Content -LiteralPath $p4 -Raw) -match 'FORMATTED')
  }
}
}

# ---- the coverage ratchet --------------------------------------------------------------------------
# The ids a PASSING run must exercise: 31 case names + 9 advisories + the 14 fixed ids = 54. FROZEN on
# purpose - deriving them from the case table would make DELETING a case invisible, because the expected
# set would shrink with it. A lost case is worse than a slow suite, so this list only ever grows: update
# it when you ADD or RENAME a case, and the suite goes red if a case stops being exercised.
$script:baselineCases = @(
  'npx prettier --write (no cfg)'
  'pnpm exec prettier --write (no cfg)'
  'prettier --write glob (no cfg)'
  'pnpm format (no cfg)'
  'eslint --fix (no cfg)'
  'cli prettier.cmd --write (no cfg)'
  'npx prettier --write (cfg)'
  'eslint --fix (cfg)'
  'pnpm format (cfg)'
  'prettier --write, cfg in app pkg'
  'prettier --check (no cfg)'
  'pnpm typecheck'
  'git diff --stat'
  'non-formatter codegen'
  'clang-format -i (no cfg)'
  'clang-format --dry-run'
  'gofmt -w (no cfg)'
  'cargo fmt (no rustfmt.toml)'
  'ktfmt (no cfg)'
  'rustfmt --check'
  'cargo fmt --check'
  'cargo fmt (rustfmt.toml)'
  'missing path under cfg repo'
  'ruff format (no cfg)'
  'black (no cfg)'
  'gdformat (no cfg)'
  'swiftformat (no cfg)'
  'zig fmt (no cfg)'
  'node black.mjs is not black'
  'black --check'
  'prettier --write --config (no cfg)'
)
$script:baselineWarn = @(
  'gofmt -w (no cfg)'
  'cargo fmt (no rustfmt.toml)'
  'ktfmt (no cfg)'
  'missing path under cfg repo'
  'ruff format (no cfg)'
  'black (no cfg)'
  'gdformat (no cfg)'
  'swiftformat (no cfg)'
  'zig fmt (no cfg)'
)
# The 14 ids that do not come from the case table.
$script:fixedIds = @(
  'mutation: all 4 deny cases pass through with the branch disabled'
  'allow-list: still blocks with no entry'
  'allow-list: the deny is suppressed'
  'allow-list: a NOTE explains why'
  'allow-list: the decision is audited'
  'post: a config-owning repo formats the created file'
  'post: the agent is told, as PostToolUse JSON'
  'post: the file is still formatted on the next create'
  'post: but the text is throttled per session'
  'post: a config-less repo is left alone'
  'post: and says nothing'
  'post: apply_patch is a targeted edit, never touched'
  'post: a garbage payload is silent (fail-open)'
  'post mutation: without the ownership test a config-less repo WOULD be rewritten'
)
function Get-RequiredIds {
  $o = New-Object System.Collections.Generic.List[string]
  foreach ($k in $script:baselineCases) { $o.Add("case $k") }
  foreach ($k in $script:baselineWarn) { $o.Add("warn $k") }
  foreach ($f in $script:fixedIds) { $o.Add($f) }
  return $o
}
# An EMITTED id -> its REQUIRED form. block=... carries the expectation and warn... the alignment, so both
# are compared by CASE NAME: flipping an expectation is deliberate and must not trip the ratchet.
function Get-NormalizedId([string]$id) {
  if ($id -match '^block=\S+\s\s(.+)$') { return "case $($Matches[1])" }
  if ($id -match '^warn\s+(.+)$') { return "warn $($Matches[1])" }
  return $id
}

if ($List) {
  $cases = Get-Cases
  $ids = New-Object System.Collections.Generic.List[string]
  foreach ($k in $cases.Keys) { $ids.Add((BlockId $cases[$k].block $k)) }
  foreach ($k in $cases.Keys) { if ($cases[$k].warn) { $ids.Add((WarnId $k)) } }
  foreach ($f in $script:fixedIds) { $ids.Add($f) }
  foreach ($id in $ids) { Write-Host $id }
  Write-Host ("guard-format: " + $ids.Count + " emitted check ids")
  exit 0
}

# ---------------------------------------------------------------- worker: run ONE group in this process
if ($Group -ne 'auto') {
  $fx = if ($WorkDir) { $WorkDir } else { Get-FixtureRoot 'gf-' }
  $ownDir = -not $WorkDir
  New-Item -ItemType Directory -Force -Path $fx | Out-Null
  $script:idFile = Join-Path $fx 'ids.txt'
  try {
    switch ($Group) {
      'block-1' { Invoke-BlockGroup $Group $fx }
      'block-2' { Invoke-BlockGroup $Group $fx }
      'block-3' { Invoke-BlockGroup $Group $fx }
      'guard-mutation' { Invoke-GuardMutation $fx }
      'allow-list' { Invoke-AllowList $fx }
      'post' { Invoke-Post $fx }
    }
  } finally {
    # Always leave the emitted ids behind: the orchestrator reads them for the coverage ratchet.
    try { [IO.File]::WriteAllLines($script:idFile, $script:ids) } catch { }
    if ($ownDir -and -not $KeepWork) { Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue }
  }
  if ($script:fails) { Write-Host "$($script:fails) failure(s)" -ForegroundColor Red; exit 1 }
  exit 0
}

# -------------------------------------------------------------------------------------------- orchestrator
function Get-HostExe {
  $p = $null
  try { $p = (Get-Process -Id $PID).Path } catch { }
  if (-not $p) { try { $p = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { } }
  if (-not $p) { $p = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' } }
  return $p
}
function Quote-Arg([string]$a) { if ($a -match '\s') { return '"' + $a + '"' } return $a }

$order = @((Get-BlockShards).Keys) + @('guard-mutation', 'allow-list', 'post')
$w = $Workers
if ($w -le 0 -and $env:AGENTQ_GUARD_FORMAT_WORKERS) { $w = [int]$env:AGENTQ_GUARD_FORMAT_WORKERS }
if ($w -le 0) { $w = $order.Count }
if ($w -gt $order.Count) { $w = $order.Count }
if ($w -lt 1) { $w = 1 }
$root = Get-FixtureRoot 'gf-'
$hostExe = Get-HostExe
$self = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
Write-Host ("guard-format: running $($order.Count) group(s) with $w worker(s) via $hostExe")
$groups = @()
for ($i = 0; $i -lt $order.Count; $i += $w) {
  $running = @()
  foreach ($g in @($order | Select-Object -Skip $i -First $w)) {
    $wd = Join-Path $root $g
    New-Item -ItemType Directory -Force -Path $wd | Out-Null
    $out = Join-Path $root ("$g.out.txt"); $err = Join-Path $root ("$g.err.txt")
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $self, '-Group', $g, '-Guard', $Guard, '-Exe', $Exe, '-WorkDir', $wd)
    try {
      $proc = Start-Process -FilePath $hostExe -ArgumentList (($argv | ForEach-Object { Quote-Arg $_ }) -join ' ') -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    } catch {
      Write-Host ("FAIL group $g could not start: $($_.Exception.Message)") -ForegroundColor Red; $script:fails++
      continue
    }
    $running += [pscustomobject]@{ Group = $g; Proc = $proc; Out = $out; Err = $err; Wd = $wd }
  }
  foreach ($j in $running) { $j.Proc.WaitForExit() }
  $groups += $running
}
# Re-emit every worker line verbatim (run-all.ps1 counts the PASS/FAIL lines) and collect its ids.
foreach ($j in $groups) {
  Write-Host ("# group {0} exit={1}" -f $j.Group, $j.Proc.ExitCode)
  $lines = @()
  if (Test-Path -LiteralPath $j.Out) { $lines += @(Get-Content -LiteralPath $j.Out -Encoding utf8) }
  if ((Test-Path -LiteralPath $j.Err) -and (Get-Item -LiteralPath $j.Err).Length) {
    $lines += @(Get-Content -LiteralPath $j.Err -Encoding utf8 | ForEach-Object { "stderr: $_" })
  }
  foreach ($l in $lines) {
    if ($l -match '^\s*PASS\b') { $script:pass++; Write-Host $l }
    elseif ($l -match '^\s*FAIL\b') { $script:fails++; Write-Host $l -ForegroundColor Red }
    else { Write-Host $l }
  }
  foreach ($id in @(Get-Content -LiteralPath (Join-Path $j.Wd 'ids.txt') -Encoding utf8 -ErrorAction SilentlyContinue)) {
    if ($id) { $script:ids.Add($id) }
  }
  if ($j.Proc.ExitCode -ne 0) { Check ("group {0} exited non-zero" -f $j.Group) $false ("exit=" + $j.Proc.ExitCode) }
}
# The ratchet: every required id has to have been EXERCISED somewhere.
$seen = @{}
foreach ($id in $script:ids) { $seen[(Get-NormalizedId $id)] = $true }
foreach ($id in (Get-RequiredIds)) {
  if (-not $seen.ContainsKey($id)) { Check ("required check not exercised: " + $id) $false }
}
# ...and the case table must still CONTAIN every frozen id. The check above cannot see a case deleted
# from the table if its frozen line was deleted in the same edit; this pair closes that half.
$casesNow = Get-Cases
$tableKeys = @($casesNow.Keys)
foreach ($k in $script:baselineCases) {
  if ($tableKeys -cnotcontains $k) { Check ("baseline case missing from the case table: " + $k) $false }
}
foreach ($k in $script:baselineWarn) {
  if ($tableKeys -cnotcontains $k) { Check ("baseline advisory missing from the case table: " + $k) $false }
  elseif (-not $casesNow[$k].warn) { Check ("case lost its advisory flag: " + $k) $false }
}
$checks = $script:pass + $script:fails
Write-Host ''
if (-not $KeepWork) { Remove-Item -Recurse -Force $root -ErrorAction SilentlyContinue }
if ($script:fails) { Write-Host "$($script:fails) failure(s)" -ForegroundColor Red; exit 1 }
Write-Host ("guard-format: checks=$checks pass=$($script:pass) fail=0 groups=$($order.Count) workers=$w exe=$Exe")
Write-Host "all guard-format cases pass (exe: $Exe)"
exit 0
