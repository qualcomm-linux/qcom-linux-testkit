# STM Source Enable/Disable Stress Test

## Overview
This test validates the stability of the STM (System Trace Macrocell) driver by repeatedly enabling and disabling the source in a loop.

## Test Goals
- Validate the stability and reliability of the STM driver under stress.
- Ensure the STM source can be repeatedly enabled and disabled without causing kernel panics or hangs.
- Verify that sysfs state correctly reflects the enabled/disabled status across multiple rapid transitions.
- Confirm proper initialization and teardown of STP policy directories and global tracing events.

## Prerequisites
- Kernel must be built with Coresight STM support (e.g., `CONFIG_CORESIGHT_STM`).
- sysfs access to `/sys/bus/coresight/devices/`.
- Access to configfs for STP policy directory creation.
- Root privileges (to configure sysfs nodes, reset devices, and create policies).

## Script Location
`Runner/suites/Kernel/DEBUG/STM-Source-Enable-Disable/run.sh`

## Files
- `run.sh` - Main test script
- `STM-Source-Enable-Disable.res` - Summary result file with PASS/FAIL
- `STM-Source-Enable-Disable.log` - Full execution log (generated if logging is enabled)

## How It Works
1. **Setup:**
   - Creates STP policy directories.
   - Resets all Coresight source/sink devices.
   - Disables hardware events and clears global tracing events.
2. **Loop (50 Iterations):**
   - Resets source/sink.
   - Enables `tmc_etf` sink.
   - Enables `stm` source -> Checks if `enable_source` is 1.
   - Disables `stm` source -> Checks if `enable_source` is 0.
3. **Teardown:**
   - Resets all devices back to their default, disabled state.

## Example Output
```
[INFO] 2026-03-16 09:51:32 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-16 09:51:32 - -------------------Starting STM-Source-Enable-Disable Testcase----------------------------
[INFO] 2026-03-16 09:51:32 - Setting up STP policy...
[INFO] 2026-03-16 09:51:32 - Using existing STP policy: p_basic
[INFO] 2026-03-16 09:51:32 - Initial cleanup...
[INFO] 2026-03-16 09:51:32 - Starting 50 iteration loop...
[PASS] 2026-03-16 09:51:33 - STM source enable/disable loop passed (50 iterations)
```

## Return Code

- `0` — All 50 iterations successfully enabled and disabled the STM source
- `1` — One or more iterations failed to toggle the source or verify its state

## Integration in CI

- Can be run standalone or via LAVA
- Result file STM-Source-Enable-Disable.res will be parsed by result_parse.sh

## Notes

- The test performs 50 iterations specifically to catch intermittent concurrency bugs or race conditions in the driver's enable/disable path.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.