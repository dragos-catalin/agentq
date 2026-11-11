<#
  git-publish: make one folder a properly published PRIVATE git repo (git-first workspace, rules G1-G5).
  Idempotent. Never deletes or rewrites files; only appends .gitignore lines and writes LARGE-FILES.md,
  secrets/*.enc (sops+age) and .sops.yaml.

    git-publish.ps1 -Path E:\gh\<folder> [-WhatIf]
    git-publish.ps1 -Path <dir> -Remote <url>      # use this remote instead of creating github.com/<Org>/<name>

  G1 every folder = one repo with origin (new: github.com/<Org>/<name>, private)
  G2 rebuildable output never committed (.gitignore baseline; snapshot drops build/cache dirs)
  G3 files > -MaxMB never committed; listed in LARGE-FILES.md with sha256
  G4 secrets never in clear: .env*/keys -> secrets/<rel>.enc (sops + age), clear files stay ignored
  G5 a repo with uncommitted work gets a snapshot branch (-Branch, default wip/snapshot-<date>) built in a
     temporary index; the current branch, index and worktree are untouched. Local branches missing on the
     remote are pushed (no force; diverged -> wip/diverged-<b>-<date>), stashes -> wip/stash-<n>-<date>.
  Active shared clones (folders with agent slots under the worktree root) are refused: use git-wip-snapshot.ps1.
#>
param(
  [Parameter(Mandatory)][string]$Path,
  [string]$Org = 'dragos-catalin',
  [string]$Branch = ('wip/snapshot-' + (Get-Date -Format 'yyyy-MM-dd')),
  [string]$Remote,
  [int]$MaxMB = 50,
  [string]$AgeKeyFile = $(if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $HOME '.config/sops/age/keys.txt' }),
  [string]$WtRoot = $(if ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT } elseif ($IsWindows) { 'E:\gh\.wt' } else { '/work/.wt' }),
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$Path = (Resolve-Path -LiteralPath $Path).Path.TrimEnd('\', '/')
$sep = [IO.Path]::DirectorySeparatorChar
$name = ((Split-Path $Path -Leaf) -replace '[^A-Za-z0-9._-]', '-').Trim('-')
if ($IsWindows -and $Path -like 'E:\GitHub\*' -and (Test-Path "E:\gh\$name")) { $name = "$name-github" }
$stamp = Get-Date -Format 'yyyy-MM-dd'
$report = [ordered]@{ path = $Path; repo = $(if ($Remote) { $Remote } else { "$Org/$name" }); actions = @() }
function Act([string]$m) { $report.actions += $m }
function G {
  $a = @($args)
  # backup refs never run the repo's pre-push gates (brivio verify took minutes per WIP ref)
  if ($a[0] -eq 'push') { $a = @('push', '--no-verify') + $a[1..($a.Count - 1)] }
  & git -C $Path @a; if ($LASTEXITCODE -ne 0) { throw "git $a failed ($LASTEXITCODE)" }
}
function Get-AgeRecipient {
  if (-not (Test-Path -LiteralPath $AgeKeyFile)) { throw "secrets found but no age key at $AgeKeyFile (set SOPS_AGE_KEY_FILE): refusing to publish without encrypting them" }
  $m = Get-Content -LiteralPath $AgeKeyFile | Select-String '^# public key: (.+)$' | Select-Object -First 1
  if (-not $m) { throw "no '# public key:' line in $AgeKeyFile" }
  $m.Matches[0].Groups[1].Value
}

$baseIgnore = @('node_modules/', '.pnpm-store/', '.pnpm-cache/', '.npm/', '.yarn/cache/', '.next/', '.nuxt/', '.turbo/', 'dist/', 'build/', 'out/',
  'target/', '.gradle/', '.venv/', 'venv/', '__pycache__/', '*.pyc', '.pytest_cache/', '.mypy_cache/', '.ruff_cache/', '.cache/', 'coverage/',
  'playwright-report/', 'test-results/', 'obj/', '**/bin/Debug/', '**/bin/Release/', '*.tsbuildinfo', '.DS_Store', 'Thumbs.db', '.copilot-tmp/',
  '.env', '.env.*', '!.env.example', '!.env.*.example', '*.pem', '*.key', '*.p12', '*.jks', '*.keystore', 'local.properties', '.dev.vars',
  '*credentials*.json', '*-token.json', '*service-account*.json', '*firebase-adminsdk*.json', 'client_secret*.json')
$encUnignore = @('!secrets/', '!secrets/**', '!secrets/**/*.enc')
$junkRe = '(^|/)(node_modules|\.next|\.turbo|\.pnpm-store|\.pnpm-cache|dist|build|target|\.gradle|\.venv|venv|__pycache__|coverage|obj)/'

$isGit = Test-Path (Join-Path $Path '.git')
$active = @(Get-ChildItem -LiteralPath $WtRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object Name)
if ($isGit -and (Split-Path $Path -Leaf) -in $active) { throw "ACTIVE shared clone ($name has agent slots in $WtRoot) - use git-wip-snapshot.ps1, not git-publish" }
if ($isGit) {
  $o = git -C $Path remote get-url origin 2>$null
  if ($o -match 'github\.com[:/](.+?)(\.git)?$') {
    $vis = gh repo view $Matches[1] --json visibility -q .visibility 2>$null
    if ($vis -and $vis -ne 'PRIVATE') { throw "origin $($Matches[1]) is $vis - WIP must not be published there (use git-wip-snapshot.ps1 -> shared-clone-backups)" }
  }
}
if (-not $isGit) { Act 'git init'; if (-not $WhatIf) { G init -q -b main } }

# 1) .gitignore baseline (append missing lines only)
$gi = Join-Path $Path '.gitignore'
$have = if (Test-Path $gi) { @(Get-Content $gi) } else { @() }
$missing = @($baseIgnore | Where-Object { $_ -notin $have })
if ($missing) { Act ".gitignore +$($missing.Count)"; if (-not $WhatIf) { Add-Content $gi (@('', "# workspace baseline (git-publish $stamp)") + $missing) } }
# the un-ignore must be the LAST matching rule (else `.env.*` swallows secrets/.env.enc): re-append when not last
$tail = if (Test-Path $gi) { @(Get-Content $gi | Select-Object -Last 3) } else { @() }
if (-not $WhatIf -and (Compare-Object $tail $encUnignore)) { Add-Content $gi (@('# encrypted secrets are committed (sops+age)') + $encUnignore) }

# 2) secrets: encrypt every ignored env/key file into secrets/<relpath>.enc
$secretGlobs = @('.env*', '*.pem', '*.key', 'local.properties', '.dev.vars', '*credentials*.json', '*-token.json', '*service-account*.json', '*firebase-adminsdk*.json', 'client_secret*.json') | ForEach-Object { '-g', $_ }
$secretFiles = @(& rg --files --hidden --no-ignore --no-messages @secretGlobs -g '!**/node_modules/**' -g '!**/.git/**' -g '!**/secrets/**' -g '!*.example' -g '!**/.copilot-tmp/**' $Path)
if ($secretFiles) {
  Act "secrets: $($secretFiles.Count) encrypted"
  if (-not $WhatIf) {
    $age = Get-AgeRecipient
    $ga = Join-Path $Path '.gitattributes'
    if (-not ((Test-Path $ga) -and (Select-String -Path $ga -SimpleMatch 'secrets/** binary' -Quiet))) { Add-Content $ga 'secrets/** binary' }
    $sopsCfg = Join-Path $Path '.sops.yaml'
    if (-not (Test-Path $sopsCfg)) { [IO.File]::WriteAllText($sopsCfg, "creation_rules:`n  - path_regex: secrets/.*`n    age: $age`n") }
    foreach ($f in $secretFiles) {
      $rel = $f.Substring($Path.Length + 1)
      $dst = Join-Path (Join-Path $Path 'secrets') ($rel + '.enc')
      New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
      & sops --encrypt --age $age --input-type binary --output-type json --output $dst $f
      if ($LASTEXITCODE -ne 0) { throw "sops failed on $rel" }
    }
  }
}

# 3) large files: never committed, recorded with hash
$large = @(& rg --files --hidden --no-messages -g '!.git' $Path | ForEach-Object { Get-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue } | Where-Object { $_ -and $_.Length -gt $MaxMB * 1MB })
if ($large) {
  Act "large files excluded: $($large.Count)"
  if (-not $WhatIf) {
    $lines = @("# Files over $MaxMB MB kept out of git", '', '| path | MB | sha256 |', '|---|---|---|')
    $lines += $large | ForEach-Object { '| {0} | {1:N0} | {2} |' -f $_.FullName.Substring($Path.Length + 1).Replace('\', '/'), ($_.Length / 1MB), (Get-FileHash -LiteralPath $_.FullName).Hash }
    Set-Content (Join-Path $Path 'LARGE-FILES.md') $lines -Encoding utf8
    $ign = $large | ForEach-Object { '/' + $_.FullName.Substring($Path.Length + 1).Replace('\', '/') }
    Add-Content $gi (@('', '# large files (see LARGE-FILES.md)') + ($ign | Where-Object { $_ -notin $have }))
  }
}

# 4) remote: -Remote, or create a private GitHub repo when there is no origin
$origin = if ($isGit) { git -C $Path remote get-url origin 2>$null } else { $null }
if (-not $origin) {
  $url = $Remote
  if (-not $url) {
    $exists = gh repo view "$Org/$name" --json name -q .name 2>$null
    if (-not $exists) { Act "gh repo create $Org/$name --private"; if (-not $WhatIf) { gh repo create "$Org/$name" --private --disable-wiki | Out-Null } }
    $url = "https://github.com/$Org/$name.git"
  }
  Act 'origin added'; if (-not $WhatIf) { G remote add origin $url }
}

if ($WhatIf) { [pscustomobject]$report | ConvertTo-Json -Depth 3; return }

# 5) commit: fresh repo -> main; existing repo with changes -> snapshot branch, current branch untouched
$hasHead = $null -ne (git -C $Path rev-parse --verify --quiet HEAD 2>$null)
$cur = git -C $Path branch --show-current 2>$null
if (-not $hasHead) {
  G add -A; G commit -q -m "chore: initial import (git-publish $stamp)" --no-verify
  G push -q -u origin main; Act 'initial commit pushed to main'
} else {
  $dirty = @(git -C $Path status --porcelain).Count
  if ($dirty) {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('gp-idx-' + [guid]::NewGuid().ToString('n'))
    $env:GIT_INDEX_FILE = $tmp
    try {
      G read-tree HEAD; G add -A
      $junk = @(git -C $Path ls-files | Where-Object { $_ -match $junkRe })
      if ($junk) {
        $dirs = $junk | ForEach-Object { [regex]::Match($_, '^(.*?(^|/)(node_modules|\.next|\.turbo|\.pnpm-store|\.pnpm-cache|dist|build|target|\.gradle|\.venv|venv|__pycache__|coverage|obj))/').Groups[1].Value } | Select-Object -Unique
        foreach ($d in $dirs) { git -C $Path rm -r -q --cached -- $d 2>$null | Out-Null }
        Act "snapshot dropped $($junk.Count) build/cache files"
      }
      $big = @(git -C $Path ls-files -s | ForEach-Object {
          $blob = ($_ -split '\s+', 4)[1]; $p = ($_ -split "`t", 2)[1]
          if ([long](git -C $Path cat-file -s $blob) -gt $MaxMB * 1MB) { $p } })
      foreach ($b in $big) { git -C $Path rm -q --cached -- $b | Out-Null }
      if ($big) { Act "snapshot dropped $($big.Count) files > $MaxMB MB" }
      $tree = (git -C $Path write-tree).Trim()
      $prev = ((git -C $Path ls-remote origin "refs/heads/$Branch" 2>$null) -split '\s' | Select-Object -First 1)
      if ($prev) { git -C $Path fetch -q origin "refs/heads/${Branch}" 2>$null }
      if (-not $prev) { $prev = git -C $Path rev-parse --verify --quiet "refs/heads/$Branch" 2>$null }
      $base = 'HEAD'
      # filtered remote (git-push-filtered rewrote history): parent the snapshot on the remote branch tip
      $rcur = ((git -C $Path ls-remote origin "refs/heads/$cur" 2>$null) -split '\s' | Select-Object -First 1)
      $lcur = (git -C $Path rev-parse HEAD).Trim()
      if ($rcur -and $rcur -ne $lcur) {
        git -C $Path fetch -q origin "refs/heads/$cur" 2>$null
        git -C $Path merge-base --is-ancestor $rcur $lcur 2>$null
        if ($LASTEXITCODE -ne 0) { $base = $rcur; Act "snapshot parented on remote $cur (filtered history)" }
      }
      $parents = @('-p', $base); if ($prev) { $parents += @('-p', $prev.Trim()) }
      $c = (git -C $Path commit-tree $tree @parents -m "wip: snapshot of uncommitted work on $cur (git-publish $stamp)").Trim()
    } finally { Remove-Item Env:GIT_INDEX_FILE; Remove-Item $tmp -ErrorAction SilentlyContinue }
    G update-ref "refs/heads/$Branch" $c
    G push -q origin "refs/heads/${Branch}:refs/heads/$Branch"; Act "dirty=$dirty -> $Branch pushed"
  }
  # push every local branch that is not on the remote (no force)
  foreach ($b in @(git -C $Path for-each-ref --format='%(refname:short)' refs/heads)) {
    $remoteSha = (git -C $Path ls-remote origin "refs/heads/$b" 2>$null) -split '\s' | Select-Object -First 1
    $localSha = (git -C $Path rev-parse $b).Trim()
    if ($remoteSha -eq $localSha) { continue }
    $ff = $true
    if ($remoteSha) { git -C $Path merge-base --is-ancestor $remoteSha $localSha 2>$null; $ff = ($LASTEXITCODE -eq 0) }
    if (-not $ff) { G push -q origin "refs/heads/${b}:refs/heads/wip/diverged-$b-$stamp"; Act "diverged $b -> wip/diverged-$b-$stamp" }
    else { G push -q origin "refs/heads/${b}:refs/heads/$b"; Act "pushed $b" }
  }
  if ($cur -and -not (git -C $Path rev-parse --abbrev-ref '@{u}' 2>$null)) { git -C $Path branch -q --set-upstream-to "origin/$cur" 2>$null }
  if ($cur -and -not $origin -and -not $Remote) { gh repo edit "$Org/$name" --default-branch $cur 2>$null | Out-Null; Act "default branch $cur" }
  $stash = @(git -C $Path stash list).Count
  if ($stash) { for ($i = 0; $i -lt $stash; $i++) { G push -q origin "stash@{$i}:refs/heads/wip/stash-$i-$stamp" }; Act "stash $stash pushed" }
}
[pscustomobject]$report | ConvertTo-Json -Depth 3
