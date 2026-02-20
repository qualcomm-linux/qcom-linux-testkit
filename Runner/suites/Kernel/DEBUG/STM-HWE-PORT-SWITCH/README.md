# STM-HWE-PORT-SWITCH Test

## Overview
This test verifies that the **STM (System Trace Macrocell)** attributes `hwevent_enable` and `port_enable` can be successfully toggled (0 and 1) via sysfs, regardless of whether the main STM source (`enable_source`) is currently active or inactive.

## Execution
1.  **Setup**:
    *   Creates STP policy directories.
    *   Resets Coresight devices.
    *   Enables `tmc_etf0` as the sink.
2.  **Test Loop (Run for both `hwevent_enable` and `port_enable`)**:
    *   **Outer Loop**: Toggles STM `enable_source` (0, then 1).
    *   **Inner Loop**: Toggles the target attribute (0, then 1).
    *   **Verification**: Reads back the attribute value to ensure it matches the written value.
3.  **Teardown**:
    *   Resets all devices.
    *   Restores `hwevent_enable` to `0`.
    *   Restores `port_enable` to `0xffffffff` (all ports enabled).

## Output
*   Console logs detailing the read/write operations.
*   `STM-HWEvent-Port-Enable-Disable.res` containing Pass/Fail status for each attribute.