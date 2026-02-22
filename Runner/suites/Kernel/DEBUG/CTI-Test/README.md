# CTI Test

## Overview
This test verifies the functionality of the Coresight CTI (Cross Trigger Interface) driver. It ensures that hardware triggers can be successfully mapped (attached) to CTI channels and subsequently unmapped (detached).

## Execution Logic
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

## Output
*   Logs identifying which CTI device, trigger, and channel are being tested.
*   `CTI-Trigger-Map.res` containing the final Pass/Fail status.