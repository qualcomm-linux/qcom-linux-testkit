# Ftrace-Dump-ETF-Base

## Overview
The `Ftrace-Dump-ETF-Base` test case validates STM trace data flow to an ETF sink through Ftrace. It ensures correct sink selection and verifies successful trace capture by reading ETF output.

## Test Goals

- Verify that the CoreSight sink correctly switches to ETF mode.
- Validate STM trace data routing to ETF via Ftrace integration.
- Ensure sched_switch events are captured and stored in the ETF buffer.
- Confirm valid trace data generation by checking ETF output size.

## Prerequisites

- Coresight framework enabled in the kernel
- Multiple Coresight sink devices should be present
- Coresight STM and ETM device nodes for post-test data generation

## Script Location

```
Runner/suites/Kernel/DEBUG/Ftrace-Dump-ETF-Base/run.sh
```

## Files

- `run.sh` - Main test script
- `Ftrace-Dump-ETF-Base.res` - Summary result file with PASS/FAIL
- `Ftrace-Dump-ETF-Base.log` - Full execution log.

## How it works
1. Mounts required filesystems, resets all CoreSight sources and sinks, and disables any existing tracing.
2. Enables the ETF sink and verifies that the sink switch to ETF is successful.
3. Connects the STM source to Ftrace and enables sched_switch events as the trace input.
4. Starts tracing, allows the system to run for a fixed duration, then stops tracing.
5. Reads trace data from the ETF device and verifies successful capture by checking the output size.

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-04-06 06:19:42 - ---------------------------Ftrace-Dump-ETF-Base Starting---------------------------
[INFO] 2026-04-06 06:19:42 - Using Source: stm0, Sink: tmc_etf0
[INFO] 2026-04-06 06:19:42 - PASS: sink switch to tmc_etf0 successful
[INFO] 2026-04-06 06:19:42 - Linking Ftrace to stm0...
[INFO] 2026-04-06 06:20:03 - Collected bin size: 65536 bytes
[INFO] 2026-04-06 06:20:03 - PASS: tmc_etf0 sink data through Ftrace verified
[INFO] 2026-04-06 06:20:03 - ---------------------------Ftrace-Dump-ETF-Base Finished---------------------------
```

## Return Code

- `0` — All stress test cases passed
- `1` — One or more stress test cases failed

## Integration in CI

- Can be run standalone or via LAVA
- Result file `Ftrace-Dump-ETF-Base.res` will be parsed by `result_parse.sh`

## Notes

- The test relies on Ftrace sched_switch events as the trace data source.
- The test will stop and flag a failure as soon as any sink remains enabled after reset, ensuring strict correctness.

## License

SPDX-License-Identifier: BSD-3-Clause.
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.