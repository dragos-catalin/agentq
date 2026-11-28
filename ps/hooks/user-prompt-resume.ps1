<#
.SYNOPSIS
  UserPromptSubmit: when the submitted prompt is a resumed-effort word ("continue", "continua",
  "gata", ...), re-inject THIS workspace's newest repository handoff note so the new turn starts from
  the state the previous chat recorded instead of re-deriving it blind.

.DESCRIPTION
  Why this exists: when a chat stops and the user types "continue" / "continua" / "try again", nothing
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

  It ALSO injects the session PLAN when one belongs to this workspace -- the record the resume protocol
  (docs/tracking-and-resume.md, layer "The resume protocol") says a resume must read: goal + doneMeans +
  the next[] steps with their status, written by `node tools/track.mjs plan set ...` into the agentq
  state dir (spec: spec/plan.schema.json, when present). A plan has NO workspace field and the resuming
  chat has a NEW session id, so a plan cannot be matched by session; its only link to a workspace is
  handoffPath, which points into that workspace's `memory-tool\memories\repo\handoffs\` -- the SAME
  directory Resolve-HandoffDir returns. So a plan is injected ONLY when its handoffPath resolves INSIDE
  this workspace's handoff directory, and the newest such plan by updatedAt wins. A plan from ANY OTHER
  workspace is ignored: injecting a foreign plan would resume the turn onto the wrong work, which is
  exactly the wrong injection this hook holds to be worse than no hook at all. The plan section is
  omitted (never an error) when no such plan exists or the file is malformed.

  Output: VS Code / Copilot UserPromptSubmit JSON, hookSpecificOutput.additionalContext. The note is
  bounded to $maxChars characters -- the proposal fixes no bound, and additionalContext is re-sent and
  billed on every later model call, so a whole multi-kilobyte note must not ride along unmetered.

  Registration: the config key is the EDITOR's alias, not the canonical event name. Its alias table
  (read out of workbench.desktop.main.js on 2026-11-28) is
    sessionStart->SessionStart, sessionEnd->SessionEnd,
    userPromptSubmitted->UserPromptSubmit, userPromptTransformed->UserPromptTransformed,
    preToolUse->PreToolUse, postToolUse->PostToolUse, preCompact->PreCompact,
    subagentStart->SubagentStart, agentStop->Stop, subagentStop->SubagentStop,
    errorOccurred->ErrorOccurred
  and the canonical spellings are accepted verbatim too. So the key to register is
  `userPromptSubmitted`: `userPromptSubmit` is NOT a key, is ignored without a diagnostic, and this
  hook would never fire. The payload then carries the CANONICAL name in
  hook_event_name/hookEventName, which is what the guard below compares against.

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

# Resolve the agentq state directory EXACTLY as tools/track.mjs does: $env:AGENTQ_HOME, else
# ~/.codai/coord (in track.mjs, `process.env.AGENTQ_HOME || join(homedir(), ".codai", "coord")`). The
# plan records live in <state>/chats/, one <session>.plan.json per chat -- the same files `track plan
# set` writes and `loadAllPlans` reads. Returns the chats directory path (which may not exist).
function Get-PlanChatsDir {
  $state = $env:AGENTQ_HOME
  if (-not $state) {
    # NOT $home: PowerShell variable names are case-insensitive, and $HOME is a read-only automatic
    # variable, so assigning to it throws. Use a distinct name.
    $userHome = $env:USERPROFILE
    if (-not $userHome) { $userHome = $HOME }
    if (-not $userHome) { return $null }
    $state = Join-Path $userHome '.codai\coord'
  }
  return (Join-Path $state 'chats')
}

# Read ONE plan JSON defensively: a malformed, empty or unreadable file is $null, never an error.
function Read-PlanFile([string]$file) {
  try {
    $raw = [IO.File]::ReadAllText($file)
    if (-not $raw) { return $null }
    return ($raw | ConvertFrom-Json)
  } catch { return $null }
}

# The bounded digest of the plan that belongs to THIS workspace, or $null. Ownership is decided ONLY by
# handoffPath (see the header): the record has no workspace field, and the chat resuming it has a NEW
# session id, so the session cannot be matched by construction. A plan is ours iff its handoffPath
# resolves strictly inside $handoffDir; ANY other plan -- a foreign workspace's -- is IGNORED, because
# injecting it would resume the turn onto the wrong work. Among ours, the newest by updatedAt wins (the
# file's mtime when updatedAt is absent or unparseable). Dependency-free: reads the JSON directly.
function Get-WorkspacePlanDigest([string]$handoffDir) {
  $chats = Get-PlanChatsDir
  if (-not $chats) { return $null }
  if (-not [IO.Directory]::Exists($chats)) { return $null }
  $root = ''
  try { $root = [IO.Path]::GetFullPath($handoffDir).TrimEnd('\', '/') } catch { return $null }
  if (-not $root) { return $null }

  $best = $null
  $bestAt = [DateTimeOffset]::MinValue
  foreach ($file in [IO.Directory]::GetFiles($chats)) {
    if (-not $file.EndsWith('.plan.json')) { continue }
    $plan = Read-PlanFile $file
    if (-not $plan) { continue }
    $hp = "$($plan.handoffPath)"
    if (-not $hp) { continue }
    $hpFull = ''
    try { $hpFull = [IO.Path]::GetFullPath($hp) } catch { continue }
    # Strictly inside: longer than the root, sharing it, and separated by a slash.
    if ($hpFull.Length -le $root.Length) { continue }
    if ($hpFull.Substring(0, $root.Length) -ine $root) { continue }
    $sep = $hpFull[$root.Length]
    if ($sep -ne '\' -and $sep -ne '/') { continue }

    $at = [DateTimeOffset]::MinValue
    $known = $false
    if ($plan.updatedAt) {
      $dto = [DateTimeOffset]::MinValue
      if ([DateTimeOffset]::TryParse("$($plan.updatedAt)", [ref]$dto)) { $at = $dto; $known = $true }
    }
    if (-not $known) {
      try { $at = [DateTimeOffset](Get-Item -LiteralPath $file).LastWriteTimeUtc } catch { $at = [DateTimeOffset]::MinValue }
    }
    if ($best -eq $null -or $at -gt $bestAt) { $best = $plan; $bestAt = $at }
  }
  if ($best -eq $null) { return $null }
  return (Format-PlanDigest $best)
}

# The text injected for a plan: its goal, its done-means, and every next[] entry with its status, plus
# the handoff path it came from and the session id that names it. Not the roster/jobs/todos -- the
# resume protocol reads goal + next[0..] off the plan, and additionalContext is re-sent and billed on
# every later model call, so the digest is bounded like the note.
function Format-PlanDigest($plan) {
  $lines = New-Object System.Collections.ArrayList
  $sid = "$($plan.sessionId)"
  if ($sid) {
    [void]$lines.Add("Resumed effort. The session plan recorded for this workspace (session '$sid') says to resume at:")
  } else {
    [void]$lines.Add("Resumed effort. The session plan recorded for this workspace says to resume at:")
  }
  if ($plan.goal) { [void]$lines.Add("goal: $($plan.goal)") }
  $done = @()
  if ($plan.doneMeans) { $done = @($plan.doneMeans) }
  if ($done.Count) {
    [void]$lines.Add("done means:")
    foreach ($d in $done) { [void]$lines.Add("  - $d") }
  }
  $next = @()
  if ($plan.next) { $next = @($plan.next) }
  if ($next.Count) {
    [void]$lines.Add("next:")
    foreach ($n in $next) {
      $title = "$($n.title)"
      $status = "$($n.status)"
      if ($status) { [void]$lines.Add("  - $title [$status]") } else { [void]$lines.Add("  - $title") }
    }
  }
  if ($plan.handoffPath) { [void]$lines.Add("handoff: $($plan.handoffPath)") }
  $digest = ($lines -join "`n").TrimEnd()
  $maxPlan = 4000
  if ($digest.Length -gt $maxPlan) { $digest = $digest.Substring(0, $maxPlan) + "`n... (plan truncated)" }
  return $digest
}

try {
  # Read stdin as raw UTF-8 BYTES, not via [Console]::In. Windows PowerShell 5.1 (which VS Code
  # invokes as `powershell.exe`) decodes a REDIRECTED stdin with the console code page, so a UTF-8
  # payload carrying a diacritic ("Continua") arrives mangled and the whole-prompt match would miss
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
  # the resume words. "please continue" therefore does NOT match; "Continua" folds to "continua" and does.
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

  # The plan for THIS workspace, if any, is injected BEFORE the handoff note: a resume should first read
  # what the previous chat said it would do next, then the state it recorded. Absent, foreign or
  # malformed => an empty section, and the note alone is injected exactly as it was before this existed.
  $planSection = ''
  $planDigest = Get-WorkspacePlanDigest $handoffDir
  if ($planDigest) { $planSection = "$planDigest`n`n" }

  $noteSection = ''
  $notes = @(Get-ChildItem -LiteralPath $handoffDir -File -Filter '*.md' -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending)
  if ($notes.Count) {
    $newest = $notes[0]
    $content = ''
    try { $content = [IO.File]::ReadAllText($newest.FullName) } catch { $content = '' }
    if ($content) {
      $maxChars = 8000
      if ($content.Length -gt $maxChars) {
        $content = $content.Substring(0, $maxChars) + "`n... (handoff truncated here; open '$($newest.Name)' for the rest)"
      }
      $noteSection = "Resumed effort. This workspace's newest repository handoff note is '$($newest.Name)' " +
        "($($newest.LastWriteTime.ToString('yyyy-MM-dd'))). Resume from the state recorded there instead of " +
        "re-deriving it:`n`n$content"
    }
  }

  if (-not $planSection -and -not $noteSection) { exit 0 }
  $ctx = $planSection + $noteSection

  @{ hookSpecificOutput = @{ hookEventName = 'UserPromptSubmit'; additionalContext = $ctx } } |
    ConvertTo-Json -Compress -Depth 5
  exit 0
} catch {
  exit 0
}
