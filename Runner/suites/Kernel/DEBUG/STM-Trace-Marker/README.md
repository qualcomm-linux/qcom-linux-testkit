# STM-Trace-Marker Test

## Overview
This test case verifies the functionality of the System Trace Macrocell (STM) by generating software trace events via Ftrace and capturing them in the Embedded Trace FIFO (ETF).

## Test Goals
- Verify STM functionality by generating software trace events via Ftrace.
- Capture software trace events in the Embedded Trace FIFO (ETF).
- Validate that the captured binary data in the sink meets the expected size thresholds.

## Prerequisites
- **Hardware:** 
  - STM Source: `stm0` (must be present in `/sys/bus/coresight/devices/`)
  - ETF Sink: `tmc_etf0` (must be present in `/sys/bus/coresight/devices/`)
- **Software:** `configfs`, `debugfs`
- **Tools:** `timeout`, `stat`, `seq`, `awk`
- **Permissions:** Root access required to write to sysfs and debugfs nodes.

## Script Location
`Runner/suites/Kernel/DEBUG/STM-Trace-Marker/STM-Trace-Marker.sh`

## Files
- `STM-Trace-Marker.sh` - Main test script
- `STM-Trace-Marker.res` - Summary result file with PASS/FAIL

## How It Works
1. **Setup:** 
   - Mounts `configfs` at `/sys/kernel/config`.
   - Mounts `debugfs` at `/sys/kernel/debug`.
   - Creates default STP policies for `stm0`.
2. **Execution:** 
   - Links the STM source to Ftrace.
   - Enables the ETF sink (`tmc_etf0`).
   - Writes marker data for the specified number of iterations.
3. **Verification:** 
   - Verifies that the captured binary data in the sink meets the expected size thresholds.

## Example Output
```
[INFO] 2026-03-16 10:26:35 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-16 10:26:35 - -------------------Starting STM-Trace-Marker Testcase----------------------------
[INFO] 2026-03-16 10:26:35 - === Test Initialization ===
[INFO] 2026-03-16 10:26:35 - Checking if required tools are available
[INFO] 2026-03-16 10:26:35 - Cleaning up Ftrace and STM settings...
[INFO] 2026-03-16 10:26:35 - Configuring Coresight Path...
[INFO] 2026-03-16 10:26:35 - Enabling Ftrace events...
[INFO] 2026-03-16 10:26:35 - Generating 500 trace marker events...
[INFO] 2026-03-16 10:26:45 - Dumping ETF buffer to /tmp/etf0.bin...
[INFO] 2026-03-16 10:26:45 - Captured binary size: 65536 bytes
[PASS] 2026-03-16 10:26:45 - Successfully captured STM trace data (65536 bytes)
[INFO] 2026-03-16 10:26:45 - Cleaning up Ftrace and STM settings...
```

## Return Code

- `0` — Captured data met the expected size threshold and all transitions passed
- `1` — Verification failed or required components (hardware/filesystems) were missing

## Integration in CI

- Can be run standalone or via LAVA
- Result file STM-Trace-Marker.res will be parsed by result_parse.sh

## Notes

- The test relies heavily on the presence of `/sys/kernel/debug` and `/sys/kernel/config` to correctly route Ftrace data to the STM device.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.