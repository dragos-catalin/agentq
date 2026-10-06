param([string]$Tool = (Join-Path $PSScriptRoot '..\bin\repo-migrate.ps1'))
$ErrorActionPreference = 'Stop'
$Tool = (Resolve-Path $Tool).Path
$fx = Join-Path $env:TEMP ('rmig-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:CODAI_WT_ROOT = "$fx\.wt"
$fails = 0
function Check([string]$n, [bool]$ok, [string]$d = '') { if ($ok) { Write-Host "PASS $n" } else { Write-Host "FAIL $n $d" -ForegroundColor Red; $script:fails++ } }
try {
  git init -q --bare -b main "$fx\o.git"
  $r = "$fx\repo"; git init -q -b main $r; git -C $r config user.email t@t; git -C $r config user.name t
  'a' | Set-Content "$r\a.txt"; git -C $r add a.txt; git -C $r commit -qm init; git -C $r remote add origin "$fx\o.git"; git -C $r push -q -u origin main 2>$null
  # integrated branch, unpushed branch, a stash, dirty tracked + untracked
  git -C $r branch done-b; git -C $r branch -q wip-b; git -C $r -c user.email=t@t -c user.name=t commit -q --allow-empty -m 'x' ; git -C $r branch -f wip-b HEAD; git -C $r reset -q --soft HEAD~1
  'stashed' | Set-Content "$r\s.txt"; git -C $r add s.txt; git -C $r stash push -q -m 'old stash'
  'edit' | Set-Content "$r\a.txt"; 'new' | Set-Content "$r\u.txt"; git -C $r add u.txt
  $statusBefore = (git -C $r status --porcelain) -join '|'
  $indexBefore = (git -C $r diff --cached --name-only) -join '|'
  & pwsh -NoProfile -File $Tool -Repos $r -MinAgeHours 0 -Report "$fx\rep.jsonl" | Out-Null
  $rep = Get-Content "$fx\rep.jsonl" | ConvertFrom-Json
  Check 'no errors' (-not @($rep.errors).Count) ($rep.errors -join ';')
  Check 'working tree untouched' (((git -C $r status --porcelain) -join '|') -eq $statusBefore)
  Check 'index untouched' (((git -C $r diff --cached --name-only) -join '|') -eq $indexBefore)
  $d = ((git -C $r ls-remote origin $rep.dirtyRef) -split '\s+')[0]
  Check 'dirty snapshot on origin has edit + untracked' ((git --git-dir="$fx\o.git" show "${d}:a.txt") -eq 'edit' -and (git --git-dir="$fx\o.git" show "${d}:u.txt") -eq 'new')
  $s = ((git -C $r ls-remote origin @($rep.stashRefs)[0]) -split '\s+')[0]
  Check 'stash backed up on origin and dropped' ($s -and -not (git -C $r stash list))
  Check 'stash content recoverable' ((git --git-dir="$fx\o.git" show "${s}:s.txt") -eq 'stashed')
  Check 'unpushed branch backed up before delete' (@($rep.branchBackups) -contains 'refs/backup/branch/repo/wip-b' -and (git -C $r ls-remote origin refs/backup/branch/repo/wip-b))
  Check 'integrated + unpushed branches deleted, current kept' ((@($rep.branchesDeleted) -contains 'done-b') -and (@($rep.branchesDeleted) -contains 'wip-b') -and (git -C $r rev-parse --verify -q refs/heads/main))
  # no-origin repo: bundle only, nothing changed
  $n = "$fx\local"; git init -q -b main $n; git -C $n config user.email t@t; git -C $n config user.name t
  'l' | Set-Content "$n\l.txt"; git -C $n add l.txt; git -C $n commit -qm l; git -C $n branch keep-me; 'd' | Set-Content "$n\d.txt"
  & pwsh -NoProfile -File $Tool -Repos $n -MinAgeHours 0 -Report "$fx\rep2.jsonl" | Out-Null
  $rep2 = Get-Content "$fx\rep2.jsonl" | ConvertFrom-Json
  Check 'no-origin repo -> verified bundle' ($rep2.bundle -and (Test-Path $rep2.bundle)) ($rep2 | ConvertTo-Json -Compress)
  Check 'no-origin repo: branches + tree untouched' ((git -C $n rev-parse --verify -q refs/heads/keep-me) -and (Test-Path "$n\d.txt"))
  git clone -q $rep2.bundle "$fx\restored" 2>$null
  Check 'bundle restores the dirty snapshot ref' ([bool](git -C "$fx\restored" ls-remote $rep2.bundle "refs/backup/main/local/*"))
} finally { Remove-Item Env:CODAI_WT_ROOT -ErrorAction SilentlyContinue; cmd /c rmdir /s /q "`"$fx`"" 2>$null }
if ($fails) { Write-Host "$fails FAILED"; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
