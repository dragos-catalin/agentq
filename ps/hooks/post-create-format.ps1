<#
.SYNOPSIS
  PostToolUse: when a file is CREATED into a repo that owns a formatter config for it, format that
  one file with the repo's OWN settings - so the agent does not have to be told, and does not have a
  reason to reach for a bare formatter.

.DESCRIPTION
  Why this exists (owner, 2026-11-25: "should the gate apply the formatting when the repo configures
  it, instead of the agent getting an error?"). The refusal in guard-tooluse.ps1 covers the case a
  repo owns NO config, where there is nothing to apply. The case it cannot cover is the reverse: the
  repo DOES own the settings and an agent still writes an unformatted file (or "fixes" it later by
  running `prettier --write` on the whole file, which is what reformats lines nobody touched).

  What it does, per created file:
    - only on whole-file CREATES (create_file and friends). apply_patch is a TARGETED edit: diffing
      hunks means it cannot clobber, and the agent chose the exact bytes - leave it alone.
    - the repo must OWN a config for the chosen formatter, OR the tool's defaults must BE the
      community style (rustfmt/gofmt/ruff/...), OR the repo be in the owner's formatter-allow.json.
      A tool whose config the repo does not own is NEVER applied: that is the incident this whole
      pair of hooks exists for (brivio: no prettier config, 40/40 sampled files dirty, one --write
      touched 705 lines).
    - the repo's pinned binary wins over PATH (Get-FormatterBin).
    - fail-open everywhere: no output, exit 0. A tool call is never failed by this hook.

  The formatter knowledge is NOT here: it is lib\FormatterConfig.ps1, shared with guard-tooluse.ps1,
  so the two can never disagree (a duplicated guard is invisible to mutation testing).

  Output: VS Code / Copilot PostToolUse JSON with hookSpecificOutput.additionalContext. Throttled to
  one reminder per session per 10 minutes (the formatting still happens every time - only the text
  is throttled, because additionalContext is re-sent and billed on every later model call).
#>
$ErrorActionPreference = 'Stop'
try {
  $raw = [Console]::In.ReadToEnd()
  if (-not $raw) { exit 0 }
  $p = $raw | ConvertFrom-Json

  $tool = "$($p.tool_name)$($p.toolName)"
  # Firing proof for test-config-integrity: only a log line proves this hook is delivered.
  $fireLog = Join-Path $HOME '.codai\hook-fires.log'
  try {
    if ((Test-Path $fireLog) -and (Get-Item $fireLog).Length -gt 200KB) { Remove-Item $fireLog -ErrorAction SilentlyContinue }
    "$((Get-Date).ToString('o')) postToolUse(create-format) $tool" | Add-Content -Path $fireLog -ErrorAction SilentlyContinue
  } catch { }

  if ($tool -notmatch '(?i)^(create_file|createFile|write_file|writeFile|create_new|WriteAllLines)$') { exit 0 }

  # ---- the file that was just created ----
  $path = $null
  foreach ($c in $p.tool_input, $p.toolInput) {
    if (-not $c) { continue }
    foreach ($k in 'filePath', 'path', 'file', 'uri') {
      if ($c.PSObject.Properties.Name -contains $k -and $c.$k) { $path = "$($c.$k)"; break }
    }
    if ($path) { break }
  }
  if (-not $path) { exit 0 }
  $path = $path -replace '^file:///', '' -replace '/', '\'
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { exit 0 }

  # A generated/blob file is not worth a formatter run (and prettier would legitimately fail).
  try { if ((Get-Item -LiteralPath $path).Length -gt 2MB) { exit 0 } } catch { exit 0 }

  # ---- the repo that owns it ----
  $dir = Split-Path -Parent $path
  if (-not $dir) { exit 0 }
  $repo = $null
  try {
    $top = @(& git -C $dir rev-parse --show-toplevel 2>$null)
    if ($LASTEXITCODE -eq 0 -and $top.Count -and "$($top[0])".Trim()) { $repo = "$($top[0])".Trim().Replace('/', '\') }
  } catch { }
  # Outside a repo there is no config to honour; the guard's rule is about repos.
  if (-not $repo) { exit 0 }

  . (Join-Path $PSScriptRoot 'lib\FormatterConfig.ps1')

  $repAllowsDefaults = Test-FormatterRepoAllowed $repo
  $used = $null
  foreach ($cand in (Get-FormatterCandidatesForFile $path)) {
    $owns = Test-FormatterConfigured -start $dir -stop $repo -kind $cand
    if (-not $owns -and -not (Test-FormatterDefaultIsCanonical $cand) -and -not $repAllowsDefaults) { continue }
    $bin = Get-FormatterBin -startDir $dir -repo $repo -tool $cand
    if (-not $bin) { continue }
    if (Invoke-FormatterOnFile -bin $bin -tool $cand -file $path) {
      $used = $cand
      Add-FormatterAudit -event 'auto-formatted' -repo $repo -tool $cand -detail $path
      break
    }
    # A tool that ran and changed nothing proves the file is already in this repo's style - do not
    # try the next candidate and do not tell the agent anything.
    break
  }
  if (-not $used) { exit 0 }

  # Throttle the TEXT only: one reminder per session per 10 minutes.
  $sid = "$($p.session_id)$($p.sessionId)"
  if (-not $sid) { $sid = 'nosession' }
  $sid = ($sid -replace '[^A-Za-z0-9_-]', '')
  if ($sid.Length -gt 60) { $sid = $sid.Substring(0, 60) }
  $mdir = Join-Path $HOME '.codai\created-format'
  New-Item -ItemType Directory -Force -Path $mdir | Out-Null
  $mark = Join-Path $mdir $sid
  if ((Test-Path $mark) -and ((Get-Date) - (Get-Item $mark).LastWriteTime).TotalMinutes -lt 10) { exit 0 }
  Set-Content -Path $mark -Value (Get-Date).ToString('o')

  $leaf = Split-Path $path -Leaf
  $msg = "Created '$leaf': it was formatted with $used using the repo's own settings, so it needs no formatting step. " +
    "Do NOT run a bare formatter over it or over the repo to 'clean up' - this repo owns its settings and the file now matches them " +
    "(a bare `prettier --write`/`eslint --fix` with no config is refused by the guard, and a repo-wide run reformats lines nobody touched)."
  @{ hookSpecificOutput = @{ hookEventName = 'PostToolUse'; additionalContext = $msg } } | ConvertTo-Json -Compress -Depth 4
  exit 0
} catch {
  exit 0
}
