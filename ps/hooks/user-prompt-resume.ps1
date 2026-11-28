<#
.SYNOPSIS
  UserPromptSubmit: when the submitted prompt is a resumed-effort word ("continue", "continuă",
  "gata", ...), re-inject THIS workspace's newest repository handoff note so the new turn starts from
  the state the previous chat recorded instead of re-deriving it blind.

.DESCRIPTION
  Why this exists: when a chat stops and the user types "continue" / "continuă" / "try again", nothing
  re-injects where the work had reached. The agent re-derives the next step from the transcript, does
  not re-dispatch its subagents and does not re-attach to in-flight jobs. This hook re-attaches the
  turn to the newest handoff note the previous chat left under the workspace's
  `memory-tool\memories\repo\handoffs\` directory -- the SAME resolution session-start.ps1 already
  uses to list those notes by title, so there is exactly one way this workspace finds them.

  Advisory and READ-ONLY. It must never block a prompt and must never inject into an unrelated turn,
  so it prints AT MOST one thing and ONLY when all of these hold:
    - the submitted prompt, trimmed and WHOLE, equals one of the resume words, matched case- and
      diacritic-insensitively. It is an EQUALITY test against the whole prompt, never a substring of a
      longer sentence, so "please continue with the plan" is left alone;
    - this workspace resolves to a memory root AND that root has at least one *.md handoff note.
  Every other case, and every error (empty stdin, malformed JSON, a missing directory, an unreadable
  file), exits 0 with NO output. A resume hook that injects into the wrong turn is worse than none.

  Payload fields are read defensively: the prompt from prompt/userPrompt/user_prompt/message/text, the
  workspace from cwd/cwdPath/workingDirectory/workspace/workspaceFolder (falling back to $PWD). A
  harness that renames a field then degrades to SILENT, never to a wrong injection.

  Output: VS Code / Copilot UserPromptSubmit JSON, hookSpecificOutput.additionalContext. The note is
  bounded to $maxChars characters -- the proposal fixes no bound, and additionalContext is re-sent and
  billed on every later model call, so a whole multi-kilobyte note must not ride along unmetered.

  PowerShell 5.1 compatible (VS Code invokes hooks as powershell.exe): no ternary, no `??`, no
  `-Parallel`. Source is ASCII only (diacritics are folded by CODE POINT), so no BOM is needed.
#>
$ErrorActionPreference = 'SilentlyContinue'

# Fold Romanian diacritics (plus the two cedilla forms) to ASCII by CODE POINT: a .ps1 read as ANSI
# would mangle literal letters and match nothing. Same set nudge-parallel.ps1 folds, so the two agree.
function ConvertTo-Folded([string]$s) {
  $s = $s.ToLowerInvariant()
  $s = $s -replace [string][char]0x0103, 'a'   # a-breve
  $s = $s -replace [string][char]0x00e2, 'a'   # a-circumflex
  $s = $s -replace [string][char]0x00ee, 'i'   # i-circumflex
  $s = $s -replace [string][char]0x00ed, 'i'   # i-acute
  $s = $s -replace [string][char]0x0219, 's'   # s-comma
  $s = $s -replace [string][char]0x015f, 's'   # s-cedilla
  $s = $s -replace [string][char]0x021b, 't'   # t-comma
  $s = $s -replace [string][char]0x0163, 't'   # t-cedilla
  $s
}

# Resolve THIS workspace's handoff directory exactly the way session-start.ps1 does: find the
# workspaceStorage entry whose workspace.json names this folder, then use that entry's memory-tool
# root. Returns the handoffs directory path (which may not exist) or $null when no entry matches.
function Resolve-HandoffDir([string]$workspace) {
  $appData = $env:APPDATA
  if (-not $appData) { return $null }
  $storeRoot = Join-Path $appData 'Code - Insiders\User\workspaceStorage'
  if (-not [IO.Directory]::Exists($storeRoot)) { return $null }
  # The manifest stores the folder as a file:// URI; compare in the same forward-slash spelling.
  $want = ($workspace -replace '\\', '/').TrimEnd('/')
  foreach ($dir in [IO.Directory]::GetDirectories($storeRoot)) {
    $manifest = Join-Path $dir 'workspace.json'
    if (-not [IO.File]::Exists($manifest)) { continue }
    try { if ((Get-Item -LiteralPath $manifest).Length -gt 65536) { continue } } catch { continue }
    $raw = ''
    try { $raw = Get-Content -LiteralPath $manifest -Raw } catch { continue }
    if ($raw -notmatch '(?i)"folder"\s*:\s*"file:///([^"]+)"') { continue }
    if ([Uri]::UnescapeDataString($Matches[1]).TrimEnd('/') -ieq $want) {
      return (Join-Path $dir 'GitHub.copilot-chat\memory-tool\memories\repo\handoffs')
    }
  }
  return $null
}

try {
  # Read stdin as raw UTF-8 BYTES, not via [Console]::In. Windows PowerShell 5.1 (which VS Code
  # invokes as `powershell.exe`) decodes a REDIRECTED stdin with the console code page, so a UTF-8
  # payload carrying a diacritic ("Continuă") arrives mangled and the whole-prompt match would miss
  # the very word this hook exists for. Bytes + an explicit UTF-8 decode are code-page independent.
  $raw = ''
  try {
    $in = [Console]::OpenStandardInput()
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 4096
    while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) { $ms.Write($buf, 0, $n) }
    $raw = [Text.Encoding]::UTF8.GetString($ms.ToArray())
    if ($raw.Length -gt 0 -and $raw[0] -eq [char]0xFEFF) { $raw = $raw.Substring(1) }
  } catch { $raw = '' }
  if (-not $raw) { exit 0 }

  $p = $null
  try { $p = $raw | ConvertFrom-Json } catch { exit 0 }
  if (-not $p) { exit 0 }

  # Only ever act on our own event; a renamed/different event means do nothing.
  $ev = "$($p.hook_event_name)$($p.hookEventName)"
  if ($ev -and $ev -ne 'UserPromptSubmit') { exit 0 }

  # --- the submitted prompt ---
  $prompt = ''
  foreach ($k in 'prompt', 'userPrompt', 'user_prompt', 'message', 'text') {
    if ($p.PSObject.Properties.Name -contains $k -and $p.$k) { $prompt = "$($p.$k)"; break }
  }
  if (-not $prompt) { exit 0 }

  # Whole-prompt match, not a substring: collapse whitespace runs, then require EQUALITY with one of
  # the resume words. "please continue" therefore does NOT match; "Continuă" folds to "continua" and does.
  $norm = ((ConvertTo-Folded $prompt) -replace '\s+', ' ').Trim()
  $resumeWords = @('continua', 'continue', 'try again', 'gata', 'da', 'go', 'done')
  if ($resumeWords -notcontains $norm) { exit 0 }

  # --- which workspace ---
  $cwd = ''
  foreach ($k in 'cwd', 'cwdPath', 'workingDirectory', 'workspace', 'workspaceFolder') {
    if ($p.PSObject.Properties.Name -contains $k -and $p.$k) { $cwd = "$($p.$k)"; break }
  }
  if (-not $cwd) { $cwd = $PWD.Path }

  $handoffDir = Resolve-HandoffDir $cwd
  if (-not $handoffDir) { exit 0 }
  if (-not [IO.Directory]::Exists($handoffDir)) { exit 0 }

  $notes = @(Get-ChildItem -LiteralPath $handoffDir -File -Filter '*.md' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending)
  if (-not $notes.Count) { exit 0 }

  $newest = $notes[0]
  $content = ''
  try { $content = [IO.File]::ReadAllText($newest.FullName) } catch { exit 0 }
  if (-not $content) { exit 0 }

  $maxChars = 8000
  if ($content.Length -gt $maxChars) {
    $content = $content.Substring(0, $maxChars) + "`n... (handoff truncated here; open '$($newest.Name)' for the rest)"
  }

  $ctx = "Resumed effort. This workspace's newest repository handoff note is '$($newest.Name)' " +
    "($($newest.LastWriteTime.ToString('yyyy-MM-dd'))). Resume from the state recorded there instead of " +
    "re-deriving it:`n`n$content"

  @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $ctx } } |
    ConvertTo-Json -Compress -Depth 5
  exit 0
} catch {
  exit 0
}
