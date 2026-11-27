# Static guard for the class behind the red `agentq v3` suite (2026-11-22).
#
# In a `pwsh -File` script the top-level scope IS the script scope, so a script-scope write of `$null`
# placed AFTER a real value was computed silently discards it. Commit cf8278c added such a "pre-initialise
# so StrictMode 3 cannot throw" block right after the argument parse loop:
#     $script:Lane = $null; $script:Priority = $null; $script:Capacity = $null ...
# Every `-Lane/-Priority/-Capacity` was then ignored: all tickets got lane `gate` + priority 0, the v3
# soft slots (quick burst, beside-batch) and the priority order never fired, and three cases of
# test-agentq-v3.ps1 went red. The same commit put `$script:ReadOnly = $null` at the top of agentq-v2.ps1,
# which agentq.ps1 dot-sources AFTER computing `$script:ReadOnly`, turning every read-only verb into a
# writer. Three rules, one per shape:
#   A (intra-file)  : a column-0 `NAME = $null` in file F, where F assigned NAME a non-null value earlier
#                     and references NAME later.
#   B (cross-file)  : a column-0 `NAME = $null` at a dot-sourced child's top level, where the parent's last
#                     write to NAME before the dot-source is non-null and the parent references NAME later.
#   C (param clobber): a dot-sourced child C declares NAME in its own `param()` block, and the parent P both
#                     writes NAME before the dot-source and reads NAME after it. Dot-sourcing assigns C's
#                     parameters INTO P's scope, so C's default (or bound value) for NAME silently overwrites
#                     P's, with NO assignment visible in P for a grep to find. 2026-11-27: gate.ps1's
#                     `-PoolParallel 7` was accepted, then read back as the child's default 4 (it printed 7 at
#                     the top of the script and 4 thirty lines later). B is blind to it - B only looks for a
#                     column-0 `$script:NAME = $null` reset in C, and a `param()` declaration is not that.
# The test also mutates temp copies to prove it would catch every defect again.
param([string]$Ps = (Join-Path $PSScriptRoot '..'))
$ErrorActionPreference = 'Stop'
$Ps = (Resolve-Path $Ps).Path
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') { if ($ok) { Write-Host "PASS $name" } else { Write-Host "FAIL $name $detail" -ForegroundColor Red; $script:fail++ } }

$script:Skip = @('Error', 'PSScriptRoot', 'PSCommandPath', 'Verb', 'true', 'false', 'null', 'HOME', 'IsWindows', 'LASTEXITCODE', 'PID', 'args', 'env')

function Get-SourceMap([string]$dir) {
  $h = @{}
  foreach ($f in (Get-ChildItem $dir -Recurse -Filter '*.ps1' | Where-Object { $_.FullName -notmatch '\\tests\\' })) { $h[$f.Name] = @(Get-Content $f.FullName) }
  $h
}
# every `NAME = <rhs>` assignment on a line, for both `$script:NAME` and bare `$NAME`
function Get-Assignments([string]$line) {
  $out = @()
  # rhs stops at the first `;` (so `$a = 1; $b = 2` yields both) or at end of line
  foreach ($m in [regex]::Matches($line, '\$(script:)?(\w+)\s*=\s*([^;]*?)(?=\s*(?:;|$))')) {
    if ($m.Groups[2].Value -in $script:Skip) { continue }
    $out += [pscustomobject]@{ Name = $m.Groups[2].Value; Rhs = "$($m.Groups[3].Value)".Trim() }
  }
  $out
}
function Test-Nullish([string]$rhs) { $rhs -match '^\$null$' -or $rhs -eq "''" -or $rhs -eq '""' }

function Get-RuleA([hashtable]$src) {
  $f = @()
  foreach ($name in $src.Keys) {
    $lines = $src[$name]
    for ($i = 0; $i -lt $lines.Count; $i++) {
      # a script-scope reset at column 0. A bare `$X = $null` at column 0 is the same slot as `$script:X`
      # in a `pwsh -File` script, so both forms are in scope.
      if ($lines[$i] -notmatch '^\$(script:)?[A-Za-z_]') { continue }
      foreach ($a in (Get-Assignments $lines[$i])) {
        if (-not (Test-Nullish $a.Rhs)) { continue }
        $realBefore = $false; $readAfter = $false
        for ($j = 0; $j -lt $lines.Count; $j++) {
          if ($j -eq $i) { continue }
          if ($lines[$j] -notmatch "(?<![\w:`$])\`$(script:)?$($a.Name)\b") { continue }
          if ($j -lt $i) { foreach ($b in (Get-Assignments $lines[$j])) { if ($b.Name -eq $a.Name -and -not (Test-Nullish $b.Rhs)) { $realBefore = $true } } }
          else { $readAfter = $true }
        }
        if ($realBefore -and $readAfter) { $f += [pscustomobject]@{ File = $name; Line = $i + 1; Name = $a.Name; Text = $lines[$i].Trim() } }
      }
    }
  }
  $f
}
function Get-DotSources([hashtable]$src, [string]$name) {
  $out = @(); $lines = $src[$name]; if (-not $lines) { return $out }
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    # `. (Join-Path $Any 'path')` - the variable need not be $PSScriptRoot (gate.ps1 uses `$repoRoot` with a
    # `ps\bin\...` path), so the child is matched by its LEAF name (the map is keyed by file name).
    if ($l -match "\.\s*\(Join-Path\s+\`$\w+\s+'([^']+)'\)") { $out += [pscustomobject]@{ Line = $i + 1; Child = (Split-Path -Leaf $Matches[1]) } }
    elseif ($l -match '^\s*\.\s+\$(\w+)') {
      $var = $Matches[1]
      for ($j = $i - 1; $j -ge 0; $j--) {
        if ($lines[$j] -match "\`$$var\s*=\s*Join-Path\s+\`$\w+\s+'([^']+)'") { $out += [pscustomobject]@{ Line = $i + 1; Child = (Split-Path -Leaf $Matches[1]) }; break }
      }
    }
  }
  $out
}
# the PARAMETER NAMES declared in a file's TOP-LEVEL `param(...)` block: every `$name` on a non-comment
# line between `param(` and its matching `)` (depth-tracked, so defaults/arrays/attributes need no special
# casing). Lines before it may be comments, `<#...#>` blocks, `#requires` or `[CmdletBinding()]`; a real
# statement before `param()` means there is no top-level param block.
function Get-ParamNames([string[]]$lines) {
  $names = @(); $start = -1; $inBlock = $false
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($inBlock) { if ($l -match '#>') { $inBlock = $false }; continue }
    if ($l -match '^\s*<#') { if ($l -notmatch '#>') { $inBlock = $true }; continue }
    if ($l -match '^\s*#') { continue }
    if ($l -match '^\s*param\s*\(') { $start = $i; break }
    if ($l -match '^\s*\[CmdletBinding') { continue }
    if ($l -match '^\s*\S') { break }
  }
  if ($start -lt 0) { return $names }
  $depth = 0
  for ($i = $start; $i -lt $lines.Count; $i++) {
    $l = $lines[$i]
    if ($l -notmatch '^\s*#') { foreach ($m in [regex]::Matches($l, '\$(\w+)')) { $names += $m.Groups[1].Value } }
    $depth += ([regex]::Matches($l, '\(')).Count
    $depth -= ([regex]::Matches($l, '\)')).Count
    if ($depth -le 0) { break }
  }
  @($names | Select-Object -Unique)
}
function Get-RuleB([hashtable]$src) {
  $f = @()
  foreach ($name in $src.Keys) {
    foreach ($ds in (Get-DotSources $src $name)) {
      if (-not $src.ContainsKey($ds.Child)) { continue }
      $clines = $src[$ds.Child]
      for ($i = 0; $i -lt $clines.Count; $i++) {
        if ($clines[$i] -notmatch '^\$script:') { continue }
        foreach ($a in (Get-Assignments $clines[$i])) {
          if (-not (Test-Nullish $a.Rhs)) { continue }
          # the parent's LAST write to NAME before the dot-source must be non-null, and it must read NAME later
          $last = $null; $readAfter = $false
          for ($j = 0; $j -lt $src[$name].Count; $j++) {
            if ($src[$name][$j] -notmatch "(?<![\w:`$])\`$(script:)?$($a.Name)\b") { continue }
            if ($j + 1 -lt $ds.Line) { foreach ($b in (Get-Assignments $src[$name][$j])) { if ($b.Name -eq $a.Name) { $last = $b } } }
            elseif ($j + 1 -gt $ds.Line) { $readAfter = $true }
          }
          if ($last -and -not (Test-Nullish $last.Rhs) -and $readAfter) {
            $f += [pscustomobject]@{ Parent = $name; Dot = $ds.Line; Child = $ds.Child; ChildLine = $i + 1; Name = $a.Name; Text = $clines[$i].Trim() }
          }
        }
      }
    }
  }
  $f
}
function Get-RuleC([hashtable]$src) {
  $f = @()
  foreach ($pname in $src.Keys) {
    foreach ($ds in (Get-DotSources $src $pname)) {
      if (-not $src.ContainsKey($ds.Child)) { continue }
      $childParams = @(Get-ParamNames $src[$ds.Child])
      if (-not $childParams.Count) { continue }
      $plines = $src[$pname]
      foreach ($n in $childParams) {
        if ($n -in $script:Skip) { continue }
        # the parent must have a write to NAME somewhere BEFORE the dot-source and a read somewhere AFTER it
        $wrote = $false; $readAfter = $false
        for ($j = 0; $j -lt $plines.Count; $j++) {
          if ($j + 1 -lt $ds.Line) { foreach ($b in (Get-Assignments $plines[$j])) { if ($b.Name -eq $n) { $wrote = $true } } }
          elseif ($j + 1 -gt $ds.Line) { if ($plines[$j] -match "(?<![\w:`$])\`$(script:)?$n\b") { $readAfter = $true } }
        }
        if ($wrote -and $readAfter) { $f += [pscustomobject]@{ Parent = $pname; Dot = $ds.Line; Child = $ds.Child; Name = $n } }
      }
    }
  }
  $f
}
function Get-Clobber([string]$dir) {
  $src = Get-SourceMap $dir
  @{ A = @(Get-RuleA $src); B = @(Get-RuleB $src); C = @(Get-RuleC $src) }
}

# 1) the tree is clean today
$r = Get-Clobber $Ps
$all = @($r.A) + @($r.B)
Check '1 no script-scope null reset after a real value (rule A: same file)' ($r.A.Count -eq 0) (($r.A | ForEach-Object { "$($_.File):$($_.Line) $($_.Name) -> $($_.Text)" }) -join ' | ')
Check '1 no script-scope null reset after a real value (rule B: dot-sourced child)' ($r.B.Count -eq 0) (($r.B | ForEach-Object { "$($_.Child):$($_.ChildLine) $($_.Name) <- $($_.Parent):$($_.Dot)" }) -join ' | ')
# rule C: a dot-sourced child's `param()` colliding with a parent value the parent passes through. Exactly
# ONE real hit today - gate.ps1's $PoolParallel, mitigated there by a re-assert from $PSBoundParameters.
# Two or none is a change that must be looked at, not silently accepted.
Check '1c rule C: exactly the gate.ps1 $PoolParallel param clobber and nothing else' ((@($r.C | Where-Object { $_.Parent -eq 'gate.ps1' -and $_.Name -eq 'PoolParallel' }).Count -eq 1) -and ($r.C.Count -eq 1)) ('C=' + (@($r.C | ForEach-Object { "$($_.Parent):$($_.Name)" }) -join ','))

# 2) the pre-init block in agentq.ps1 resets only the two exit codes (the concrete 2026-11-22 regression)
$aq = @(Get-Content (Join-Path $Ps 'bin\agentq.ps1'))
$idx = 0; for ($i = 0; $i -lt $aq.Count; $i++) { if ($aq[$i] -match '^Set-StrictMode') { $idx = $i + 1; break } }
$reset = @()
for ($i = $idx; $i -lt $aq.Count; $i++) {
  if ($aq[$i] -eq '') { break }
  if ($aq[$i] -match '^\$script:') { $reset += (Get-Assignments $aq[$i] | ForEach-Object Name) }
}
Check '2 the pre-init block covers exactly LandExit + DoctorExit' ((@($reset | Sort-Object -Unique) -join ',') -eq 'DoctorExit,LandExit') ("reset=" + ($reset -join ','))

# 3) the analyser catches both defects again when they are re-introduced (mutation check)
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('aqscope-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force (Join-Path $tmp 'bin') | Out-Null
$defect1 = '$script:Lane = $null' + "`n" + '$script:Priority = $null' + "`n" + '$script:Capacity = $null' + "`n" + '$script:CapacityGiven = $null'
$t = [IO.File]::ReadAllText((Join-Path $Ps 'bin\agentq.ps1'))
[IO.File]::WriteAllText((Join-Path $tmp 'bin\agentq.ps1'), $t.Replace('Set-StrictMode -Version 3', "Set-StrictMode -Version 3`n$defect1"))
$t2 = [IO.File]::ReadAllText((Join-Path $Ps 'bin\agentq-v2.ps1'))
[IO.File]::WriteAllText((Join-Path $tmp 'bin\agentq-v2.ps1'), $t2.Replace('$script:PickBad = $null', '$script:ReadOnly = $null' + "`n" + '$script:PickBad = $null'))
foreach ($n in 'agentq-probe.ps1', 'agentq-prune.ps1', 'agentq-doctor.ps1', 'agentq-jobobject-lib.ps1') {
  $p = Join-Path $Ps "bin\$n"; if (Test-Path $p) { Copy-Item $p (Join-Path $tmp "bin\$n") -Force }
}
$m = Get-Clobber $tmp
$names = @(@($m.A) + @($m.B) | ForEach-Object Name | Sort-Object -Unique)
Check '3 mutation: rule A catches the -Lane/-Priority/-Capacity pre-init' (@($m.A | Where-Object Name -in 'Lane', 'Priority', 'Capacity', 'CapacityGiven').Count -ge 4) ("names=" + ($names -join ','))
Check '3 mutation: rule B catches the v2 ReadOnly wipe' (@($m.B | Where-Object Name -eq 'ReadOnly').Count -ge 1) ("names=" + ($names -join ','))
# 4) the bare form (`$Lane = $null`, no `$script:` prefix) is the same slot in a `pwsh -File` script
$bare = $tmp + 'b'
New-Item -ItemType Directory -Force (Join-Path $bare 'bin') | Out-Null
[IO.File]::WriteAllText((Join-Path $bare 'bin\agentq.ps1'), $t.Replace('Set-StrictMode -Version 3', "Set-StrictMode -Version 3`n" + '$Lane = $null'))
$mb = Get-Clobber $bare
Check '4 mutation: rule A catches the bare form too' (@($mb.A | Where-Object Name -eq 'Lane').Count -ge 1) ("names=" + (@($mb.A | ForEach-Object Name | Sort-Object -Unique) -join ','))
# 5) rule C mutation: the REAL defect reproduced on a temp copy. The child IS the real
#    bin\agentq-suite-inputs.ps1 (its own param() block is the collision, RunPool/Skip/SuiteRepoKey/
#    PoolParallel) and the parent reproduces gate.ps1's exact shape - `. (Join-Path $repoRoot
#    'ps\bin\agentq-suite-inputs.ps1')` plus a later read of $PoolParallel.
$rc = Join-Path ([IO.Path]::GetTempPath()) ('aqrulec-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force (Join-Path $rc 'bin') | Out-Null
Copy-Item (Join-Path $Ps 'bin\agentq-suite-inputs.ps1') (Join-Path $rc 'bin\agentq-suite-inputs.ps1') -Force
$parentC = @('param([int]$PoolParallel = 4)', '. (Join-Path $repoRoot ''ps\bin\agentq-suite-inputs.ps1'')', '"pool=$PoolParallel"') -join "`n"
[IO.File]::WriteAllText((Join-Path $rc 'parent.ps1'), $parentC)
$mC = @(Get-RuleC (Get-SourceMap $rc))
Check '5 mutation: rule C catches a child param() clobbering the parent -PoolParallel' (@($mC | Where-Object { $_.Parent -eq 'parent.ps1' -and $_.Name -eq 'PoolParallel' }).Count -ge 1) ('C=' + (@($mC | ForEach-Object { "$($_.Parent):$($_.Name)" }) -join ','))
# 6) rule C negative control: the SAME child, a parent whose parameter does NOT collide -> ZERO findings.
$rc2 = Join-Path ([IO.Path]::GetTempPath()) ('aqrulec2-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force (Join-Path $rc2 'bin') | Out-Null
Copy-Item (Join-Path $Ps 'bin\agentq-suite-inputs.ps1') (Join-Path $rc2 'bin\agentq-suite-inputs.ps1') -Force
$parentC2 = @('param([string]$Workspace = ''agentq'')', '. (Join-Path $PSScriptRoot ''agentq-suite-inputs.ps1'')', '"ws=$Workspace"') -join "`n"
[IO.File]::WriteAllText((Join-Path $rc2 'parent.ps1'), $parentC2)
$mC2 = @(Get-RuleC (Get-SourceMap $rc2))
Check '6 mutation control: a non-colliding dot-source yields ZERO rule C findings' ($mC2.Count -eq 0) ('C=' + (@($mC2 | ForEach-Object { "$($_.Parent):$($_.Name)" }) -join ','))
Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $bare -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $rc -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force $rc2 -ErrorAction SilentlyContinue

if ($fail) { "FAILED $fail"; exit 1 } else { 'ALL OK'; exit 0 }
