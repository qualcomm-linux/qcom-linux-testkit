# Resume_Check

Verifies that the system resumed from suspend without errors. Suspending the
system and providing the wakeup source are out of scope: this test runs after
the system is back up and only inspects what the kernel recorded about the
cycle that already happened.

Run [Pre_Suspend_Check](../Pre_Suspend_Check/README.md) before the suspend to
get a baseline. Without it the test still runs, but it cannot tell a resume
from a reboot and falls back to the counter baselines given on the command
line.

## What it checks

| Check | Source |
|---|---|
| `boot_id` unchanged (no reboot) | state file |
| new successful cycle counted | `/sys/power/suspend_stats/success` |
| no new failed cycles | `/sys/power/suspend_stats/fail` |
| no new failures in any suspend/resume phase | `/sys/power/suspend_stats/failed_*` |
| suspend entered after Pre_Suspend_Check ran | kernel log |
| suspend exit logged | kernel log |
| no errors matching `ERROR_PATTERN` during the cycle | kernel log |
| cycle ran in `SUSPEND_MODE` (when set and not `default`) | `PM: suspend entry (<mode>)` in the kernel log, or the `/sys/power/mem_sleep` selection on kernels that do not log it |

The kernel log checks cover the records stamped after `DMESG_BOUNDARY` from
the state file. When the ring buffer has dropped some of them, a missing
suspend entry is reported as a warning rather than a failure, since the
dropped records may have held it. Without a boundary, the checks cover the
last cycle the kernel logged.

A baseline that the state file leaves empty is treated as unavailable: the
check that needs it is skipped with a warning and the result relies on the
other evidence. The command line baselines are used only without a state
file.

Every check is logged individually, but they are folded into a single result
written to `Resume_Check.res`:

- **FAIL** - any check failed, or an option or state file field is invalid
  (unknown option or mode, negative or non-numeric baseline, invalid
  `ERROR_PATTERN`)
- **PASS** - no check failed and the resume was confirmed by `suspend_stats`
  or the kernel log
- **SKIP** - no check failed, but neither `suspend_stats` nor the kernel log
  was available to confirm the resume

With `--suspend-mode MODE` the result is named `Resume_Check_MODE` instead,
e.g. `Resume_Check_deep`, so that the result shows which mode the cycle
used. The result of an earlier run is removed first.

## Usage

```sh
./run.sh [--state-file PATH] [--baseline-success N] [--baseline-fail N] \
         [--error-pattern REGEXP] [--suspend-mode default|s2idle|shallow|deep]
```

The same values can be passed through the `STATE_FILE`, `BASELINE_SUCCESS`,
`BASELINE_FAIL`, `ERROR_PATTERN` and `SUSPEND_MODE` environment variables;
command line options take precedence.

## Example LAVA job

See the [example job](../Pre_Suspend_Check/README.md#example-lava-job) in the
Pre_Suspend_Check README: it runs Pre_Suspend_Check, suspends the board,
has the lab wake it and then runs this test.
