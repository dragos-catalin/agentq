<#
.SYNOPSIS
  PreToolUse guard: destructive shell commands AND clobbering whole-file writes.

.DESCRIPTION
  Merged from guard-command.ps1 + guard-write.ps1 on 2026-09-06. Both ran on
  EVERY tool call and the hook config has no per-tool filter, so two pwsh
  processes started every time: ~1s of dead latency per tool use, ~250ms x2 of
  it process startup alone. One process halves that.

  Both original logics are kept verbatim; only the plumbing is shared. The
  write half still runs solely for whole-file writes and exits immediately for
  anything else.

  Exit 0 = allow, exit 2 = block with the reason on stderr.
#>
$ErrorActionPreference = 'Stop'

try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { Flush-Stderr; exit 0 }
$tool = "$($payload.tool_name)$($payload.toolName)$($payload.tool)$($payload.name)"
# VS Code reports an exit-2 hook as "NonBlockingError" and RUNS the tool (verified 2026-09-27:
# 21 real blocks executed; a harmless probe string with a destructive pattern ran twice). It only
# honours a JSON PreToolUse decision on stdout with EXIT 0. So every block goes through Deny-Exit:
# VS Code payload (has hook_event_name) -> JSON deny + exit 0; other harnesses -> exit 2 (stderr).
$script:DenyLines = [System.Collections.Generic.List[string]]::new()
$script:RealStderr = [Console]::Error
$script:DenyWriter = [System.IO.StringWriter]::new()
[Console]::SetError([System.IO.TextWriter]::Synchronized($script:DenyWriter))
function Deny-Exit {
  $text = $script:DenyWriter.ToString().TrimEnd()
  $script:RealStderr.Write($text + [Environment]::NewLine)
  if ($payload.PSObject.Properties.Name -contains 'hook_event_name') {
    @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = $text } } |
      ConvertTo-Json -Compress -Depth 4 | Write-Output
    exit 0
  }
  exit 2
}
# Flush captured non-blocking warnings (WARNING lines) on a normal allow path.
function Flush-Stderr { $t = $script:DenyWriter.ToString(); if ($t) { $script:RealStderr.Write($t) } }

# Physical "blocked" signal (room bulb flash / desk screen). Background so the
# block itself is not delayed; the receiver is vmui on this PC.
function Signal-Blocked([string]$Why) {
  $sid = "$($payload.session_id)"
  $envFile = 'E:\gh\vmui\.private\credentials.env'
  if (-not (Test-Path $envFile)) { return }
  $tmp = Join-Path $env:TEMP ("copilot-signal-{0}.json" -f [guid]::NewGuid())
  (@{ _m = 'POST'; event = 'blocked'; text = $Why.Substring(0, [Math]::Min(120, $Why.Length)); session = $sid; source = 'guard' } | ConvertTo-Json -Compress) | Set-Content $tmp
  $worker = Join-Path $PSScriptRoot 'lib\copilot-signal-send.ps1'
  Start-Process -WindowStyle Hidden -FilePath pwsh -ArgumentList '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $worker, '-Queue', $tmp, '-EnvFile', $envFile -ErrorAction SilentlyContinue | Out-Null
}

# ---------------------------------------------------------------- commands --
$cmd = ''
# X-01 (2026-10-05): edit tools carry FILE TEXT in tool_input.input/content, not a command.
# Scanning it blocked patches whose context merely mentioned a build/deploy/SQL word
# (CI workflow edits, hook tests, docs) and pushed agents to write files through ad-hoc
# scripts instead -- less safe, not more. Edit payloads skip command rules; the
# whole-file clobber check at the bottom still applies to create_file.
$isEditTool = $tool -match '^(apply_patch|applyPatch|replace_string_in_file|multi_replace_string_in_file|insert_edit_into_file|edit_file|editFile|create_file|createFile|write_file|writeFile|edit_notebook_file|str_replace_editor|Edit|MultiEdit|Write)$'
foreach ($p in 'command', 'input', 'args') {
  if ($payload.PSObject.Properties.Name -contains $p -and $payload.$p) {
    $cmd = "$($payload.$p)"; break
  }
}
# Harnesses disagree on casing and VS Code nests the command one level down.
# Verified 2026-08-31: VS Code sends {"tool_name":...,"tool_input":{"command":...}}
# while this guard only read camelCase `toolInput`, so EVERY destructive-command
# check failed open in VS Code -- 790 invocations, zero blocks. Read both, and
# accept tool_input as either an object or a bare string.
foreach ($container in $payload.tool_input, $payload.toolInput) {
  if ($cmd -or -not $container) { continue }
  if ($container -is [string]) { $cmd = $container; continue }
  foreach ($k in 'command', 'input', 'args', 'commandLine') {
    if ($container.PSObject.Properties.Name -contains $k -and $container.$k) {
      $cmd = "$($container.$k)"; break
    }
  }
}
if ($isEditTool) { $cmd = '' }

# ---- ADR 0001: slot leases (E:\gh\.wt\<repo>\<slot>) --------------------------------------
# (1) Renew: any tool call whose command or file path touches a leased slot is activity for that
#     lease (cheap: a dir scan of ~/.codai/coord/leases + one file timestamp).
# (2) Protect: deleting / removing a leased slot (or a parent of one) is refused, whatever the tool.
$script:WtRootG = if ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT } else { 'E:\gh\.wt' }
$script:LeaseRootG = Join-Path $(if ($env:AGENTQ_HOME) { $env:AGENTQ_HOME } else { Join-Path $HOME '.codai\coord' }) 'leases'
function Get-GuardLeases {
  $out = @()
  foreach ($f in Get-ChildItem $script:LeaseRootG -Recurse -Filter '*.json' -File -EA SilentlyContinue) {
    $j = $null; try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { }
    $p = if ($j -and $j.path) { "$($j.path)" } else { Join-Path (Join-Path $script:WtRootG $f.Directory.Name) $f.BaseName }
    $out += [pscustomobject]@{ path = $p.TrimEnd('\'); file = $f.FullName; who = $(if ($j) { "$($j.session) ($($j.leaseId)) '$($j.purpose)'" } else { 'unreadable lease' }); id = $(if ($j) { "$($j.leaseId)" } else { '' }) }
  }
  $out
}
$touchText = "$cmd"
foreach ($container in $payload.tool_input, $payload.toolInput) { if ($container -and $container -isnot [string]) { foreach ($k in 'filePath', 'path', 'file', 'dirPath', 'cwd') { if ($container.PSObject.Properties.Name -contains $k -and $container.$k) { $touchText += " $($container.$k)" } } } }
if ($touchText -match '(?i)[\\/]\.wt[\\/]' -and (Test-Path $script:LeaseRootG)) {
  $norm = $touchText.Replace('/', '\')
  $gl = @(Get-GuardLeases)
  foreach ($l in $gl) { if ($norm.IndexOf($l.path, [StringComparison]::OrdinalIgnoreCase) -ge 0) { try { [IO.File]::SetLastWriteTimeUtc("$($l.file).hb", [DateTime]::UtcNow) } catch { } } }
  if ($cmd) {
    $isDelete = $cmd -match '(?i)\b(Remove-Item|rm|rmdir|rd|del|ri|erase)\b' -or $cmd -match '(?i)\bgit\b[^;|&]*\bworktree\s+(remove|move|prune)\b' -or $cmd -match '(?i)\[IO\.Directory\]::Delete|Directory\.Delete|rmSync|rimraf'
    # The sanctioned tools check the lease themselves (and back up); everything else is refused.
    $viaTool = $cmd -match '(?i)(worktree|agentq|deploy-clean)\.ps1'
    if ($isDelete -and -not $viaTool) {
      foreach ($l in $gl) {
        $lp = $l.path
        $parent = Split-Path -Parent $lp
        # Only the slot ROOT (or a parent) - the holder must still be able to delete files inside it.
        $hitsSlot = $norm -match ('(?i)' + [regex]::Escape($lp) + '\\?([''"\s]|$)')
        # a parent (E:\gh\.wt\<repo> or E:\gh\.wt) deleted with a recursive flag also kills the slot
        $hitsParent = ($norm -match [regex]::Escape($parent) + '([''"\s]|$)' -or $norm -match [regex]::Escape($script:WtRootG) + '([''"\s]|$)') -and $cmd -match '(?i)(-Recurse|-r\b|/s\b|-rf?\b|recursive)'
        if ($hitsSlot -or $hitsParent) {
          [Console]::Error.WriteLine("BLOCKED by guard (ADR 0001): '$lp' is a LEASED worktree slot - held by $($l.who). Deleting it destroys another agent's live work (incident 2026-10-06: a cleanup removed a live worktree and a deploy slot mid-release).")
          [Console]::Error.WriteLine("Release your own slot:  pwsh -NoProfile -File `"$env:USERPROFILE\.copilot\bin\agentq.ps1`" unlease -Repo `"$lp`" -LeaseId $($l.id)   (backs up, then frees)")
          [Console]::Error.WriteLine("Cleanup: pwsh -NoProfile -File `"$env:USERPROFILE\.copilot\bin\worktree.ps1`" migrate|prune -All   (skips leased slots). Stale leases expire on their own (agentq sweep).")
          Signal-Blocked 'delete of leased slot'
          Deny-Exit
        }
      }
    }
  }
}
# Raw `git worktree remove` / `move` anywhere: only the tools may do it (they check leases + back up).
if ($cmd -match '\bgit\b[^;|&]*\bworktree\s+(remove|move)\b' -and $cmd -notmatch '(?i)(worktree|agentq|deploy-clean)\.ps1') {
  [Console]::Error.WriteLine("BLOCKED by guard (ADR 0001): raw 'git worktree remove/move' skips the lease check and the backup. Use: pwsh -NoProfile -File `"$env:USERPROFILE\.copilot\bin\worktree.ps1`" remove -Path <dir>  (or unlease your slot).")
  Deny-Exit
}
# Stale-script trap (hit 3x, last 2026-10-05: a denied create_file of ship5.ps1 was run in the
# SAME parallel tool block, so the OLD script re-committed files under a wrong message). Every
# denied whole-file write leaves a marker; running a script with that path within 10 min is blocked.
$script:DeniedDir = Join-Path $env:TEMP 'copilot-guard-denied'
if (-not $isEditTool -and $cmd -and (Test-Path $script:DeniedDir)) {
  foreach ($m in Get-ChildItem $script:DeniedDir -File -EA SilentlyContinue) {
    if ($m.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-10)) { Remove-Item $m.FullName -EA SilentlyContinue; continue }
    $denied = (Get-Content $m.FullName -Raw -EA SilentlyContinue).Trim()
    if (-not $denied) { continue }
    $leafD = Split-Path $denied -Leaf
    if ($cmd.IndexOf($denied, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or ($leafD -match '\.(ps1|mjs|js|ts|cmd|sh|py)$' -and $cmd -match "(^|[\\/\s'`"])$([regex]::Escape($leafD))(\s|'|`"|$)")) {
      [Console]::Error.WriteLine("BLOCKED by guard (stale script): the create_file of '$denied' was DENIED moments ago, so the file on disk is the OLD script, not what you just wrote. Write it under a NEW filename, check that the create succeeded, then run it. Never batch create_file with the run of that file.")
      Signal-Blocked 'stale script run'
      Deny-Exit
    }
  }
}
if (-not $cmd -and -not $isEditTool) { Flush-Stderr; exit 0 }

# pattern -> why it is blocked
$blocked = [ordered]@{
  # Shared clone: sweeps other agents' uncommitted work into your commit.
  'git\s+add\s+(-A|--all|\.)(\s|$)'   = "git add -A/. in a shared clone stages other agents' work. Stage explicit paths."
  # -am / -a / --all: combined short flags must match too.
  'git\s+commit\s+(-[a-z]*a[a-z]*|--all)(\s|$)' = 'git commit -a/-am stages every tracked change, including other agents''. Stage explicit paths instead.'
  # Irreversible history / working-tree destruction.
  # --force-with-lease is safer than --force but still rewrites remote history,
  # and it appears AFTER the refspec, so the old pattern missed it entirely.
  'git\s+push\s+.*(--force-with-lease|--force|-f)(\s|=|$)' = 'Force-push rewrites remote history, --force-with-lease included. Ask the user first.'
  'git\s+reset\s+--hard'              = 'git reset --hard destroys uncommitted work, including other agents''. Ask first.'
  'git\s+clean\s+-[a-z]*f'            = 'git clean -f deletes untracked files irreversibly. Ask first.'
  # Every form of "throw away working-tree changes". In a shared clone the
  # discarded work is usually another agent's and is NOT recoverable: it was
  # never committed, and if it was never staged there is no dangling blob.
  # Destructive forms only: "checkout -- <path>", "checkout ." and
  # "checkout <ref> -- <path>". Branch work (-b/-B/--help/--track) is fine.
  'git\s+checkout\s+(?!-b\b|-B\b|--help|--track|--orphan)(--\s+\S|\.(\s|$)|\S+\s+--\s+\S)' = 'git checkout -- <path> discards uncommitted changes permanently, and in a shared clone they are probably another agent''s. Use `git stash push -- <path>` if you must set changes aside, or fix forward. To switch branch, ask the user.'
  'git\s+restore\b'                   = 'git restore discards uncommitted changes permanently. In a shared clone that work is probably another agent''s. Fix forward instead.'
  # Stash traps (hit twice, 2026-09-20 and 2026-09-21): flags after `--` are pathspecs, so
  # `stash push -- <path> -m msg` stashes NOTHING and the following `stash pop` applies the
  # FOREIGN stash@{0} into the shared tree (UU conflicts + staged files).
  # `git -C <dir> stash …` is how the incident command was actually written; allow global options.
  'git(\s+-C\s+\S+|\s+--git-dir=\S+|\s+--work-tree=\S+)*\s+stash\s+push\b.*\s--\s.*\s-(m|q|u|a|k|p)\b' = 'git stash push: flags after `--` are treated as PATHS, nothing is stashed. Put -m/-u/... BEFORE the `--`.'
  'git(\s+-C\s+\S+|\s+--git-dir=\S+|\s+--work-tree=\S+)*\s+stash\s+(pop|apply|drop)(\s|$)(?!\s*[''"]?stash@\{)' = 'Bare `git stash pop/apply/drop` acts on stash@{0}, which in a shared clone is usually ANOTHER agent''s stash. Name the entry explicitly (stash@{N}) after `git stash list`.'
  # Destructive SQL.
  '\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b' = 'Destructive SQL. Ask the user before dropping or truncating.'
  'DELETE\s+FROM\s+\w+\s*(;|$)'       = 'DELETE with no WHERE clause. Ask the user first.'
  # Filesystem.
  'rm\s+-[a-z]*rf?\s+[/~]\s*$'        = 'Recursive delete of a root or home path.'
  'Remove-Item.*-Recurse.*-Force.*(C:\\|/)\s*$' = 'Recursive force delete at a drive root.'
}

foreach ($pat in $blocked.Keys) {
  if ($cmd -match $pat) {
    [Console]::Error.WriteLine("BLOCKED by guard-command hook: $($blocked[$pat])")
    [Console]::Error.WriteLine("Command: $cmd")
    Signal-Blocked $blocked[$pat]
    Deny-Exit
  }
}

# Commits (policy 2026-09-27, agentq). A `git commit` WITHOUT a pathspec commits
# EVERYTHING staged, including other agents' files (7cc672f7 swallowed 43 foreign files;
# 44 more swept on 2026-09-26). Commits go through `agentq commit -Paths ...` (pathspec +
# repo commit queue + trailers + push-retry) or at least `git commit ... -- <paths>`.
# agentq itself runs git from inside its own script, which this hook never sees.
$aqPath = Join-Path $env:USERPROFILE '.copilot\bin\agentq.ps1'
if ($cmd -match '(^|[;&|({]\s*|\bthen\s+)git(\.exe)?(\s+-C\s+\S+|\s+-c\s+\S+)*\s+commit\b' -and $cmd -notmatch 'agentq\.ps1' -and
    $cmd -notmatch '\bcommit\b[^;|&]*\s--\s+\S' -and $cmd -notmatch '\bcommit\b[^;|&]*--(amend|allow-empty)\b' -and
    $cmd -notmatch '\bcommit-tree\b') {
  [Console]::Error.WriteLine("BLOCKED by guard-command hook: 'git commit' without a pathspec commits EVERYTHING staged, including other agents' files (incidents 7cc672f7, 2026-09-26).")
  [Console]::Error.WriteLine("Use:  pwsh -NoProfile -File `"$aqPath`" commit -Purpose '<why>' -Message '<type(scope): msg>' -Paths a.ts,b.ts")
  [Console]::Error.WriteLine("      (queues on commit:<repo>, commits ONLY those paths, adds Agent-Session/Agent-Purpose trailers, pushes with fetch+merge retry; -NoPush to skip the push)")
  [Console]::Error.WriteLine("Or at minimum:  git commit -m '<msg>' -- <path> <path>")
  Signal-Blocked 'git commit without pathspec'
  Deny-Exit
}

# Frozen / blocked resources (agentq mark). Refuse the matching command class so an
# incident freeze is not bypassed by a direct command. Marks live in ~/.codai/coord/marks.
$markDir = if ($env:AGENTQ_HOME) { Join-Path $env:AGENTQ_HOME 'marks' } else { Join-Path $env:USERPROFILE '.codai\coord\marks' }
if ((Test-Path $markDir) -and $cmd -notmatch 'agentq\.ps1') {
  $marks = @(Get-ChildItem $markDir -Filter '*.json' -File -EA SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
  if ($marks) {
    $repoName = $null
    try {
      $cd = git rev-parse --path-format=absolute --git-common-dir 2>$null
      if ($LASTEXITCODE -eq 0 -and $cd) { $repoName = (Split-Path -Leaf (Split-Path -Parent $cd.Replace('/', '\'))).ToLowerInvariant() }
    } catch { }
    $classes = @()
    if ($cmd -match '\b(pnpm|npm|yarn|turbo|next|tsc|cargo|gradlew?)\b.*\b(build|typecheck|test)\b|run-build\.ps1') { $classes += 'build' }
    if ($cmd -match '(^|[;&|({]\s*)git(\.exe)?\b[^;|&]*\s(commit|push)\b') { $classes += 'commit' }
    if ($cmd -match '\b(pnpm|npm|yarn)\s+(install|i|ci|add|remove)\b') { $classes += 'install' }
    if ($cmd -match 'deploy-clean\.ps1|deploy-[a-z0-9-]+\.(ps1|mjs)|scripts[\\/]deploy\.mjs|\bgcloud\s+(run|builds)\b|\bvercel\b|\bterraform\s+apply\b|\bdocker\s+(build|push)\b') { $classes += 'deploy' }
    foreach ($m in $marks) {
      $r = "$($m.resource)"
      $kind = ($r -split ':')[0]
      $mRepo = if (($r -split ':').Count -ge 2) { ($r -split ':')[1] } else { $null }
      $repoOk = (-not $mRepo) -or ($mRepo -eq 'machine') -or ($repoName -and $mRepo -eq $repoName)
      if ($repoOk -and $classes -contains $kind) {
        # deploy:<repo>:<target> only blocks commands that name that target (or no target known).
        if ($kind -eq 'deploy' -and ($r -split ':').Count -ge 3) {
          $tgt = ($r -split ':')[2]
          if ($tgt -ne 'any' -and $cmd -notmatch [regex]::Escape($tgt)) { continue }
        }
        [Console]::Error.WriteLine("BLOCKED by guard-command hook: $r is $("$($m.state)".ToUpper()) since $($m.at) by $($m.session): $($m.reason)")
        [Console]::Error.WriteLine("Do not bypass a freeze. Check: pwsh -NoProfile -File `"$aqPath`" status -All")
        [Console]::Error.WriteLine("Clear it only if the reason no longer holds: pwsh -NoProfile -File `"$aqPath`" mark -Resource $r -State clear -Reason '<why safe>'")
        Signal-Blocked "$r $($m.state)"
        Deny-Exit
      }
    }
  }
}

# Playwright runs in the cloud (brivio ADR-0214, user 2026-09-28: "sa nu mai ruleze deloc pe
# masina asta"). Refuses a command that STARTS `playwright test` at a command position (start of
# line / after ; & | ( { / after cd x;), not one that merely mentions it inside a string - the
# first version blocked a .Replace() whose literal contained the text. list/show-report/install
# pass. PW_ALLOW_LOCAL=1 is the deliberate one-off escape. The config refuses too
# (apps/web/playwright.config.ts); this catches it before a dev server spins up.
$pwPos = '(^|[;&|({]\s*|\r?\n\s*)'
$pwEnv = '(\$env:[A-Z_]+\s*=\s*\S+\s*;\s*|[A-Z_]+=\S+\s+)*'
if ($cmd -notmatch 'PW_ALLOW_LOCAL\s*=\s*1' -and (
    $cmd -match ($pwPos + $pwEnv + '(npx\s+|pnpm\s+(--filter\s+\S+\s+|-F\s+\S+\s+)?exec\s+|pnpm\s+dlx\s+)?playwright(\.cmd)?\s+test\b(?![^;|&\r\n]*--list)') -or
    $cmd -match ($pwPos + $pwEnv + 'node\s+\S*playwright(-core)?[\\/](test[\\/])?cli\.js\s+test\b(?![^;|&\r\n]*--list)') -or
    $cmd -match ($pwPos + $pwEnv + 'pnpm\s+(--filter\s+\S+\s+)?(run\s+)?(a11y:routes|a11y:ibm|e2e:visual:local)\b'))) {
  [Console]::Error.WriteLine('BLOCKED by guard-command hook: Playwright does not run on this machine (brivio ADR-0214).')
  [Console]::Error.WriteLine('Run it on an ephemeral cloud VM instead (report lands in apps/web/playwright-report/):')
  [Console]::Error.WriteLine('    pnpm e2e:cloud [spec ...] [--project=...]              # against https://local.brivio.ro')
  [Console]::Error.WriteLine('    pnpm e2e:cloud --target https://staging.brivio.ro ...  # any origin')
  [Console]::Error.WriteLine('    pnpm e2e:cloud --target vm ...                         # dev server + Postgres on the VM')
  [Console]::Error.WriteLine('    pnpm e2e:cloud --target vm --cmd "pnpm a11y:routes"')
  [Console]::Error.WriteLine('Deliberate one-off local run only if the user asked for it: prefix PW_ALLOW_LOCAL=1.')
  Signal-Blocked 'local playwright run'
  Deny-Exit
}

# Worktrees (policy 2026-09-27): 45 ad-hoc sibling worktrees had piled up in E:\gh
# (brivio-launch-p3-wt-deploy-wt, codai/.deploy-opus-min, ...), each with its own
# multi-GB node_modules, none ever removed. Every worktree must be created by
# ~/.copilot/bin/worktree.ps1 (lands in E:\gh\.wt\<repo>\<name>, recorded, prunable)
# or by deploy-clean.ps1 (pooled slots). `git worktree remove --force` is also
# refused: it follows junctions into their targets (memory 2026-09-21).
# ADR 0001 (2026-10-06): ANY raw `git worktree add` is refused, also inside E:\gh\.wt - only the
# standard slots exist and they are created by agentq lease (unleased ad-hoc trees were deleted live).
if ($cmd -match '\bgit\b[^;|&]*\bworktree\s+add\b' -and $cmd -notmatch '(?i)(worktree|agentq|deploy-clean)\.ps1') {
  [Console]::Error.WriteLine("BLOCKED by guard-command hook: raw 'git worktree add'. Worktrees are fixed, LEASED slots (E:\gh\.wt\<repo>\task-N|release|land, ADR 0001).")
  [Console]::Error.WriteLine("Use:  pwsh -NoProfile -File `"$env:USERPROFILE\.copilot\bin\agentq.ps1`" lease -Purpose '<why>' [-Branch <b>] [-Ref <sha>]   -> prints the slot path + leaseId")
  [Console]::Error.WriteLine("Deploys: deploy-clean.ps1 (release slot). Landing: agentq land -Branch <b> -Onto <dev|main>. Done: agentq unlease -Repo <slot> -LeaseId <id>")
  Deny-Exit
}
if ($cmd -match '\bgit\b[^;|&]*\bworktree\s+remove\b[^;|&]*(--force|-f\b)') {
  [Console]::Error.WriteLine("BLOCKED by guard-command hook: 'git worktree remove --force' follows Windows junctions and deletes their TARGETS (emptied another clone's node_modules, 2026-09-21), and discards uncommitted work.")
  [Console]::Error.WriteLine("Use:  pwsh -NoProfile -File `"$env:USERPROFILE\.copilot\bin\worktree.ps1`" remove -Path <dir>   (refuses dirty/unpushed; rmdir-based, junction-safe)")
  Deny-Exit
}

# Builds: serialise instead of warning. Two turbo/tsc runs in one clone share
# .next, .turbo and *.tsbuildinfo, so a concurrent run corrupts incremental
# state and yields phantom errors the other agent then tries to "fix".
# Measured here: 231 pairs of overlapping sessions in brivio alone.
$isBuild = $cmd -match '\b(pnpm|npm|yarn|npx)\s+(run\s+)?(build|typecheck|test:e2e)\b' -or
           # Workspace-scoped forms are how builds are actually invoked in a
           # monorepo: `pnpm --filter @scope/pkg build`, `pnpm -F web typecheck`.
           # The verb sits after the filter, so the pattern above never matched.
           $cmd -match '\b(pnpm|npm|yarn)\s+(--filter|-F|--workspace|-w)\s+\S+\s+(run\s+)?(build|typecheck)\b' -or
           $cmd -match '\bturbo\s+(run\s+)?build\b' -or
           $cmd -match '\bnext\s+build\b' -or
           $cmd -match '\btsc\s+--noEmit\b' -or
           # Agents invoke the compiler directly to raise the heap:
           #   node --max-old-space-size=8192 node_modules/typescript/lib/tsc.js --noEmit
           # Two of those on apps/web ran concurrently at 8 GB each and killed
           # the extension host with "Worker terminated ... JS heap out of
           # memory". The `tsc --noEmit` pattern above never matched this form.
           $cmd -match 'typescript[/\\]lib[/\\]tsc\.js' -or
           $cmd -match '\bnode\b.*\btsc\.js\b'
# The wrapper invokes the real command, so never intercept the wrapper itself.
$viaWrapper = $cmd -match 'run-build\.ps1'

if ($isBuild -and -not $viaWrapper) {
  $runner = Join-Path $env:USERPROFILE '.copilot\hooks\run-build.ps1'
  $lock = Join-Path (Get-Location) '.copilot-tmp\build.lock'
  try {
    $top = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { $lock = Join-Path $top.Replace('/', '\') '.copilot-tmp\build.lock' }
  } catch { }

  $busy = $false
  if (Test-Path $lock) {
    try {
      $l = Get-Content $lock -Raw | ConvertFrom-Json
      if ($l.pid -and (Get-Process -Id $l.pid -EA SilentlyContinue)) { $busy = $true }
    } catch { }
  }

  if ($busy) {
    [Console]::Error.WriteLine("BLOCKED by guard-command hook: another session is already running a build in this repo. Starting a second one corrupts shared incremental state (.next/.turbo/tsbuildinfo) for both.")
    [Console]::Error.WriteLine("Check it:  pwsh -NoProfile -File `"$runner`" -Status")
    [Console]::Error.WriteLine("Then either read their log, or wait for it:")
    [Console]::Error.WriteLine("  pwsh -NoProfile -File `"$runner`" -Command '$cmd' -Wait")
    Deny-Exit
  }

  [Console]::Error.WriteLine("BLOCKED by guard-command hook: run builds through the lock wrapper so a concurrent session cannot start a second one mid-flight. It also captures full output to a file, which you and later sessions can re-read instead of rebuilding.")
  [Console]::Error.WriteLine("Use:  pwsh -NoProfile -File `"$runner`" -Command '$cmd'")
  Deny-Exit
}

# ---------------------------------------------------------------------------
# Deploys and release builds run ONLY from a clean tree (user instruction
# 2026-09-21, re-stated 2026-09-22 after an incident). The shared clone is
# never clean by design, and on 2026-09-22 a gateway deploy from it (a) had
# its staged set swept into another agent's commit twice, so the image tag
# named a commit whose content it did not match, and (b) built other agents'
# half-finished files. The rule already existed in three rule files and was
# violated anyway — hence a hard block here.
#
# Allowed only when EITHER
#   - the repo root the command runs in has an empty `git status --porcelain`
#     (a detached deploy worktree / CI checkout), or
#   - the command is the clean-worktree wrapper itself (deploy-clean.ps1), or
#   - the command is a pure read (describe/list/log/status/read/services describe).
# ---------------------------------------------------------------------------
$isDeploy = $cmd -match '\bgcloud\s+run\s+(services\s+(replace|update|deploy)|deploy)\b' -or
            $cmd -match '\bgcloud\s+builds\s+submit\b' -or
            $cmd -match '\bgcloud\s+run\s+jobs\s+(deploy|update|replace|create)\b' -or
            $cmd -match '\bvercel\s+(deploy|--prod|-p)(\s|$)' -or
            $cmd -match '\bvercel\b.*\s--prod\b' -or
            $cmd -match '\bdocker\s+(build|buildx\s+build|push)\b' -or
            $cmd -match '\bfly\s+deploy\b' -or
            $cmd -match '\bwrangler\s+(deploy|publish)\b' -or
            $cmd -match '\bterraform\s+apply\b' -or
            $cmd -match '\bpulumi\s+up\b' -or
            $cmd -match '\bcargo\s+(tauri\s+build|publish)\b' -or
            $cmd -match '\bnpm\s+publish\b|\bpnpm\s+publish\b' -or
            $cmd -match '\btwine\s+upload\b|\bhatch\s+publish\b' -or
            $cmd -match '\bgradlew?\b.*\b(assembleRelease|bundleRelease|publish)\b' -or
            # Repo deploy scripts: anything under scripts/ops named deploy-*.ps1
            # EXCEPT the clean-worktree wrapper.
            ($cmd -match 'scripts[\\/]ops[\\/]deploy-[a-z0-9-]+\.ps1' -and $cmd -notmatch 'deploy-clean\.ps1')
$viaCleanWrapper = $cmd -match 'deploy-clean\.ps1'

if ($isDeploy -and -not $viaCleanWrapper) {
  $dirty = $null
  try {
    $top = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) {
      $dirty = git -C $top status --porcelain --untracked-files=normal 2>$null
    }
  } catch { }
  # Not a git repo → nothing to protect (e.g. terraform in a scratch dir).
  if ($null -ne $dirty -and @($dirty | Where-Object { $_ }).Count -gt 0) {
    $n = @($dirty | Where-Object { $_ }).Count
    $wrapper = Join-Path $env:USERPROFILE '.copilot\hooks\deploy-clean.ps1'
    [Console]::Error.WriteLine("BLOCKED by guard-command hook: deploy/release from a DIRTY tree ($n changed/untracked paths). A deploy image must be built from a detached worktree at an exact commit, or the tag names content it does not contain and ships other agents' half-finished files (incident 2026-09-22).")
    [Console]::Error.WriteLine("Use the clean-worktree wrapper (commit first; it deploys HEAD by default):")
    [Console]::Error.WriteLine("  pwsh -NoProfile -File `"$wrapper`" -Command '$cmd'")
    [Console]::Error.WriteLine("  pwsh -NoProfile -File `"$wrapper`" -Ref <sha> -Command '<deploy command>'")
    Deny-Exit
  }
}

# Not dangerous alone, but destructive to OTHER concurrent sessions sharing this
# clone. Warn and let it through: the agent sees the note and can coordinate.
$warn = [ordered]@{
  '\b(pnpm|npm|yarn)\s+(install|i|ci)(\s|$)' = 'This rewrites node_modules under any other session currently building or testing. Confirm nobody else is mid-run.'
  '\b(db:push|db:migrate|drizzle-kit\s+push|prisma\s+migrate)' = 'Schema change on a DB another session may be querying. Coordinate before running.'
  '\b(taskkill|Stop-Process|pkill)\b'        = 'You may be killing a dev server or watcher another session started. Verify the PID is yours.'
  '\bpnpm\s+(clean|--filter\s+\S+\s+clean)'  = 'Deleting build output another session may be using.'
}

foreach ($pat in $warn.Keys) {
  if ($cmd -match $pat) {
    [Console]::Error.WriteLine("WARNING (guard-command): $($warn[$pat])")
    break
  }
}

# ------------------------------------------------------------------ writes --
# Targeted edits (apply_patch / replace_string) are safe: they fail loudly on a
# stale anchor instead of silently discarding. Only whole-file writes clobber.
if ($tool -notmatch 'create_file|createFile|write_file|writeFile|WriteAllLines|create_new') { Flush-Stderr; exit 0 }
# Targeted edits (apply_patch / replace_string) are safe: they fail loudly on a
# stale anchor instead of silently discarding. Only whole-file writes clobber.
if ($tool -notmatch 'create_file|createFile|write_file|writeFile|WriteAllLines|create_new') { Flush-Stderr; exit 0 }

$path = $null
foreach ($p in 'filePath', 'path', 'file', 'uri') {
  if ($payload.PSObject.Properties.Name -contains $p -and $payload.$p) { $path = "$($payload.$p)"; break }
}
foreach ($container in $payload.tool_input, $payload.toolInput) {
  if ($path -or -not $container) { continue }
  foreach ($p in 'filePath', 'path', 'file', 'uri') {
    if ($container.PSObject.Properties.Name -contains $p -and $container.$p) {
      $path = "$($container.$p)"; break
    }
  }
}
if (-not $path) { Flush-Stderr; exit 0 }

$path = $path -replace '^file:///', '' -replace '/', '\'
# Creating a genuinely new file cannot clobber anything.
if (-not (Test-Path $path)) { Flush-Stderr; exit 0 }

$WindowMin = 15
$leaf = Split-Path $path -Leaf
$parent = Split-Path (Split-Path $path -Parent) -Leaf
$needle = if ($parent) { "%$parent%$leaf" } else { "%$leaf" }
$mine = $env:COPILOT_SESSION_ID

$stores = @()
Get-ChildItem (Join-Path $HOME 'VS Code Insiders Profiles') -Directory -EA SilentlyContinue | ForEach-Object {
  $p = "$($_.FullName)\User\globalStorage\github.copilot-chat\session-store.db"
  if (Test-Path $p) { $stores += [pscustomobject]@{ Name = $_.Name; Path = $p } }
}
$d = "$env:APPDATA\Code - Insiders\User\globalStorage\github.copilot-chat\session-store.db"
if (Test-Path $d) { $stores += [pscustomobject]@{ Name = 'DEFAULT'; Path = $d } }

$owners = @()
foreach ($s in $stores) {
  $tmp = Join-Path $env:TEMP "gw_$($s.Name).db"
  try {
    Copy-Item $s.Path $tmp -Force -EA Stop
    # Recent writes live in the WAL; without it the newest rows are invisible,
    # which is exactly the window this hook cares about.
    foreach ($ext in '-wal', '-shm') {
      if (Test-Path "$($s.Path)$ext") { Copy-Item "$($s.Path)$ext" "$tmp$ext" -Force -EA SilentlyContinue }
    }
  } catch { continue }

  # datetime() on both sides: updated_at is '...T..Z' while datetime('now')
  # yields '... ...', and 'T' sorts after a space, so raw comparison is always true.
  $sql = @"
SELECT s.id, s.updated_at, COALESCE(s.agent_name,'?')
FROM session_files sf JOIN sessions s ON s.id = sf.session_id
WHERE sf.file_path LIKE '$needle'
  AND datetime(s.updated_at) > datetime('now','-$WindowMin minutes')
ORDER BY s.updated_at DESC;
"@
  foreach ($r in (sqlite3 -separator '|' $tmp "$sql" 2>$null)) {
    if (-not $r) { continue }
    $f = $r -split '\|'
    if ($mine -and $f[0] -eq $mine) { continue }
    $owners += [pscustomobject]@{
      Profile = $s.Name
      Session = $f[0].Substring(0, [Math]::Min(8, $f[0].Length))
      Updated = $f[1]
      Agent   = if ($f.Count -gt 2) { $f[2] } else { '?' }
    }
  }
  Remove-Item $tmp, "$tmp-wal", "$tmp-shm" -Force -EA SilentlyContinue
}

if (-not $owners) { Flush-Stderr; exit 0 }

$top = $owners | Sort-Object Updated -Descending | Select-Object -First 1
[Console]::Error.WriteLine("BLOCKED by guard-write hook: another session edited '$leaf' in the last $WindowMin minutes. A whole-file write would silently discard their work -- this is how the CHANGELOG incident started.")
[Console]::Error.WriteLine("  session $($top.Session)  profile $($top.Profile)  agent $($top.Agent)  last active $($top.Updated) UTC")
[Console]::Error.WriteLine("Do this instead:")
[Console]::Error.WriteLine("  1. Re-read the file NOW -- it is not what you last saw.")
[Console]::Error.WriteLine("  2. Apply a targeted edit (apply_patch / replace_string) so a stale anchor fails loudly instead of overwriting.")
[Console]::Error.WriteLine("  3. Confirm ownership: pwsh -NoProfile -File `"$env:USERPROFILE\.copilot\hooks\who-owns-file.ps1`" -Path `"$path`"")
try {
  New-Item -ItemType Directory -Force -Path $script:DeniedDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $script:DeniedDir ([guid]::NewGuid().ToString('n') + '.txt')), $path)
} catch { }
Deny-Exit

foreach ($p in 'command', 'input', 'args') {
  if ($payload.PSObject.Properties.Name -contains $p -and $payload.$p) {
    $cmd = "$($payload.$p)"; break
  }
}
# Harnesses disagree on casing and VS Code nests the command one level down.
# Verified 2026-08-31: VS Code sends {"tool_name":...,"tool_input":{"command":...}}
# while this guard only read camelCase `toolInput`, so EVERY destructive-command
# check failed open in VS Code -- 790 invocations, zero blocks. Read both, and
# accept tool_input as either an object or a bare string.
foreach ($container in $payload.tool_input, $payload.toolInput) {
  if ($cmd -or -not $container) { continue }
  if ($container -is [string]) { $cmd = $container; continue }
  foreach ($k in 'command', 'input', 'args', 'commandLine') {
    if ($container.PSObject.Properties.Name -contains $k -and $container.$k) {
      $cmd = "$($container.$k)"; break
    }
  }
}
if (-not $cmd) { Flush-Stderr; exit 0 }
if (-not $cmd) { Flush-Stderr; exit 0 }

# pattern -> why it is blocked
$blocked = [ordered]@{
  # Shared clone: sweeps other agents' uncommitted work into your commit.
  'git\s+add\s+(-A|--all|\.)(\s|$)'   = "git add -A/. in a shared clone stages other agents' work. Stage explicit paths."
  # -am / -a / --all: combined short flags must match too.
  'git\s+commit\s+(-[a-z]*a[a-z]*|--all)(\s|$)' = 'git commit -a/-am stages every tracked change, including other agents''. Stage explicit paths instead.'
  # Irreversible history / working-tree destruction.
  # --force-with-lease is safer than --force but still rewrites remote history,
  # and it appears AFTER the refspec, so the old pattern missed it entirely.
  'git\s+push\s+.*(--force-with-lease|--force|-f)(\s|=|$)' = 'Force-push rewrites remote history, --force-with-lease included. Ask the user first.'
  'git\s+reset\s+--hard'              = 'git reset --hard destroys uncommitted work, including other agents''. Ask first.'
  'git\s+clean\s+-[a-z]*f'            = 'git clean -f deletes untracked files irreversibly. Ask first.'
  # Every form of "throw away working-tree changes". In a shared clone the
  # discarded work is usually another agent's and is NOT recoverable: it was
  # never committed, and if it was never staged there is no dangling blob.
  # Destructive forms only: "checkout -- <path>", "checkout ." and
  # "checkout <ref> -- <path>". Branch work (-b/-B/--help/--track) is fine.
  'git\s+checkout\s+(?!-b\b|-B\b|--help|--track|--orphan)(--\s+\S|\.(\s|$)|\S+\s+--\s+\S)' = 'git checkout -- <path> discards uncommitted changes permanently, and in a shared clone they are probably another agent''s. Use `git stash push -- <path>` if you must set changes aside, or fix forward. To switch branch, ask the user.'
  'git\s+restore\b'                   = 'git restore discards uncommitted changes permanently. In a shared clone that work is probably another agent''s. Fix forward instead.'
  # Stash traps (hit twice, 2026-09-20 and 2026-09-21): flags after `--` are pathspecs, so
  # `stash push -- <path> -m msg` stashes NOTHING and the following `stash pop` applies the
  # FOREIGN stash@{0} into the shared tree (UU conflicts + staged files).
  # `git -C <dir> stash …` is how the incident command was actually written; allow global options.
  'git(\s+-C\s+\S+|\s+--git-dir=\S+|\s+--work-tree=\S+)*\s+stash\s+push\b.*\s--\s.*\s-(m|q|u|a|k|p)\b' = 'git stash push: flags after `--` are treated as PATHS, nothing is stashed. Put -m/-u/... BEFORE the `--`.'
  'git(\s+-C\s+\S+|\s+--git-dir=\S+|\s+--work-tree=\S+)*\s+stash\s+(pop|apply|drop)(\s|$)(?!\s*[''"]?stash@\{)' = 'Bare `git stash pop/apply/drop` acts on stash@{0}, which in a shared clone is usually ANOTHER agent''s stash. Name the entry explicitly (stash@{N}) after `git stash list`.'
  # Destructive SQL.
  '\b(DROP|TRUNCATE)\s+(TABLE|DATABASE|SCHEMA)\b' = 'Destructive SQL. Ask the user before dropping or truncating.'
  'DELETE\s+FROM\s+\w+\s*(;|$)'       = 'DELETE with no WHERE clause. Ask the user first.'
  # Filesystem.
  'rm\s+-[a-z]*rf?\s+[/~]\s*$'        = 'Recursive delete of a root or home path.'
  'Remove-Item.*-Recurse.*-Force.*(C:\\|/)\s*$' = 'Recursive force delete at a drive root.'
}

foreach ($pat in $blocked.Keys) {
  if ($cmd -match $pat) {
    [Console]::Error.WriteLine("BLOCKED by guard-command hook: $($blocked[$pat])")
    [Console]::Error.WriteLine("Command: $cmd")
    Signal-Blocked $blocked[$pat]
    Deny-Exit
  }
}

# Commits (policy 2026-09-27, agentq). A `git commit` WITHOUT a pathspec commits
# EVERYTHING staged, including other agents' files (7cc672f7 swallowed 43 foreign files;
# 44 more swept on 2026-09-26). Commits go through `agentq commit -Paths ...` (pathspec +
# repo commit queue + trailers + push-retry) or at least `git commit ... -- <paths>`.
# agentq itself runs git from inside its own script, which this hook never sees.
$aqPath = Join-Path $env:USERPROFILE '.copilot\bin\agentq.ps1'
if ($cmd -match '(^|[;&|({]\s*|\bthen\s+)git(\.exe)?(\s+-C\s+\S+|\s+-c\s+\S+)*\s+commit\b' -and $cmd -notmatch 'agentq\.ps1' -and
    $cmd -notmatch '\bcommit\b[^;|&]*\s--\s+\S' -and $cmd -notmatch '\bcommit\b[^;|&]*--(amend|allow-empty)\b' -and
    $cmd -notmatch '\bcommit-tree\b') {
  [Console]::Error.WriteLine("BLOCKED by guard-command hook: 'git commit' without a pathspec commits EVERYTHING staged, including other agents' files (incidents 7cc672f7, 2026-09-26).")
  [Console]::Error.WriteLine("Use:  pwsh -NoProfile -File `"$aqPath`" commit -Purpose '<why>' -Message '<type(scope): msg>' -Paths a.ts,b.ts")
  [Console]::Error.WriteLine("      (queues on commit:<repo>, commits ONLY those paths, adds Agent-Session/Agent-Purpose trailers, pushes with fetch+merge retry; -NoPush to skip the push)")
  [Console]::Error.WriteLine("Or at minimum:  git commit -m '<msg>' -- <path> <path>")
  Signal-Blocked 'git commit without pathspec'
  Deny-Exit
}

# Frozen / blocked resources (agentq mark). Refuse the matching command class so an
# incident freeze is not bypassed by a direct command. Marks live in ~/.codai/coord/marks.
$markDir = if ($env:AGENTQ_HOME) { Join-Path $env:AGENTQ_HOME 'marks' } else { Join-Path $env:USERPROFILE '.codai\coord\marks' }
if ((Test-Path $markDir) -and $cmd -notmatch 'agentq\.ps1') {
  $marks = @(Get-ChildItem $markDir -Filter '*.json' -File -EA SilentlyContinue | ForEach-Object { try { Get-Content $_.FullName -Raw | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
  if ($marks) {
    $repoName = $null
    try {
      $cd = git rev-parse --path-format=absolute --git-common-dir 2>$null
      if ($LASTEXITCODE -eq 0 -and $cd) { $repoName = (Split-Path -Leaf (Split-Path -Parent $cd.Replace('/', '\'))).ToLowerInvariant() }
    } catch { }
    $classes = @()
    if ($cmd -match '\b(pnpm|npm|yarn|turbo|next|tsc|cargo|gradlew?)\b.*\b(build|typecheck|test)\b|run-build\.ps1') { $classes += 'build' }
    if ($cmd -match '(^|[;&|({]\s*)git(\.exe)?\b[^;|&]*\s(commit|push)\b') { $classes += 'commit' }
    if ($cmd -match '\b(pnpm|npm|yarn)\s+(install|i|ci|add|remove)\b') { $classes += 'install' }
    if ($cmd -match 'deploy-clean\.ps1|deploy-[a-z0-9-]+\.(ps1|mjs)|scripts[\\/]deploy\.mjs|\bgcloud\s+(run|builds)\b|\bvercel\b|\bterraform\s+apply\b|\bdocker\s+(build|push)\b') { $classes += 'deploy' }
    foreach ($m in $marks) {
      $r = "$($m.resource)"
      $kind = ($r -split ':')[0]
      $mRepo = if (($r -split ':').Count -ge 2) { ($r -split ':')[1] } else { $null }
      $repoOk = (-not $mRepo) -or ($mRepo -eq 'machine') -or ($repoName -and $mRepo -eq $repoName)
      if ($repoOk -and $classes -contains $kind) {
        # deploy:<repo>:<target> only blocks commands that name that target (or no target known).
        if ($kind -eq 'deploy' -and ($r -split ':').Count -ge 3) {
          $tgt = ($r -split ':')[2]
          if ($tgt -ne 'any' -and $cmd -notmatch [regex]::Escape($tgt)) { continue }
        }
        [Console]::Error.WriteLine("BLOCKED by guard-command hook: $r is $("$($m.state)".ToUpper()) since $($m.at) by $($m.session): $($m.reason)")
        [Console]::Error.WriteLine("Do not bypass a freeze. Check: pwsh -NoProfile -File `"$aqPath`" status -All")
        [Console]::Error.WriteLine("Clear it only if the reason no longer holds: pwsh -NoProfile -File `"$aqPath`" mark -Resource $r -State clear -Reason '<why safe>'")
        Signal-Blocked "$r $($m.state)"
        Deny-Exit
      }
    }
  }
}

# Playwright runs in the cloud (brivio ADR-0214, user 2026-09-28: "sa nu mai ruleze deloc pe
# masina asta"). Refuses a command that STARTS `playwright test` at a command position (start of
# line / after ; & | ( { / after cd x;), not one that merely mentions it inside a string - the
# first version blocked a .Replace() whose literal contained the text. list/show-report/install
# pass. PW_ALLOW_LOCAL=1 is the deliberate one-off escape. The config refuses too
# (apps/web/playwright.config.ts); this catches it before a dev server spins up.
$pwPos = '(^|[;&|({]\s*|\r?\n\s*)'
$pwEnv = '(\$env:[A-Z_]+\s*=\s*\S+\s*;\s*|[A-Z_]+=\S+\s+)*'
if ($cmd -notmatch 'PW_ALLOW_LOCAL\s*=\s*1' -and (
    $cmd -match ($pwPos + $pwEnv + '(npx\s+|pnpm\s+(--filter\s+\S+\s+|-F\s+\S+\s+)?exec\s+|pnpm\s+dlx\s+)?playwright(\.cmd)?\s+test\b(?![^;|&\r\n]*--list)') -or
    $cmd -match ($pwPos + $pwEnv + 'node\s+\S*playwright(-core)?[\\/](test[\\/])?cli\.js\s+test\b(?![^;|&\r\n]*--list)') -or
    $cmd -match ($pwPos + $pwEnv + 'pnpm\s+(--filter\s+\S+\s+)?(run\s+)?(a11y:routes|a11y:ibm|e2e:visual:local)\b'))) {
  [Console]::Error.WriteLine('BLOCKED by guard-command hook: Playwright does not run on this machine (brivio ADR-0214).')
  [Console]::Error.WriteLine('Run it on an ephemeral cloud VM instead (report lands in apps/web/playwright-report/):')
  [Console]::Error.WriteLine('    pnpm e2e:cloud [spec ...] [--project=...]              # against https://local.brivio.ro')
  [Console]::Error.WriteLine('    pnpm e2e:cloud --target https://staging.brivio.ro ...  # any origin')
  [Console]::Error.WriteLine('    pnpm e2e:cloud --target vm ...                         # dev server + Postgres on the VM')
  [Console]::Error.WriteLine('    pnpm e2e:cloud --target vm --cmd "pnpm a11y:routes"')
  [Console]::Error.WriteLine('Deliberate one-off local run only if the user asked for it: prefix PW_ALLOW_LOCAL=1.')
  Signal-Blocked 'local playwright run'
  Deny-Exit
}

# Worktrees (policy 2026-09-27): 45 ad-hoc sibling worktrees had piled up in E:\gh
# (brivio-launch-p3-wt-deploy-wt, codai/.deploy-opus-min, ...), each with its own
# multi-GB node_modules, none ever removed. Every worktree must be created by
# ~/.copilot/bin/worktree.ps1 (lands in E:\gh\.wt\<repo>\<name>, recorded, prunable)
# or by deploy-clean.ps1 (pooled slots). `git worktree remove --force` is also
# refused: it follows junctions into their targets (memory 2026-09-21).
if ($cmd -match '\bgit\b[^;|&]*\bworktree\s+add\b' -and $cmd -notmatch 'worktree\.ps1|deploy-clean\.ps1') {
  $wtRoot = if ($env:CODAI_WT_ROOT) { [regex]::Escape($env:CODAI_WT_ROOT) } else { 'E:[\\/]+gh[\\/]+\.wt[\\/]' }
  if ($cmd -notmatch $wtRoot) {
    [Console]::Error.WriteLine("BLOCKED by guard-command hook: ad-hoc 'git worktree add' outside E:\gh\.wt. Unmanaged worktrees are never removed (45 had accumulated by 2026-09-27).")
    [Console]::Error.WriteLine("Use:  pwsh -NoProfile -File `"$env:USERPROFILE\.copilot\bin\worktree.ps1`" new -Name <short-name> [-Ref <sha>] [-Branch <b>] -Purpose '<why>'")
    [Console]::Error.WriteLine("Deploys: deploy-clean.ps1 (pooled). When done: worktree.ps1 remove -Path <dir>")
    Deny-Exit
  }
}
if ($cmd -match '\bgit\b[^;|&]*\bworktree\s+remove\b[^;|&]*(--force|-f\b)') {
  [Console]::Error.WriteLine("BLOCKED by guard-command hook: 'git worktree remove --force' follows Windows junctions and deletes their TARGETS (emptied another clone's node_modules, 2026-09-21), and discards uncommitted work.")
  [Console]::Error.WriteLine("Use:  pwsh -NoProfile -File `"$env:USERPROFILE\.copilot\bin\worktree.ps1`" remove -Path <dir>   (refuses dirty/unpushed; rmdir-based, junction-safe)")
  Deny-Exit
}

# Builds: serialise instead of warning. Two turbo/tsc runs in one clone share
# .next, .turbo and *.tsbuildinfo, so a concurrent run corrupts incremental
# state and yields phantom errors the other agent then tries to "fix".
# Measured here: 231 pairs of overlapping sessions in brivio alone.
$isBuild = $cmd -match '\b(pnpm|npm|yarn|npx)\s+(run\s+)?(build|typecheck|test:e2e)\b' -or
           # Workspace-scoped forms are how builds are actually invoked in a
           # monorepo: `pnpm --filter @scope/pkg build`, `pnpm -F web typecheck`.
           # The verb sits after the filter, so the pattern above never matched.
           $cmd -match '\b(pnpm|npm|yarn)\s+(--filter|-F|--workspace|-w)\s+\S+\s+(run\s+)?(build|typecheck)\b' -or
           $cmd -match '\bturbo\s+(run\s+)?build\b' -or
           $cmd -match '\bnext\s+build\b' -or
           $cmd -match '\btsc\s+--noEmit\b' -or
           # Agents invoke the compiler directly to raise the heap:
           #   node --max-old-space-size=8192 node_modules/typescript/lib/tsc.js --noEmit
           # Two of those on apps/web ran concurrently at 8 GB each and killed
           # the extension host with "Worker terminated ... JS heap out of
           # memory". The `tsc --noEmit` pattern above never matched this form.
           $cmd -match 'typescript[/\\]lib[/\\]tsc\.js' -or
           $cmd -match '\bnode\b.*\btsc\.js\b'
# The wrapper invokes the real command, so never intercept the wrapper itself.
$viaWrapper = $cmd -match 'run-build\.ps1'

if ($isBuild -and -not $viaWrapper) {
  $runner = Join-Path $env:USERPROFILE '.copilot\hooks\run-build.ps1'
  $lock = Join-Path (Get-Location) '.copilot-tmp\build.lock'
  try {
    $top = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) { $lock = Join-Path $top.Replace('/', '\') '.copilot-tmp\build.lock' }
  } catch { }

  $busy = $false
  if (Test-Path $lock) {
    try {
      $l = Get-Content $lock -Raw | ConvertFrom-Json
      if ($l.pid -and (Get-Process -Id $l.pid -EA SilentlyContinue)) { $busy = $true }
    } catch { }
  }

  if ($busy) {
    [Console]::Error.WriteLine("BLOCKED by guard-command hook: another session is already running a build in this repo. Starting a second one corrupts shared incremental state (.next/.turbo/tsbuildinfo) for both.")
    [Console]::Error.WriteLine("Check it:  pwsh -NoProfile -File `"$runner`" -Status")
    [Console]::Error.WriteLine("Then either read their log, or wait for it:")
    [Console]::Error.WriteLine("  pwsh -NoProfile -File `"$runner`" -Command '$cmd' -Wait")
    Deny-Exit
  }

  [Console]::Error.WriteLine("BLOCKED by guard-command hook: run builds through the lock wrapper so a concurrent session cannot start a second one mid-flight. It also captures full output to a file, which you and later sessions can re-read instead of rebuilding.")
  [Console]::Error.WriteLine("Use:  pwsh -NoProfile -File `"$runner`" -Command '$cmd'")
  Deny-Exit
}

# ---------------------------------------------------------------------------
# Deploys and release builds run ONLY from a clean tree (user instruction
# 2026-09-21, re-stated 2026-09-22 after an incident). The shared clone is
# never clean by design, and on 2026-09-22 a gateway deploy from it (a) had
# its staged set swept into another agent's commit twice, so the image tag
# named a commit whose content it did not match, and (b) built other agents'
# half-finished files. The rule already existed in three rule files and was
# violated anyway — hence a hard block here.
#
# Allowed only when EITHER
#   - the repo root the command runs in has an empty `git status --porcelain`
#     (a detached deploy worktree / CI checkout), or
#   - the command is the clean-worktree wrapper itself (deploy-clean.ps1), or
#   - the command is a pure read (describe/list/log/status/read/services describe).
# ---------------------------------------------------------------------------
$isDeploy = $cmd -match '\bgcloud\s+run\s+(services\s+(replace|update|deploy)|deploy)\b' -or
            $cmd -match '\bgcloud\s+builds\s+submit\b' -or
            $cmd -match '\bgcloud\s+run\s+jobs\s+(deploy|update|replace|create)\b' -or
            $cmd -match '\bvercel\s+(deploy|--prod|-p)(\s|$)' -or
            $cmd -match '\bvercel\b.*\s--prod\b' -or
            $cmd -match '\bdocker\s+(build|buildx\s+build|push)\b' -or
            $cmd -match '\bfly\s+deploy\b' -or
            $cmd -match '\bwrangler\s+(deploy|publish)\b' -or
            $cmd -match '\bterraform\s+apply\b' -or
            $cmd -match '\bpulumi\s+up\b' -or
            $cmd -match '\bcargo\s+(tauri\s+build|publish)\b' -or
            $cmd -match '\bnpm\s+publish\b|\bpnpm\s+publish\b' -or
            $cmd -match '\btwine\s+upload\b|\bhatch\s+publish\b' -or
            $cmd -match '\bgradlew?\b.*\b(assembleRelease|bundleRelease|publish)\b' -or
            # Repo deploy scripts: anything under scripts/ops named deploy-*.ps1
            # EXCEPT the clean-worktree wrapper.
            ($cmd -match 'scripts[\\/]ops[\\/]deploy-[a-z0-9-]+\.ps1' -and $cmd -notmatch 'deploy-clean\.ps1')
$viaCleanWrapper = $cmd -match 'deploy-clean\.ps1'

if ($isDeploy -and -not $viaCleanWrapper) {
  $dirty = $null
  try {
    $top = git rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -eq 0 -and $top) {
      $dirty = git -C $top status --porcelain --untracked-files=normal 2>$null
    }
  } catch { }
  # Not a git repo → nothing to protect (e.g. terraform in a scratch dir).
  if ($null -ne $dirty -and @($dirty | Where-Object { $_ }).Count -gt 0) {
    $n = @($dirty | Where-Object { $_ }).Count
    $wrapper = Join-Path $env:USERPROFILE '.copilot\hooks\deploy-clean.ps1'
    [Console]::Error.WriteLine("BLOCKED by guard-command hook: deploy/release from a DIRTY tree ($n changed/untracked paths). A deploy image must be built from a detached worktree at an exact commit, or the tag names content it does not contain and ships other agents' half-finished files (incident 2026-09-22).")
    [Console]::Error.WriteLine("Use the clean-worktree wrapper (commit first; it deploys HEAD by default):")
    [Console]::Error.WriteLine("  pwsh -NoProfile -File `"$wrapper`" -Command '$cmd'")
    [Console]::Error.WriteLine("  pwsh -NoProfile -File `"$wrapper`" -Ref <sha> -Command '<deploy command>'")
    Deny-Exit
  }
}

# Not dangerous alone, but destructive to OTHER concurrent sessions sharing this
# clone. Warn and let it through: the agent sees the note and can coordinate.
$warn = [ordered]@{
  '\b(pnpm|npm|yarn)\s+(install|i|ci)(\s|$)' = 'This rewrites node_modules under any other session currently building or testing. Confirm nobody else is mid-run.'
  '\b(db:push|db:migrate|drizzle-kit\s+push|prisma\s+migrate)' = 'Schema change on a DB another session may be querying. Coordinate before running.'
  '\b(taskkill|Stop-Process|pkill)\b'        = 'You may be killing a dev server or watcher another session started. Verify the PID is yours.'
  '\bpnpm\s+(clean|--filter\s+\S+\s+clean)'  = 'Deleting build output another session may be using.'
}

foreach ($pat in $warn.Keys) {
  if ($cmd -match $pat) {
    [Console]::Error.WriteLine("WARNING (guard-command): $($warn[$pat])")
    break
  }
}

# ------------------------------------------------------------------ writes --
# Targeted edits (apply_patch / replace_string) are safe: they fail loudly on a
# stale anchor instead of silently discarding. Only whole-file writes clobber.
if ($tool -notmatch 'create_file|createFile|write_file|writeFile|WriteAllLines|create_new') { Flush-Stderr; exit 0 }
# Targeted edits (apply_patch / replace_string) are safe: they fail loudly on a
# stale anchor instead of silently discarding. Only whole-file writes clobber.
if ($tool -notmatch 'create_file|createFile|write_file|writeFile|WriteAllLines|create_new') { Flush-Stderr; exit 0 }

$path = $null
foreach ($p in 'filePath', 'path', 'file', 'uri') {
  if ($payload.PSObject.Properties.Name -contains $p -and $payload.$p) { $path = "$($payload.$p)"; break }
}
foreach ($container in $payload.tool_input, $payload.toolInput) {
  if ($path -or -not $container) { continue }
  foreach ($p in 'filePath', 'path', 'file', 'uri') {
    if ($container.PSObject.Properties.Name -contains $p -and $container.$p) {
      $path = "$($container.$p)"; break
    }
  }
}
if (-not $path) { Flush-Stderr; exit 0 }

$path = $path -replace '^file:///', '' -replace '/', '\'
# Creating a genuinely new file cannot clobber anything.
if (-not (Test-Path $path)) { Flush-Stderr; exit 0 }

$WindowMin = 15
$leaf = Split-Path $path -Leaf
$parent = Split-Path (Split-Path $path -Parent) -Leaf
$needle = if ($parent) { "%$parent%$leaf" } else { "%$leaf" }
$mine = $env:COPILOT_SESSION_ID

$stores = @()
Get-ChildItem (Join-Path $HOME 'VS Code Insiders Profiles') -Directory -EA SilentlyContinue | ForEach-Object {
  $p = "$($_.FullName)\User\globalStorage\github.copilot-chat\session-store.db"
  if (Test-Path $p) { $stores += [pscustomobject]@{ Name = $_.Name; Path = $p } }
}
$d = "$env:APPDATA\Code - Insiders\User\globalStorage\github.copilot-chat\session-store.db"
if (Test-Path $d) { $stores += [pscustomobject]@{ Name = 'DEFAULT'; Path = $d } }

$owners = @()
foreach ($s in $stores) {
  $tmp = Join-Path $env:TEMP "gw_$($s.Name).db"
  try {
    Copy-Item $s.Path $tmp -Force -EA Stop
    # Recent writes live in the WAL; without it the newest rows are invisible,
    # which is exactly the window this hook cares about.
    foreach ($ext in '-wal', '-shm') {
      if (Test-Path "$($s.Path)$ext") { Copy-Item "$($s.Path)$ext" "$tmp$ext" -Force -EA SilentlyContinue }
    }
  } catch { continue }

  # datetime() on both sides: updated_at is '...T..Z' while datetime('now')
  # yields '... ...', and 'T' sorts after a space, so raw comparison is always true.
  $sql = @"
SELECT s.id, s.updated_at, COALESCE(s.agent_name,'?')
FROM session_files sf JOIN sessions s ON s.id = sf.session_id
WHERE sf.file_path LIKE '$needle'
  AND datetime(s.updated_at) > datetime('now','-$WindowMin minutes')
ORDER BY s.updated_at DESC;
"@
  foreach ($r in (sqlite3 -separator '|' $tmp "$sql" 2>$null)) {
    if (-not $r) { continue }
    $f = $r -split '\|'
    if ($mine -and $f[0] -eq $mine) { continue }
    $owners += [pscustomobject]@{
      Profile = $s.Name
      Session = $f[0].Substring(0, [Math]::Min(8, $f[0].Length))
      Updated = $f[1]
      Agent   = if ($f.Count -gt 2) { $f[2] } else { '?' }
    }
  }
  Remove-Item $tmp, "$tmp-wal", "$tmp-shm" -Force -EA SilentlyContinue
}

if (-not $owners) { Flush-Stderr; exit 0 }

$top = $owners | Sort-Object Updated -Descending | Select-Object -First 1
[Console]::Error.WriteLine("BLOCKED by guard-write hook: another session edited '$leaf' in the last $WindowMin minutes. A whole-file write would silently discard their work -- this is how the CHANGELOG incident started.")
[Console]::Error.WriteLine("  session $($top.Session)  profile $($top.Profile)  agent $($top.Agent)  last active $($top.Updated) UTC")
[Console]::Error.WriteLine("Do this instead:")
[Console]::Error.WriteLine("  1. Re-read the file NOW -- it is not what you last saw.")
[Console]::Error.WriteLine("  2. Apply a targeted edit (apply_patch / replace_string) so a stale anchor fails loudly instead of overwriting.")
[Console]::Error.WriteLine("  3. Confirm ownership: pwsh -NoProfile -File `"$env:USERPROFILE\.copilot\hooks\who-owns-file.ps1`" -Path `"$path`"")
Deny-Exit
