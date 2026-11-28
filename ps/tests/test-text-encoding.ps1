# The CP437 trap (2026-11-28): a PowerShell pipeline that CAPTURES a file's bytes as text
# (`(git show <ref>:CHANGELOG.md) -join "`n"`) decodes them with the console's OEM code page, and
# writing that text back as UTF-8 makes the damage permanent. It shipped to main inside a landed
# commit and a diff review did not catch it, because the terminal renders the mojibake with the SAME
# shapes as the characters it replaced: `-` looks like an em dash, `rows=[...]` looks like an ellipsis.
# Only a byte census found it (45582 B, 45 high-bit bytes, 0 proper em dash).
#
# This suite is the mechanical defence for that class. It reads the WORKING TREE, decodes every
# source file STRICTLY as UTF-8 and fails on:
#   1  a byte sequence that is not valid UTF-8 (a write-back in Latin-1/CP1252 looks exactly like this)
#   2  a run of two or more consecutive non-ASCII characters that contains the CP437 render of a UTF-8
#      LEAD byte - i.e. a character that is really the first byte of a multi-byte character that was
#      decoded per byte. The alphabet below is that mapping, measured against this tree: the glyphs the
#      repository uses for real ASCII box-drawing (78x '-', 7x '|', 2x 'o', 2x 'j' corners) and as real
#      characters (2x +-, 7x >=, 7x <=) are EXCLUDED, so a table in a doc is not a finding. Everything
#      else in the set is a glyph no prose in this repository legitimately needs.
#   3  a LINE that carries the suite's escape marker is exempt, because one line in this repository is
#      ABOUT this character set: agentq-flakes.mjs matches the mangled marks cloud job logs arrive with
#      on purpose. The oracle for that is the author's intent, not a rule, so the escape hatch is
#      explicit, it exempts exactly the line that carries it (never the file, so a real finding cannot
#      hide behind it), and the suite counts how many lines in the tree claim it.
#
# The source of THIS file is pure ASCII by construction: every fixture is built from [char] codes, so
# the guard can never be the reason it fails, and the fixtures are readable as codepoints, which is the
# only unambiguous way to write a mojibake test. The marker itself is assembled from pieces in the param
# block for the same reason: if this file contained the literal, the census below would count the guard's
# own definition of the escape hatch as a claim to use it, and the suite would fail on its own source.
#
# Exit 0 only if every check passes; 1 otherwise (the run-all convention).
[CmdletBinding(PositionalBinding = $false)]
param(
  # Default = the repository this file lives in (tests/ -> ps/ -> repo root).
  [string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)),
  # Scan a directory tree instead of the git index. Used by the mutation arms so they never touch the repo.
  [string]$Dir = '',
  # The escape marker, assembled so THIS file does not contain it (see the header).
  [string]$Marker = ('encoding-guard' + ': ' + 'allow')
)
$ErrorActionPreference = 'Stop'
$script:pass = 0
$script:fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
  if ($Ok) { $script:pass++; Write-Output "PASS $Name" }
  else { $script:fail++; Write-Output "FAIL $Name$(if ($Detail) { ' - ' + $Detail })" }
}
function Note([string]$Text) { Write-Output "note: $Text" }

# Which files carry text a human or a model reads. Binary formats are not readable as text at all, and
# a lockfile is generated, so neither can carry a hand-made edit that this guard must catch.
$script:Exts = @('md', 'mdx', 'ps1', 'psm1', 'mjs', 'cjs', 'js', 'json', 'jsonc', 'yml', 'yaml', 'sh', 'txt', 'csv', 'rs', 'ts', 'tsx', 'py', 'c', 'h', 'toml')
function Test-Scannable([string]$Path) {
  $ext = $Path.Substring($Path.LastIndexOf('.') + 1).ToLowerInvariant()
  $Path.Contains('.') -and ($script:Exts -contains $ext)
}

# CP437 (0xC2..0xF4) minus what this repository uses for real box-drawing and as real characters.
# The comment on each exclusion is the census that justifies it (2026-11-28, 226 tracked text files).
$script:LeadShadows = [System.Collections.Generic.HashSet[int]]::new()
foreach ($code in @(
    0x252C, # ┬  0xC2
    0x251C, # ├  0xC3
    # 0xC4 is '-' (U+2500), used 78 times as ASCII box drawing - excluded
    0x256C, # ╬  0xCE
    0x2569, # ╩  0xCA
    0x2554, # ╔  0xC9
    0x255A, # ╚  0xC8
    0x2560, # ╠  0xCC
    0x2566, # ╦  0xCB
    0x00E3, # ã  0xC6
    0x00C3, # Ã  0xC7
    0x00A4, # ¤  0xCF
    0x00F0, # ð  0xD0
    0x00D0, # Ð  0xD1
    0x00CA, # Ê  0xD2
    0x00CB, # Ë  0xD3
    0x00C8, # È  0xD4
    0x0131, # ı  0xD5
    0x00CD, # Í  0xD6
    0x00CE, # Î  0xD7
    0x00CF, # Ï  0xD8
    # 0xD9 is 'j' (U+2518) and 0xDA is 'r' (U+250C), used as ASCII box corners - excluded
    0x2588, # █  0xDB
    0x2584, # ▄  0xDC
    0x00A6, # ¦  0xDD
    0x00CC, # Ì  0xDE
    0x2580, # ▀  0xDF
    0x00D3, # Ó  0xE0
    0x00DF, # ß  0xE1
    0x0393, # Γ  0xE2 - the shadow of EVERY 3-byte character (em dash, ellipsis, arrow)
    0x03C0, # π  0xE3
    0x03A3, # Σ  0xE4
    0x03C3, # σ  0xE5
    0x00B5, # µ  0xE6
    0x03C4, # τ  0xE7
    0x03A6, # Φ  0xE8
    0x0398, # Θ  0xE9
    0x03A9, # Ω  0xEA
    0x03B4, # δ  0xEB
    0x221E, # ∞  0xEC
    0x03C6, # φ  0xED
    0x03B5, # ε  0xEE
    0x2229, # ∩  0xEF
    0x2261, # ≡  0xF0
    # 0xF1 is '±' (U+00B1, used twice) - excluded; 0xF2/F3 are '>='/'<=' (U+2265/U+2264, used 7x each) - excluded
    0x2320, # ⌠  0xF4
    0x2321, # ⌡  0xF5
    0x00F7, # ÷  0xF6
    0x2248  # ≈  0xF7
  )) { [void]$script:LeadShadows.Add($code) }

function U([int[]]$Codes) { -join ($Codes | ForEach-Object { [char]$_ }) }

# The one predicate. Returns one object per offending run; the codepoints are printed so the repair is
# mechanical (they are the bytes of the intended character, read through CP437).
function Get-MojibakeFindings([string]$Line) {
  $out = @()
  $i = 0
  while ($i -lt $Line.Length) {
    if ([int]$Line[$i] -lt 128) { $i++; continue }
    $j = $i
    while ($j -lt $Line.Length -and [int]$Line[$j] -ge 128) { $j++ }
    if (($j - $i) -ge 2) {
      $run = $Line.Substring($i, $j - $i)
      $shadow = $false
      foreach ($ch in $run.ToCharArray()) { if ($script:LeadShadows.Contains([int]$ch)) { $shadow = $true; break } }
      if ($shadow) {
        $out += [pscustomobject]@{
          Run   = $run
          Codes = (@($run.ToCharArray() | ForEach-Object { 'U+' + ([int]$_).ToString('X4') }) -join ' ')
        }
      }
    }
    $i = $j
  }
  @($out)
}

# Read one file: strict UTF-8, and a decode failure is itself a finding (that is what a CP1252 write-back
# of a UTF-8 file looks like - the bytes are valid in the source code page, not here).
function Get-FileFindings([string]$Path, [string]$Rel) {
  $out = @()
  $bytes = [IO.File]::ReadAllBytes($Path)
  $strict = [Text.UTF8Encoding]::new($false, $true)
  try { $text = $strict.GetString($bytes) }
  catch {
    return @([pscustomobject]@{ Rel = $Rel; Line = 0; Run = ''; Codes = ''; Why = 'not valid UTF-8 (a byte-level write-back)' })
  }
  $n = 0
  foreach ($line in ($text -split "`r?`n")) {
    $n++
    if ($line.Contains($Marker)) { continue }
    foreach ($f in @(Get-MojibakeFindings $line)) {
      $out += [pscustomobject]@{ Rel = $Rel; Line = $n; Run = $f.Run; Codes = $f.Codes; Why = 'CP437 re-encoding' }
    }
  }
  @($out)
}

# Which files to read: the working tree of the git repository (untracked scratch is not source), or a
# plain directory walk for the mutation arms.
# The git index is the right list - it is exactly "source, not scratch" - but this suite also runs in
# the land pool, which uploads a working tree that may carry no .git at all. So the index is preferred
# and a bounded walk is the fallback: never throw (a guard that cannot state its subject is worse than
# no guard), never descend into build output, and say which one was used.
$script:SkipDirs = @('.git', '.copilot-tmp', 'node_modules', 'target', 'dist', 'obj', '.turbo', '.venv', '__pycache__', 'coverage', '.next', 'TestResults')
$script:ListSource = ''
function Get-WalkFiles([string]$Top, [int]$Cap = 4000) {
  $out = @()
  $stack = [System.Collections.Generic.Stack[string]]::new()
  $stack.Push($Top)
  while ($stack.Count -gt 0 -and $out.Count -lt $Cap) {
    $d = $stack.Pop()
    foreach ($e in @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) {
      if ($e.PSIsContainer) {
        if ($script:SkipDirs -contains $e.Name) { continue }
        $stack.Push($e.FullName)
      } elseif (Test-Scannable $e.Name) { $out += $e.FullName }
    }
  }
  @($out)
}
function Get-TargetFiles([string]$TheRoot, [string]$TheDir) {
  if ($TheDir) {
    $script:ListSource = 'directory walk'
    return @(Get-WalkFiles $TheDir)
  }
  $rel = @()
  $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue
  if ($git) { $rel = @(& $git.Source -C $TheRoot ls-files 2>$null | Where-Object { $_ }) }
  if ($rel.Count -gt 0) {
    $script:ListSource = "the git index ($($rel.Count) tracked files)"
    $out = @()
    foreach ($r in $rel) {
      $p = $r.Replace('/', '\')
      if (-not (Test-Scannable $p)) { continue }
      $full = Join-Path $TheRoot $p
      if (Test-Path -LiteralPath $full) { $out += $full }
    }
    return @($out)
  }
  $script:ListSource = 'a directory walk (no git index here - build output and scratch are skipped)'
  @(Get-WalkFiles $TheRoot)
}

function Invoke-Scan([string]$TheRoot, [string]$TheDir) {
  $findings = @()
  $files = @(Get-TargetFiles $TheRoot $TheDir)
  $bytes = 0
  foreach ($f in $files) {
    try { $bytes += (Get-Item -LiteralPath $f).Length } catch { }
    # Repo-relative where it can be, absolute in a temp tree - a report must be actionable either way.
    $rel = if ($TheDir) { $f } else { $f.Substring($TheRoot.Length).TrimStart('\') }
    $findings += @(Get-FileFindings $f $rel)
  }
  [pscustomobject]@{ Findings = @($findings); Files = $files.Count; Bytes = $bytes; Source = $script:ListSource }
}

# --- 1. the predicate, on fixtures built from codepoints (this file stays ASCII) -------------------
$mdash = 0x2014; $ell = 0x2026; $arrow = 0x2192; $times = 0x00D7; $sect = 0x00A7
$shadMdash = U @(0x0393, 0x00C7, 0x00F6)     # what a CP437 pipeline leaves of an em dash
$shadEll = U @(0x0393, 0x00C7, 0x00AA)       # ... of an ellipsis
$shadArrow = U @(0x0393, 0x00E5, 0x00C6)     # ... of a rightwards arrow
$shadTimes = U @(0x251C, 0x00F9)             # ... of a multiplication sign
$shadSect = U @(0x252C, 0x00BA)              # ... of a section sign
$shadDouble = U @(0x256C, 0x00F4, 0x251C, 0x00E7, 0x252C, 0x00AC)  # a double-encoded ellipsis

Check 'a CP437 em dash is a finding' (@(Get-MojibakeFindings "text $shadMdash more").Count -eq 1)
Check 'a CP437 ellipsis is a finding' (@(Get-MojibakeFindings "rows=[$shadEll]").Count -eq 1)
Check 'a CP437 arrow is a finding' (@(Get-MojibakeFindings "25 $shadArrow 240").Count -eq 1)
Check 'a CP437 multiplication sign is a finding' (@(Get-MojibakeFindings "p50/p90 $shadTimes lane").Count -eq 1)
Check 'a CP437 section sign is a finding' (@(Get-MojibakeFindings "docs.md $shadSect 6.3").Count -eq 1)
Check 'a double-encoded run is a finding' (@(Get-MojibakeFindings "rows=[$shadDouble]").Count -eq 1)
Check 'the real em dash is not a finding' (@(Get-MojibakeFindings "a $(U @($mdash)) b").Count -eq 0)
Check 'the real arrow is not a finding' (@(Get-MojibakeFindings "25 $(U @($arrow)) 240").Count -eq 0)
Check 'a line of real characters is not a finding' (@(Get-MojibakeFindings "50% $(U @($times)) 3, $(U @($sect))6.3, $(U @($ell))").Count -eq 0)
Check 'a lone glyph followed by ASCII is not a finding' (@(Get-MojibakeFindings ((U @(0x251C)) + '-- file')).Count -eq 0)
Check 'a box-drawing tree IS a finding, which is why the line marker exists' (@(Get-MojibakeFindings ((U @(0x251C, 0x2500, 0x2500)) + ' file')).Count -eq 1)
Check 'a table drawn with the excluded glyphs is not a finding' (@(Get-MojibakeFindings ((U @(0x2500, 0x2500, 0x2500)) + '  ' + (U @(0x2502)))).Count -eq 0)
Check 'a lone non-ASCII character is not a finding' (@(Get-MojibakeFindings (U @(0x2192))).Count -eq 0)
Check 'a legitimate 2-char run with no lead shadow is not a finding' (@(Get-MojibakeFindings ((U @(0x2014, 0x2026)))).Count -eq 0)
Check 'two runs on one line are two findings' (@(Get-MojibakeFindings "$shadMdash and $shadTimes").Count -eq 2)

# --- 2. the scanner, on a temp tree (never on the repository) --------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('te-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$null = New-Item -ItemType Directory -Path $tmp -Force
try {
  $good = Join-Path $tmp 'good.md'
  $bad = Join-Path $tmp 'bad.md'
  $marked = Join-Path $tmp 'marked.ps1'
  $linewise = Join-Path $tmp 'linewise.md'
  $bin = Join-Path $tmp 'not-utf8.txt'
  [IO.File]::WriteAllText($good, "a real em dash $(U @($mdash)) and an arrow $(U @($arrow))`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($bad, "line one`nrows=[$shadEll] and 25 $shadArrow 240`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($marked, "# $Marker deliberate matchers: $shadTimes $shadArrow`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText($linewise, "| col | col |  # $Marker this table is drawn with box glyphs`n| --- | --- |`nrows=[$shadEll]`n", [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllBytes($bin, [byte[]]@(0x63, 0x61, 0x66, 0xE9, 0x0A))   # 'cafe' in CP1252
  $scan = Invoke-Scan '' $tmp
  Check 'MUTATION: the scanner finds the corrupted file' (@($scan.Findings | Where-Object { $_.Rel -like '*bad.md' }).Count -eq 2) "found $(@($scan.Findings | Where-Object { $_.Rel -like '*bad.md' }).Count)"
  Check 'MUTATION: the clean file is not reported' (@($scan.Findings | Where-Object { $_.Rel -like '*good.md' }).Count -eq 0)
  Check 'MUTATION: the marked file is not reported' (@($scan.Findings | Where-Object { $_.Rel -like '*marked.ps1' }).Count -eq 0)
  Check 'MUTATION: a marker on ONE line exempts that line only' (@($scan.Findings | Where-Object { $_.Rel -like '*linewise.md' }).Count -eq 1) "found $(@($scan.Findings | Where-Object { $_.Rel -like '*linewise.md' }).Count)"
  Check 'MUTATION: a file that is not valid UTF-8 is reported' (@($scan.Findings | Where-Object { $_.Rel -like '*not-utf8.txt' }).Count -eq 1)
  Check 'the scanner read every fixture (not vacuous)' ($scan.Files -eq 5 -and $scan.Bytes -gt 0) "files=$($scan.Files) bytes=$($scan.Bytes)"
  Check 'the finding names the file and the line' ((@($scan.Findings | Where-Object { $_.Rel -like '*bad.md' } | Select-Object -First 1)[0].Line) -eq 2)
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 3. the subject tree: the repository by default, -Dir when a mutation arm names one ------------
# -Dir SCANS THE NAMED TREE (it is not ignored - an unused parameter would make every -Dir arm pass,
# which is exactly how the first version of this file managed to report the corrupted CHANGELOG clean).
$subject = Invoke-Scan $Root $Dir
Note "scanned $($subject.Files) text files, $([math]::Round($subject.Bytes / 1MB, 2)) MB, from $($subject.Source)"
$byFile = @($subject.Findings | Group-Object Rel)
foreach ($f in $byFile) {
  foreach ($x in @($f.Group | Select-Object -First 3)) {
    Write-Output "  $($x.Rel):$($x.Line)  [$($x.Run)]  $($x.Codes)  $($x.Why)"
  }
  if ($f.Count -gt 3) { Write-Output "  $($f.Name): $($f.Count) findings (first 3 shown)" }
}
$enough = if ($Dir) { $subject.Files -ge 1 -and $subject.Bytes -gt 0 } else { $subject.Files -ge 150 -and $subject.Bytes -ge 1MB }
Check 'MUTATION: the scan actually reads its subject' $enough "files=$($subject.Files) bytes=$($subject.Bytes)"
Check 'no file in the subject tree is re-encoded through CP437' ($subject.Findings.Count -eq 0) "$($subject.Findings.Count) finding(s)"

# The escape hatch is a decision, so its spread is visible: exactly ONE line in the tree may claim it,
# the line that matches the mangled mark glyphs. A second one is a red suite, and the author then has to
# say why - in a commit, where it can be reviewed.
if (-not $Dir) {
  $markedLines = @()
  # This file is the one place where a future edit could type the marker in prose (it DEFINES the hatch),
  # so it is not counted. Its own content is still scanned above - only the census skips it.
  $self = 'ps\tests\test-text-encoding.ps1'
  foreach ($f in @(Get-TargetFiles $Root '')) {
    $rel = $f.Substring($Root.Length).TrimStart('\')
    if ($rel -eq $self) { continue }
    $n = 0
    foreach ($line in ((Get-Content -LiteralPath $f -Raw) -split "`r?`n")) {
      $n++
      if ($line.Contains($Marker)) { $markedLines += "${rel}:$n" }
    }
  }
  Check 'exactly one line in the tree claims the escape marker' ($markedLines.Count -eq 1) "marked: $($markedLines -join ', ')"
  Check 'the deliberate CP437 matchers in agentq-flakes.mjs are the marked line' (($markedLines.Count -eq 1) -and $markedLines[0].StartsWith('ps\bin\agentq-flakes.mjs:')) "marked: $($markedLines -join ', ')"
}

if ($script:fail -gt 0) { Write-Output "text-encoding suite: $script:pass passed, $script:fail failed"; exit 1 }
Write-Output "text-encoding suite: $script:pass passed, 0 failed"
exit 0
