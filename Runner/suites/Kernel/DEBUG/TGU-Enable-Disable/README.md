# Coresight TGU Enable/Disable Test

## Overview
This test validates the **Trace Generation Unit (TGU)** drivers in the Coresight subsystem. It ensures that TGUs can be enabled and disabled successfully when paired with standard sinks (ETR and ETF).

## Test Goals

- Validate the functionality of TGU drivers in the Coresight subsystem.
- Ensure TGUs can be successfully enabled and disabled via sysfs.
- Verify proper operation when TGUs are paired and routed to standard sinks (ETR and ETF).
- Confirm that enabling/disabling TGUs does not return unexpected I/O errors.

## Prerequisites

- Kernel must be built with Coresight support. 
- `sysfs` access to `/sys/bus/coresight/devices/`.
- Root priviledges needed.

## Script Location

```
Runner/suites/Kernel/DEBUG/TGU-Enable-Disable/run.sh
```

## Files

- `run.sh` - Main test script
- `TGU-Enable-Disable.res` - Summary result file with PASS/FAIL
- `TGU-Enable-Disable.log` - Full execution log.

## How it Works
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

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-24 05:58:32 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-24 05:58:32 - -------------------Starting TGU-Enable-Disable Testcase----------------------------
[WARN] 2026-03-24 05:58:32 - No TGU (Trace Generation Unit) devices found. Skipping test.
[INFO] 2026-03-24 05:58:32 - Cleaning up...
[INFO] 2026-03-24 05:58:32 - -------------------TGU-Enable-Disable Testcase Finished----------------------------
```

## Return Code

- `0` — All TGUs are enabled and disabled successfully across all tested sinks
- `1` — One or more TGUs failed to enable or disable

## Integration in CI

- Can be run standalone or via LAVA
- Result file `TGU-Enable-Disable.res` will be parsed by `result_parse.sh`

## Notes

- The test systematically pairs TGUs with different sinks to ensure that the Coresight routing topology functions correctly for each configuration.

## License

SPDX-License-Identifier: BSD-3-Clause.
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.