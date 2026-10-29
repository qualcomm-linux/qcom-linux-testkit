# TPDM-Enable-Disable Test

## Overview

This test acts as a stress test for the Coresight Trace Port Debug Module (TPDM) drivers. It repeatedly enables and disables all available TPDM sources to verify the stability and correctness of the toggling mechanism under repeated stress.

## Test Goals

- Validate the stability of the TPDM drivers under repeated enable/disable cycles.
- Ensure all TPDM sources can be successfully toggled with ETF/ETR sinks enabled without causing system hangs or crashes.
- Verify that sysfs states correctly reflect the enabled/disabled status across multiple rapid transitions.
- Ensure 100% success rate across 50 iterations for pass criteria.

## Prerequisites

- Kernel must be built with Coresight TPDM support.
- `sysfs` access to `/sys/bus/coresight/devices/`.
- Root privileges (to configure source enables).

### Optional sink behavior

ETF and ETR are independent subcases:

- If ETF is unavailable but ETR is usable, the ETF subcase is reported as `SKIP` and the ETR subcase is executed.
- If ETR is unavailable but ETF is usable, the ETR subcase is reported as `SKIP` and the ETF subcase is executed.
- If both ETF and ETR are unavailable, the test cannot run and reports `FAIL`.
- The availability of ETF or ETR is not mandatory for every target. A target-specific requirement for ETF or ETR must be defined separately if required by that target.

## Script Location

Runner/suites/Kernel/DEBUG/TPDM-Enable-Disable/run.sh


## Files

- `run.sh` - Main test script
- `TPDM-Enable-Disable.res` - Summary result file with PASS/FAIL
- `TPDM-Enable-Disable.log` - Full execution log (generated if logging is enabled)

## How It Works

1. **Discovery**: Scans `/sys/bus/coresight/devices/` for all available TPDM devices (e.g., `tpdm*`).
2. **Setup**: Resets all Coresight devices to ensure a clean state.
3. **Loop (50 Iterations)**:
   - **Enable**: Attempts to enable each discovered TPDM device.
   - **Verify**: Confirms the device successfully transitioned to the enabled state.
   - **Disable**: Attempts to disable each TPDM device.
   - **Verify**: Confirms the device successfully transitioned to the disabled state.
4. **Teardown**: Ensures all devices are left in a disabled, clean state.

## Usage

Run the script directly via the framework:

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-10-13 03:01:05 - -----------------------------------------------------------------------------------------
[INFO] 2026-10-13 03:01:05 - -------------------Starting TPDM-Enable-Disable Testcase----------------------------
[INFO] 2026-10-13 03:01:06 - Running with ETF sink
[INFO] 2026-10-13 03:01:14 - Iteration: 0 - PASS
[INFO] 2026-10-13 03:01:20 - Iteration: 1 - PASS
[INFO] 2026-10-13 03:01:28 - Iteration: 2 - PASS
[INFO] 2026-10-13 03:01:35 - Iteration: 3 - PASS
[INFO] 2026-10-13 03:01:43 - Iteration: 4 - PASS

[INFO] 2026-10-13 03:07:12 - Iteration: 49 - PASS
[INFO] 2026-10-13 03:07:19 - Iteration: 50 - PASS

[INFO] 2026-10-13 03:07:19 - Running with ETR sink
[INFO] 2026-10-13 03:07:26 - Iteration: 0 - PASS
[INFO] 2026-10-13 03:07:34 - Iteration: 1 - PASS
[INFO] 2026-10-13 03:07:42 - Iteration: 2 - PASS
[INFO] 2026-10-13 03:07:50 - Iteration: 3 - PASS
[INFO] 2026-10-13 03:07:57 - Iteration: 4 - PASS

[INFO] 2026-10-13 03:13:35 - Iteration: 49 - PASS
[INFO] 2026-10-13 03:13:43 - Iteration: 50 - PASS
[PASS] 2026-10-13 03:13:43 - -------------enable/disable TPDMs Test PASS-------------
[INFO] 2026-10-13 03:13:43 - -------------------TPDM-Enable-Disable Testcase Finished----------------------------
```

## Return Code

- `0` — All 50 iterations successfully enabled and disabled the TPDM sources
- `1` — One or more iterations failed to toggle a source or verify its state

## Integration in CI

- Can be run standalone or via LAVA

- Result file TPDM-Enable-Disable.res will be parsed by result_parse.sh

## Notes

- The test performs exactly 50 iterations specifically to catch intermittent concurrency bugs or resource leaks in the driver's enable/disable path.

- A failure in any single iteration immediately flags the overall test run as a failure.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear

(c) Qualcomm Technologies, Inc. and/or its subsidiaries.