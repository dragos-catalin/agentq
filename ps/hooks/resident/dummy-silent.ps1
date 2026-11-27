# A peer that ACCEPTS a connection and then never answers.
#
# It is the only fixture that can prove the CLIENT's own budget: a dead host refuses the connection (the
# client falls back at once, which is a different property) and a real host eventually replies, so neither
# can tell a client with a deadline from one that hangs until the peer gives up. verify-resident.ps1 case 5
# starts this, then requires the client to come back INSIDE its budget with the classic answer.
#
# The accept is bounded: an unbounded WaitForConnection would outlive a run that never connects and leave a
# holder on the pipe name for the rest of the session, which would make the NEXT run measure the wrong
# server (that failure mode is why the suite kills every holder of the name before it starts).
param(
    [Parameter(Mandatory)][string]$PipeName,
    [int]$HoldSec = 30,
    [int]$AcceptSec = 60
)
$ErrorActionPreference = 'Stop'
$s = [IO.Pipes.NamedPipeServerStream]::new(
    $PipeName, [IO.Pipes.PipeDirection]::InOut, 1,
    [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
try {
    if (-not $s.WaitForConnectionAsync().Wait([TimeSpan]::FromSeconds($AcceptSec))) { exit 3 }
    # Accepted, and deliberately silent: read nothing, write nothing, just hold the connection open.
    Start-Sleep -Seconds $HoldSec
} finally {
    $s.Dispose()
}
