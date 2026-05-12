# ETM Test Mode

## Overview

This test verifies the stability and write-access of the **ETM (Embedded Trace Macrocell)** `mode` attribute. It sets the mode to `0XFFFFFFF` (enabling various mode bits like cycle-accurate tracing, etc., depending on the hardware revision) and attempts to enable the ETM sources.

## Test Goals

- Verify the stability and write-access of the Coresight ETM `mode` attribute
- Ensure ETM sources can be successfully enabled when complex mode bits are activated (`0XFFFFFFF`)
- Validate that the system does not crash or return errors during aggressive mode configurations
- Ensure proper teardown and restoration of default ETM mode values

## Prerequisites

- Kernel must be built with Coresight ETM support
- `sysfs` access to `/sys/bus/coresight/devices/`
- Root privileges (to write to `mode` and enable entries)

## Script Location

```
Runner/suites/Kernel/DEBUG/ETM-Test-Mode/run.sh
```

## Files

- `run.sh` - Main test script
- `ETM-Test-Mode.res` - Summary result file with PASS/FAIL
- `ETM-Test-Mode.log` - Full execution log (generated if logging is enabled)

## How It Works

1. **Discovery**: Scans `/sys/bus/coresight/devices/` for ETM devices (`etm*` or `coresight-etm*`).
2. **Setup**:
   - Resets all Coresight sources and sinks.
   - Enables `tmc_etr0` as the trace sink.
3. **Test**:
   - Iterates through all detected ETM devices.
   - Writes `0XFFFFFFF` to the `mode` sysfs attribute.
   - Enables the ETM source.
4. **Teardown**:
   - Writes `0x0` to the `mode` sysfs attribute (restoring defaults).
   - Disables all sources and sinks.

## Example Output

```
[INFO] 2026-03-17 11:11:53 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-17 11:11:53 - -------------------Starting ETM-Test-Mode Testcase----------------------------
[INFO] 2026-03-17 11:11:53 - Enabling Sink: /sys/bus/coresight/devices/tmc_etr0
[INFO] 2026-03-17 11:11:53 - Configuring etm0
[INFO] 2026-03-17 11:11:53 - etm0 mode set and verified: 0xfffffff
[INFO] 2026-03-17 11:11:53 - etm0 enabled and verified (enable_source=1)
.....
[PASS] 2026-03-17 11:11:54 - ETM Mode Configuration Successful
[INFO] 2026-03-17 11:11:54 - -------------------ETM-Test-Mode Testcase Finished----------------------------
```

## Return Code

- `0` — All ETM devices successfully configured and enabled with the test mode
- `1` — One or more ETM devices failed configuration or enablement

## Integration in CI

- Can be run standalone or via LAVA
- Result file `ETM-Test-Mode.res` will be parsed by `result_parse.sh`

## Notes

- Writing `0XFFFFFFF` acts as a stress test by attempting to flip all available configuration bits simultaneously. The exact features enabled (e.g., cycle-accurate tracing) will vary depending on the specific hardware revision of the ETM.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.
