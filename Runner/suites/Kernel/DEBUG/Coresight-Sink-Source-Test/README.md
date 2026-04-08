# Coresight-Sink-Source-Test

## Overview
The `Coresight-Sink-Source-Test` test iterates through all CoreSight sources and sinks to validate end‑to‑end trace path accessibility. It ensures trace data capture works correctly and that all sources are cleanly disabled after execution.

## Test Goals

- Verify that the CoreSight sink correctly switches to ETF mode.
- Validate STM trace data routing to ETF via Ftrace integration.
- Ensure sched_switch events are captured and stored in the ETF buffer.
- Confirm valid trace data generation by checking ETF output size.

## Prerequisites

- Coresight framework enabled in the kernel with `sysfs` and `debugfs` accessible
- Multiple Coresight sink and source devices should be present
- Coresight STM, ETM, ETF devices must be included
- Root priviledges

## Script Location

```
Runner/suites/Kernel/DEBUG/Coresight-Sink-Source-Test/run.sh
```

## Files

- `run.sh` - Main test script
- `Coresight-Sink-Source-Test.res` - Summary result file with PASS/FAIL
- `Coresight-Sink-Source-Test.log` - Full execution log.

## How it works
1. Parses input parameters, sources common utilities, gathers all CoreSight devices, and configures the ETR sink to memory output mode.
2. Loops over all valid CoreSight sinks and sources, optionally skipping remote ETMs and unsupported TPDM sources.
3. Resets all sources and sinks, enables one sink at a time, then enables each applicable source to form a complete trace path.
4. Reads trace data from each sink device and verifies successful data capture based on output file size.
5. Resets the system again and checks that all sources are properly disabled before reporting pass or fail status.

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-04-06 05:17:08 - ---------------------------Coresight-Sink-Source-Test Starting---------------------------
[INFO] 2026-04-06 05:17:08 - Starting iteration: 1
[INFO] 2026-04-06 05:17:08 - Sink Active:- tmc_etf0
[INFO] 2026-04-06 05:17:09 - Source: etm0 with trace captured of size 65536 bytes
[INFO] 2026-04-06 05:17:10 - Source: etm1 with trace captured of size 65536 bytes
[INFO] 2026-04-06 05:17:11 - Source: etm2 with trace captured of size 65536 bytes
.........
[INFO] 2026-04-06 05:20:15 - Source: tpdm7 with trace captured of size 96 bytes
[INFO] 2026-04-06 05:20:16 - Source: tpdm8 with trace captured of size 96 bytes
[INFO] 2026-04-06 05:20:17 - Source: tpdm9 with trace captured of size 80 bytes
[INFO] 2026-04-06 05:20:17 - PASS: coresight source/sink path test
[INFO] 2026-04-06 05:20:17 - ---------------------------Coresight-Sink-Source-Test Finished---------------------------
```

## Return Code

- `0` — All test cases passed
- `1` — One or more test cases failed

## Integration in CI

- Can be run standalone or via LAVA
- Result file `Coresight-Sink-Source-Test.res` will be parsed by `result_parse.sh`

## Notes

- Remote ETM sources and unsupported TPDM sources are conditionally skipped during testing.
- Trace validity is confirmed by checking a minimum output file size from each sink.

## License

SPDX-License-Identifier: BSD-3-Clause.
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.