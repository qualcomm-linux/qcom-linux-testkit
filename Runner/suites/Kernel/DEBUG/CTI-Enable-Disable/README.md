# Coresight CTI Enable/Disable Test

## Overview
This test validates the basic toggle functionality of the Coresight Cross Trigger Interface (CTI) drivers. It ensures that every CTI device exposed in sysfs can be turned on and off without errors.

## Execution Logic
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

## Output
*   Logs for every device toggle attempt.
*   `CTI-Enable-Disable.res` containing the final Pass/Fail status.