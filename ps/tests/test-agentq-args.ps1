# ADR 0003 W1-5: PowerShell entry hardening. -Paths must work as "a,b", as a string[] from an in-process
# call (arrives joined with spaces), and as several values; a lost '--' gets an explicit message.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqarg-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
$env:AGENTQ_HOME = Join-Path $tmp 'coord'; $env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_SESSION = 'test-args'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
New-Item -ItemType Directory -Force $tmp | Out-Null
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
$repo = Join-Path $tmp 'repo'
git init -q -b main $repo
foreach ($n in 'a', 'b', 'c', 'd', 'e', 'f') { [IO.File]::WriteAllText("$repo\$n.txt", "$n`n") }
git -C $repo add -A; git -C $repo commit -qm init
Push-Location $repo
try {
  function Edit([string[]]$names) { foreach ($n in $names) { [IO.File]::AppendAllText("$repo\$n.txt", "x`n") } }
  function Committed { @(git -C $repo show --name-only --format= HEAD | Where-Object { $_ }) }
  # 1 comma form via -File
  Edit a, b
  $o = @(& pwsh -NoProfile -File $Aq commit -Purpose 'args 1' -Message 'chore: 1' -Paths 'a.txt,b.txt' -NoPush 2>&1) -join "`n"
  Check '1 comma list' ((Committed) -join ',' -eq 'a.txt,b.txt') $o
  # 2 in-process with a string[] (the 2026-10-14 trap: "pathspec 'a b' did not match")
  Edit c, d
  $arr = @('c.txt', 'd.txt')
  $o = @(& $Aq commit -Purpose 'args 2' -Message 'chore: 2' -Paths $arr -NoPush 2>&1) -join "`n"
  Check '2 in-process string[]' ((Committed) -join ',' -eq 'c.txt,d.txt') $o
  # 3 several values via -File
  Edit e, f
  $o = @(& pwsh -NoProfile -File $Aq commit -Purpose 'args 3' -Message 'chore: 3' -Paths e.txt f.txt -NoPush 2>&1) -join "`n"
  Check '3 several values' ((Committed) -join ',' -eq 'e.txt,f.txt') $o
  # 4 lost '--' on run: explicit hint
  $o = @(& pwsh -NoProfile -Command "& '$Aq' run -Resource build -Purpose x pnpm install" 2>&1) -join "`n"
  Check '4 lost -- explained' ($o -match "must follow '--'") $o
} finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
