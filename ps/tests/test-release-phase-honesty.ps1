# The release record stores `phase` = the LAST checkpoint the run ENTERED (release-phase) and `state` =
# the run's own outcome. They are independent: a FAILED run is NOT a failed phase, and nothing in the
# record attributes a failing exit code to a phase. 2026-11-21: a release exited 1 (its post-deploy gate
# returned `incomplete`) while `phase` still read `github`; `agentq status` printed `phase=github` next to
# FAILED and a human read it as "the GitHub step failed".
#
# This suite pins the honest display so the misleading wording cannot come back:
#   - the checkpoint column is labelled `last-phase=<p>`, never a bare `phase=<p>`;
#   - the run's own exit code is shown SEPARATELY as `exit=<n>` (never on the phase);
#   - the header legend says the phase is the last checkpoint recorded, NOT the step that failed;
#   - the record SCHEMA keeps the `phase` field (existing readers depend on it);
#   - release-end -Code records the exit code WITHOUT touching `phase`.
# MUTATION: revert Format-V2Status to print `phase={3}` -> the 'last-phase'/'no bare phase=' checks fail.
# Isolated: AGENTQ_HOME, CODAI_WT_ROOT and AGENTQ_CONFIG point into %TEMP%.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqrel-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_ENV_COPY = '1'; $env:AGENTQ_NO_PREP = '1'; $env:AGENTQ_NO_PRUNE = '1'
$env:AGENTQ_SESSION = 'rel-tester'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$cfg = Join-Path $tmp 'cfg.json'; $env:AGENTQ_CONFIG = $cfg
@{ taskSlotsPerRepo = 2; taskSlotsMachine = 3; minFreeCommitGB = 0 } | ConvertTo-Json | Set-Content $cfg
$fail = 0
$checks = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { $script:checks++; if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
$utf8 = [Text.UTF8Encoding]::new($false)

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n")
git -C $repo add a.txt; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$sha = (git -C $repo rev-parse HEAD).Trim()

# --- fixture: exactly the record the tool wrote on 2026-11-21 (failed run, last phase `github`) -----
$rd = Join-Path $env:AGENTQ_HOME 'releases'; New-Item -ItemType Directory -Force $rd | Out-Null
$relF = Join-Path $rd 'repo__web.json'
$past = [DateTime]::UtcNow.AddMinutes(-40).ToString('o')
[IO.File]::WriteAllText($relF, (@{
      runId = 'misread01'; repo = 'repo'; target = 'web'; sha = 'ca3176c109327864b23da854f8bc66bbc25d05c9'
      ref = 'v0.479.47'; follow = ''; phase = 'github'; preemptible = $false; committed = $true
      phaseAt = ([DateTime]::UtcNow.AddMinutes(-30).ToString('o')); state = 'failed'
      supersedeSha = ''; pendingSha = ''; session = 'term-80432'; pid = 999999; procStart = $past
      started = ([DateTime]::UtcNow.AddMinutes(-40).ToString('o')); purpose = 'post-deploy gate incomplete'
      exitCode = 1
    } | ConvertTo-Json), $utf8)

Push-Location $repo
try {
  $s = AQ status; $c = $code
  Check 'status exits 0' ($c -eq 0) $s
  Check 'the failed release is listed' ($s -match 'repo/web\s+FAILED') $s
  # the release row itself (the line naming repo/web)
  $row = (@($s -split "`n") | Where-Object { $_ -match 'repo/web\s+FAILED' } | Select-Object -First 1)
  Check 'row found' ([bool]$row) $s

  # 1) honest label: the checkpoint column is `last-phase=`, not a bare `phase=`
  Check 'row labels the checkpoint as last-phase=' ($row -match 'last-phase=github') $row
  Check 'row does NOT print a bare phase= that reads as "this phase failed"' (-not ($row -match '(?<!last-)phase=github')) $row
  # 2) the run's exit code is shown separately
  Check 'row shows the run exit code separately (exit=1)' ($row -match '(^|\s)exit=1(\s|$)') $row
  # 3) the legend says what last-phase is
  $header = (@($s -split "`n") | Where-Object { $_ -match '==\s*RELEASES' } | Select-Object -First 1)
  Check 'legend names last-phase as the last checkpoint recorded' ($header -match 'last checkpoint recorded') $header
  Check 'legend says it is NOT the step that failed' ($header -match 'NOT the step that failed') $header

  # 4) schema kept: the `phase` field is still in the record and still exposed by `status -Json`
  Check 'record keeps the phase field' ((Get-Content $relF -Raw | ConvertFrom-Json).phase -eq 'github')
  $j = AQ status -Json | ConvertFrom-Json
  $jr = @($j.releases | Where-Object target -eq 'web')[0]
  Check 'status -Json still exposes phase' ($jr.phase -eq 'github') ($j.releases | ConvertTo-Json -Compress)
  Check 'status -Json exposes exitCode' ($jr.exitCode -eq 1) ($jr | ConvertTo-Json -Compress)

  # 5) release-end -Code records the exit code WITHOUT touching phase (the honest writer)
  AQ release-begin -Target api -Sha $sha -Follow dev -OwnerPid $PID -Purpose 'honesty round-trip' | Out-Null
  $env:AGENTQ_RELEASE_FILE = (Join-Path $rd 'repo__api.json')
  AQ release-phase -Phase prod -Unsafe | Out-Null
  AQ release-end -State failed -Code 7 | Out-Null
  $rec = Get-Content $env:AGENTQ_RELEASE_FILE -Raw | ConvertFrom-Json
  Check 'release-end records exitCode' ($rec.exitCode -eq 7) ($rec | ConvertTo-Json -Compress)
  Check 'release-end does NOT overwrite phase with the exit code' ($rec.phase -eq 'prod') ($rec | ConvertTo-Json -Compress)
  Check 'release-end sets state=failed' ($rec.state -eq 'failed')
  Remove-Item Env:AGENTQ_RELEASE_FILE -ErrorAction SilentlyContinue
  $s2 = AQ status
  $row2 = (@($s2 -split "`n") | Where-Object { $_ -match 'repo/api\s+FAILED' } | Select-Object -First 1)
  Check 'the api row shows last-phase=prod + exit=7' ($row2 -match 'last-phase=prod' -and $row2 -match '(^|\s)exit=7(\s|$)') $row2
  Check 'the api row has no bare phase=' (-not ($row2 -match '(?<!last-)phase=prod')) $row2
} finally { Pop-Location }

if ($fail) { Write-Host "FAILED $fail check(s)" -ForegroundColor Red; exit 1 }
Write-Host "PASS release phase honesty ($checks checks)"
exit 0
