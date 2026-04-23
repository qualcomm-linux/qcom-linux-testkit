# Reset-Random-Sinks-Base

## Overview

This script tests multiple Coresight sinks during a continuous loop. It discovers all available sinks, pairs them up, enables them simultaneously, and ensures that a reset operation safely and completely disables both sinks. A post-stress validation runs a live trace through the STM and ETM nodes to confirm the hardware sink is still functional and returns trace data.

## Test Goals

- Ensure that when two sinks are enabled simultaneously and a reset is triggered, all sinks transition back to a disabled state.
- Repeatedly perform sink enable and reset operations over multiple iterations to identify stability or intermittent reset issues.
- Confirm through sysfs that no sink remains enabled after a reset operation, indicating a successful reset.
- Verify that after extensive reset testing, trace data can still be successfully captured and read from a selected sink. 

## Prerequisites

- Kernel must be built with Coresight support.
- sysfs access to `/sys/bus/coresight/devices/stm0/`.
- Multiple Coresight sink devices (`tmc_et*`).
- Coresight STM and ETM device nodes for post-test data generation.
- Root privileges.

## Script Location

```
`Runner/suites/Kernel/DEBUG/Reset-Random-Sinks-Base/run.sh`
```

## Files

- `run.sh` - Main test script
- `Reset-Random-Sinks-Base.res` - Summary result file with PASS/FAIL
- `Reset-Random-Sinks-Base.log` - Full execution log (generated if logging is enabled)

## How It Works

1. Discovers standard coresight sink devices (excluding tmc_etf1)
2. Loops for a configured number of iterations (default 1000)
3. Iterates through all paired combinations of available sinks
4. Enables both sinks simultaneously, issues a global reset, and validates that neither remains active
5. Performs a final read verification of an active source via tmc_etf0/tmc_etf to confirm system trace flow functionality

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh

./run.sh [no. of iterations]
```

## Example Output
```
[INFO] 2026-04-06 07:27:48 - ---------------------------Reset-Random-Sinks-Base Starting---------------------------
[INFO] 2026-04-06 07:27:48 - Start run reset sinks for 1000 iterations with 3 available sinks
[INFO] 2026-04-06 07:27:48 - start run reset sinks in loop: 0
[INFO] 2026-04-06 07:27:48 - start run reset sinks in loop: 1
[INFO] 2026-04-06 07:27:48 - start run reset sinks in loop: 2
[INFO] 2026-04-06 07:27:48 - start run reset sinks in loop: 3
................
[INFO] 2026-04-06 07:28:28 - start run reset sinks in loop: 997
[INFO] 2026-04-06 07:28:28 - start run reset sinks in loop: 998
[INFO] 2026-04-06 07:28:28 - start run reset sinks in loop: 999
[INFO] 2026-04-06 07:28:28 - Starting post-stress validation...
[INFO] 2026-04-06 07:28:28 - Using sink: tmc_etf0 and source: etm0 for verification.
[INFO] 2026-04-06 07:28:29 - Post-stress read successful (size 65536 bytes).
[INFO] 2026-04-06 07:28:29 - -------------------Reset-Random-Sinks-Base Testcase Finished----------------------------
```

## Return Code

- `0` — All the sinks were enabled and reset successfully.
- `1` — One or more sink reset failed.

## Integration in CI

- Can be run standalone or via LAVA
- Result file `Reset-Random-Sinks-Base.res` will be parsed by `result_parse.sh`

## Notes

- The test enables sink pairs in nested loops to ensure wide range of coverage of sink combinations during reset testing.
- A final functional check reads trace output from a CoreSight Sink to ensure reset operations have not affected normal trace behavior.

## License

SPDX-License-Identifier: BSD-3-Clause
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.