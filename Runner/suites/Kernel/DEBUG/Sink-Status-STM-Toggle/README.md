# Coresight Sink Status Test (STM Toggle)

## Overview
This test verifies the dependency behavior between Coresight Sources (STM, ETM) and Sinks (TMC-ETF, TMC-ETR). It ensures that sinks open and close correctly based on the activity of connected sources.

## Test Goals
- Verify the dependency management between Coresight trace sources and sinks.
- Ensure sinks correctly activate when a connected source (STM) is enabled.
- Ensure sinks correctly deactivate and release resources when the sole connected source is disabled.
- Validate multi-source behavior, ensuring a sink remains active if at least one connected source (e.g., ETM) is still active after another (e.g., STM) is disabled.

## Prerequisites
- Kernel must be built with Coresight STM and ETM support.
- sysfs access to `/sys/bus/coresight/devices/`.
- Root privileges (to configure source and sink enables).

## Script Location
`Runner/suites/Kernel/DEBUG/Sink-Status-STM-Toggle/run.sh`

## Files
- `run.sh` - Main test script
- `Sink-Status-STM-Toggle.res` - Summary result file with PASS/FAIL
- `Sink-Status-STM-Toggle.log` - Full execution log (generated if logging is enabled)

## How It Works
The test performs validation for every available sink (`tmc_etf0`, `tmc_etr0`, etc., excluding `tmc_etf1`).

### Phase 1: Single Source (STM Only)
- **Setup:** Resets all Coresight devices.
- **Enable:** Enables the Sink -> Enables the STM Source. Verifies that the Sink's `enable_sink` attribute is 1.
- **Disable:** Disables the STM Source. Verifies that the Sink's `enable_sink` attribute drops to 0 (releasing the resource).

### Phase 2: Multi-Source (STM + ETM) 
*(Note: Runs only if an ETM device is detected)*
- **Setup:** Resets all Coresight devices.
- **Enable:** Enables the Sink -> Enables the STM Source -> Enables the ETM Source. Verifies that the Sink's `enable_sink` attribute is 1.
- **Partial Disable:** Disables only the STM Source. Verifies that the Sink's `enable_sink` attribute remains 1 (since the active ETM should keep the sink open).
- **Cleanup:** Resets all devices.

## Example Output
```
[INFO] 2026-03-16 09:33:19 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-16 09:33:19 - -------------------Starting Sink-Status-STM-Toggle Testcase----------------------------
[INFO] 2026-03-16 09:33:19 - === Phase 1: STM Only Test ===
[INFO] 2026-03-16 09:33:19 - Testing Sink: tmc_etf0
[PASS] 2026-03-16 09:33:20 - Phase1_STM_Enable: /sys/bus/coresight/devices/tmc_etf0 status is 1
[PASS] 2026-03-16 09:33:21 - Phase1_STM_Disable: /sys/bus/coresight/devices/tmc_etf0 status is 0
[INFO] 2026-03-16 09:33:21 - Testing Sink: tmc_etr0
[PASS] 2026-03-16 09:33:22 - Phase1_STM_Enable: /sys/bus/coresight/devices/tmc_etr0 status is 1
[PASS] 2026-03-16 09:33:23 - Phase1_STM_Disable: /sys/bus/coresight/devices/tmc_etr0 status is 0
[INFO] 2026-03-16 09:33:23 - Testing Sink: tmc_etr1
[PASS] 2026-03-16 09:33:24 - Phase1_STM_Enable: /sys/bus/coresight/devices/tmc_etr1 status is 1
[PASS] 2026-03-16 09:33:25 - Phase1_STM_Disable: /sys/bus/coresight/devices/tmc_etr1 status is 0
[INFO] 2026-03-16 09:33:25 - === Phase 2: STM + ETM Test ===
[INFO] 2026-03-16 09:33:25 - Testing Sink (Multi-Source): tmc_etf0
[PASS] 2026-03-16 09:33:26 - Phase2_Both_Enable: /sys/bus/coresight/devices/tmc_etf0 status is 1
[PASS] 2026-03-16 09:33:26 - Phase2_STM_Disable_ETM_Active: /sys/bus/coresight/devices/tmc_etf0 status is 1
[INFO] 2026-03-16 09:33:26 - Testing Sink (Multi-Source): tmc_etr0
[PASS] 2026-03-16 09:33:27 - Phase2_Both_Enable: /sys/bus/coresight/devices/tmc_etr0 status is 1
[PASS] 2026-03-16 09:33:27 - Phase2_STM_Disable_ETM_Active: /sys/bus/coresight/devices/tmc_etr0 status is 1
[INFO] 2026-03-16 09:33:27 - Testing Sink (Multi-Source): tmc_etr1
[PASS] 2026-03-16 09:33:28 - Phase2_Both_Enable: /sys/bus/coresight/devices/tmc_etr1 status is 1
[PASS] 2026-03-16 09:33:28 - Phase2_STM_Disable_ETM_Active: /sys/bus/coresight/devices/tmc_etr1 status is 1
[PASS] 2026-03-16 09:33:28 - Sink status check passed across all phases
```

## Return Code

- `0` — All sink states transitioned correctly across all phases and tested sinks
- `1` — One or more sinks failed to report the correct state during transitions

## Integration in CI

- Can be run standalone or via LAVA
- Result file Sink-Status-STM-Toggle.res will be parsed by result_parse.sh

## Notes

- tmc_etf1 is explicitly excluded from the available sinks for this test.
- The multi-source phase dynamically skips itself if no ETM devices are found on the target platform, preventing false failures on STM-only configurations.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.