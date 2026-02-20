# ETM-CPU-Toggle-Composite-Base Test

## Overview
This test performs a compostite stress validation of the Coresight ETM subsystem. It verifies that enabling/disabling trace sources and capturing data remains stable even when the system is under heavy CPU Hotplug stress (randomly offlinin/onlining cores).

## Test Goals

- Validate the stability of the Coresight ETM subsystem under heavy CPU hotplug stress.
- Ensure trace sources can be reliably enabled and disabled while CPU cores are dynamically offlined and onlined.
- Prevent and detect driver race conditions (e.g., "Invalid argument" or "Operation not permitted" errors).
- Ensure captured trace data remains valid and meets the minimum size threshold (>= 64 bytes) during stress.

## Prerequisites

- Kernel must be built with Coresight ETM and CPU Hotplug support.
- `sysfs` access to `/sys/bus/coresight/devices/` and `/sys/devices/system/cpu/`.
- Access to read from sink character devices (e.g., `/dev/tmc_etf0`).
- Root privileges (to configure Coresight devices and toggle CPU states).

## Script Location

```
Runner/suites/Kernel/DEBUG/ETM_CPU_Toggle_Composite_Base/run.sh
```

## Files

- `run.sh` - Main test script
- `ETM-CPU-Toggle-Composite-Base.res` - Summary result file with PASS/FAIL
- `ETM-CPU-Toggle-Composite-Base.log` - Full execution log (generated if logging is enabled)

## How It Works

The test uses a two-pronged approach:

1. **Background Stress**: A background process continuously and randomly offlines and onlines available CPU cores (excluding `CPU0`).
2. **Foreground Validation**: Iterates `N` times (default: 100):
   - Enables the `tmc_etf0` sink.
   - Enables ETM on all currently online cores.
   - Waits for 1 second to allow trace generation.
   - Captures data from `/dev/tmc_etf0`.
   - **Verification**:
     - Ensures no "Invalid argument" or "Operation not permitted" errors occur (which often indicate driver race conditions).
     - Ensures captured trace data size is >= 64 bytes.
   - Disables ETM sources before the next iteration.

## Usage

Run the script with an optional argument for the number of stress iterations.

```bash
./run.sh

./run.sh 500
```

## Example Output

```
[INFO] 2026-03-17 11:53:39 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-17 11:53:39 - -------------------Starting ETM_CPU_Toggle_Composite_Base Testcase----------------------------
[INFO] 2026-03-17 11:53:39 - Targeting 7 cores for 100 iterations
[INFO] 2026-03-17 11:53:39 - Started CPU hotplug stress (PID: 17189)
[INFO] 2026-03-17 11:53:39 - Iteration 1/100...
[INFO] 2026-03-17 11:53:40 - Iteration 2/100...
......
[INFO] 2026-03-17 11:55:44 - Iteration 99/100...
[INFO] 2026-03-17 11:55:45 - Iteration 100/100...
[PASS] 2026-03-17 11:55:46 - Successfully completed 100 iterations of ETM + Hotplug Stress
[INFO] 2026-03-17 11:55:46 - -------------------$TESTNAME Testcase Finished----------------------------
```

## Return Code

- `0` — All iterations completed successfully without driver errors and valid data captures
- `1` — One or more driver errors occurred, or trace captures were invalid/undersized

## Integration in CI

- Can be run standalone or via LAVA
- Result file ETM-CPU-Toggle-Composite-Base.res will be parsed by result_parse.sh

## Notes

- CPU0 is explicitly excluded from the background hotplug stress to prevent system instability or panics related to the primary boot CPU.

## License
SPDX-License-Identifier: BSD-3-Clause-Clear
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.