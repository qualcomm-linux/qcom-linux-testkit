# STM Source Enable/Disable Stress Test

## Overview
This test validates the stability of the **STM (System Trace Macrocell)** driver by repeatedly enabling and disabling the source in a loop.

## Execution
1.  **Setup**:
    *   Creates STP policy directories.
    *   Resets all Coresight source/sink devices.
    *   Disables hardware events and clears global tracing events.
2.  **Loop (50 Iterations)**:
    *   Resets source/sink.
    *   Enables `tmc_etf` sink.
    *   Enables `stm` source $\to$ Checks if `enable_source` is `1`.
    *   Disables `stm` source $\to$ Checks if `enable_source` is `0`.
3.  **Teardown**: Resets devices.

## Output
*   Console logs indicating iteration failures (if any).
*   `STM-Source-Enable-Disable.res` containing Pass/Fail status.