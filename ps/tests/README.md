# PowerShell test suites

Each `test-*` file in this folder is one suite. `run-all.ps1` runs the suites against this checkout, not against an
installed copy. A suite runs only if it is in the table at the top of `run-all.ps1`.

## Run

```powershell
pwsh -NoProfile -File ps/tests/run-all.ps1                    # every suite, one after another
pwsh -NoProfile -File ps/tests/run-all.ps1 -List              # print the suite names
pwsh -NoProfile -File ps/tests/run-all.ps1 -Only 'args,slo'   # only these suites
pwsh -NoProfile -File ps/tests/run-all.ps1 -Skip jobs -LogDir .copilot-tmp/logs -TimeoutMin 25
```

A full run takes a long time, hours on a busy machine. Use `-Only` while you work.

| Switch or variable     | Meaning                                                                                     |
| ---------------------- | ------------------------------------------------------------------------------------------- |
| `-Only a,b`            | Run only these suites. Names are exact and not case-sensitive.                              |
| `-Skip a,b`            | Leave these suites out.                                                                     |
| `-List`                | Print the suite names and exit 0.                                                           |
| `-LogDir <dir>`        | Write the full output of every suite to `<dir>\<name>.log`, pass or fail.                   |
| `-TimeoutMin n`        | Stop a suite and everything it started after `n` minutes and count it as failed. 0 = never. |
| `AGENTQ_TEST_SKIP=a,b` | Same as `-Skip`. Lets a caller skip suites without changing its command line.               |

Pass several names as one comma-separated value. A name that is not in `-List` is an error.

## Output

- One line per suite: `<name> exit=<code> pass=<n> fail=<n> sec=<n>`, then its `FAIL` lines.
- `TIMEOUT after n min` under a suite that was stopped.
- `SKIP <name> (<reason>)`. The reason is `-Skip`, `AGENTQ_TEST_SKIP` or `missing <file>`.
- `TOTAL sec=<n> suites=<n> failed=<n> skipped=<n>`.
- Last line: `ALL SUITES PASS`, `FAILED: <names>` or `NO SUITES RAN`.

Exit code: 0 when every suite passed, 1 when a suite failed or no suite ran, 2 for a bad argument.

## Rules

- A run without arguments must stay as it is: every suite, one after another, in this process. The installer runs it
  that way and refuses to install when the exit code is not 0. Do not make the default run parallel.
- New fields go at the end of a line. Other tools may match the start of the summary lines.
- A new suite prints `PASS <text>` or `FAIL <text>` per check and exits non-zero when a check failed.
- A suite keeps its state in a temporary folder. It must not read or change the real coordination store.
- A suite must not depend on how busy the machine is. `run-all.ps1` sets `AGENTQ_NO_ADMISSION=1` for every suite,
  so a lease or a build in a suite is never held back by the real load probe. A suite that tests admission clears
  the variable and fakes the probe with `AGENTQ_PROBE_FAKE`. Set the variable yourself when you run one suite
  file directly on a busy machine.
- A suite waits for a state, not for a number of seconds. A helper process that must outlive a check runs until a
  stop file exists; a fixed sleep ends too early on a slow machine.

## What the suites need

PowerShell 7, Git, Node (the version in `.nvmrc`), Python 3 and ripgrep (`rg`) on the path. Windows PowerShell 5.1 is
used when it is there: the editor starts the hooks with it.

## CI

The `ps` job in `.github/workflows/ci.yml` runs every suite on a hosted Windows runner, with `-LogDir` and
`-TimeoutMin 25`. The logs are uploaded as the `ps-logs` artifact and kept for 7 days, also when the job fails. The
hosted image has no ripgrep, so the job installs a pinned release and checks its SHA-256 first.

CI skips no suite today. The job has an `AGENTQ_TEST_SKIP` value for suites that cannot run on a hosted runner. Add a
name there only with the failing line from a real run, and list it here with its reason.

What the job enforces:

- A pull request shows the result of the `ps` check.
- A push to `main` runs the job after the push. A red job does not undo or block that push.
- To make a red job block a change, the repository owner must require the `ps` check in a branch protection rule,
  or the tool that lands changes must run the suites as a gate before it pushes.
