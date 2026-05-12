# Toggle-SetEnforce

## Overview
The `Toggle-SetEnforce` test case validates dynamic toggle of SELinux enforcement mode at runtime, ensuring OS can be switched between multiple modes and then return to 'Permissive' mode.

## Test Goals

- Verify the current SELinux enforcement status.
- Validate that SELinux can be switched between multiple modes during runtime.
- Ensure SELinux can be successfully toggled back to Permissive mode.

## Prerequisites

- The getenforce and setenforce command must be available in the system PATH.

## Script Location

```
Runner/suites/Kernel/DEBUG/Toggle-SetEnforce/run.sh
```

## Files

- `run.sh` - Main test script
- `Toggle-SetEnforce.res` - Summary result file with PASS/FAIL
- `Toggle-SetEnforce.log` - Full execution log.

## How it works
1. Execute the `getenforce` command to retrieve the current SELinux mode.
2. If the system is initially in Permissive mode:
   - Execute setenforce 1 to switch SELinux to Enforcing.
   - Verify and log the new state.
3. Execute setenforce 0 to switch SELinux back to Permissive.
4. Validate the final state.

## Usage

Run the script directly. No iterations or special arguments are required for this basic test.

```bash
./run.sh
```

## Example Output

```
[INFO] 2026-03-13 19:54:15 - ------------------------Toggle-SetEnforce Starting------------------------
[INFO] 2026-03-13 19:54:15 - Running command 'setenforce 1'
[INFO] 2026-03-13 19:54:15 - Output after running command: Enforcing
[INFO] 2026-03-13 19:54:15 - Running command 'setenforce 0'
[INFO] 2026-03-13 19:54:15 - Output after running command: Permissive
[PASS] 2026-03-13 19:54:15 - PASS: Successfully toggled from Permissive to Permissive
[INFO] 2026-03-13 19:54:15 - ------------------------Toggle-SetEnforce Finished------------------------
```

## Integration in CI

- Can be run standalone or via LAVA
- Result file `Toggle-SetEnforce.res` will be parsed by `result_parse.sh`

## Notes

- This test modifies the SELinux enforcement state temporarily during execution.
- The final state is always restored to Permissive.

## License

SPDX-License-Identifier: BSD-3-Clause.
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.