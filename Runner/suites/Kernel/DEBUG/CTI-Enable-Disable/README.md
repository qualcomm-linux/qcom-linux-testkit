# Coresight CTI Enable/Disable Test

## Overview
This test validates the basic toggle functionality of the Coresight Cross Trigger Interface (CTI) drivers. It ensures that every CTI device exposed in sysfs can be turned on and off without errors.

## Test Goals

- Validate basic toggle functionality of Coresight CTI drivers.
- Ensure all sysfs-exposed CTI drivers can be enabled and disabled without errors.
- Verify that the device states are correctly reflected in sysfs after toggling.
- Ensure proper cleanup and reset of devices to a clean state after testing.

## Prerequisites

- Kernel must be built with Coresight CTI support. 
- `sysfs` access to `/sys/bus/coresight/devices/`.
- Root priviledges needed.

## Script Location

```
Runner/suites/Kernel/DEBUG/CTI-Enable-Disable/run.sh
```

## Files

- `run.sh` - Main test script
- `CTI-Enable-Disable.res` - Summary result file with PASS/FAIL
- `CTI-Enable-Disable.log` - Full execution log.

## How it works
1.  **Preparation**:
    *   Disables `stm0`, `tmc_etr0`, and `tmc_etf0` to ensure a clean state.
    *   Enables `tmc_etf0` (Embedded Trace FIFO) as a sink, as some CTI configurations may require an active sink.
2.  **Discovery**: Scans `/sys/bus/coresight/devices/` for any directory containing `cti`.
3.  **Iteration**: For each CTI device:
    *   **Enable**: Writes `1` to the `enable` file.
    *   **Verify**: Reads the `enable` file; expects `1`.
    *   **Disable**: Writes `0` to the `enable` file.
    *   **Verify**: Reads the `enable` file; expects `0`.
4.  **Cleanup**: Resets all devices to disabled state.

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-23 10:43:51 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-23 10:43:51 - -------------------Starting CTI-Enable-Disable Testcase----------------------------
[INFO] 2026-03-23 10:43:51 - Saving state and resetting Coresight devices...
[INFO] 2026-03-23 10:43:51 - Testing Device: cti_sys0
[PASS] 2026-03-23 10:43:51 - cti_sys0 Enabled Successfully
[PASS] 2026-03-23 10:43:51 - cti_sys0 Disabled Successfully
[PASS] 2026-03-23 10:43:51 - CTI Enable/Disable Test Completed Successfully
[INFO] 2026-03-23 10:43:51 - Restoring Coresight devices state...
[INFO] 2026-03-23 10:09:51 - -------------------CTI-Enable-Disable Testcase Finished----------------------------
```

## Return Code

- `0` — All CTI devices were toggled successfully
- `1` — One or more CTI devices failed to toggle

## Integration in CI

- Can be run standalone or via LAVA
- Result file `CTI-Enable-Disable.res` will be parsed by `result_parse.sh`

## Notes

- Some CTI cofigurations may require an active sink (like `tmc_etf0`) to function properly, which is handled in the preparation phase.
- Ensure no other trace/debug sessions are actively using the CTI devices before running this test.

## License

SPDX-License-Identifier: BSD-3-Clause.
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.