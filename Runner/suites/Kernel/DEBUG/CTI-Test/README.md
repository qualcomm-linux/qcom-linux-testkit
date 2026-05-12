# CTI Test

## Overview
This test verifies the functionality of the Coresight CTI (Cross Trigger Interface) driver. It ensures that hardware triggers can be successfully mapped (attached) to CTI channels and subsequently unmapped (detached).

## Test Goals

- Validate the core functionality of Coresight CTI driver.
- Ensure hardware triggers can be correctly attached to CTI channels.
- Validate compatibility across both Modern and Legacy sysfs interfaces.
- Prevent device low-power states during testing to ensure register accessibility.

## Prerequisites

- Kernel must be built with Coresight CTI support. 
- `sysfs` access to `sys/module/lpm_levels/parameters/sleep_disabled`.
- `sysfs` access to `/sys/bus/coresight/devices/`.
- Root priviledges needed.

## Script Location

```
Runner/suites/Kernel/DEBUG/CTI-Test/run.sh
```

## Files

- `run.sh` - Main test script
- `CTI-Test.res` - Summary result file with PASS/FAIL
- `CTI-Test.log` - Full execution log.

## How it works
1.  **Sleep Disable**: Temporarily prevents the device from entering low-power modes (`/sys/module/lpm_levels/parameters/sleep_disabled`) to ensure CTI registers are accessible.
2.  **Discovery**: Finds all CTI devices in `/sys/bus/coresight/devices/`.
3.  **Mode Detection**: Checks for the existence of `enable` sysfs node to determine if the driver uses the Modern or Legacy sysfs interface.
4.  **Configuration Parsing**: Reads the `devid` (Modern) or `show_info` (Legacy) to calculate the maximum number of triggers and channels supported by the hardware.
5.  **Test Loop**:
    *   Iterates through a subset of triggers (randomized within valid range).
    *   Iterates through valid channels.
    *   **Attach**: writes `channel trigger` to `trigin_attach` / `trigout_attach`.
    *   **Verify**: Reads back via `chan_xtrigs_sel` and `chan_xtrigs_in`/`out` to confirm mapping.
    *   **Detach**: Unmaps the trigger and confirms the entry is cleared.
6.  **Cleanup**: Restores the original LPM sleep setting.

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-24 04:56:37 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-24 04:56:37 - -------------------Starting CTI-Test Testcase----------------------------
[INFO] 2026-03-24 04:56:37 - CTI Driver Version: Modern
[INFO] 2026-03-24 04:56:37 - Device: cti_sys0 (MaxTrig: 8, MaxCh: 4)
[INFO] 2026-03-24 04:56:37 - Attach trigin: trig 0 -> ch 0 on cti_sys0
[INFO] 2026-03-24 04:56:37 - Attach trigout: trig 0 -> ch 0 on cti_sys0
.....
[INFO] 2026-03-24 04:56:39 - Attach trigout: trig 7 -> ch 2 on cti_sys0
[INFO] 2026-03-24 04:56:39 - Attach trigin: trig 7 -> ch 3 on cti_sys0
[INFO] 2026-03-24 04:56:39 - Attach trigout: trig 7 -> ch 3 on cti_sys0
[PASS] 2026-03-24 04:56:39 - CTI map/unmap Test PASS
[INFO] 2026-03-24 04:56:39 - -------------------CTI-Test Testcase Finished----------------------------
```

## Return Code

- `0` — All triggers and channels mapped/unmapped successfully across all CTI devices
- `1` — One or more mapping/unmapping operations failed

## Integration in CI

- Can be run standalone or via LAVA
- Result file `CTI-Test.res` will be parsed by `result_parse.sh`

## Notes

- The test iterates through a randomized subset of triggers rather than exhaustively testing every combination to optimize execution time while maintaining coverage.
- Disabling sleep modes is critical; if the device enters a low-power state, CTI registers may drop, causing false failures or system crashes.

## License

SPDX-License-Identifier: BSD-3-Clause.
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.