# Node Access Test

## Overview
This test acts as a "fuzz" or stability test for the Coresight driver sysfs interface. It iterates through every exposed Coresight device (excluding `tpdm`) and attempts to read every readable attribute. This ensures that reading status registers or configuration nodes does not crash the system or return unexpected I/O errors.

## Execution Logic
1.  **Iterations**: Runs the scan loop 3 times.
2.  **Discovery**: Scans `/sys/bus/coresight/devices/`.
3.  **Exclusion**: Skips any path containing `tpdm` (Trace Port Debug Module).
4.  **Reset**: Resets basic source/sink enables (`stm0`, `tmc_etf0`, `tmc_etr0`) before accessing a new device folder to ensure a clean state.
5.  **Access**:
    *   Iterates all files in the device folder.
    *   Checks if the file is readable (`-r`).
    *   Performs a `cat` operation.
    *   Repeats the process for the `mgmt/` subdirectory if it exists.
6.  **Verification**: Any read failure (exit code non-zero) increments the failure counter.

## Output
*   Logs warnings for any specific node that fails to read.
*   `Node-Access.res` containing the final Pass/Fail status.