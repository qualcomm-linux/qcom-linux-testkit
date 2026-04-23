# Reset-All-Sinks-Base Test

## Overview
The `Reset-All-Sinks-Base` test case validates the correctness and robustness of CoreSight reset logic when multiple trace sinks are enabled simultaneously.

## Test Goals

- Validate correct reset behavior with multiple active sinks.
- Ensure stress‑test reset robustness across multiple sink combinations.
- Verify post‑reset trace functionality.

## Prerequisites

- Coresight framework enabled in the kernel
- Multiple Coresight sink devices should be present
- Coresight STM and ETM device nodes for post-test data generation

## Script Location

```
Runner/suites/Kernel/DEBUG/Reset-All-Sinks-Base/run.sh
```

## Files

- `run.sh` - Main test script
- `Reset-All-Sinks-Base.res` - Summary result file with PASS/FAIL
- `Reset-All-Sinks-Base.log` - Full execution log.

## How it works
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
[INFO] 2026-03-26 09:44:07 - ----------------------------------------------------
[INFO] 2026-03-26 09:44:07 - -----Reset All Sinks Base Starting-----
[INFO] 2026-03-26 09:44:08 - Discovered Sinks (3): tmc_etf0 tmc_etr0 tmc_etr1
[INFO] 2026-03-26 09:44:08 - Discovered STM: stm0
[INFO] 2026-03-26 09:44:08 - Discovered ETM: etm0
[INFO] 2026-03-26 09:44:08 - starting reset sinks stress test for 1000 iterations...
[INFO] 2026-03-26 09:44:08 - stress test running loop: 0
[INFO] 2026-03-26 09:44:08 - stress test running loop: 1
[INFO] 2026-03-26 09:44:08 - stress test running loop: 2
.........
[INFO] 2026-03-26 09:44:57 - stress test running loop: 998
[INFO] 2026-03-26 09:44:57 - stress test running loop: 999
[INFO] 2026-03-26 09:44:57 - Starting post-stress trace capture verification...
[INFO] 2026-03-26 09:44:57 - enabled dynamic STM source
[INFO] 2026-03-26 09:44:57 - enabled dynamic ETM source
[PASS] 2026-03-26 09:44:58 - -----Reset All Sinks Base PASS-----
[INFO] 2026-03-26 09:44:58 - -------------------Reset-All-Sinks-Base Testcase Finished----------------------------
```

## Return Code

- `0` — All stress test cases passed
- `1` — One or more stress test cases failed

## Integration in CI

- Can be run standalone or via LAVA
- Result file `Reset-All-Sinks-Base.res` will be parsed by `result_parse.sh`

## Notes

- the test with 1000 default iterations heavily exercises reset paths to catch intermittent or timing‑sensitive failures..
- The test will stop and flag a failure as soon as any sink remains enabled after reset, ensuring strict correctness.

## License

SPDX-License-Identifier: BSD-3-Clause.
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.