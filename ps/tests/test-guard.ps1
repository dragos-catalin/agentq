<#
.SYNOPSIS
  Regression suite for guard-command.ps1.

.DESCRIPTION
  The guard has had three holes of the same class, each found only after
  damage: a pattern matched the canonical form while agents wrote a different
  one.

    `git checkout .`   matched  ->  `git checkout -- <file>`            did not
    `tsc --noEmit`     matched  ->  `node .../typescript/lib/tsc.js`    did not
    `git push --force` matched  ->  `git push origin dev --force-with-lease` did not

  The lesson is not "write better regexes" -- it is that a guard must be tested
  against the forms people actually type. Run this after touching the guard, or
  after any incident where something dangerous got through.

    test-guard.ps1            # exit 1 on any hole or false positive
    test-guard.ps1 -Verbose   # list every case

.NOTES
  When a new hole is found in the wild, add the exact command here FIRST, watch
  it fail, then fix the pattern. A case added after the fix proves nothing.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
# guard-command.ps1 is the pre-2026-09-06 file; the REGISTERED hook is guard-tooluse.ps1
# (codai-hooks.json). Testing the old file proved nothing about the live guard.
$guard = "$env:USERPROFILE\.copilot\hooks\guard-tooluse.ps1"
if (-not (Test-Path $guard)) { Write-Host "guard not found: $guard" -ForegroundColor Red; exit 1 }

function Invoke-Guard([string]$cmd) {
  $json = @{ command = $cmd } | ConvertTo-Json -Compress
  $null = ($json | pwsh -NoProfile -File $guard 2>&1)
  return $LASTEXITCODE
}

# Variants that must be refused. Ordered by the incident that produced them.
$mustBlock = @(
  # shared-clone staging
  'git add -A', 'git add --all', 'git add .', 'cd E:\gh\brivio; git add -A'
  'git commit -am "wip"', 'git commit -a -m "wip"', 'git commit --all -m x'
  # pathspec-less commit sweeps foreign staged files (7cc672f7, 2026-09-26) -> agentq commit
  'git commit -m "fix: x"', 'git commit -F .copilot-tmp/msg.txt', 'cd E:\gh\codai; git commit -m x'
  'git -C E:\gh\brivio commit -m "feat: y"'
  # history rewriting -- note the flag can follow the refspec
  'git push --force origin dev', 'git push -f', 'git push origin dev --force-with-lease'
  # working-tree destruction
  'git reset --hard HEAD~1', 'git reset --hard', 'git clean -fd', 'git clean -xfd'
  'git checkout -- CHANGELOG.md', 'git checkout .', 'git checkout HEAD -- src/x.ts'
  'git restore x.ts', 'git restore --staged --worktree x.ts'
  # stash traps (2026-09-20 + 2026-09-21: flags after -- are pathspecs; bare pop applied a foreign stash)
  'git stash push -- apps/desktop/src-tauri/src/shell.rs -m "btn-audit rust probe"'
  'git stash push -- x.ts -u', 'git stash pop', 'git stash apply', 'git stash drop'
  'git -C E:\gh\codai stash pop | Select-Object -Last 2'
  # builds must go through the lock, in every invocation form
  'pnpm build', 'pnpm typecheck', 'pnpm run build', 'npm run build', 'yarn build'
  'turbo build', 'turbo run build', 'next build'
  'tsc --noEmit', 'npx tsc --noEmit'
  'node node_modules/typescript/lib/tsc.js --noEmit'
  'node --max-old-space-size=8192 node_modules/typescript/lib/tsc.js --noEmit -p apps/web/tsconfig.json'
  'pnpm --filter @brivio/web build', 'pnpm -F web typecheck', 'cd apps/web; pnpm build'
  # destructive SQL
  'DROP TABLE users;', 'TRUNCATE TABLE invoices;', 'DELETE FROM invoices;'
  # unmanaged worktrees (2026-09-27: 45 piled up in E:\gh)
  'git worktree add --detach E:\gh\brivio-qa1-wt HEAD', 'git -C E:\gh\codai worktree add --detach .deploy-opus-min 968abbc9'
  'cd E:\gh\brivio; git worktree add ..\brivio-wt-agent2 -b agent2/work', 'git worktree add --detach .copilot-tmp/deploy-b4f01849 b4f01849'
  'git worktree remove --force E:\gh\brivio-w-a', 'git -C E:\gh\brivio worktree remove -f x'
)

# Everyday commands. A false positive here is worse than a miss: it teaches
# people to work around the guard.
$mustPass = @(
  'git status', 'git add src/x.ts', 'git add apps/web/src/a.ts apps/web/src/b.ts'
  'git commit -m "fix: x" -- src/x.ts', 'git commit -F .copilot-tmp/msg.txt -- a.ts b.ts'
  'pwsh -NoProfile -File C:\Users\vladu\.copilot\bin\agentq.ps1 commit -Message "fix: x" -Paths a.ts'
  'rg -n "git commit" C:\Users\vladu\.copilot\hooks', 'git log --grep "commit"'
  'git checkout -b feat/x', 'git checkout --help', 'git stash push -- x.ts'
  'git stash push -m "probe" -- x.ts', 'git stash list', 'git stash pop stash@{1}', 'git stash show -p stash@{0}'
  'git diff --cached --name-only', 'git log --oneline -5', 'git push origin dev'
  'pnpm dev', 'pnpm lint', 'pnpm test', 'pnpm --filter @brivio/web lint'
  'node scripts/check-sdk-coverage.mjs', 'node --version', 'rg -n "pattern" src'
  'DELETE FROM invoices WHERE id = 5;'
  'pwsh -NoProfile -File C:\Users\vladu\.copilot\hooks\run-build.ps1 -Command "pnpm build"'
  'git worktree list', 'git worktree prune', 'git worktree remove E:\gh\.wt\brivio\x'
  'git worktree add --detach E:\gh\.wt\brivio\probe HEAD'
  'pwsh -NoProfile -File C:\Users\vladu\.copilot\bin\worktree.ps1 new -Name probe -Ref HEAD'
)

# Local Playwright (brivio ADR-0214, 2026-09-28). Built by concatenation: this file is edited
# through tools whose text the same guard scans.
$pwT = 'playwright' + ' test'
$mustBlock += @(
  "npx $pwT", "pnpm --filter @brivio/web exec $pwT e2e/a11y.spec.ts", "cd apps/web; npx $pwT --project=chromium"
  "node node_modules/@playwright/test/cli.js test --project=theming", ('pnpm a11y' + ':routes'), ('pnpm run a11y' + ':ibm')
)
$mustPass += @(
  "npx $pwT --list", 'npx playwright show-report', 'pnpm --filter @brivio/web exec playwright install chromium'
  ('pnpm e2e' + ':cloud e2e/a11y.spec.ts'), 'node scripts/e2e-cloud/run.mjs --target vm --cmd "pnpm a11y:routes"'
  ('$env:PW_ALLOW_LOCAL=1; npx ' + $pwT + ' x.spec.ts'), 'rg -n "playwright" apps/web'
)
$pwReplace = '$s=$s.Replace(''run: pnpm --filter @brivio/web exec ' + $pwT + ''',''x'')'
$mustPass += @($pwReplace, ('rg -n "npx ' + $pwT + '" docs'))
$mustBlock += @(('$env:CI=1; npx ' + $pwT + ' a.spec.ts'), ('cd apps/web; pnpm exec ' + $pwT))
# X-01 (2026-10-05): edit tools (apply_patch, replace_string, create_file) carry FILE TEXT,
# not a command. Patches whose context lines contain a build/deploy/SQL word were blocked as
# if they were being run (CI workflow edits, hook tests, docs). Commands are scanned; edit
# payloads are not. Real payload shape: {"tool_name":"apply_patch","tool_input":{"input":"..."}}.
function Invoke-GuardTool([string]$tool, [hashtable]$toolInput) {
  $json = @{ tool_name = $tool; tool_input = $toolInput } | ConvertTo-Json -Compress -Depth 5
  $null = ($json | pwsh -NoProfile -File $guard 2>&1)
  return $LASTEXITCODE
}
$patchBuild = "*** Begin Patch`n*** Update File: E:\x\.github\workflows\ci.yml`n@@`n       - run: pnpm build`n+      - run: pnpm scan:contrast`n*** End Patch"
$patchSql = "*** Begin Patch`n*** Update File: E:\x\test.ts`n+const p = 'DROP ' + 'TABLE';`n+// DROP TABLE users;`n*** End Patch"
$editPass = @(
  @('apply_patch', @{ input = $patchBuild; explanation = 'ci gates' }),
  @('apply_patch', @{ input = $patchSql; explanation = 'fixture' }),
  @('replace_string_in_file', @{ filePath = 'E:\x\docs\CI.md'; oldString = 'a'; newString = 'run pnpm build then deploy' }),
  @('create_file', @{ filePath = 'E:\x\.copilot-tmp\gates.ps1'; content = "pnpm build`nnpx tsc --noEmit" })
)
$editBlock = @(
  # run_in_terminal still blocks: command field
  @('run_in_terminal', @{ command = 'pnpm build'; explanation = 'x' }),
  @('run_in_terminal', @{ command = 'DROP TABLE users;'; explanation = 'x' })
)
$editHoles = @(); $editFalse = @()
foreach ($c in $editPass) { if ((Invoke-GuardTool $c[0] $c[1]) -eq 2) { $editFalse += "$($c[0]): $($c[1].Values -join ' | ')" } }
foreach ($c in $editBlock) { if ((Invoke-GuardTool $c[0] $c[1]) -ne 2) { $editHoles += "$($c[0]): $($c[1].command)" } }
Write-Host ("edit payloads allowed     : {0} / {1}" -f ($editPass.Count - $editFalse.Count), $editPass.Count)
Write-Host ("terminal payloads blocked : {0} / {1}" -f ($editBlock.Count - $editHoles.Count), $editBlock.Count)
if ($editFalse) { Write-Host 'FALSE POSITIVES (edit text scanned as a command):' -ForegroundColor Red; $editFalse | ForEach-Object { Write-Host "  $_" } }
if ($editHoles) { Write-Host 'HOLES (terminal command got through):' -ForegroundColor Red; $editHoles | ForEach-Object { Write-Host "  $_" } }
# Stale-script trap (2026-10-05): a denied create_file leaves a marker; running that path is blocked for 10 min.
$deniedDir = Join-Path $env:TEMP 'copilot-guard-denied'
New-Item -ItemType Directory -Force -Path $deniedDir | Out-Null
$marker = Join-Path $deniedDir 'selftest.txt'
[IO.File]::WriteAllText($marker, 'E:\x\.copilot-tmp\ship5.ps1')
$staleBlock = Invoke-GuardTool 'run_in_terminal' @{ command = 'pwsh -NoProfile -File E:\x\.copilot-tmp\ship5.ps1'; explanation = 'x' }
$stalePass = Invoke-GuardTool 'run_in_terminal' @{ command = 'pwsh -NoProfile -File E:\x\.copilot-tmp\ship6.ps1'; explanation = 'x' }
Remove-Item $marker -EA SilentlyContinue
$staleOk = ($staleBlock -eq 2) -and ($stalePass -ne 2)
Write-Host ("stale-script trap         : block={0} pass={1} -> {2}" -f $staleBlock, $stalePass, $(if ($staleOk) { 'OK' } else { 'FAIL' }))
if (-not $staleOk) { $editHoles += 'stale-script trap' }
if ($editFalse -or $editHoles) { exit 1 }

$holes = @(); $falsePos = @()
foreach ($c in $mustBlock) {
  $code = Invoke-Guard $c
  if ($code -ne 2) { $holes += $c } elseif ($VerbosePreference -ne 'SilentlyContinue') { Write-Host "  blocked  $c" -ForegroundColor DarkGray }
}
foreach ($c in $mustPass) {
  $code = Invoke-Guard $c
  if ($code -eq 2) { $falsePos += $c } elseif ($VerbosePreference -ne 'SilentlyContinue') { Write-Host "  allowed  $c" -ForegroundColor DarkGray }
}

Write-Host ("blocked correctly : {0} / {1}" -f ($mustBlock.Count - $holes.Count), $mustBlock.Count)
Write-Host ("allowed correctly : {0} / {1}" -f ($mustPass.Count - $falsePos.Count), $mustPass.Count)

if ($holes) {
  Write-Host ''
  Write-Host 'HOLES - these got through:' -ForegroundColor Red
  $holes | ForEach-Object { Write-Host "  $_" }
}
if ($falsePos) {
  Write-Host ''
  Write-Host 'FALSE POSITIVES - these were wrongly blocked:' -ForegroundColor Red
  $falsePos | ForEach-Object { Write-Host "  $_" }
}
if ($holes -or $falsePos) { exit 1 }

# ---------------------------------------------------------------------------
# agentq freeze marks: a frozen resource refuses its command class, clear lifts it.
# ---------------------------------------------------------------------------
$aqHome = Join-Path $env:TEMP ("guard-aq-fx-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $aqHome 'marks') -Force | Out-Null
$prevAq = $env:AGENTQ_HOME; $env:AGENTQ_HOME = $aqHome
try {
  @{ resource = 'build:codai'; state = 'frozen'; reason = 'test freeze'; at = 'now'; session = 'test' } |
    ConvertTo-Json | Set-Content (Join-Path $aqHome 'marks\build_codai.json')
  @{ resource = 'deploy:codai:gateway'; state = 'blocked'; reason = 'test incident'; at = 'now'; session = 'test' } |
    ConvertTo-Json | Set-Content (Join-Path $aqHome 'marks\deploy_codai_gateway.json')
  $rb = 'pwsh -NoProfile -File C:\Users\vladu\.copilot\hooks\run-build.ps1 -Command "pnpm build"'
  $dc = 'pwsh -NoProfile -File C:\Users\vladu\.copilot\hooks\deploy-clean.ps1 -Command "pwsh -File scripts/ops/deploy-service-direct.ps1 -Service '
  Push-Location E:\gh\codai
  $fBlock = @($rb, ($dc + 'gateway"'))
  $fPass = @(($dc + 'auth"'), 'git status', 'pnpm lint')
  $mHoles = @($fBlock | Where-Object { (Invoke-Guard $_) -ne 2 })
  $mFalse = @($fPass | Where-Object { (Invoke-Guard $_) -eq 2 })
  Pop-Location
  Push-Location E:\gh\brivio
  if ((Invoke-Guard $rb) -eq 2) { $mFalse += 'brivio build blocked by a codai freeze' }
  Pop-Location
  Remove-Item (Join-Path $aqHome 'marks\*.json')
  Push-Location E:\gh\codai
  if ((Invoke-Guard $rb) -eq 2) { $mFalse += 'build still blocked after mark cleared' }
  Pop-Location
  Write-Host ("frozen resources blocked      : {0} / {1}" -f ($fBlock.Count - $mHoles.Count), $fBlock.Count)
  Write-Host ("unfrozen / other repo allowed : {0}" -f $(if ($mFalse) { 'FAIL' } else { 'ok' }))
  if ($mHoles) { Write-Host 'HOLES (frozen bypassed):' -ForegroundColor Red; $mHoles | ForEach-Object { Write-Host "  $_" } }
  if ($mFalse) { Write-Host 'FALSE POSITIVES (freeze):' -ForegroundColor Red; $mFalse | ForEach-Object { Write-Host "  $_" } }
  if ($mHoles -or $mFalse) { exit 1 }
} finally {
  $env:AGENTQ_HOME = $prevAq
  Remove-Item -Recurse -Force $aqHome -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Deploy-from-dirty-tree block (incident 2026-09-22). State-dependent, so it
# gets its own fixture: a throwaway git repo that is made dirty, then clean.
# ---------------------------------------------------------------------------
$fx = Join-Path $env:TEMP ("guard-deploy-fx-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $fx | Out-Null
Push-Location $fx
try {
  git init -q .; git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  $deploys = @(
    'gcloud run services replace deploy/cloud-run/gateway.service.yaml --region europe-west1'
    'gcloud builds submit --config deploy/cloud-run/cloudbuild-gateway.yaml .'
    'gcloud run deploy codai-gateway --image x'
    'gcloud run jobs deploy codai-crawler --image x'
    'pwsh -NoProfile -File scripts/ops/deploy-service-direct.ps1 -Service gateway'
    'vercel --prod', 'vercel deploy --prod --yes'
    'docker build -f apps/gateway/Dockerfile -t x .', 'docker push x'
    'terraform apply -auto-approve', 'pulumi up --yes'
    'pnpm publish --access public', 'npm publish'
    'wrangler deploy', 'cargo tauri build'
  )
  $reads = @(
    'gcloud run services describe codai-gateway --region europe-west1'
    'gcloud run revisions list --service codai-gateway'
    'gcloud builds list --limit 3', 'gcloud builds log abc'
    'terraform plan', 'docker images', 'vercel ls'
    'pwsh -NoProfile -File C:\Users\vladu\.copilot\hooks\deploy-clean.ps1 -Command "gcloud run services replace x.yaml"'
  )
  # dirty: an untracked file is enough
  Set-Content -Path (Join-Path $fx 'wip.txt') -Value 'x'
  $dHoles = @(); $dFalse = @()
  foreach ($c in $deploys) { if ((Invoke-Guard $c) -ne 2) { $dHoles += $c } }
  foreach ($c in $reads)   { if ((Invoke-Guard $c) -eq 2) { $dFalse += $c } }
  # clean: same commands must pass
  Remove-Item (Join-Path $fx 'wip.txt')
  $cFalse = @()
  foreach ($c in $deploys) { if ((Invoke-Guard $c) -eq 2) { $cFalse += $c } }

  Write-Host ("deploy blocked on DIRTY tree : {0} / {1}" -f ($deploys.Count - $dHoles.Count), $deploys.Count)
  Write-Host ("reads allowed on dirty tree  : {0} / {1}" -f ($reads.Count - $dFalse.Count), $reads.Count)
  Write-Host ("deploy allowed on CLEAN tree : {0} / {1}" -f ($deploys.Count - $cFalse.Count), $deploys.Count)
  if ($dHoles) { Write-Host 'HOLES (deploy ran from dirty tree):' -ForegroundColor Red; $dHoles | ForEach-Object { Write-Host "  $_" } }
  if ($dFalse) { Write-Host 'FALSE POSITIVES (read blocked):' -ForegroundColor Red; $dFalse | ForEach-Object { Write-Host "  $_" } }
  if ($cFalse) { Write-Host 'FALSE POSITIVES (clean tree blocked):' -ForegroundColor Red; $cFalse | ForEach-Object { Write-Host "  $_" } }
  if ($dHoles -or $dFalse -or $cFalse) { exit 1 }
} finally {
  Pop-Location
  Remove-Item -Recurse -Force $fx -ErrorAction SilentlyContinue
}

Write-Host 'guard OK' -ForegroundColor Green
exit 0
