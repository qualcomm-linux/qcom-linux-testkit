# TPDM Integration Test

## Overview

This test acts as an integration validation for the Coresight Trace Port Debug Module (TPDM). It verifies actual trace data generation and routing by artificially injecting data into the TPDM's `integration_test` nodes and confirming that the data successfully reaches the trace sink (ETF) by monitoring its internal Read/Write Pointer (`mgmt/rwp`).

## Test Goals

- Verify the end-to-end trace generation and routing capabilities of TPDM devices.
- Inject artificial trace data using the Coresight `integration_test` sysfs nodes.
- Validate that the injected trace data successfully reaches the TMC-ETF sink.
- Confirm success by observing a change in the ETF's `mgmt/rwp` (Read/Write Pointer) register value, which indicates data was written to the FIFO.

## Prerequisites

- Kernel must be built with Coresight TPDM and TMC (ETF) support.
- `sysfs` access to `/sys/bus/coresight/devices/`.
- Root privileges (to configure devices and write to `integration_test` nodes).

## Script Location

```
Runner/suites/Kernel/DEBUG/TPDM-Integration-Test/run.sh
```

## Files

- `run.sh` - Main test script
- `TPDM-Integration-Test.res` - Summary result file with PASS/FAIL
- `TPDM-Integration-Test.log` - Full execution log (generated if logging is enabled)

## How It Works

1. **Setup**: Resets the Coresight topology to a clean state.
2. **Enable**: Activates the `tmc_etf0` (or available ETF) sink and the target TPDM source.
3. **Baseline**: Reads and stores the initial value of the ETF's `mgmt/rwp` register.
4. **Injection**: Writes dummy/test data to the TPDM's `integration_test` sysfs node to force trace generation.
5. **Verification**: Reads the ETF's `mgmt/rwp` register again. The test passes if the new value is different from the baseline value (proving data flowed into the sink).
6. **Teardown**: Disables the TPDM and ETF devices.

## Example Output

```
[INFO] 2026-03-23 05:33:24 - ------------------------------------------------------
[INFO] 2026-03-23 05:33:24 - -----  Coresight TPDM integration Test Starting  -----
[INFO] 2026-03-23 05:33:24 - tpdm0 Integration Test Start
[INFO] 2026-03-23 05:33:24 - tpdm0 Integration Test PASS
[INFO] 2026-03-23 05:33:24 - tpdm1 Integration Test Start
[INFO] 2026-03-23 05:33:24 - tpdm1 Integration Test PASS
....
[INFO] 2026-03-23 05:33:24 - tpdm9 Integration Test Start
[INFO] 2026-03-23 05:33:24 - tpdm9 Integration Test PASS
[PASS] 2026-03-23 05:33:24 - -----PASS: All TPDM devices integration test-----
[INFO] 2026-03-23 05:33:24 - -------------------TPDM-Integration-Test Testcase Finished----------------------------
```

## Return Code

- `0` — The `mgmt/rwp` value changed successfully after data injection (PASS)
- `1` — The `mgmt/rwp` value did not change, indicating trace data was lost or not generated (FAIL)

## Integration in CI

- Can be run standalone or via LAVA
- Result file `TPDM-Integration-Test.res` will be parsed by `result_parse.sh`

## Notes

- The `mgmt/rwp` (Read/Write Pointer) is a hardware register in the Trace Memory Controller (TMC) that increments as trace data is written into its SRAM/FIFO. Checking this register is a reliable, lightweight way to verify data flow without needing to dump and parse the entire binary trace buffer.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.