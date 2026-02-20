# ETM Test Mode

## Overview
This test verifies the stability and write-access of the **ETM (Embedded Trace Macrocell)** `mode` attribute. It sets the mode to `0XFFFFFFF` (enabling various mode bits like cycle-accurate tracing, etc., depending on the hardware revision) and attempts to enable the ETM sources.

## Execution
1.  **Discovery**: Scans `/sys/bus/coresight/devices/` for ETM devices (`etm*` or `coresight-etm*`).
2.  **Setup**:
    *   Resets all Coresight sources and sinks.
    *   Enables `tmc_etr0` as the trace sink.
3.  **Test**:
    *   Iterates through all detected ETM devices.
    *   Writes `0XFFFFFFF` to the `mode` sysfs attribute.
    *   Enables the ETM source.
4.  **Teardown**:
    *   Writes `0x0` to the `mode` sysfs attribute (restoring defaults).
    *   Disables all sources and sinks.

## Output
*   Console logs showing detection and configuration of each core.
*   `ETM-Test-Mode.res` containing the final Pass/Fail status.