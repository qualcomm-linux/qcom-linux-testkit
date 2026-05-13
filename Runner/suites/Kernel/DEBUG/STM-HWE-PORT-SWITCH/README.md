# STM-HWE-PORT-SWITCH Test

## Overview
This test verifies that the STM (System Trace Macrocell) attributes `hwevent_enable` and `port_enable` can be successfully toggled (0 and 1) via sysfs, regardless of whether the main STM source (`enable_source`) is currently active or inactive.

## Test Goals
- Verify the ability to toggle STM hardware event enabling (`hwevent_enable`).
- Verify the ability to toggle STM port enabling (`port_enable`).
- Ensure that these attributes can be modified independently of the main STM source's active state (enabled or disabled).
- Validate that sysfs reads accurately reflect the values written to these configuration attributes.
- Ensure proper restoration of default values post-testing.

## Prerequisites
- Kernel must be built with Coresight STM support (e.g., `CONFIG_CORESIGHT_STM`).
- sysfs access to `/sys/bus/coresight/devices/stm0/` (or equivalent STM device path).
- Access to configfs for STP policy directory creation.
- Root privileges (to configure attributes, enable sources/sinks, and manage policies).

## Script Location
`Runner/suites/Kernel/DEBUG/STM-HWE-PORT-SWITCH/run.sh`

## Files
- `run.sh` - Main test script
- `STM-HWE-PORT-SWITCH.res` - Summary result file with PASS/FAIL
- `STM-HWE-PORT-SWITCH.log` - Full execution log (generated if logging is enabled)

## How It Works
1. **Setup:**
   - Creates STP policy directories.
   - Resets Coresight devices to ensure a clean state.
   - Enables `tmc_etf0` as the trace sink.
2. **Test Loop (Run for both `hwevent_enable` and `port_enable`):**
   - **Outer Loop:** Toggles the main STM `enable_source` (sets to 0, then 1).
   - **Inner Loop:** Toggles the target attribute (sets to 0, then 1).
3. **Verification:** Reads back the attribute value to ensure it matches the written value.
4. **Teardown:**
   - Resets all Coresight devices.
   - Restores `hwevent_enable` to 0.
   - Restores `port_enable` to 0xffffffff (all ports enabled).

## Example Output
```
[INFO] 2026-03-16 09:03:42 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-16 09:03:42 - -------------------Starting STM-HWE-PORT-SWITCH Testcase----------------------------
[INFO] 2026-03-16 09:03:42 - Testing Attribute: hwevent_enable
[PASS] 2026-03-16 09:03:42 - STM_Src:0 | hwevent_enable set to 0
[PASS] 2026-03-16 09:03:42 - STM_Src:0 | hwevent_enable set to 1
[PASS] 2026-03-16 09:03:42 - STM_Src:1 | hwevent_enable set to 0
[PASS] 2026-03-16 09:03:42 - STM_Src:1 | hwevent_enable set to 1
[INFO] 2026-03-16 09:03:42 - Testing Attribute: port_enable
[PASS] 2026-03-16 09:03:42 - STM_Src:0 | port_enable set to 0
[PASS] 2026-03-16 09:03:42 - STM_Src:0 | port_enable set to 1
[PASS] 2026-03-16 09:03:42 - STM_Src:1 | port_enable set to 0
[PASS] 2026-03-16 09:03:42 - STM_Src:1 | port_enable set to 1

## Return Code

- `0` — All attributes were toggled and verified successfully in all source states
- `1` — One or more read/write verifications failed

## Integration in CI

- Can be run standalone or via LAVA
- Result file STM-HWE-PORT-SWITCH.res will be parsed by result_parse.sh

## Notes

- Ensuring that configuration changes can happen while the main source is active is critical for dynamic trace adjustments without needing to tear down the entire Coresight topology.
- 0xffffffff represents a bitmask enabling all 32 ports in standard STM configurations.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.