# guard-tooluse.ps1 formatter rule (2026-11-24): a formatter run over files the agent did not write
# must not silently apply the tool's DEFAULTS. Denies when the target repo declares no config for
# that formatter; warns about the cross-checkout "mixture tell". Then MUTATION tests: the no-config
# branch is disabled in a copy of the guard and the deny cases must start to pass through.
param(
  [string]$Guard = (Join-Path $PSScriptRoot 'guard-tooluse.ps1'),
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

Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
Write-Host ''
if ($fails) { Write-Host "$fails failure(s)" -ForegroundColor Red; exit 1 }
Write-Host "all guard-format cases pass (exe: $Exe)"
exit 0
