# Run-GetEnforce

## Overview
The `Run-GetEnforce` test case validates the SELinux enforcement mode on the target system that should be in 'Permissive' mode for certain operation that need disabling security policies.

## Test Goals

- Verify the current SELinux enforcement status.
- Ensure the system is running in Permissive mode.

## Prerequisites

- The getenforce command must be available in the system PATH.

## Script Location

```
Runner/suites/Kernel/DEBUG/Run-GetEnforce/run.sh
```

## Files

- `run.sh` - Main test script
- `Run-GetEnforce.res` - Summary result file with PASS/FAIL
- `Run-GetEnforce.log` - Full execution log.

## How it works
1. Execute the `getenforce` command to retrieve the current SELinux mode.
2. Compare the output against the expected value(Permissive).

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-13 18:38:53 - ------------------------Run-GetEnforce Starting------------------------
[INFO] 2026-03-13 18:38:53 - Output after running command: Permissive
[PASS] 2026-03-13 18:38:53 - PASS: SELinux is in Permissive mode
[INFO] 2026-03-13 18:38:53 - ------------------------Run-GetEnforce Finished------------------------
```

## Integration in CI

- Can be run standalone or via LAVA
- Result file `Run-GetEnforce.res` will be parsed by `result_parse.sh`

## Notes

- This test does not modify SELinux state; it only inspects the current configuration.

## License

SPDX-License-Identifier: BSD-3-Clause.
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.