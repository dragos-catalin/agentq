# agentq lesson/lessons: a durable lesson any future agent can read back, appended to the SAME journal
# as `note` (so it inherits the hash chain and the hub mirror). Synthetic state in %TEMP%; asserts the
# append is a `lesson` event carrying the message + optional -Kind, that `lessons` lists it newest first,
# that the repo filter narrows to the caller's repo, and that -Limit caps the list.
param([string]$Aq = (Join-Path $PSScriptRoot '..\bin\agentq.ps1'))
$ErrorActionPreference = 'Stop'
$Aq = (Resolve-Path $Aq).Path
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("aqlesson-" + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force $tmp | Out-Null
$env:AGENTQ_HOME = Join-Path $tmp 'coord'
$env:CODAI_WT_ROOT = Join-Path $tmp 'wt'
$env:AGENTQ_NO_SIGNAL = '1'; $env:AGENTQ_NO_REGISTRY = '1'; $env:AGENTQ_NO_ADMISSION = '1'
$env:AGENTQ_SESSION = 'test-lessons'
$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }
function AQ { $o = @(& pwsh -NoProfile -File $Aq @args 2>&1 | ForEach-Object { "$_" }); $script:code = $LASTEXITCODE; $o -join "`n" }
$H = $env:AGENTQ_HOME
$jf = Join-Path $H 'journal.jsonl'
function JournalHas([string]$pat) { (Test-Path -LiteralPath $jf) -and (@(Get-Content -LiteralPath $jf) -join "`n") -match [regex]::Escape($pat) }
$repo = Join-Path $tmp 'lessonsrepo'
git init -q -b main $repo
[IO.File]::WriteAllText("$repo\a.txt", "a`n")
git -C $repo add -A; git -C $repo commit -qm init

try {
  Push-Location $repo
  try {
    # ---- 1. append a lesson ------------------------------------------------------------------------
    $out = AQ lesson -Message 'symptom -> what I believed -> what proved it -> the fix'
    Check '1 lesson exits 0' ($script:code -eq 0) "exit=$($script:code) $out"
    Check '1a lesson says it recorded' ($out -match 'lesson recorded') $out
    Check '1b the journal has a lesson event' (JournalHas '"event":"lesson"') ''
    Check '1c the lesson message is in the journal' (JournalHas 'symptom -> what I believed') ''

    # ---- 2. -Kind is an optional class on the line -------------------------------------------------
    $out = AQ lesson -Message 'vertex 400s on lone surrogates' -Kind build
    Check '2 lesson -Kind exits 0' ($script:code -eq 0) "exit=$($script:code) $out"
    Check '2a the kind is recorded' (JournalHas '"kind":"build"') ''

    # a plain note must NOT leak into the lessons list (event filter, not just a grep)
    $null = AQ note -Message 'a handoff, not a lesson'

    # ---- 3. lessons lists them, newest first -------------------------------------------------------
    $out = AQ lessons
    Check '3 lessons exits 0' ($script:code -eq 0) "exit=$($script:code) $out"
    Check '3a lessons shows a recorded message' ($out -match 'symptom -> what I believed') $out
    Check '3b newest is first' ($out.IndexOf('vertex 400s') -ge 0 -and $out.IndexOf('vertex 400s') -lt $out.IndexOf('symptom -> what I believed')) $out
    Check '3c a plain note is not listed' (-not ($out -match 'a handoff, not a lesson')) $out

    # ---- 4. -Limit caps the list; -Json is machine-readable ----------------------------------------
    $out = AQ lessons -Limit 1 -Json
    $parsed = $out | ConvertFrom-Json
    Check '4 lessons -Limit 1 -Json returns exactly one lesson' (@($parsed).Count -eq 1) "n=$(@($parsed).Count) $out"
    $one = @($parsed)[0]
    Check '4a the one lesson is the newest' ($one.event -eq 'lesson' -and $one.message -match 'vertex 400s') $out

    # ---- 5. the repo filter narrows to the caller's repo -------------------------------------------
    $out = AQ lessons -Repo $repo
    Check '5 lessons -Repo <this repo> lists this repo''s lessons' ($out -match 'symptom -> what I believed') $out
    Push-Location $tmp
    try {
      $outNone = AQ lessons -Repo (Join-Path $tmp 'other-repo')
      Check '5a lessons -Repo <other> lists nothing here' (-not ($outNone -match 'symptom -> what I believed')) $outNone
    } finally { Pop-Location }

    # ---- 6. help teaches the new verbs in one step -------------------------------------------------
    $out = AQ help lesson
    Check '6 help lesson exits 0' ($script:code -eq 0) "exit=$($script:code)"
    Check '6a help lesson shows usage' ($out -match 'lesson -Message') $out
    $out = AQ help lessons
    Check '6b help lessons shows usage' ($script:code -eq 0 -and $out -match 'lessons \[-Repo') $out
  } finally { Pop-Location }
} finally { Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue }
if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
