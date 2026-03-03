# Probe Failure Check Test

This directory contains the **Probe_Failure_Check** test suite for the Qualcomm Linux Testkit. This test verifies that no device driver probe errors occurred during the most recent system boot.

## Test Overview

- **Test Name:** Probe_Failure_Check
- **Purpose:** Scan the kernel log for any "probe failed", "failed to probe", or "probe error" messages, indicating a driver failed to initialize.
- **Results:**
  - On success: a result file `Probe_Failure_Check.res` is written with `Probe_Failure_Check PASS`.
  - On failure: a `probe_failures.log` file is created containing the matching log entries, and `Probe_Failure_Check.res` is written with `Probe_Failure_Check FAIL`.

## Files

- **run.sh**: The main test script. Execute to perform the check.
- **probe_failures.log**: (Generated on failure) Contains all discovered probe failure messages.
- **Probe_Failure_Check.res**: Test result file with PASS or FAIL.

## Usage

1. Ensure the testkit environment is set up and the board has booted.
2. From this directory, make sure the script is executable:
   ```sh
   chmod +x run.sh
   ```
3. Run the test:
   ```sh
   ./run.sh
   ```
4. Check the result:
   - If the test passes, look for `Probe_Failure_Check.res` containing `PASS`.
   - If the test fails, examine `probe_failures.log` for details.

## Integration

This test integrates with the top-level runner in `Runner/run-test.sh` and can be invoked as:

```sh
cd Runner
./run-test.sh Probe_Failure_Check
```

The `.res` file will be parsed by CI/LAVA to determine overall test status.

## Dependencies

- **shell**: POSIX compliant (`/bin/sh`)
- **journalctl** (optional): for collecting kernel logs. Falls back to `dmesg` or `/var/log/kern.log` if unavailable.
- **grep**: for pattern matching.

## Shellcheck Compliance

The script is tested with `shellcheck` and disables SC2039 and SC1091 where sourcing dynamic paths.

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause