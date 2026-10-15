# Regression tests for `agentq land` on brivio (2026-10-15):
#  1. the CHANGELOG union must be BYTE-exact: the old resolver piped the stages through PowerShell
#     (native output decoded with the console code page, CP437) and re-wrote them as UTF-8, so every
#     non-ASCII byte became 2-3 bytes on each land (brivio CHANGELOG 24 MB -> 124 MB, GitHub GH001);
#  2. land refuses to push (exit 8) when a CHANGELOG blob grows past 1.5x its size on origin;
#  3. a backup whose push origin refuses falls back to a verified local bundle instead of throwing
#     "could not be verified (got '')" and wedging every later land/unlease.
# Isolated: AGENTQ_HOME, CODAI_WT_ROOT and AGENTQ_CONFIG point into %TEMP%; a bare repo = origin.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqland-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'
$env:AGENTQ_SESSION = 'test-L'
$cfg = Join-Path $tmp 'cfg.json'
New-Item -ItemType Directory -Force $tmp | Out-Null
'{"taskSlotsPerRepo":2,"taskSlotsMachine":3,"leaseDeadIdleMin":1,"leaseMaxIdleMin":5,"minFreeCommitGB":0}' | Set-Content $cfg
$env:AGENTQ_CONFIG = $cfg
$fail = 0
$utf8 = [Text.UTF8Encoding]::new($false)
$script:Line = '- intrare 11999: factură, ș ț ă î â — „ghilimele” și emoji 🚀 pentru contabilitate'
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
function BlobSize([string]$rev) { [long]"$(git -C $repo cat-file -s $rev)".Trim() }
function BlobText([string]$rev) {
  # cmd redirection keeps the raw bytes (no PowerShell decoding of native output)
  $f = Join-Path $tmp ('blob-' + [guid]::NewGuid().ToString('N'))
  cmd /c "git -C `"$repo`" cat-file -p $rev > `"$f`""
  $t = $utf8.GetString([IO.File]::ReadAllBytes($f)); Remove-Item $f; $t
}
function Prepend([string]$dir, [string]$entry) {
  $p = Join-Path $dir 'CHANGELOG.md'; $t = [IO.File]::ReadAllText($p, $utf8)
  [IO.File]::WriteAllText($p, $t.Replace("# Changelog`n`n", "# Changelog`n`n$entry`n"), $utf8)
}
function NewTopic([string]$name) {
  git -C $tw fetch -q origin
  git -C $tw checkout -q -B $name origin/dev 2>$null
}

$bare = Join-Path $tmp 'origin.git'; $repo = Join-Path $tmp 'repo'
git init -q --bare -b dev $bare
git init -q -b dev $repo; git -C $repo config user.email t@t; git -C $repo config user.name t; git -C $repo config core.autocrlf false
# A big CHANGELOG full of Romanian diacritics + emoji (UTF-8 multi-byte), shaped like brivio's.
$sb = [Text.StringBuilder]::new("# Changelog`n`n## [0.1.0]`n")
for ($i = 0; $i -lt 12000; $i++) { [void]$sb.Append($script:Line.Replace('11999', "$i") + "`n") }
[IO.File]::WriteAllText((Join-Path $repo 'CHANGELOG.md'), $sb.ToString(), $utf8)
Set-Content (Join-Path $repo 'a.txt') 'a'
git -C $repo add a.txt CHANGELOG.md; git -C $repo commit -qm init
git -C $repo remote add origin $bare; git -C $repo push -q -u origin dev 2>$null
$tw = Join-Path $tmp 'topic'
git -C $repo worktree add -q --detach $tw origin/dev 2>$null
git -C $tw config user.email t@t; git -C $tw config user.name t; git -C $tw config core.autocrlf false
Push-Location $repo
try {
  # --- 1. union on a big UTF-8 CHANGELOG is byte-exact ---------------------------------------
  NewTopic 'topic1'
  Prepend $tw '## [0.1.2] — topic: corecție „ș”'
  Set-Content (Join-Path $tw 't.txt') 't'; git -C $tw add CHANGELOG.md t.txt; git -C $tw commit -qm 'topic 0.1.2'
  git -C $tw push -q origin topic1 2>$null
  # dev moved past the topic's version with its own entry at the same spot -> CHANGELOG conflict
  Prepend $repo '## [0.1.1] — dev: îmbunătățire'
  git -C $repo add CHANGELOG.md; git -C $repo commit -qm 'dev 0.1.1'; git -C $repo push -q origin dev 2>$null
  $before = BlobSize 'origin/dev:CHANGELOG.md'
  $o = AQ land -Branch topic1 -Onto dev -Purpose 'land big changelog'
  Check 'land with CHANGELOG conflict exits 0' ($code -eq 0) $o
  git -C $repo fetch -q origin
  $after = BlobSize 'origin/dev:CHANGELOG.md'
  Check 'CHANGELOG did not blow up (< before + 1 KB)' ($after -lt $before + 1024) "before=$before after=$after"
  $txt = BlobText 'origin/dev:CHANGELOG.md'
  Check 'both entries kept, UTF-8 intact' ($txt.Contains('## [0.1.2] — topic: corecție „ș”') -and $txt.Contains('## [0.1.1] — dev: îmbunătățire')) $txt.Substring(0, [Math]::Min(300, $txt.Length))
  Check 'old lines byte-identical (diacritics + emoji)' ($txt.Contains($script:Line + "`n"))
  Check 'no conflict markers' (-not ($txt -match '(?m)^(<{7}|>{7}|={7})( |$)'))
  Check 'no mojibake (no U+2500 box-drawing chars)' (-not ($txt -match '[\u2500-\u257F]'))
  Check 'land slot lease released' (-not (Test-Path (Join-Path $env:AGENTQ_HOME 'leases\repo\land.json')))

  # --- 2. a CHANGELOG growing > 1.5x is refused, nothing pushed -------------------------------
  NewTopic 'topic2'
  $p = Join-Path $tw 'CHANGELOG.md'; $t = [IO.File]::ReadAllText($p, $utf8)
  [IO.File]::WriteAllText($p, $t + $t, $utf8)
  git -C $tw commit -qam 'doubled changelog'; git -C $tw push -q origin topic2 2>$null
  $tip = (git -C $repo ls-remote origin refs/heads/dev).Split("`t")[0]
  $o = AQ land -Branch topic2 -Onto dev -Purpose 'land doubled'
  $tip2 = (git -C $repo ls-remote origin refs/heads/dev).Split("`t")[0]
  Check 'oversized CHANGELOG -> exit 8' ($code -eq 8) $o
  Check 'oversized: message names the file and the 1.5x limit' ($o -match 'CHANGELOG\.md' -and $o -match '1\.5x') $o
  Check 'oversized: nothing pushed' ($tip -eq $tip2)
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'land-oversized' })
  Check 'oversized: journaled' ($j.Count -eq 1)
  $bk = @(git -C $repo --git-dir=$bare for-each-ref --format='%(objectname)' refs/backup/wt/repo/land)
  Check 'oversized: the bad result is not backed up to origin' (-not @($bk | Where-Object { (git --git-dir=$bare cat-file -s "${_}:CHANGELOG.md") -gt 1.5 * $before }).Count)

  # --- 3. backup refused by origin -> verified local bundle, nothing wedged -----------------
  $hook = Join-Path $bare 'hooks\pre-receive'
  $hookText = @'
#!/bin/sh
while read o n r; do
  case "$r" in refs/backup/*) echo "remote: error: GH001: Large files detected." >&2; exit 1;; esac
done
exit 0
'@
  [IO.File]::WriteAllText($hook, $hookText.Replace("`r`n", "`n"), $utf8)
  $o = AQ lease -Purpose 'bk' -Json; $l = $o | Select-Object -Last 1 | ConvertFrom-Json
  Set-Content (Join-Path $l.path 'a.txt') 'dirty'
  $o = AQ unlease -Repo $l.path -LeaseId $l.leaseId
  Check 'unlease with a refused backup push -> exit 0' ($code -eq 0) $o
  Check 'unlease names the bundle fallback' ($o -match 'bundle') $o
  $bundles = @(Get-ChildItem (Join-Path $env:CODAI_WT_ROOT '_bundles') -Filter 'repo-task-*.bundle' -ErrorAction SilentlyContinue)
  Check 'fallback bundle written' ($bundles.Count -ge 1)
  if ($bundles) {
    $null = cmd /c "git -C `"$repo`" bundle verify -q `"$($bundles[0].FullName)`" 2>nul"
    Check 'fallback bundle verifies' ($LASTEXITCODE -eq 0)
    $heads = cmd /c "git bundle list-heads `"$($bundles[0].FullName)`""
    $sha = ("$heads" -split '\s+')[0]
    Check 'bundle holds the dirty edit' ((cmd /c "git -C `"$repo`" fetch -q `"$($bundles[0].FullName)`" $sha 2>nul && git -C `"$repo`" show ${sha}:a.txt") -eq 'dirty')
  }
  $j = @(Get-Content (Join-Path $env:AGENTQ_HOME 'journal.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.event -eq 'backup' } | Select-Object -Last 1)
  Check 'journal records the refused push + bundle' ("$($j.pushError)" -match 'GH001' -and "$($j.bundle)" -match '\.bundle$') ($j | ConvertTo-Json -Compress)

  # --- 4. the next land after all that still works -------------------------------------------
  NewTopic 'topic3'
  Prepend $tw '## [0.1.3] — după refuz'
  git -C $tw commit -qam 'topic 0.1.3'; git -C $tw push -q origin topic3 2>$null
  git -C $repo pull -q --no-rebase origin dev 2>$null
  Prepend $repo '## [0.1.2b] — dev iar'
  git -C $repo add CHANGELOG.md; git -C $repo commit -qm 'dev 0.1.2b'; git -C $repo push -q origin dev 2>$null
  $o = AQ land -Branch topic3 -Onto dev -Purpose 'land after refusal'
  Check 'land after a refused land + refused backup exits 0' ($code -eq 0) $o
  git -C $repo fetch -q origin
  $txt = BlobText 'origin/dev:CHANGELOG.md'
  Check 'third entry landed, still byte-exact' ($txt.Contains('## [0.1.3] — după refuz') -and $txt.Contains('## [0.1.2b] — dev iar') -and -not ($txt -match '[\u2500-\u257F]'))
} finally {
  Pop-Location
  foreach ($v in 'AGENTQ_HOME', 'CODAI_WT_ROOT', 'AGENTQ_CONFIG', 'AGENTQ_SESSION') { Remove-Item "Env:$v" -ErrorAction SilentlyContinue }
  cmd /c rmdir /s /q "`"$tmp`"" 2>$null
}
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red; exit 1 } else { Write-Host 'ALL PASS'; exit 0 }
