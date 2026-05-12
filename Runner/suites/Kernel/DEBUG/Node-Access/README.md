# Node Access Test

## Overview
This test acts as a "fuzz" or stability test for the Coresight driver sysfs interface. It iterates through every exposed Coresight device (excluding `tpdm`) and attempts to read every readable attribute. This ensures that reading status registers or configuration nodes does not crash the system or return unexpected I/O errors.

## Test Goals

- Perform stability/fuzz testing on the Coresight sysfs interface.
- Ensure reading exposed device attributes does not cause system crashes or hangs.
- Verify that readable nodes do not return unexpected I/O errors upon access.
- Validate the robustness of the `mgmt/subdirectory` nodes if present.

## Prerequisites

- Kernel must be built with Coresight support. 
- `sysfs` access to `/sys/bus/coresight/devices/`.
- Root priviledges needed.

## Script Location

```
Runner/suites/Kernel/DEBUG/Node-Access/run.sh
```

## Files

- `run.sh` - Main test script
- `Node-Access.res` - Summary result file with PASS/FAIL
- `Node-Access.log` - Full execution log.

## How it works
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

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-23 10:09:39 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-23 10:09:39 - -------------------Starting Node-Access Testcase----------------------------
[INFO] 2026-03-23 10:09:39 - --- Iteration 1 / 3 Ongoing ---
[PASS] 2026-03-23 10:09:43 - Iteration 1 PASS
[INFO] 2026-03-23 10:09:43 - --- Iteration 2 / 3 Ongoing ---
[PASS] 2026-03-23 10:09:47 - Iteration 2 PASS
[INFO] 2026-03-23 10:09:47 - --- Iteration 3 / 3 Ongoing ---
[PASS] 2026-03-23 10:09:51 - Iteration 3 PASS
[PASS] 2026-03-23 10:09:51 - All sysfs nodes (except tpdm) Read Test PASS
[INFO] 2026-03-23 10:09:51 - -------------------Node-Access Testcase Finished----------------------------
```

## Return Code

- `0` — All readable nodes were accessed successfully across all iterations
- `1` — One or more readable nodes failed to be read or returned an error

## Integration in CI

- Can be run standalone or via LAVA
- Result file `Node-Access.res` will be parsed by `result_parse.sh`

## Notes

- tpdm devices are explicitly excluded from this test.
- The test runs 3 iterations to catch int4ermittent read failures or state-dependent crashes.

## License

SPDX-License-Identifier: BSD-3-Clause. 
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.