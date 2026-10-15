# Single-Sink-Reset-Base

## Overview

Thie `Single-Sink-Reset-Base` test validates CoreSight sink reset behavior while STM/ETM sources are actively generating trace data. It ensures all sinks properly reset and trace capture remains functional after repeated reset operations.

## Test Goals

- Ensure CoreSight sinks can be safely reset while STM or ETM sources are actively generating trace data.
- Repeatedly perform sink enable, source enable, and reset operations across numerous iterations to expose timing or stability issues.
- Verify through sysfs that no CoreSight sink remains enabled after a reset, even when the reset occurs during active tracing.
- Validate that trace data can still be captured and read from an ETF sink after extensive sink reset operations.

## Prerequisites

- Kernel must be built with Coresight support.
- sysfs access to `/sys/bus/coresight/devices/stm0/`.
- Multiple Coresight sink devices (`tmc_et*`).
- Coresight STM and ETM device nodes for post-test data generation.
- Root privileges.

## Script Location

```
`Runner/suites/Kernel/DEBUG/Single-Sink-Reset-Base/run.sh`
```

## Files

- `run.sh` - Main test script
- `Single-Sink-Reset-Base.res` - Summary result file with PASS/FAIL
- `Single-Sink-Reset-Base.log` - Full execution log (generated if logging is enabled)

## How It Works

1. Initialize the CoreSight hardware by disabling all sources and sinks globally.
2. **Stress Loop (default 250 iterations)**:
   - For every available CoreSight sink (excluding `tmc_etf1`):
     - Enable the target sink.
     - Enable the active source (STM).
     - Trigger `reset_source_sink` while data is flowing.
     - Assert that the sink registers correctly as disabled (`enable_sink` == 0).
3. **Validation Phase**:
   - Re-enable `tmc_etf0` (sink) and `etm0` (source).
   - Dump standard character data directly from the ETF devnode.
   - Fail if the dump yields less than 64 bytes of output, indicating a damaged trace path.

## Usage

Run the script directly. An optional numeric argument specifies loop iterations (default 250):

```bash
./run.sh 

./run.sh [no. of iterations]
```

## Example Output
```
[INFO] 2026-04-06 09:29:06 - ------------------------Single-Sink-Reset-Base Starting------------------------
[INFO] 2026-04-06 09:29:07 - Starting sink reset test for 250 iterations...
[INFO] 2026-04-06 09:29:07 - Stress test running loop: 0
[INFO] 2026-04-06 09:29:10 - Stress test running loop: 1
[INFO] 2026-04-06 09:29:13 - Stress test running loop: 2
[INFO] 2026-04-06 09:29:16 - Stress test running loop: 3
..............
[INFO] 2026-04-06 09:41:47 - Stress test running loop: 247
[INFO] 2026-04-06 09:41:50 - Stress test running loop: 248
[INFO] 2026-04-06 09:41:53 - Stress test running loop: 249
[INFO] 2026-04-06 09:41:57 - Starting reset_sink functionality check by reading from tmc_etf0 using source etm0.
[PASS] 2026-04-06 09:42:02 - PASS: sink reset during active source
[INFO] 2026-04-06 09:42:02 - ------------------------Single-Sink-Reset-Base Finished------------------------
```

## Return Code

- `0` — All the sinks were enabled and reset successfully.
- `1` — One or more sink reset failed.

## Integration in CI

- Can be run standalone or via LAVA
- Result file `Single-Sink-Reset-Base.res` will be parsed by `result_parse.sh`

## Notes

- Each sink is tested individually while the trace source is active to isolate reset behavior per sink.
- A final ETF read check confirms that reset stress testing does not corrupt or disable normal trace data output.

## License

SPDX-License-Identifier: BSD-3-Clause
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.