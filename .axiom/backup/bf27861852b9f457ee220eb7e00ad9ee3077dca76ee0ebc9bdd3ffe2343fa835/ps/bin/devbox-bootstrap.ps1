<#
  devbox-bootstrap (ADR 0007): provision a devbox from this PC, git-first.
    1. root:  ps/devbox/devbox-root.sh  (tools, agentq system install, devbox-teams, sweep timer)
    2. user:  ps/devbox/devbox-user.sh as -User (clones REPOS into /work, decrypts secrets with the age key)
    3. teams: devbox-team-sync.ps1 (hub members -> users/groups/2770) unless -NoTeams
  Secrets (age key, gh token) travel once in a 0600 env file and are deleted on both sides; never echoed.

    devbox-bootstrap.ps1 -Repos 'codai-ro/codai-cc=codai dragoscv/axiom=axiom'   # explicit pairs
    devbox-bootstrap.ps1 -ActiveRepos                                             # every repo with agent slots here
    devbox-bootstrap.ps1 -RootOnly                                                # refresh agentq/devbox-teams only
#>
param(
  [string]$Vm = 'ws-devbox', [string]$Zone = 'europe-west4-b', [string]$Project = 'codai-training',
  [string]$User = 'dev', [string]$Repos = '', [switch]$ActiveRepos, [switch]$RootOnly, [switch]$NoTeams, [switch]$NoSecrets,
  [string]$AgentqSrc = '/work/agentq',
  [string]$WtRoot = $(if ($env:CODAI_WT_ROOT) { $env:CODAI_WT_ROOT } else { 'E:\gh\.wt' }), [string]$ReposRoot = 'E:\gh'
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$devboxDir = if (Test-Path (Join-Path $here 'devbox-root.sh')) { $here } else { Join-Path (Split-Path $here -Parent) 'devbox' }
$c = @('--zone', $Zone, '--project', $Project, '--tunnel-through-iap', '--quiet', '--strict-host-key-checking=no')
function ToLf([string]$src) { $d = Join-Path ([IO.Path]::GetTempPath()) (Split-Path $src -Leaf); [IO.File]::WriteAllText($d, ([IO.File]::ReadAllText($src) -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false)); $d }
function Remote([string]$cmd) { $o = @(& gcloud compute ssh $Vm @c --command $cmd 2>&1 | ForEach-Object { "$_" }); if ($LASTEXITCODE) { throw "remote failed ($LASTEXITCODE): $($o | Select-Object -Last 3)" }; $o }

$root = ToLf (Join-Path $devboxDir 'devbox-root.sh')
$usr = ToLf (Join-Path $devboxDir 'devbox-user.sh')
& gcloud compute scp $root $usr "${Vm}:/tmp/" @c 2>&1 | Out-Null
if ($LASTEXITCODE) { throw "scp to $Vm failed" }
Remote "sudo bash /tmp/devbox-root.sh $AgentqSrc" | Select-Object -Last 2
if ($RootOnly) { return }

if ($ActiveRepos) {
  $pairs = foreach ($n in @(Get-ChildItem -LiteralPath $WtRoot -Directory | Where-Object { $_.Name -notlike '_*' -and (Test-Path (Join-Path (Join-Path $ReposRoot $_.Name) '.git')) } | ForEach-Object Name)) {
    $o = git -C (Join-Path $ReposRoot $n) remote get-url origin 2>$null
    if ($o -match 'github\.com[:/](.+?)(\.git)?$') { "$($Matches[1])=$n" }
  }
  $Repos = ($pairs -join ' ')
}
$vars = [ordered]@{ REPOS = $Repos }
if (-not $NoSecrets) {
  $ak = if ($env:SOPS_AGE_KEY_FILE) { $env:SOPS_AGE_KEY_FILE } else { Join-Path $HOME '.config\sops\age\keys.txt' }
  if (Test-Path $ak) { $vars['AGE_KEY_B64'] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ak)) }
  $ghOut = (gh auth token 2>$null); if ($ghOut) { $vars['GH_TOKEN'] = "$ghOut".Trim() }
}
$lines = @($vars.Keys | ForEach-Object { "export $_='" + $vars[$_] + "'" })
$envFile = Join-Path ([IO.Path]::GetTempPath()) ('dbx-' + [guid]::NewGuid().ToString('n'))
[IO.File]::WriteAllText($envFile, (($lines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))
try {
  & gcloud compute scp $envFile "${Vm}:/tmp/dbx.env" @c 2>&1 | Out-Null
  if ($LASTEXITCODE) { throw 'scp env failed' }
  Remote "sudo install -o $User -g $User -m 600 /tmp/dbx.env /home/$User/.dbx.env; rm -f /tmp/dbx.env; sudo install -m 644 /tmp/devbox-user.sh /home/$User/devbox-user.sh; sudo -iu $User bash -c 'set -a; . ~/.dbx.env; rm -f ~/.dbx.env; bash ~/devbox-user.sh 2>&1'" | Where-Object { $_ -match '^repo |DEVBOX_BOOTSTRAP_OK|no access|error|fatal' }
} finally { Remove-Item $envFile -Force -ErrorAction SilentlyContinue }
if (-not $NoTeams) { & pwsh -NoProfile -File (Join-Path $here 'devbox-team-sync.ps1') -DevboxName $Vm }
