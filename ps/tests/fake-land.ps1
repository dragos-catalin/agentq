# Test double for `agentq land -Branch <topic> -Onto <branch>`: cherry-picks the topic's commits that are not
# on origin/<onto> in a throwaway clone and pushes. FAKE_LAND_FAIL=1 -> exit 7 without pushing.
param([Parameter(Position = 0)][string]$Cmd, [string]$Branch, [string]$Onto, [string]$Purpose)
if ($env:FAKE_LAND_FAIL) { Add-Content $env:FAKE_LAND_CALLS 'fail'; exit 7 }
Add-Content $env:FAKE_LAND_CALLS 'land'
$origin = (git remote get-url origin).Trim()
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('fl-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
git clone -q $origin $tmp 2>$null
git -C $tmp checkout -q $Onto
$picks = @(git -C $tmp rev-list --reverse --no-merges --cherry-pick --right-only "origin/$Onto...origin/$Branch")
foreach ($c in $picks) { git -C $tmp cherry-pick -x --allow-empty $c 2>&1 | Out-Null; if ($LASTEXITCODE) { exit 5 } }
git -C $tmp push -q origin "HEAD:$Onto" 2>$null
$rc = $LASTEXITCODE
Remove-Item -Recurse -Force $tmp
exit $rc
