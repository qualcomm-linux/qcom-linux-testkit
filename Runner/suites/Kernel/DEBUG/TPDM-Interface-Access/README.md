# TPDM-Interface-Access Test

## Overview
This test performs comprehensive reads across all Trace Profiling and Diagnostics Monitor (TPDM) sysfs interfaces within the Coresight subsystem. It ensures that sysfs nodes correctly expose dataset properties and that interfaces remain securely readable without causing panics or "Invalid argument" responses. 

## Test Goals

- Dynamically scan and iterate through all registered TPDM devices in `/sys/bus/coresight/devices/`.
- Validate the dataset map implementation mapping (DSB, CMB, TC, BC, GPR, MCMB).
- Validate dataset configuration properties (e.g. converting hexadecimal active datasets mappings to logical subsystem checks).
- Prevent and detect attribute read failures on dynamically exposed sysfs device interfaces.

## Prerequisites

- Kernel must be built with Coresight TPDM/ETF source support.
- `sysfs` access to `/sys/bus/coresight/devices/`.
- DebugFS access to `/d/npu/ctrl` or `/sys/kernel/debug/npu/ctrl` for TPDM-NPU tests.
- Root privileges (to configure Coresight source elements and access hardware attributes).

## Script Location

```
Runner/suites/Kernel/DEBUG/TPDM-Interface-Access/run.sh
```

## Files

- `run.sh` - Main test script
- `TPDM-Interface-Access.res` - Summary result file with PASS/FAIL
- `TPDM-Interface-Access.log` - Full execution log (generated if logging is enabled via functestlib)

## How It Works

The test uses a two-pronged approach:

1. **Dataset Verification Phase**: 
   - Dynamically discovers all TPDM nodes.
   - Parses the active bit map exposed by the node's `enable_datasets` file.
   - Translates the hex output to human-readable subsets (e.g., DSB, CMB).
   - Dynamically probes every sysfs file matching the mapped properties to ensure driver readability.
2. **Global Read Validation Phase**: 
   - Flushes all coresight elements (Resets sinks and sources to `0`).
   - Recursively performs standard `cat` reads on every readable (`-r`) generic node under the device.
   - Detects node read failures that typically indicate misconfigured kernel data boundaries.

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-23 05:56:52 - ------------------------------------------------------
[INFO] 2026-03-23 05:56:52 - Starting Testcase: TPDM-Interface-Access
[INFO] 2026-03-23 05:56:52 - Performing initial device reset...
[INFO] 2026-03-23 05:56:52 - --- Phase 1: Source dataset mode tests ---
[INFO] 2026-03-23 05:56:52 - Testing device: tpdm0
[INFO] 2026-03-23 05:56:52 -   Default datasets:  (Mode: 00) -> Configurations: none
[INFO] 2026-03-23 05:56:52 - Testing device: tpdm1
[INFO] 2026-03-23 05:56:52 -   Default datasets:  (Mode: 00) -> Configurations: none
......
[INFO] 2026-03-23 05:56:52 - Testing device: tpdm8
[INFO] 2026-03-23 05:56:52 -   Default datasets:  (Mode: 00) -> Configurations: none
[INFO] 2026-03-23 05:56:52 - Testing device: tpdm9
[INFO] 2026-03-23 05:56:52 -   Default datasets:  (Mode: 00) -> Configurations: none
[PASS] 2026-03-23 05:56:52 - Phase 1 Completed: All TPDM mode attributes check passed
[INFO] 2026-03-23 05:56:52 - Performing mid-test device reset...
[INFO] 2026-03-23 05:56:52 - --- Phase 2: Readable attributes check ---
[INFO] 2026-03-23 05:56:52 - Reading 8 accessible nodes under tpdm0
[INFO] 2026-03-23 05:56:52 - Reading 8 accessible nodes under tpdm1
......
[INFO] 2026-03-23 05:56:52 - Reading 8 accessible nodes under tpdm8
[INFO] 2026-03-23 05:56:52 - Reading 8 accessible nodes under tpdm9
[PASS] 2026-03-23 05:56:52 - Result: TPDM-Interface-Access PASS
[INFO] 2026-03-23 05:33:24 - -------------------TPDM-Interface-Access Testcase Finished----------------------------

```

## Return Code

- `0` — All attributes were read successfully without any panics, permission denials, or generic read errors
- `1` — One or more files in the TPDM tree failed to perform a valid return on cat

## Integration in CI

- Can be run standalone or via LAVA
- Result file TPDM-Interface-Access.res will be parsed by result_parse.sh

## Notes

- `tpdm-turing-llm` node paths are hardcoded to be skipped as per hardware testing constraints
- If tpdm-npu is detected, the framework will temporarily write to the NPU debugger control map at /sys/kernel/debug/npu/ctrl

## License

SPDX-License-Identifier: BSD-3-Clause-Clear
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.