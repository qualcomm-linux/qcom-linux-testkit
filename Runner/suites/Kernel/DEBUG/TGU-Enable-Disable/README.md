# Coresight TGU Enable/Disable Test

## Overview
This test validates the **Trace Generation Unit (TGU)** drivers in the CoresigCCCCht subsystem. It ensures that TGUs can be enabled and disabled successfully when paired with standard sinks (ETR and ETF).

## Execution Logic
1.  **Discovery**:
    *   Scans `/sys/bus/coresight/devices/` for devices matching `tgu` (e.g., `coresight-tgu`).
    *   Identifies available sinks (`tmc_etr`, `tmc_etf`, or `coresight-tmc-*` variants).
2.  **Outer Loop (Sinks)**:
    *   Iterates through available sinks (ETR, then ETF).
    *   Resets the Coresight topology (`reset_source_sink`).
    *   Enables the current sink.
3.  **Inner Loop (TGUs)**:
    *   **Enable**: Writes `1` to `enable_tgu`.
    *   **Verify**: Checks the exit code of the write operation.
    *   **Disable**: Writes `0` to `enable_tgu`.
    *   **Verify**: Checks the exit code.
4.  **Cleanup**: Disables the sink before the next iteration.

## Output
*   Logs indicating which Sink-TGU pair is being tested.
*   `TGU-Enable-Disable.res` containing the final Pass/Fail status.