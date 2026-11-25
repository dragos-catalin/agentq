# Formatter knowledge shared by the hooks (2026-11-25).
#
# WHY A LIB: two hooks need the same two answers - "which formatter is this invocation, and does the
# repo own a config for it?" - and a guard that exists in two copies is invisible to mutation testing
# (one copy rots while the suite stays green). Both load this file:
#   guard-tooluse.ps1       PreToolUse  : refuses a formatter COMMAND that would run with defaults
#   post-create-format.ps1  PostToolUse : formats a NEWLY CREATED file with the repo's OWN settings
#
# The incident this encodes (2026-11-18): brivio declares prettier but owns NO config, 40/40 sampled
# .tsx files fail `prettier --check`, and a single `--write` touched 705 lines - in a shared clone
# where another agent had uncommitted edits in that file.
#
# Loaded with `. $path`. MUST stay compatible with powershell.exe 5.1 (that is what VS Code spawns).
# It deliberately does NOT call Set-StrictMode: a dot-sourced strict mode leaks into the caller and
# has broken machine-wide tooling before (2026-11-22).

# Config-file names per formatter. STRICT kinds have a config convention every repo using them is
# expected to own and their defaults differ wildly from repo style; SOFT kinds either have no config
# file at all or their defaults ARE the community style (a refusal there would block normal work).
function Get-FormatterConfigNames([string]$kind) {
  switch ($kind) {
    'prettier' { return @('.prettierrc', '.prettierrc.json', '.prettierrc.json5', '.prettierrc.yml', '.prettierrc.yaml', '.prettierrc.js', '.prettierrc.cjs', '.prettierrc.mjs', '.prettierrc.ts', '.prettierrc.toml', 'prettier.config.js', 'prettier.config.cjs', 'prettier.config.mjs', 'prettier.config.ts') }
    'eslint' { return @('eslint.config.js', 'eslint.config.mjs', 'eslint.config.cjs', 'eslint.config.ts', '.eslintrc', '.eslintrc.json', '.eslintrc.js', '.eslintrc.cjs', '.eslintrc.yml', '.eslintrc.yaml') }
    'biome' { return @('biome.json', 'biome.jsonc') }
    'dprint' { return @('dprint.json', 'dprint.jsonc', '.dprint.json', '.dprint.jsonc') }
    'oxfmt' { return @('.oxfmtrc.json', '.oxfmtrc.jsonc', 'oxfmt.json') }
    'clang-format' { return @('.clang-format', '_clang-format', '.clang-format-ignore') }
    'rustfmt' { return @('rustfmt.toml', '.rustfmt.toml') }
    'ktlint' { return @('.editorconfig') }
    # These read a SECTION of pyproject.toml (checked by name below) or a dotfile; a bare
    # pyproject.toml is NOT proof (most Python repos have one without a [tool.ruff] section).
    'ruff' { return @('ruff.toml', '.ruff.toml') }
    'black' { return @('.black') }
    'gdformat' { return @() }
    'swiftformat' { return @('.swiftformat') }
    # gofmt and `zig fmt` have NO config file by design (they ARE the canonical style); ktfmt takes
    # flags only. Nothing can satisfy them, so they can only ever warn.
    'gofmt' { return @() }
    'zigfmt' { return @() }
    default { return @() }
  }
}

# pyproject.toml is a shared file: only a TOOL-SPECIFIC section counts. Same reasoning as the
# top-level package.json keys below - a plain text match made brivio look configured.
function Test-PyProjectSection([string]$file, [string]$kind) {
  try { $t = [IO.File]::ReadAllText($file) } catch { return $false }
  switch ($kind) {
    'ruff' { return ($t -match '(?im)^\s*\[tool\.ruff') }
    'black' { return ($t -match '(?im)^\s*\[tool\.black') }
    'gdformat' { return ($t -match '(?im)^\s*\[tool\.gdformat') }
    default { return $false }
  }
}

function Test-FormatterConfigured([string]$start, [string]$stop, [string]$kind) {
  # prettier/eslint/biome/dprint resolve their config from the FILE's directory upward, so a
  # monorepo app package may carry its own; walk from $start up to (and including) $stop.
  $names = Get-FormatterConfigNames $kind
  $d = $start; $levels = 0
  while ($d -and $levels -lt 12) {
    foreach ($n in $names) { if (Test-Path -LiteralPath (Join-Path $d $n)) { return $true } }
    if ($kind -in 'ruff', 'black', 'gdformat') {
      $pp = Join-Path $d 'pyproject.toml'
      if ((Test-Path -LiteralPath $pp) -and (Test-PyProjectSection $pp $kind)) { return $true }
    }
    # package.json only carries a config in a TOP-LEVEL key, and only prettier (1970) and eslint
    # (eslintConfig) use that convention. A plain text match here is WRONG: every repo that depends
    # on prettier has `"prettier": "catalog:"` inside devDependencies - measured 2026-11-24, it made
    # brivio (no config at all) look configured and the whole rule silently allowed everything.
    $key = $null
    if ($kind -eq 'prettier') { $key = 'prettier' } elseif ($kind -eq 'eslint') { $key = 'eslintConfig' }
    if ($key) {
      $pj = Join-Path $d 'package.json'
      if (Test-Path -LiteralPath $pj) {
        try {
          $j = [IO.File]::ReadAllText($pj) | ConvertFrom-Json
          if ($j -and ($j.PSObject.Properties.Name -contains $key)) { return $true }
        } catch { }
      }
    }
    if ($stop -and $d -eq $stop) { break }
    $parent = Split-Path -Parent $d
    if (-not $parent -or $parent -eq $d) { break }
    $d = $parent; $levels++
  }
  return $false
}

# The tools whose defaults ARE the style, so auto-formatting a new file needs no config.
# The STRICT set (refused without a config) lives inline in guard-tooluse.ps1 - it is a different
# question and keeping one copy of it avoids two lists drifting apart.
function Test-FormatterDefaultIsCanonical([string]$tool) {
  return ($tool -in 'rustfmt', 'gofmt', 'zigfmt', 'black', 'ruff', 'ktlint', 'gdformat', 'swiftformat')
}

# ---- per-file formatter (used by the post-create auto-format) -------------------------------

# Candidate formatters for a file, best first. Formatting quality first, lint-fix last.
function Get-FormatterCandidatesForFile([string]$file) {
  $ext = ''
  try { $ext = [IO.Path]::GetExtension($file).ToLowerInvariant() } catch { }
  $web = @('.ts', '.tsx', '.js', '.jsx', '.mjs', '.cjs', '.json', '.jsonc', '.md', '.mdx', '.css', '.scss', '.less', '.html', '.vue', '.svelte', '.yml', '.yaml', '.graphql', '.gql')
  $c = @()
  if ($web -contains $ext) { $c += 'prettier', 'biome', 'dprint', 'eslint' }
  if (@('.c', '.cc', '.cpp', '.cxx', '.h', '.hpp', '.hh', '.hxx', '.m', '.mm', '.proto', '.java', '.cs') -contains $ext) { $c += 'clang-format' }
  if (@('.py', '.pyi') -contains $ext) { $c += 'ruff', 'black' }
  if ($ext -eq '.gd') { $c += 'gdformat' }
  if ($ext -eq '.swift') { $c += 'swiftformat' }
  if ($ext -eq '.rs') { $c += 'rustfmt' }
  if ($ext -eq '.go') { $c += 'gofmt' }
  if (@('.kt', '.kts') -contains $ext) { $c += 'ktlint' }
  if ($ext -eq '.zig') { $c += 'zigfmt' }
  return $c
}

# Repo-local binary first (that is the version the repo pins), PATH second.
function Get-FormatterBin([string]$startDir, [string]$repo, [string]$tool) {
  if ($tool -eq 'zigfmt') { $tool = 'zig' }
  if ($tool -eq 'repo-script') { return $null }
  $exeNames = @("$tool.cmd", "$tool.exe", "$tool.ps1", $tool)
  $dirs = @(); $d = $startDir; $g = 0
  while ($d -and $g -lt 12) {
    $dirs += $d
    if ($repo -and ($d -eq $repo)) { break }
    $p = Split-Path -Parent $d
    if (-not $p -or $p -eq $d) { break }
    $d = $p; $g++
  }
  foreach ($dir in $dirs) {
    foreach ($sub in 'node_modules\.bin', '.venv\Scripts', 'venv\Scripts', '.venv\bin', 'venv\bin') {
      foreach ($n in $exeNames) {
        $cand = Join-Path $dir "$sub\$n"
        if (Test-Path -LiteralPath $cand) { return $cand }
      }
    }
  }
  # PATH second: the .cmd/.exe shim npm and friends install. `Source` is set for both Application
  # and ExternalScript commands, so one lookup covers `prettier.cmd`, `prettier.ps1` and `prettier`.
  $c = @(Get-Command $tool -ErrorAction SilentlyContinue) | Select-Object -First 1
  if ($c -and $c.Source) { return $c.Source }
  return $null
}

# The invocation that WRITES, per tool. `--` guards filenames that start with a dash.
function Get-FormatterArgs([string]$tool, [string]$file) {
  switch ($tool) {
    'prettier' { return @('--write', '--', $file) }
    'eslint' { return @('--fix', '--', $file) }
    'biome' { return @('format', '--write', '--', $file) }
    'dprint' { return @('fmt', '--', $file) }
    'oxfmt' { return @('--', $file) }
    'clang-format' { return @('-i', '--', $file) }
    'ruff' { return @('format', '--', $file) }
    'black' { return @('--', $file) }
    'gdformat' { return @('--', $file) }
    'swiftformat' { return @('--', $file) }
    'rustfmt' { return @('--', $file) }
    'gofmt' { return @('-w', '--', $file) }
    'ktlint' { return @('-F', '--', $file) }
    'zig' { return @('fmt', '--', $file) }
    default { return @() }
  }
}

# Format ONE file in place with the tool's own settings. Fail-open: any error returns $false and
# nothing is reported to the agent. Returns $false when the run changed nothing (the common case).
function Invoke-FormatterOnFile([string]$bin, [string]$tool, [string]$file, [int]$timeoutSec = 10) {
  if (-not $bin -or -not (Test-Path -LiteralPath $file)) { return $false }
  $before = ''
  try { $before = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } catch { return $false }
  $fargs = Get-FormatterArgs $tool $file
  if (-not $fargs.Count) { return $false }
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bin
    # ArgumentList is .NET Core only; powershell.exe 5.1 is .NET Framework, where the property does
    # not exist at all (the plain assignment would throw and auto-format would silently never run
    # under the shell VS Code actually spawns hooks with).
    if ($psi.PSObject.Properties.Name -contains 'ArgumentList') {
      foreach ($a in $fargs) { $psi.ArgumentList.Add($a) }
    } else {
      $quoted = foreach ($a in $fargs) { if ($a -match '[\s"]') { '"' + ($a -replace '"', '\"') + '"' } else { $a } }
      $psi.Arguments = ($quoted -join ' ')
    }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = (Split-Path -Parent $file)
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($timeoutSec * 1000)) { try { $proc.Kill() } catch { }; return $false }
  } catch { return $false }
  $after = ''
  try { $after = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash } catch { return $false }
  return ($after -and $after -ne $before)
}

# ---- per-repo override and audit trail (2026-11-25) -----------------------------------------

function Get-GuardDir {
  $d = Join-Path $HOME '.codai\guard'
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return $d
}

# Some repos legitimately reformat everything on purpose. Listed under
# ~/.codai/guard/formatter-allow.json = {"repos":["E:\\gh\\x"]} the no-config refusal is skipped
# (with a NOTE), because the owner has decided the repo's default IS its style. Deliberately a
# machine-local file outside the repo: no repo needs a change, and no agent can add an entry.
function Test-FormatterRepoAllowed([string]$repo) {
  if (-not $repo) { return $false }
  try {
    $f = Join-Path $HOME '.codai\guard\formatter-allow.json'
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    $j = [IO.File]::ReadAllText($f) | ConvertFrom-Json
    $list = @()
    if ($j -and $j.PSObject.Properties.Name -contains 'repos') { $list = @($j.repos) }
    foreach ($r in $list) {
      if (-not $r) { continue }
      $a = "$r".TrimEnd('\', '/'); $b = "$repo".TrimEnd('\', '/')
      if ($a -and $b -and ($a -eq $b)) { return $true }
    }
  } catch { }
  return $false
}

# One short JSON line per decision, so "did the guard do anything?" is answerable after the fact.
function Add-FormatterAudit([string]$event, [string]$repo, [string]$tool, [string]$detail) {
  try {
    $line = @{ ts = (Get-Date).ToUniversalTime().ToString('o'); event = $event; repo = $repo; tool = $tool; detail = $detail } | ConvertTo-Json -Compress
    Add-Content -Path (Join-Path (Get-GuardDir) 'formatter.jsonl') -Value $line -ErrorAction SilentlyContinue
  } catch { }
}
