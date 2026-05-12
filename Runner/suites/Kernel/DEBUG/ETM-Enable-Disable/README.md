# ETM-Enable-Disable Test

## Overview

This test validates the user-space sysfs interface for activating and deactivating Embedded Trace Macrocells (ETM). It ensures that the kernel properly handles ETM component state transitions by evaluating individual enable/disable cycles, as well as bulk enable and bulk disable sequences.

## Test Goals

Validate the user-space sysfs interface for ETM activation and deactivation.
Ensure the kernel properly handles individual enable/disable cycles for each CoreSight ETM device.
Verify bulk enable sequences (activating all ETMs simultaneously).
Verify bulk disable sequences (deactivating all ETMs simultaneously).

## Prerequisites

Kernel must be built with CoreSight core and ETM drivers.
CoreSight ETM Devices (etm* or coresight-etm*) must be present.
A valid sink like tmc_etf0 (or default tmc_etf) must be available.
sysfs must be mounted and accessible.
Root privileges (to write to sysfs nodes).

## Script Location

```
Runner/suites/Kernel/DEBUG/ETM-Enable-Disable/run.sh
```

## Files

- `run.sh` - Main test script
- `ETM-Enable-Disable.res` - Summary result file with PASS/FAIL based on aggregated results
- `ETM-Enable-Disable.log` - Full execution log (generated if logging is enabled)

## How It Works

1.  **Discovery**: The script automatically queries the sysfs coresight bus to build a list of available ETMs.
2.  **Individual Testing**: Performs individual enable and disable cycles for each detected CoreSight ETM device.
3.  **Bulk Enable**: Executes a sequence to activate all discovered ETMs simultaneously.
4.  **Bulk Disable**: Executes a sequence to deactivate all discovered ETMs simultaneously.
5.  **Evaluation**: Evaluates the success of both individual and bulk operations, logging the status transitions.

## Usage

The script automatically queries the `sysfs` coresight bus to build a list of available ETMs and performs the transitions without requiring manual arguments.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-17 11:37:15 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-17 11:37:15 - -------------------Starting ETM-Enable-Disable Testcase----------------------------
[INFO] 2026-03-17 11:37:15 - /sys/bus/coresight/devices/etm0 initial status: 0
[INFO] 2026-03-17 11:37:15 - enable /sys/bus/coresight/devices/etm0 PASS
[INFO] 2026-03-17 11:37:15 - disable /sys/bus/coresight/devices/etm0 PASS
......
[INFO] 2026-03-17 11:43:27 - Testing etm_enable_all_cores...
[INFO] 2026-03-17 11:43:28 - Testing etm_disable_all_cores...
[PASS] 2026-03-17 11:43:28 - ETM enable and disable test end: PASS
[INFO] 2026-03-17 11:43:28 - -------------------ETM-Enable-Disable Testcase Finished----------------------------
```

## Return Code

- `0` — All individual and bulk ETM state transitions completed successfully
- `1` — One or more ETM state transitions failed

## Integration in CI

- Can be run standalone or via LAVA
- Result file ETM-Enable-Disable.res will be parsed by result_parse.sh

## Notes
- This test does not require manual arguments as it automatically detects the available CoreSight topology.

## License
SPDX-License-Identifier: BSD-3-Clause-Clear
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.
