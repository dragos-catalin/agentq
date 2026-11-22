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
  # 5 the v3 scheduling flags reach the ticket, not just the parser. Regression 2026-11-22: a
  # "pre-initialise so StrictMode cannot throw" block was written AFTER the parse loop, and because the
  # top-level scope IS the script scope, `$script:Lane/$script:Priority/$script:Capacity = $null` wiped
  # the flags just parsed - every ticket got lane `gate` + priority 0, so the v3 soft slots (quick burst,
  # beside-batch) and the priority order never fired. That is what made three cases of
  # test-agentq-v3.ps1 red. The flags are read off the ticket file, so this pins the parse -> ticket path.
  $cfg = Join-Path $tmp 'agentq-config.json'
  @{ machineCap = 1; quickBurst = 1; agingMin = 0; minFreeCommitGB = 0 } | ConvertTo-Json | Set-Content $cfg
  $env:AGENTQ_CONFIG = $cfg; $env:AGENTQ_NO_ADMISSION = '1'
  $a5 = @('-NoProfile', '-File', $Aq, 'run', '-Resource', 'build', '-Purpose', 'flags-probe', '-Lane', 'quick', '-Priority', '33', '-Capacity', '2', '-MinFreeGB', '0', '-TimeoutMin', '2', '--', 'pwsh', '-NoProfile', '-Command', 'Start-Sleep -Seconds 12')
  $p5 = Start-Process pwsh -ArgumentList $a5 -WorkingDirectory $repo -PassThru -WindowStyle Hidden
  $q5 = Join-Path $env:AGENTQ_HOME 'queues'
  $t5 = @()
  for ($k = 0; $k -lt 40 -and -not $t5.Count; $k++) {
    Start-Sleep -Milliseconds 400
    $t5 = @(Get-ChildItem $q5 -Recurse -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.purpose -eq 'flags-probe' })
  }
  $cap5 = @(Get-ChildItem $q5 -Recurse -Filter 'capacity' -ErrorAction SilentlyContinue | Where-Object { $_.Directory.Name -eq 'build_repo' } | ForEach-Object { (Get-Content $_.FullName -Raw).Trim() })
  Check '5 -Lane/-Priority/-Capacity reach the ticket' (($t5.Count -ge 1) -and -not ($t5 | Where-Object { $_.lane -ne 'quick' -or [int]$_.prio -ne 33 }) -and ($cap5 -contains '2')) ("tickets=" + $t5.Count + " lane=" + (($t5 | ForEach-Object lane) -join ',') + " prio=" + (($t5 | ForEach-Object prio) -join ',') + " cap=" + ($cap5 -join ','))
  $p5.WaitForExit(30000) | Out-Null
  Remove-Item Env:AGENTQ_CONFIG, Env:AGENTQ_NO_ADMISSION -ErrorAction SilentlyContinue
} finally { Pop-Location; Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
