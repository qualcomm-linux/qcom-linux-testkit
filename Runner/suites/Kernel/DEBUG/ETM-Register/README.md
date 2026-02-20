# ETM-Register Test

## Overview

This test case validates the readability of the CoreSight Embedded Trace Macrocell (ETM) sysfs registers. It iterates through all available ETM devices, temporarily enables them as trace sources with an active sink (ETF), and attempts to read their management (mgmt) and base node configurations to ensure they are accessible without throwing I/O or kernel errors.

## Test Goals

- Validate the readability of CoreSight ETM sysfs registers.
- Ensure management (mgmt) and base node configurations are accessible.
- Verify that reading these registers while the source is active does not cause I/O errors or kernel panics.
- Confirm smooth transition and sequential testing across multiple ETM devices.

## Prerequisites

- Kernel must be built with `CoreSight ETM` and TMC drivers.
- `CoreSight ETM` sources (etm* or coresight-etm*) must be present.
- A valid TMC sink, such as tmc_etf0 (or generic tmc_etf), must be available.
- `sysfs` must be mounted and accessible at `/sys`.
- Root privileges (to write to sysfs nodes and configure sources/sinks).

## Script Location

```
Runner/suites/Kernel/DEBUG/ETM-Register/run.sh
```

## Files

- `run.sh` - Main test script
- `ETM-Register.res` - Summary result file with PASS/FAIL based on whether all mgmt registers were successfully read
- `ETM-Register.log` - Full execution log (generated if logging is enabled)

## How It Works

1.  **Discovery**: The script automatically discovers all available ETM devices and the designated ETF sink in the sysfs directory.
2.  **Iteration**: For each discovered ETM device:
    - **Setup**: Temporarily enables the tmc_etf sink.
    - **Enable Source**: Enables the current ETM device as a trace source.
    - **Read Registers**: Attempts to read the management (mgmt/) registers and base node configurations for the active ETM.
    - **Verification**: Checks that the read operations succeed without throwing I/O errors or kernel issues.
    - **Teardown**: Disables the ETM source and the sink before moving to the next device.

## Usage

The script automatically discovers available ETM devices and tests them sequentially. No manual arguments are required.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-17 11:29:22 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-17 11:29:22 - -------------------Starting ETM-Register Testcase----------------------------
[INFO] 2026-03-17 11:29:22 - Found 8 ETM devices
[INFO] 2026-03-17 11:29:22 - Testing ETM node: /sys/bus/coresight/devices/etm0
[INFO] 2026-03-17 11:29:23 - Testing ETM node: /sys/bus/coresight/devices/etm1
[INFO] 2026-03-17 11:29:23 - Testing ETM node: /sys/bus/coresight/devices/etm2
[INFO] 2026-03-17 11:29:23 - Testing ETM node: /sys/bus/coresight/devices/etm3
[INFO] 2026-03-17 11:29:23 - Testing ETM node: /sys/bus/coresight/devices/etm4
[INFO] 2026-03-17 11:29:23 - Testing ETM node: /sys/bus/coresight/devices/etm5
[INFO] 2026-03-17 11:29:23 - Testing ETM node: /sys/bus/coresight/devices/etm6
[INFO] 2026-03-17 11:29:24 - Testing ETM node: /sys/bus/coresight/devices/etm7
[PASS] 2026-03-17 11:29:24 - ETM Register Read Test Successful
[INFO] 2026-03-17 11:29:24 - -------------------ETM-Register Testcase Finished----------------------------
```

## Return Code

- `0` — All management registers across all ETM devices were successfull read without errors
- `1` — One or more register read attempts threw an I/O error or failed

## Integration in CI

- Can be run standalone or via LAVA
- Result file ETM-Register.res will be parsed by result_parse.sh

## Notes

- The test specifically enables the ETM device as an active trace source before reading the registers to ensure access is valid under active tracing conditions.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.