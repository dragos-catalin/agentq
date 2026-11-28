# Focused acceptance check for the resident hook (run after ANY change to hookc4/resident-server).
#   powershell -NoProfile -File verify-resident.ps1 [-N 5] [-BindMs 30000] [-CheckSource]
#       [-SourceRoot <resident dir|repo root>] [-AllowUnprovenSource]
# Prints ONE verdict block and writes verify-resident.out.txt. Asserts, in this order:
#   0. CORPUS parity: every guard path returns the same DECISION (and stderr) in both paths, with
#      fellBack=False on every call - a byte-identical answer that fell back proves nothing;
#   1. the fallback really re-runs hook-pre.ps1 with the SAME payload (byte-identical when down);
#   2. deny is a deny in both paths: exit code equal AND a permissionDecision on both sides;
#   3. the deadline is the CLIENT's budget (<= budget + slack), not the peer's patience.
#   4. the fallback with the server DOWN is bounded in TIME too, not only byte-identical (2026-11-28);
#   5. a run that cannot confirm the server it started is the one answering REFUSES loudly (non-zero),
#      instead of printing a verdict a reader would take for a client regression (2026-11-28).
#      The refusal also names the surviving holders of the pipe; until 2026-11-28 that line printed a
#      CommandNotFoundException instead, because the helper it called (`Procs`) did not exist here.
#   6. the concurrency case demands (a) the host advertises a pool of at least two instances and
#      (b) at least two callers are served without a spawn. Never against the burst, and not against the
#      pool count either: both those shapes report a loaded machine as a regression (measured 2026-11-28:
#      the same healthy copy served 2/6 at 21.7 busy cores and 5/6 twenty minutes later, against a pool
#      of 4). A pool of one serves 1/6 - and 2/6 on a second run - so the CLAIM is what catches it and
#      `served >= 2` only corroborates that a claimed pool is used in parallel.
#      A call that FELL BACK no longer counts as a parity difference: the client's own notice is 71
#      characters, over the 40-character window, so it used to turn one busy instance into two reds.
#
# BEFORE all of the above a FRESHNESS gate runs (2026-11-28). It hashes THIS script and the copy in the
# source root and REFUSES (non-zero, one line, no host spawned and no process killed) when they differ -
# otherwise a stale install would publish a verdict about a revision nobody has. Finding no source copy
# at all is a refusal too, unless -AllowUnprovenSource says to run anyway (loudly). -CheckSource runs only
# this gate, so a suite (or an installer) can assert freshness without starting a host.
#
# Parity is SEMANTIC on purpose. The resident path runs the guard under PowerShell 7 (the server is a
# pwsh process) whereas the classic path spawns powershell.exe 5.1, and ConvertTo-Json serializes the
# same deny differently per engine (key order, \u0027 escaping). The harness PARSES that JSON, so the
# decision - not the byte layout - is the contract. Byte equality is still required where the client
# must reproduce the classic command: with the server down (it literally runs it).
[CmdletBinding()]
param([int]$N = 5, [int]$TimeoutMs = 10000, [int]$DeadlineMs = 3000, [int]$BindMs = 30000,
    [string]$SourceRoot = '', [switch]$AllowUnprovenSource, [switch]$CheckSource)
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$out  = Join-Path $here 'verify-resident.out.txt'
$L = [System.Collections.Generic.List[string]]::new()
function W($s) { $L.Add([string]$s) }

# ---- FRESHNESS: the live copy must BE the source copy, or nothing measured here means anything ------
# This script is installed into ~/.copilot/hooks/resident and normally run FROM there, while the source
# of truth is the repo copy beside it. Until 2026-11-28 it measured whatever the LIVE directory happened
# to contain, so a stale install could print a green verdict about a revision nobody has - the exact
# "configured != installed != the code that runs" trap this whole file exists to catch elsewhere. The
# gate is FAIL CLOSED: hashes differ -> refuse; no source copy found at all -> refuse as well, unless the
# caller passes -AllowUnprovenSource (one loud line, then it continues).
#
# The client is resolved by its INSTALLED name (`hookc.exe`) first and the build product name
# (`hookc4.exe`) second, and a client older than hookc4.c earns a WARNING line in the verdict (2026-11-28:
# asking only for the build name made the check abort with no verdict on every normally installed
# machine, and the installed binary predates its source by two days).
#
# It runs BEFORE the first Stop-Matched (which kills hosts) and the first Start-Process (which spawns
# one), so a refusal can never leave a half-started run behind. It costs two Get-FileHash calls plus a
# few Test-Path probes - no node, no network, no git - and reports its own cost under -CheckSource.
#
# The source copy is looked for in this order (first hit wins); a candidate may be the resident directory
# itself OR a repo root that contains one:
#   1. -SourceRoot                    (explicit)
#   2. $env:AGENTQ_REPO_ROOT          (a repo root; an installer may export it)
#   3. a .source-root marker beside the live files (first non-blank, non-# line is a path)
#   4. <dir>\ps\hooks\resident for the caller's directory and each of its parents - the repo an agent is
#      standing in when it runs this
# The LIVE directory is deliberately NOT a candidate: comparing the live copy with itself would always
# pass and would prove nothing.
# Hashing directly with .NET rather than Get-FileHash is not a micro-optimisation: the cmdlet's FIRST
# call in a fresh process costs ~110 ms just loading its assembly (measured 2026-11-28), which alone
# blows the gate's ~50 ms budget. SHA256::HashData is 9 ms cold, and the Create()/ComputeHash fallback
# covers Windows PowerShell 5.1, where HashData does not exist. Probing the overload once and caching
# the answer keeps the fast path free of a per-call try/catch.
function Get-FileSha256([string]$p) {
    if (-not [IO.File]::Exists($p)) { return $null }
    try { $bytes = [IO.File]::ReadAllBytes($p) } catch { return $null }
    try {
        if ($null -eq $script:hashDataOk) {
            try { [void][Security.Cryptography.SHA256]::HashData([byte[]]@()); $script:hashDataOk = $true } catch { $script:hashDataOk = $false }
        }
        if ($script:hashDataOk) {
            $hash = [Security.Cryptography.SHA256]::HashData($bytes)
        } else {
            $alg = [Security.Cryptography.SHA256]::Create()
            try { $hash = $alg.ComputeHash($bytes) } finally { $alg.Dispose() }
        }
        return ([BitConverter]::ToString($hash) -replace '-', '').ToLowerInvariant()
    } catch { return $null }
}
# One candidate -> a resident directory, tried as itself and as a repo root. Returns the resolved
# directory or $null. Probed LAZILY (first hit wins) because the parent-chain walk is the expensive step
# and this gate has a ~50 ms budget.
function Test-ResidentSourceCandidate([string]$c, [string]$Leaf) {
    $base = [IO.Path]::GetFullPath([IO.Path]::Combine($PWD.Path, $c))
    if ([IO.File]::Exists([IO.Path]::Combine($base, $Leaf))) { return $base }
    $sub = [IO.Path]::Combine($base, 'ps', 'hooks', 'resident')
    if ([IO.File]::Exists([IO.Path]::Combine($sub, $Leaf))) { return $sub }
    return $null
}
function Resolve-ResidentSourceDir([string]$Explicit, [string]$Leaf) {
    if ($Explicit) { $hit = Test-ResidentSourceCandidate $Explicit $Leaf; if ($hit) { return $hit } }
    if ($env:AGENTQ_REPO_ROOT) { $hit = Test-ResidentSourceCandidate $env:AGENTQ_REPO_ROOT $Leaf; if ($hit) { return $hit } }
    $marker = [IO.Path]::Combine($PSScriptRoot, '.source-root')
    if ([IO.File]::Exists($marker)) {
        $m = Get-Content -LiteralPath $marker -EA SilentlyContinue |
            ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') } | Select-Object -First 1
        if ($m) { $hit = Test-ResidentSourceCandidate $m $Leaf; if ($hit) { return $hit } }
    }
    $d = $PWD.Path
    for ($i = 0; $i -lt 8 -and $d; $i++) {
        $hit = Test-ResidentSourceCandidate $d $Leaf
        if ($hit) { return $hit }
        $parent = [IO.Path]::GetDirectoryName($d)
        if (-not $parent -or $parent -eq $d) { break }
        $d = $parent
    }
    return $null
}
# Returns an object and never throws or exits, so the CALLER decides and a suite can exercise every branch
# without the process dying. Message is the SAME single line a refusal prints.
function Test-ResidentFreshness([string]$Explicit, [string]$LivePath) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $leaf = if ($LivePath) { [IO.Path]::GetFileName($LivePath) } else { '' }
    $liveHash = if ($leaf) { Get-FileSha256 $LivePath } else { $null }
    if (-not $liveHash) {
        return [pscustomobject]@{ Ok=$false; Unproven=$true; LiveHash=$null; SourceHash=$null; SourceDir=$null; Ms=$sw.ElapsedMilliseconds
            Message = "verify-resident: CANNOT PROVE the live copy is current - cannot read a live copy at '$LivePath' (run this as a FILE, not dot-sourced). Pass -AllowUnprovenSource to run anyway." }
    }
    $srcDir = Resolve-ResidentSourceDir -Explicit $Explicit -Leaf $leaf
    if (-not $srcDir) {
        return [pscustomobject]@{ Ok=$false; Unproven=$true; LiveHash=$liveHash; SourceHash=$null; SourceDir=$null; Ms=$sw.ElapsedMilliseconds
            Message = "verify-resident: CANNOT PROVE the live copy is current - no source copy of $leaf found (looked at -SourceRoot, `$env:AGENTQ_REPO_ROOT, a .source-root marker beside the live files, and <dir>\ps\hooks\resident up from $($PWD.Path)). Pass -AllowUnprovenSource to run anyway." }
    }
    $srcPath = [IO.Path]::Combine($srcDir, $leaf)
    $srcHash = Get-FileSha256 $srcPath
    if ($liveHash -ne $srcHash) {
        return [pscustomobject]@{ Ok=$false; Unproven=$false; LiveHash=$liveHash; SourceHash=$srcHash; SourceDir=$srcDir; Ms=$sw.ElapsedMilliseconds
            Message = "verify-resident: STALE live copy - refusing to measure: live $leaf sha256=$liveHash  source $srcPath sha256=$srcHash" }
    }
    return [pscustomobject]@{ Ok=$true; Unproven=$false; LiveHash=$liveHash; SourceHash=$srcHash; SourceDir=$srcDir; Ms=$sw.ElapsedMilliseconds
        Message = "verify-resident: live copy matches its source ($srcDir) sha256=$liveHash" }
}
$fresh = Test-ResidentFreshness -Explicit $SourceRoot -LivePath $PSCommandPath
if (-not $fresh.Ok) {
    if ($fresh.Unproven -and $AllowUnprovenSource) {
        Write-Host ("verify-resident: WARNING - " + $fresh.Message + " (continuing because -AllowUnprovenSource was passed; gate took $($fresh.Ms) ms)")
    } else {
        Write-Host $fresh.Message
        exit 9
    }
}
if ($CheckSource) {
    # Only when the gate actually proved freshness: the -AllowUnprovenSource branch above already printed
    # its one loud line and must not gain a second one.
    if ($fresh.Ok) {
        # A second, warm call: the first one pays for type loading and the JIT of this file's own
        # functions, which is a one-off in a fresh process and not the cost of the CHECK. Reporting both
        # keeps the budget claim honest instead of hiding the warm-up behind a single number (measured
        # 2026-11-28: ~45-55 ms cold vs 1-2 ms warm).
        $warm = Test-ResidentFreshness -Explicit $SourceRoot -LivePath $PSCommandPath
        Write-Host ("{0} (source gate took {1} ms cold / {2} ms warm)" -f $fresh.Message, $fresh.Ms, $warm.Ms)
    }
    exit 0
}

# The corpus budget is deliberately GENEROUS. It measures the DECISION, not latency, and this machine's
# load swings by ~10x: the same guard was measured at 350 ms one moment and 3315 ms the next (server.log,
# 2026-11-25 - read as `total 3.402 ms` because N0 renders thousands with '.' in ro-RO). A tight budget
# there tests the machine, not the client, and a fallback would mask a real decision difference. The
# DEADLINE property is tested on its own, against a peer that is known to stay silent (case 5).
$env:HOOKC_TIMEOUT_MS = "$TimeoutMs"
$hooks  = Join-Path $env:USERPROFILE '.copilot\hooks'
$guard  = Join-Path $hooks 'hook-pre.ps1'
# `$client` is resolved further down, once the pipe name is known: it may legitimately carry either name.
# 2026-11-28: this pointed at server4.ps1, which no longer exists (the host lives in
# resident-server.ps1 since it moved into the repo), so the suite could not run at all and the
# pool change went in untested. A path here IS the test's precondition: assert it.
$server = Join-Path $here 'resident-server.ps1'
if (-not (Test-Path $server)) { throw "missing $server - the host lives in this directory" }
# The DEFAULT pipe name, not a private test one: the installed form is a BARE "command": "<...>\hookc.exe"
# with no arguments, so the client defaults to BOTH hook-pre.ps1 and this pipe - the test can only be
# faithful if it uses the same name. A foreign server on this pipe cannot silently answer the run: the
# log pid must equal the process this script started, or the script refuses to measure.
$pipe   = 'codai-hookc'

# 2026-11-28: this used to be the single line `$client = Join-Path $here 'hookc4.exe'`, the BUILD product
# name, while everything else in this subsystem calls the client `hookc.exe`: it is the bare command the
# harness runs (hookc4.c's own header, README.md, install.ps1's map comment) and it is the file
# resident-ensure.ps1 refuses to start a server without. On a normally installed machine there is no
# `hookc4.exe`, so the acceptance check aborted with "missing ... hookc4.exe - compile it first" and
# printed NO verdict at all - measured on the installed copy 2026-11-28: exit 1, empty stdout, 6.9 s,
# thrown before the first process kill (which is also how we know the freshness gate is ordered right).
# Take the installed name first, keep the build name as a fallback for a dev tree, and fail with a
# message that names BOTH and the builder.
$client = @((Join-Path $here 'hookc.exe'), (Join-Path $here 'hookc4.exe')) |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

# The FRESHNESS gate above covers the SCRIPT; nothing covers the BINARY, and the two drift separately.
# Measured 2026-11-28: the installed hookc.exe was built 2026-11-25 02:06 while hookc4.c was modified
# 2026-11-27, so a run would exercise an older client than the source it is being judged against - and
# only the source is reproducible (`build-client.ps1 -Check` compiles to a temp name and byte-compares).
# This is a WARNING, not a refusal: the installed binary IS what the harness runs, and refusing would
# make the check unrunnable until someone rebuilds. It is a fact the verdict has to carry, though,
# because a green verdict about the wrong binary is exactly the trap this file exists to catch.
$csrc = Join-Path $here 'hookc4.c'
if ($client -and (Test-Path -LiteralPath $csrc)) {
    $cTime = (Get-Item -LiteralPath $client).LastWriteTimeUtc
    $sTime = (Get-Item -LiteralPath $csrc).LastWriteTimeUtc
    if ($cTime -lt $sTime) {
        $cWarn = "verify-resident: WARNING - $(Split-Path -Leaf $client) predates hookc4.c " +
            "(client $($cTime.ToString('yyyy-MM-dd HH:mm'))Z, source $($sTime.ToString('yyyy-MM-dd HH:mm'))Z); " +
            "the verdict below describes THAT binary. Rebuild with build-client.ps1 (or -Check to prove a " +
            "rebuild is byte-identical)."
        Write-Host $cWarn
        W "WARNING $cWarn"
    }
}

if (-not $client) {
    throw ("missing the resident client - looked for hookc.exe and hookc4.exe in $here. " +
        "Build it with build-client.ps1 (needs gcc on PATH, e.g. mingw-w64).")
}

# The name is deliberate. **`Kill` is a built-in ALIAS for Stop-Process, and aliases OUTRANK
# functions**, so `function Kill` was never called: `Kill '*x*'` ran `Stop-Process '*x*'`, bound the
# string to -InputObject and threw "Cannot convert ... to type System.Diagnostics.Process". Nothing was
# ever killed, so the "server down" case was answered by a LIVE server and the deadline case came back
# in 163 ms - two silent false positives. VERIFIED on PS 5.1 and 7 (`Get-Alias Kill`). Exactly the same
# trap as a function named `H` (shadowed by Get-History). No helper in this file may share a name with
# a default alias (kill, ps, sc, where, gc, cat, rm, ii, sleep, ...). Same reason `Sv` is gone: it
# collided with Set-Variable and silently lost the `-Scope 2` the helper existed for.
function Stop-Matched($pat) {
    # CIM, not Get-Process: Get-Process exposes no CommandLine, so an earlier filter matched nothing.
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -EA SilentlyContinue |
        Where-Object { $_.CommandLine -like $pat }) |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -EA SilentlyContinue }
}

# Holders of a pipe name, for the refusal below. This helper did not exist until 2026-11-28 even
# though the refusal called it, so the line whose whole job is to make a refusal diagnosable threw
# instead - the reader got a PowerShell error where the holder list should be. Same CIM source as
# Stop-Matched: Get-Process exposes NO CommandLine in pwsh 7, so a Get-Process filter matches nothing.
function Procs($pat) {
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" -EA SilentlyContinue |
        Where-Object { "$($_.CommandLine)" -like $pat })
}

function Call([string]$exe, [string[]]$pre, [string]$json, [string]$tag) {
    $so = Join-Path $here "v.so.$tag"; $se = Join-Path $here "v.se.$tag"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $json | & $exe @pre 1> $so 2> $se
    $rc = $LASTEXITCODE; $sw.Stop()
    # Read as UTF-8 explicitly: the resident path writes UTF-8, the classic path writes the console
    # codepage, and reading with the default codepage turned one Romanian character into two.
    [pscustomobject]@{ rc=$rc; ms=[int]$sw.ElapsedMilliseconds; out=((Get-Content $so -Raw -Encoding utf8 -EA SilentlyContinue) ?? '').Trim(); err=((Get-Content $se -Raw -Encoding utf8 -EA SilentlyContinue) ?? '').Trim() }
}
function VsCode($tool, $jsonIn) { @{ hook_event_name='PreToolUse'; session_id='verify'; tool_name=$tool; tool_input=($jsonIn | ConvertFrom-Json); cwd='E:\gh\codai' } | ConvertTo-Json -Compress -Depth 8 }
function Deny($r) { ($r.out -match '"permissionDecision"\s*:\s*"deny"') -or ($r.rc -eq 2) }

# Same shape, but tool_input given as a hashtable so paths need no hand-escaped JSON.
function VsCodeObj($tool, $ht) { @{ hook_event_name='PreToolUse'; session_id='verify'; tool_name=$tool; tool_input=$ht; cwd='E:\gh\codai' } | ConvertTo-Json -Compress -Depth 8 }

# The contract is the DECISION, not the byte layout: the decision + its reason, whitespace-normalized.
function SemRaw([string]$txt) {
    $t = if ($txt) { $txt.Trim() } else { '' }
    # 'ALLOW|' with the separator even when there is no reason: the corpus asserts `want|*`, so a bare
    # 'ALLOW' would have failed every allow case (measured 2026-11-25 - classicUnchanged was False while
    # every allow decision was in fact identical).
    if (-not $t) { return 'ALLOW|' }
    try { $o = $t | ConvertFrom-Json } catch { return ('UNPARSEABLE:' + $t.Substring(0, [Math]::Min(60, $t.Length))) }
    $pd = $o.hookSpecificOutput.permissionDecision; if (-not $pd) { $pd = $o.permissionDecision }
    $rs = $o.hookSpecificOutput.permissionDecisionReason; if (-not $rs) { $rs = $o.permissionDecisionReason }
    $rs = ("$rs" -replace '\s+', ' ').Trim()
    '{0}|{1}' -f $pd, $rs
}
# Same, with non-ASCII folded: powershell.exe 5.1 writes the console codepage where pwsh 7 writes UTF-8,
# so identical Romanian reasons arrive as different bytes ("agen?ii" vs "agenții"). Folding compares the
# decision and the ASCII content; the loop reports when that is the ONLY difference.
# Non-ASCII is REMOVED and '?' is removed too: powershell.exe 5.1 writes a Romanian char the console
# codepage cannot carry as a literal '?' (ASCII!) where pwsh 7 writes the real char, so replacing
# non-ASCII with '?' left 'agen?ii' vs 'agen??ii'. Neither an unrepresentable char nor a '?' is ever
# decision-bearing, so dropping both is the honest projection; the loop still REPORTS encode-only
# differences (raw SemRaw differs) so they can never hide a real one silently.
function Sem([string]$txt) { (((SemRaw $txt) -replace '[^\x20-\x7E]', '') -replace '\?', '') -replace '\s+', ' ' }
# stderr/raw prose is NOT JSON, so it must never go through SemRaw (that returns a 60-character
# truncated UNPARSEABLE window - two truncations of different lengths never match). Fold the WHOLE
# text instead: drop non-ASCII and '?' (powershell.exe 5.1 writes the console codepage, pwsh 7 writes
# UTF-8, and a Romanian letter that cannot be represented comes back as '?' or as a bare ASCII letter).
function FoldText([string]$txt) { if (-not $txt) { return '' }; ((("$txt" -replace '[^\x20-\x7E]', '') -replace '\?', '') -replace '\s+', ' ').Trim() }
# The DECISION-BEARING content, which is encoding-independent by construction: the rule id, its tier
# and every target path. Two paths that differ by one character FAIL here, so the prose tolerance
# below can never hide a substantive difference - it applies only to wording that is not in a key.
function Keys([string]$txt) {
    $f = ((("$txt" -replace '[^\x20-\x7E]', '') -replace '\?', ''))
    $k = @()
    $k += [regex]::Matches($f, 'codai\.[a-z0-9.\-]+') | ForEach-Object { $_.Value }
    $k += [regex]::Matches($f, '(tier|nivel)\s+\d+')    | ForEach-Object { $_.Value }
    $k += [regex]::Matches($f, '[A-Za-z]:\\[^\s"\'',]+') | ForEach-Object { $_.Value }
    ($k | Sort-Object -Unique) -join ' '
}
# Size of the ONE differing region: trim the common prefix and the common suffix (from the END, so the
# two strings need not have the same length - a mangled Romanian letter renders as '?', as a bare ASCII
# letter or as nothing at all in the 5.1 console codepage, so an encoding skew shifts the length by 1-2).
# 999 is returned when the surviving region is absurdly large, i.e. treat it as a real difference.
function DiffSize([string]$a, [string]$b) {
    $i = 0; while ($i -lt $a.Length -and $i -lt $b.Length -and $a[$i] -eq $b[$i]) { $i++ }
    $j = 0; while ($j -lt ($a.Length - $i) -and $j -lt ($b.Length - $i) -and $a[$a.Length - 1 - $j] -eq $b[$b.Length - 1 - $j]) { $j++ }
    $d = ([Math]::Max($a.Length, $b.Length)) - $i - $j
    if ($d -gt 40) { return 999 }
    return $d
}
function ErrNorm([string]$e) { if (-not $e) { return '' }; ("$e" -replace '\s+', ' ').Trim() }

$allowJson = VsCode 'run_in_terminal' '{"command":"git status"}'
$denyJson  = VsCode 'run_in_terminal' '{"command":"git reset --hard"}'

# One entry per guard path that matters. `want` is the decision the CLASSIC path produces TODAY
# (measured, not assumed): if that ever changes, this check fails loudly instead of comparing the
# resident path against a moving baseline. `want=$null` = "whatever classic says, resident must match".
$corpus = @(
    @{ n = 'allow read_file';     j = (VsCode    'read_file' '{"path":"e:\\gh\\codai\\README.md"}'); want = 'ALLOW' }
    @{ n = 'allow git status';    j = (VsCode    'run_in_terminal' '{"command":"git status"}');      want = 'ALLOW' }
    @{ n = 'deny git reset';      j = $denyJson;                                                     want = 'deny' }
    @{ n = 'deny force push';     j = (VsCode    'run_in_terminal' '{"command":"git push --force"}'); want = 'deny' }
    @{ n = 'trust surface write'; j = (VsCodeObj 'create_file' @{ path = (Join-Path $env:USERPROFILE '.copilot\hooks\zz-verify-probe.txt'); content = 'probe' }); want = $null }
    @{ n = 'rules surface write'; j = (VsCodeObj 'create_file' @{ path = (Join-Path $env:USERPROFILE '.claude\rules\zz-verify-probe.md'); content = 'probe' }); want = $null }
    @{ n = 'ask marker';          j = (VsCodeObj 'askQuestions' @{ question = 'probe' });             want = $null }
    # The CLI dialect writes NO stdout: the reason goes to stderr and the DECISION is the exit code,
    # so this entry pins wantRc instead of a stdout decision (and pins it hard, because losing the CLI
    # exit 2 is exactly the hole the 'file' host mode opened).
    @{ n = 'cli deny git reset';  j = '{"toolName":"run_in_terminal","toolArgs":"{\"command\":\"git reset --hard\"}"}'; wantRc = 2 }
)

# A stale server on the same pipe silently answers the whole run - measured 2026-11-25: an old
# -HostMode file server made the CLI case report exit 0 and the encoding differ, which read as two
# "failures" in a client that was correct. So: kill every holder of the pipe NAME, clear the log,
# start ours, and require the log's own pid to be the process we started.
Stop-Matched '*resident-server.ps1*'; Stop-Matched '*dummy-silent*'; Stop-Matched "*$pipe*"
Start-Sleep -Milliseconds 300
Remove-Item (Join-Path $here 'server.log') -EA SilentlyContinue
$srv = Start-Process pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',$server,'-GuardName','hook-pre.ps1','-PipeName',$pipe,'-HostMode','subst','-MaxRequests','200') -WindowStyle Hidden -PassThru
# Wait for BOTH the pipe AND the log line that names OUR process. Waiting on the pipe alone was half of
# the 2026-11-28 defect: the pipe exists as soon as the listener opens, but the pid/mode line is written
# a moment later, so under load the identity check read pid=0 and the run declared a foreign server while
# measuring its own. The budget is a PARAMETER, not a fixed 16 x 500 ms = 8 s (too tight the same day a
# bare pwsh start measured p90 7 s).
$bindTries = [Math]::Ceiling($BindMs / 500)
$up = $false; $srvPid = 0; $srvMode = '?'; $poolN = 0
for ($i = 0; $i -lt $bindTries; $i++) {
    Start-Sleep -Milliseconds 500
    $up = [bool]([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -like "*$pipe*" })
    $listen = Get-Content (Join-Path $here 'server.log') -EA SilentlyContinue | Where-Object { $_ -match 'listening on' } | Select-Object -First 1
    if ($listen -match 'mode=(\S+)') { $srvMode = $Matches[1] }
    if ($listen -match 'pid=(\d+)') { $srvPid = [int]$Matches[1] }
    # The host prints its own pool size (`instances=N`); case 3e asserts against that claim, so it is
    # parsed here, from the same line, and 0 means the host never said.
    if ($listen -match 'instances=(\d+)') { $poolN = [int]$Matches[1] }
    if ($up -and ($srvPid -eq $srv.Id) -and ($srvMode -eq 'v6-subst')) { break }
}
$srvOk = $up -and ($srvPid -eq $srv.Id) -and ($srvMode -eq 'v6-subst')
W ("server up: {0}  pipe-bound={1}  our pid {2} vs log pid {3}  mode={4}  instances={5}  -> identity {6}" -f $up, $up, $srv.Id, $srvPid, $srvMode, $poolN, $(if ($srvOk) { 'OK' } else { 'WRONG SERVER / WRONG MODE' }))
if (-not $srvOk) {
    W '  refusing to measure: the answers would come from a process this run did not start.'
    # Null-safe: a process whose CommandLine cannot be read must not turn the refusal into a second error.
    W ("  holders of the pipe name: {0}" -f ((Procs "*$pipe*" | ForEach-Object { $hc = "$($_.CommandLine)"; "$($_.ProcessId):$($hc.Substring([Math]::Max(0, $hc.Length - 70)))" }) -join ' | '))
    # The refusal must be REAL. Until 2026-11-28 it printed this and measured anyway, so a bind that lost
    # the race produced a 4/12 "verdict" that read as a client regression. Write the log, then stop.
    $L | Set-Content -LiteralPath $out -Encoding utf8
    Get-Content $out
    throw ('server identity not confirmed within {0} ms: log pid {1}, expected {2}, mode {3}' -f $BindMs, $srvPid, $srv.Id, $srvMode)
}

# 1. parity + fellBack, on a deny and an allow
# 1. corpus parity + fellBack on every call + the classic decision is still what we recorded
$parity = $true; $noFallback = $true; $wantOk = $true; $bad = @(); $enc = 0; $encCases = @()
foreach ($c in $corpus) {
    $cl = Call 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$guard) $c.j "cl.$($c.n)"
    $rs = Call $client @($guard, $pipe) $c.j "rs.$($c.n)"
    $fell = $rs.err -match 'falling back'
    if ($fell) { $noFallback = $false }
    $sCl = Sem $cl.out; $sRs = Sem $rs.out
    # The PARSED fields, never the raw JSON: the two engines emit the same object with a different key
    # ORDER (permissionDecision before/after hookEventName), which is not a decision difference.
    $dCl = ($sCl -split '\|')[0]; $dRs = ($sRs -split '\|')[0]
    $rCl = ($sCl -split '\|', 2)[1]; $rRs = ($sRs -split '\|', 2)[1]
    # A FALLBACK IS THE CLIENT EXPLAINING ITSELF, NOT A DECISION. The notice it writes is 71 characters
    # ("hookc: server busy past the connect budget (win32 121) - falling back"), which is over DiffSize's
    # 40-character window, so its sentinel 999 came back and ONE busy instance produced TWO reds
    # (`parity` AND `pipeUsed`) plus a line that contradicts itself: `classic ALLOW resident ALLOW
    # same=False`. Measured 2026-11-28 on a machine at 20.3/32 busy cores. The notice is therefore
    # excluded from the comparison, and `pipeUsed` stays the single owner of "the resident path was not
    # used" - drop this exclusion and a loaded machine reports a decision difference that does not exist.
    $eCl = FoldText $cl.err
    $eRs = FoldText (("$($rs.err)" -replace '(?m)^hookc:.*falling back.*$', ''))
    # Decision-bearing keys, taken from the DECODED reason and from stderr (not from JSON text: the raw
    # form carries \u0027 escapes that make the token sets differ for no reason).
    $kCl = Keys ($rCl + ' ' + $eCl); $kRs = Keys ($rRs + ' ' + $eRs)
    $keysOk = ($kCl -eq $kRs)
    $spanOut = DiffSize $rCl $rRs; $spanErr = DiffSize $eCl $eRs
    # Contract: same exit code, same parsed decision, same rule/tier/path tokens. The prose may differ
    # ONLY by how a Romanian letter is rendered; that is reported (encOnly) with its span size, so a
    # wording change larger than a couple of characters still fails.
    $encOnly = ($keysOk -and (($rCl -ne $rRs) -or ($eCl -ne $eRs)) -and ($spanOut -le 4) -and ($spanErr -le 4))
    $same = ($cl.rc -eq $rs.rc) -and ($dCl -eq $dRs) -and $keysOk -and ((($rCl -eq $rRs) -and ($eCl -eq $eRs)) -or $encOnly)
    if ($encOnly) { $enc++; $encCases += "$($c.n) (span $spanOut/$spanErr)" }
    if (-not $same) { $parity = $false; $bad += $c.n }
    if ($c.want -and ($sCl -notlike "$($c.want)|*")) { $wantOk = $false }
    if ($c.wantRc -and ($cl.rc -ne $c.wantRc)) { $wantOk = $false }
    W ("{0,-19} classic {1}{2,-9} resident {3}{4,-9} same={5} fell={6}" -f `
            $c.n, $(if ($cl.rc -eq 2) { 'CLI ' } else { '' }), (($sCl -split '\|')[0]), $(if ($rs.rc -eq 2) { 'CLI ' } else { '' }), (($sRs -split '\|')[0]), $same, $fell)
    if (-not $same) {
        W ("  rc {0}/{1}  decision {2}/{3}  span {4} (out) {5} (err){6}" -f $cl.rc, $rs.rc, $dCl, $dRs, $spanOut, $spanErr, $(if ($fell) { '  [client fallback notice excluded]' } else { '' }))
        W "  keys classic : $($kCl.Substring(0,[Math]::Min(160,$kCl.Length)))"
        W "  keys resident: $($kRs.Substring(0,[Math]::Min(160,$kRs.Length)))"
        W "  reason classic : $($rCl.Substring(0,[Math]::Min(160,$rCl.Length)))"
        W "  reason resident: $($rRs.Substring(0,[Math]::Min(160,$rRs.Length)))"
    }
}
W ("corpus: {0} cases, mismatch: {1}{2}" -f $corpus.Count, $(if ($bad.Count) { $bad -join ', ' } else { 'none' }), $(if ($enc) { "  encoding-only (decision identical, non-ASCII bytes differ): $($encCases -join ', ')" } else { '' }))

# 2. deny is a deny in both paths (the property that actually protects)
$cd = Call 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$guard) $denyJson 'd.cl'
$rd = Call $client @($guard, $pipe) $denyJson 'd.rs'
$denyOk = (Deny $cd) -and (Deny $rd) -and ($cd.rc -eq $rd.rc)
W ("deny both ways: {0} (classic {1} / resident {2})" -f $denyOk, (Deny $cd), (Deny $rd))

# 3. timing, only meaningful when the pipe was really used
#    Fallbacks are COUNTED: a resident call that fell back ran the classic path, so averaging it in
#    would report a speed-up that did not happen. The ratio is only about calls that used the pipe.
$cm = @(); $rm = @(); $rfell = 0
for ($i = 0; $i -lt $N; $i++) { $cm += (Call 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$guard) $allowJson 't.cl').ms }
for ($i = 0; $i -lt $N; $i++) { $r = Call $client @($guard, $pipe) $allowJson 't.rs'; $rm += $r.ms; if ($r.err -match 'falling back') { $rfell++ } }
$ca = [int](($cm | Measure-Object -Average).Average); $ra = [int](($rm | Measure-Object -Average).Average)
W ("timing ({0} calls): classic avg {1} ms | resident avg {2} ms | {3:N2}x  (resident fell back {4}/{0})" -f $N, $ca, $ra, ($ca / [Math]::Max(1,$ra)), $rfell)

# 3b. THE INSTALLED FORM: a bare client invocation, no argv at all. The installer writes exactly
# `"command": "<...>\hookc.exe"`, so a client that needed an argument would produce NO decision for
# every tool call - both guards skipped - and nothing else in this file would notice, because every
# other case passes the guard explicitly. Compared against the same call WITH argv over the same pipe.
$rbare = Call $client @()            $denyJson 'bare.rs'
$rexp  = Call $client @($guard,$pipe) $denyJson 'bare.exp'
$bareOk = ($rbare.rc -eq $rexp.rc) -and ((Sem $rbare.out) -eq (Sem $rexp.out)) -and $rbare.out -and -not ($rbare.err -match 'falling back')
W ("installed form (no argv): exit={0} out={1}B fell={2} | with argv: exit={3} out={4}B | same={5}" -f `
    $rbare.rc, $rbare.out.Length, [bool]($rbare.err -match 'falling back'), $rexp.rc, $rexp.out.Length, $bareOk)
if (-not $bareOk) { W "  bare stderr: $($rbare.err.Substring(0,[Math]::Min(200,$rbare.err.Length)))" }

# 3c. EMPTY payload. This is the shape a SKIPPED guard has, so the two paths must agree on it: if the
# harness ever delivers the payload some other way than stdin (or stdin arrives empty), the client must
# not invent a decision the classic path would not have produced.
$rempty = Call $client @($guard,$pipe) '' 'empty.rs'
$cempty = Call 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$guard) '' 'empty.cl'
$emptyOk = ($rempty.rc -eq $cempty.rc) -and ((Sem $rempty.out) -eq (Sem $cempty.out))
W ("empty payload: classic exit={0} out={1} B | resident exit={2} out={3} B | same={4}" -f `
    $cempty.rc, $cempty.out.Length, $rempty.rc, $rempty.out.Length, $emptyOk)

# 3d. RUDE CLIENT: connect, send a valid framed request, close WITHOUT reading the reply. The server's
# write then fails with "Pipe is broken." - and that is not hypothetical: measured 2026-11-25 it KILLED
# the server (the following WaitForConnection threw and the loop exited), so ONE slow tool call would
# have taken the resident path down for the rest of the session while every later call silently paid the
# spawn again. The fix must be proven on the failing path, not just asserted: the same PROCESS must keep
# serving, and its log must show the recovery line.
$logPath = Join-Path $here 'server.log'
# The DETECTOR moved with the design. The old host dropped the whole pipe on a broken write and logged
# "recreating the pipe"; the pooled host instead disconnects and re-arms that ONE instance, so that
# string no longer exists and this case would fail on a HEALTHY server (measured 2026-11-27: `recovery
# lines 0->0` while the server served its next request 1 ms later). What the case exists to protect is
# the GUARANTEE - one rude caller must not take the resident path down for the session - so it is now
# asserted from observables that survive any recovery mechanism, and the PREMISE is asserted too
# (a server that never saw a broken write would make the whole case vacuous).
$reqLine = { param($p) @(Get-Content $p -EA SilentlyContinue | Where-Object { $_ -match '\breq \d+ ' }).Count }
$brkLine = { param($p) @(Get-Content $p -EA SilentlyContinue | Where-Object { $_ -match 'write failed' }).Count }
$rd1 = Call $client @($guard,$pipe) $allowJson 'rude.pre'
$reqBefore = & $reqLine $logPath
$brkBefore = & $brkLine $logPath
$srvPidBefore = $srv.Id
try {
    $cp = [IO.Pipes.NamedPipeClientStream]::new('.', $pipe, [IO.Pipes.PipeDirection]::InOut)
    $cp.Connect(2000)
    $pl = [Text.Encoding]::UTF8.GetBytes('{"hook_event_name":"PreToolUse","tool_name":"read_file","tool_input":{"path":"x"}}')
    $hdr = [BitConverter]::GetBytes([int](-($pl.Length + 1)))
    $cp.Write($hdr, 0, 4); $cp.Write($pl, 0, $pl.Length); $cp.Flush()
    $cp.Dispose()          # the reply now has nowhere to go - this is the failure being tested
    W 'rude client: sent a request and vanished without reading the reply'
} catch { W "rude client: setup failed: $($_.Exception.Message)" }
Start-Sleep -Milliseconds 800
$brkAfter = & $brkLine $logPath
$rd2 = Call $client @($guard,$pipe) $allowJson 'rude.post'
$reqAfter = & $reqLine $logPath
$alive = [bool](Get-Process -Id $srvPidBefore -EA SilentlyContinue)
# The FIRST rude call is the one that vanishes mid-request, so IT must be served resident - that is what
# exercises the recovery path. The follow-up call is allowed to fall back on a loaded box (the connect
# budget is 900 ms) and that is reported rather than disqualifying: the facts this case owns are that the
# server is alive, that it counted the broken writes, and that the answer still matches. Requiring both
# calls to be resident made a red out of a busy instance (2026-11-28), which `pipeUsed` already reports.
$rudeOk = (-not ($rd1.err -match 'falling back')) -and `
          ((Sem $rd1.out) -eq (Sem $rd2.out)) -and $alive -and `
          ($brkAfter -gt $brkBefore) -and ($reqAfter -ge ($reqBefore + 2))
W ("rude client: before fell={0} | broken writes {1}->{2} | req lines {3}->{4} | after fell={5} same={6} | server pid {7} alive={8}" -f `
    [bool]($rd1.err -match 'falling back'), $brkBefore, $brkAfter, $reqBefore, $reqAfter, [bool]($rd2.err -match 'falling back'), ((Sem $rd1.out) -eq (Sem $rd2.out)), $srvPidBefore, $alive)

# 3e. CONCURRENCY - why a POOL of pipe instances exists at all. One instance serves one request at a
# time, so simultaneous tool calls (a batch resolved in parallel, several chats on one machine) made the
# later callers see ERROR_PIPE_BUSY and pay the spawn instead. The host states its own pool size in the
# log (`instances=N`), and `HOOKC_POOL=1` can ask for the broken shape on purpose.
#
# The assertion is anchored on measurements taken on this machine, not on the burst and not on the pool
# count (rewritten 2026-11-28). Until then it demanded 5 of 6 served, which cannot see the difference it
# exists for: at a burst of 6 against a pool of 4, TWO callers MUST queue, and a client waits only 900 ms
# for a busy instance (hookc4.c: min(budget, 900)), so a loaded box goes red against the machine.
# A pool-anchored version (`served >= instances`) was tried next and failed the SAME way: the healthy
# host served 2/6 at 21.7 busy cores, then 5/6 twenty minutes later on an unchanged copy. What the case
# must protect is: (a) the host advertises a pool at all, because ONE instance IS the regression - the
# server's own comment records 16 % of calls falling back, and (b) the pool is real, i.e. more than one
# caller is served without a spawn. Measured on this machine, four runs:
#   HOOKC_POOL=1 -> served 1/6 and 2/6  <-- a single instance CAN serve a second caller once the first is
#                                           done, so `served >= 2` alone is NOT the discriminator
#   pool as advertised (4) -> 5/6, 5/6, and 2/6 on the loaded run
# The CLAIM is what catches the regression; `served >= 2` only corroborates that the pool it claims is
# really used in parallel. Neither depends on how slow the box is. Callers beyond the pool may queue and
# fall back - that is the queue doing its job, not a defect.
$cc = 6
$ccIn = Join-Path $here 'v.conc.in'
Set-Content -LiteralPath $ccIn -Value $allowJson -NoNewline -Encoding utf8
$ccProc = @()
for ($i = 0; $i -lt $cc; $i++) {
    $ccProc += Start-Process -FilePath $client -ArgumentList @($guard, $pipe) -RedirectStandardInput $ccIn `
                -RedirectStandardOutput (Join-Path $here "v.conc.$i.out") -RedirectStandardError (Join-Path $here "v.conc.$i.err") -NoNewWindow -PassThru
}
$ccProc | Wait-Process -Timeout 90 -EA SilentlyContinue
$concServed = 0; $concFall = 0
for ($i = 0; $i -lt $cc; $i++) {
    if ((Get-Content (Join-Path $here "v.conc.$i.err") -Raw -Encoding utf8 -EA SilentlyContinue) -match 'falling back') { $concFall++ } else { $concServed++ }
}
$concOk = ($poolN -ge 2) -and ($concServed -ge 2)
W ("concurrent burst ({0} at once): served by the resident {1}/{0}, fell back {2} | pool instances={3} (claim must be >= 2, and at least TWO callers served without a spawn)" -f $cc, $concServed, $concFall, $poolN)

# 4. server down -> classic answer with the SAME payload (byte-for-byte stdout)
Stop-Matched '*resident-server.ps1*'; Start-Sleep -Milliseconds 400
$cd = Call 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$guard) $denyJson 'dn.cl'
$rd = Call $client @($guard, $pipe) $denyJson 'dn.rs'
# Timing bound: this case used to compare ONLY exit code and stdout, so a client that spent 61.5-80 s
# falling back (win32 121 = ERROR_SEM_TIMEOUT - every instance of the peer busy) passed invisibly
# (2026-11-28 defect). The client's own budget is $TimeoutMs, so a fallback must stay inside it plus the
# same slack the silent case allows.
$downOk = ($cd.rc -eq $rd.rc) -and ($cd.out -eq $rd.out) -and ($rd.ms -le ($TimeoutMs + 4000))
W ("server down: classic exit={0} out={1}B | client exit={2} out={3}B {4}ms (bound {5}ms) | same={6}" -f $cd.rc, $cd.out.Length, $rd.rc, $rd.out.Length, $rd.ms, ($TimeoutMs + 4000), $downOk)

# 5. server silent -> the CLIENT's budget, not the peer's patience (the only case with a tight budget)
$env:HOOKC_TIMEOUT_MS = "$DeadlineMs"
Start-Process pwsh -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $here 'dummy-silent.ps1'),'-PipeName',$pipe,'-HoldSec','30') -WindowStyle Hidden | Out-Null
# Same budget as the main host ($bindTries): an 8 s window here fails the SAME way - the dummy had not
# bound yet, the client fell back to classic in milliseconds and deadlineOk read False, i.e. a machine
# artefact reported as a client defect.
for ($i = 0; $i -lt $bindTries; $i++) { Start-Sleep -Milliseconds 500; if ([IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -like "*$pipe*" }) { break } }
$cd = Call 'powershell.exe' @('-NoProfile','-ExecutionPolicy','Bypass','-File',$guard) $denyJson 'sl.cl'
$rd = Call $client @($guard, $pipe) $denyJson 'sl.rs'
$deadlineOk = ($cd.rc -eq $rd.rc) -and ($cd.out -eq $rd.out) -and ($rd.ms -le ($DeadlineMs + 4000)) -and ($rd.ms -ge ($DeadlineMs - 1500))
W ("server silent: client exit={0} {1}ms (budget {2}ms, must be {3}-{4}ms) | classic exit={5} | same={6}" -f `
    $rd.rc, $rd.ms, $DeadlineMs, ($DeadlineMs - 1500), ($DeadlineMs + 4000), $cd.rc, ($cd.rc -eq $rd.rc))
$env:HOOKC_TIMEOUT_MS = "$TimeoutMs"
Stop-Matched '*dummy-silent*'

W ''
W ("VERDICT corpus={0}/{1} parity={2} classicUnchanged={3} pipeUsed={4} deny={5} fallback={6} deadline={7} encOnly={8} installedForm={9} emptyPayload={10} rudeClient={11} concurrent={12}" -f `
    ($corpus.Count - $bad.Count), $corpus.Count, $parity, $wantOk, $noFallback, $denyOk, $downOk, $deadlineOk, $enc, $bareOk, $emptyOk, $rudeOk, $concOk)
W ("  ALL PASS: {0}" -f ($parity -and $wantOk -and $noFallback -and $denyOk -and $downOk -and $deadlineOk -and $bareOk -and $emptyOk -and $rudeOk -and $concOk))
$L | Set-Content -LiteralPath $out -Encoding utf8
Get-Content $out
