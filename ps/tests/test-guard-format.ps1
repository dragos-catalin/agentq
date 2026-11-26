# guard-tooluse.ps1 formatter rule (2026-11-24): a formatter run over files the agent did not write
# must not silently apply the tool's DEFAULTS. Denies when the target repo declares no config for
# that formatter; warns about the cross-checkout "mixture tell". Then MUTATION tests: the no-config
# branch is disabled in a copy of the guard and the deny cases must start to pass through.
param(
  # '..\hooks\' resolves in BOTH layouts: the repo runs it as ps\tests\..\hooks\guard-tooluse.ps1, the
  # install maps it to hooks\test-guard-format.ps1 next to the guard itself. The bare default (PSScriptRoot)
  # only worked once installed, so a hand-run in the repo died with "Cannot find path ...ps\tests\guard-tooluse.ps1".
  [string]$Guard = (Join-Path $PSScriptRoot '..\hooks\guard-tooluse.ps1'),
  # The hooks run under powershell.exe 5.1 (that is what VS Code spawns), so the suite must be
  # runnable with it too: pwsh 7 accepting a script says nothing about the shell that runs it.
  [string]$Exe = 'pwsh'
)
$ErrorActionPreference = 'Stop'
$Guard = (Resolve-Path $Guard).Path
$fx = Join-Path $env:TEMP ('gf-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$fails = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS $n" } else { Write-Host "FAIL $n $d" -ForegroundColor Red; $script:fails++ } }

function New-Repo([string]$name) {
  $d = Join-Path $fx $name
  New-Item -ItemType Directory -Force -Path "$d\src" | Out-Null
  & git -C $d init -q 2>$null | Out-Null
  Set-Content -LiteralPath "$d\src\a.ts" -Value 'export const a = 1;'
  Set-Content -LiteralPath "$d\package.json" -Value '{"name":"fx","devDependencies":{"prettier":"3.6.2","eslint":"9.0.0"},"scripts":{"format":"prettier --write \"**/*.{ts,tsx,md,json}\"","lint:fix":"eslint --fix .","typecheck":"tsc --noEmit"}}'
  return $d
}
# cfgless: prettier+eslint declared, NO config anywhere (brivio's shape, measured 40/40 dirty).
$cfgless = New-Repo 'cfgless'
# withcfg: same repo, with a root prettier config + an eslint config.
$withcfg = New-Repo 'withcfg'
Set-Content -LiteralPath "$withcfg\.prettierrc.json" -Value '{}'
Set-Content -LiteralPath "$withcfg\eslint.config.mjs" -Value 'export default [];'
# deepcfg: the config lives in the app package, not the repo root (monorepo shape).
$deepcfg = New-Repo 'deepcfg'
New-Item -ItemType Directory -Force -Path "$deepcfg\apps\web\src" | Out-Null
Set-Content -LiteralPath "$deepcfg\apps\web\.prettierrc.json" -Value '{}'
Set-Content -LiteralPath "$deepcfg\apps\web\src\b.ts" -Value 'export const b = 1;'
# withcfg also owns a rustfmt config, so the SOFT class is covered in both states.
Set-Content -LiteralPath "$withcfg\rustfmt.toml" -Value 'max_width = 100'

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
function Blocks([string]$g, [string]$cwd, [string]$command) { (Hook $g $cwd $command) -match '"permissionDecision":"deny"' }
function Warns([string]$g, [string]$cwd, [string]$command) { (Hook $g $cwd $command) -match 'WARNING \(guard-command\)' }

$cases = [ordered]@{
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
foreach ($k in $cases.Keys) {
  $c = $cases[$k]
  $b = Blocks $Guard $c.cwd $c.cmd
  Check "block=$($c.block)  $k" ($b -eq $c.block) "(got block=$b)"
  if ($c.warn) { Check "warn             $k" (Warns $Guard $c.cwd $c.cmd) }
}

# ---- mutation: disable the no-config branch; the deny cases must stop blocking ----
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
$th = Join-Path $fx 'home'
New-Item -ItemType Directory -Force -Path (Join-Path $th '.codai\guard') | Out-Null
$o0 = HookHome $Guard $cfgless 'npx prettier --write src/a.ts' $th
Check 'allow-list: still blocks with no entry' ($o0 -match '"permissionDecision":"deny"') $o0
Set-Content -LiteralPath (Join-Path $th '.codai\guard\formatter-allow.json') -Value (@{ repos = @($cfgless) } | ConvertTo-Json)
$o1 = HookHome $Guard $cfgless 'npx prettier --write src/a.ts' $th
Check 'allow-list: the deny is suppressed' (-not ($o1 -match '"permissionDecision":"deny"')) $o1
Check 'allow-list: a NOTE explains why' ($o1 -match 'formatter-allow\.json') $o1
Check 'allow-list: the decision is audited' (Test-Path -LiteralPath (Join-Path $th '.codai\guard\formatter.jsonl'))

# ---- PostToolUse auto-format (2026-11-25) --------------------------------------------------------
# The other half of the rule, and the owner's question: when the repo OWNS the settings, a created
# file is formatted FOR the agent instead of the agent being told off later. Same lib as the guard,
# so the two cannot disagree. A fake formatter (a .cmd shim that appends a marker to its LAST
# argument) proves which file was written without needing the real tool installed.
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

Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
Write-Host ''
if ($fails) { Write-Host "$fails failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "all guard-format cases pass (exe: $Exe)"
exit 0
