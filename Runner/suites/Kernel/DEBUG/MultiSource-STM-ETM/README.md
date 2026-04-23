# Multi-Source STM + ETM Test

## Overview
This test verifies the Coresight subsystem's ability to handle simultaneous trace data from multiple sources: STM (System Trace Macrocell) for software events, and ETM (Embedded Trace Macrocell) for instruction traces from all online CPUs. It iterates through available sinks (e.g., `tmc_etf0`, `tmc_etr0`) and checks if valid binary data is captured.

## Test Goals
- Verify the Coresight subsystem's ability to handle simultaneous trace streams.
- Validate the functionality of STM (System Trace Macrocell) for generating software event traces.
- Validate the functionality of ETM (Embedded Trace Macrocell) for instruction tracing across all online CPUs.
- Ensure that Coresight links and funnels properly multiplex data without dropping critical traces.
- Verify that valid binary data is successfully captured across different available sinks.

## Prerequisites
- Kernel must be built with Coresight support:
  - `CONFIG_CORESIGHT`
  - `CONFIG_CORESIGHT_STM`
  - `CONFIG_CORESIGHT_LINK_AND_SINK_TMC`
- Availability of the common library: `Runner/utils/coresight_common.sh`
- Root privileges (to configure Coresight sysfs nodes and read from character devices).

## Script Location
`Runner/suites/Kernel/DEBUG/MultiSource-STM-ETM/run.sh`

## Files
- `run.sh` - Main test script
- `MultiSource-STM-ETM.res` - Summary result file with PASS/FAIL
- `MultiSource-STM-ETM.log` - Full execution log (generated if logging is enabled)

## How It Works
1. **Initialization:** Sources common Coresight helper functions (`coresight_common.sh`).
2. **Setup:** Resets the Coresight topology to ensure a clean state.
3. **Execution Loop:** Iterates through all available trace sinks (e.g., `tmc_etf0`, `tmc_etr0`).
   - Enables the current sink.
   - Enables STM as a trace source.
   - Enables all available ETMs (for all online CPUs) as trace sources.
   - Triggers trace data generation (both software events and CPU instruction execution).
4. **Verification:** Reads the captured binary data from the sink and verifies its validity.
5. **Teardown:** Disables all active sources and the sink before moving to the next iteration.

## Example Output
```
[INFO] 2026-03-16 07:41:58 - -----------------------------------------------------------------------------------------
[INFO] 2026-03-16 07:41:58 - -------------------Starting MultiSource-STM-ETM Testcase----------------------------
[INFO] 2026-03-16 07:41:58 - === Test Initialization ===
[INFO] 2026-03-16 07:41:58 - Checking if required tools are available
[INFO] 2026-03-16 07:41:58 - Testing Sink: tmc_etf0
[PASS] 2026-03-16 07:41:58 - Captured 65536 bytes from tmc_etf0
[INFO] 2026-03-16 07:41:58 - Testing Sink: tmc_etr0
[PASS] 2026-03-16 07:41:58 - Captured 64 bytes from tmc_etr0
[INFO] 2026-03-16 07:41:58 - Testing Sink: tmc_etr1
[PASS] 2026-03-16 07:41:58 - Captured 64 bytes from tmc_etr1
```

## Return Code

- `0` — Simultaneous trace capture succeeded for all tested sinks
- `1` — Trace capture failed, returned invalid data, or a device failed to enable/disable

## Integration in CI

- Can be run standalone or via LAVA
- Result file MultiSource-STM-ETM.res will be parsed by result_parse.sh

## Notes

- Testing multiple sources simultaneously stresses the Coresight funnels and links to ensure they  can handle interleaved trace streams without data corruption or system instability.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.