# Single Sink Reset Connected Base Test

## Overview
The `Single-Sink-Reset-Connected-Base` test case validates the robustness of CoreSight sinks when a reset occurs while trace sources are actively streaming data, specifically targeting STM/ETM writing into TMC sinks (ETR/ETF).

## Test Goals

- Validate correct sink reset behavior during active tracing.
- Ensure stress‑test sink and source reset stability under repeated cycles.
- Verify post‑reset sink functionality and data integrity.

## Prerequisites

- Coresight drivers must be loaded.
- STM and TMC devices must be present in `/sys/bus/coresight/devices`.
- Debugfs must be mounted to access tracing events if necessary.

## Script Location

```
Runner/suites/Kernel/DEBUG/Single-Sink-Reset-Connected-Base/run.sh
```

## Files

- `run.sh` - Main test script
- `Single-Sink-Reset-Connected-Base.res` - Summary result file with PASS/FAIL
- `Single-Sink-Reset-Connected-Base.log` - Full execution log.

## How it works
1. Initialize the environment and disable any existing hardware events or tracing.
2. Loop for a specified number of iterations (default 250):
    - Iterate through all available TMC sinks (excluding `tmc_etf1`).
    - Enable the sink and the STM source.
    - Wait for 1 second of active trace generation.
    - Trigger a global `reset_source_sink`.
    - Verify that the sink's `enable_sink` node successfully returned to 0.
3. After the loop, perform a functional check by enabling a sink and source for 5 seconds.
4. Read data from `/dev/tmc_etf0`.

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-26 06:57:16 - --------------------------------------------------
[INFO] 2026-03-26 06:57:16 - -----Single Sink Reset Connected Base-----
[INFO] 2026-03-26 06:57:17 - Running sink reset stress test for 250 iterations...
[INFO] 2026-03-26 06:57:17 - Sink reset running loop: 0 / 250
[INFO] 2026-03-26 06:57:18 - PASS: reset_source_sink successful for /sys/bus/coresight/devices/tmc_etf0
[INFO] 2026-03-26 06:57:19 - PASS: reset_source_sink successful for /sys/bus/coresight/devices/tmc_etr0
[INFO] 2026-03-26 06:57:20 - PASS: reset_source_sink successful for /sys/bus/coresight/devices/tmc_etr1
.........
[INFO] 2026-03-26 07:10:06 - Sink reset running loop: 249 / 250
[INFO] 2026-03-26 07:10:07 - PASS: reset_source_sink successful for /sys/bus/coresight/devices/tmc_etf0
[INFO] 2026-03-26 07:10:08 - PASS: reset_source_sink successful for /sys/bus/coresight/devices/tmc_etr0
[INFO] 2026-03-26 07:10:09 - PASS: reset_source_sink successful for /sys/bus/coresight/devices/tmc_etr1
[PASS] 2026-03-26 07:10:14 - Single-Sink-Reset-Connected-Base Passed
[INFO] 2026-03-26 07:10:14 - -------------------Single-Sink-Reset-Connected-Base Finished----------------------------
```

## Return Code

- `0` — The sink behaviour was correct
- `1` — One or more sinks failed to trace data

## Integration in CI

- Can be run standalone or via LAVA
- Result file `Single-Sink-Reset-Connected-Base.res` will be parsed by `result_parse.sh`

## Notes

- The test iterates multiple times (default 250 iterations) across all CoreSight ETR sinks.
- After stress testing it will perform a functional validation by enabling an ETF sink generating trace data and reading from the ETF node, and checking that meaningful data was captured.

## License

SPDX-License-Identifier: BSD-3-Clause.
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.