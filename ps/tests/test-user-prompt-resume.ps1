# Tests for ps/hooks/user-prompt-resume.ps1 (the UserPromptSubmit resume hook), spawned EXACTLY as
# VS Code does: powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -Command <script>
# (extension.js J8a, the same form test-hook-pre.ps1 uses).
#
# The hook must inject this workspace's NEWEST repository handoff note ONLY when the whole submitted
# prompt is a resume word, and must be SILENT (exit 0, no output) for every other prompt, a missing
# handoffs directory, and a malformed/empty payload -- a resume hook that injects into an unrelated
# turn is worse than no hook at all. Hermetic: APPDATA is redirected to a throwaway workspaceStorage,
# so the hook resolves the TEMP workspace's handoff directory and touches nothing on the real machine.
#
# Non-vacuous by construction: "injects the NEWEST note" and "a longer sentence is silent" are the
# assertions an ascending sort or a substring match turns red (mutation proved in the tracker entry).
# Exit 1 on any failure.
param([string]$Hook)
$fail = 0
$installed = Join-Path $PSScriptRoot 'user-prompt-resume.ps1'
if (-not $Hook) {
  if (Test-Path -LiteralPath $installed) { $Hook = $installed }
  else { $Hook = Join-Path $PSScriptRoot '..\hooks\user-prompt-resume.ps1' }
}
$Hook = (Resolve-Path -LiteralPath $Hook).Path
Write-Host "  hook: $Hook"

function Ok([bool]$c, [string]$name, [string]$detail = '') {
  if ($c) { Write-Host "  ok    $name" } else { Write-Host "  FAIL  $name  $detail" -ForegroundColor Red; $script:fail++ }
}

# --- throwaway APPDATA: Code - Insiders\User\workspaceStorage\<guid>\workspace.json + memory-tool ---
$store = Join-Path $env:TEMP ("upr-store-{0}" -f [guid]::NewGuid().ToString('N'))
$ws = Join-Path $env:TEMP ("upr-ws-{0}" -f [guid]::NewGuid().ToString('N'))
$wsStorage = Join-Path $store 'Code - Insiders\User\workspaceStorage'
$wsEntry = Join-Path $wsStorage ([guid]::NewGuid().ToString('N'))
$handoffDir = Join-Path $wsEntry 'GitHub.copilot-chat\memory-tool\memories\repo\handoffs'
$null = New-Item -ItemType Directory -Force -Path $wsEntry, $ws | Out-Null
$want = ($ws -replace '\\', '/').TrimEnd('/')
[IO.File]::WriteAllText((Join-Path $wsEntry 'workspace.json'), (@{ folder = "file:///$want" } | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))

$oldAppData = $env:APPDATA
$env:APPDATA = $store

function Invoke-Hook([string]$stdin) {
  $tmp = Join-Path $env:TEMP ("upr-in-{0}.json" -f [guid]::NewGuid().ToString('N'))
  $text = if ($null -eq $stdin) { '' } else { $stdin }
  [IO.File]::WriteAllText($tmp, $text, [Text.UTF8Encoding]::new($false))
  # stdout is read as raw UTF-8 bytes: that is what the harness receives.
  $psi = [Diagnostics.ProcessStartInfo]::new('cmd.exe', "/d /c `"powershell.exe -ExecutionPolicy Bypass -NoProfile -NoLogo -Command $Hook < `"$tmp`" 2>NUL`"")
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true
  $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
  $pr = [Diagnostics.Process]::Start($psi); $o = $pr.StandardOutput.ReadToEnd(); $pr.WaitForExit()
  Remove-Item $tmp -Force -ErrorAction SilentlyContinue
  [pscustomobject]@{ Out = $o; Rc = $pr.ExitCode }
}
function Payload([string]$prompt) { @{ hook_event_name = 'UserPromptSubmit'; session_id = 'upr'; cwd = $ws; prompt = $prompt } | ConvertTo-Json -Compress -Depth 5 }
function Silent([string]$name, [pscustomobject]$r) {
  Ok (($r.Rc -eq 0) -and (-not ("$($r.Out)".Trim()))) $name "rc=$($r.Rc) out=$("$($r.Out)".Trim())"
}
function Injects([string]$name, [pscustomobject]$r, [string]$mustMatch, [string]$mustNotMatch = '') {
  $good = ($r.Rc -eq 0) -and ("$($r.Out)" -match '"hookEventName":"UserPromptSubmit"') -and ("$($r.Out)" -match '"additionalContext"')
  if ($mustMatch) { $good = $good -and ("$($r.Out)" -match [regex]::Escape($mustMatch)) }
  if ($mustNotMatch) { $good = $good -and ("$($r.Out)" -notmatch [regex]::Escape($mustNotMatch)) }
  Ok $good $name "rc=$($r.Rc) out=$("$($r.Out)".Trim())"
}

try {
  # --- case 2: a matching prompt with NO handoffs directory yet -> silent ---
  Silent 'matching prompt with no handoffs directory is silent' (Invoke-Hook (Payload 'continue'))

  # --- seed two notes with EXPLICIT timestamps so "newest" is deterministic, not a race ---
  $null = New-Item -ItemType Directory -Force -Path $handoffDir | Out-Null
  $old = Join-Path $handoffDir '2026-01-01-old.md'
  $new = Join-Path $handoffDir '2026-11-27-new.md'
  [IO.File]::WriteAllText($old, "# OLD HANDOFF`nOLD-STATE-SENTINEL", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($new, "# NEW HANDOFF`nNEW-STATE-SENTINEL", [Text.UTF8Encoding]::new($false))
  [IO.File]::SetLastWriteTimeUtc($old, [DateTime]::UtcNow.AddHours(-5))
  [IO.File]::SetLastWriteTimeUtc($new, [DateTime]::UtcNow)

  # --- case 1: a matching prompt injects the NEWEST note and NOT the older one ---
  Injects 'matching prompt injects the newest handoff note' (Invoke-Hook (Payload 'continue')) 'NEW-STATE-SENTINEL' 'OLD-STATE-SENTINEL'
  Injects 'a Romanian diacritic resume word matches too' (Invoke-Hook (Payload 'Continuă')) 'NEW-STATE-SENTINEL'
  Injects 'case does not matter' (Invoke-Hook (Payload 'DONE')) 'NEW-STATE-SENTINEL'
  Injects 'surrounding whitespace is trimmed before matching' (Invoke-Hook (Payload '  gata  ')) 'NEW-STATE-SENTINEL'

  # --- case 3: a non-matching prompt is silent ---
  Silent 'a non-matching prompt is silent' (Invoke-Hook (Payload 'add a disk metric'))

  # --- case 4: a longer sentence containing the word is silent (whole-prompt, not substring) ---
  Silent 'a longer sentence containing the word is silent' (Invoke-Hook (Payload 'please continue with the plan'))
  Silent 'a word merely starting with a resume word is silent' (Invoke-Hook (Payload 'continuex'))

  # --- case 5: malformed JSON on stdin is silent, exit 0 ---
  Silent 'malformed JSON on stdin is silent' (Invoke-Hook '{ this is not json')
  # --- case 6: empty stdin is silent, exit 0 ---
  Silent 'empty stdin is silent' (Invoke-Hook '')
  # extra: a well-formed payload with no prompt field at all is silent, never a crash
  Silent 'a payload with no prompt field is silent' (Invoke-Hook '{"hook_event_name":"UserPromptSubmit","cwd":"x"}')
}
finally {
  if ($null -eq $oldAppData) { Remove-Item Env:APPDATA -ErrorAction SilentlyContinue } else { $env:APPDATA = $oldAppData }
  Remove-Item $store -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item $ws -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fail) { Write-Host "$fail failure(s)"; exit 1 }
Write-Host 'all user-prompt-resume cases passed'
exit 0
