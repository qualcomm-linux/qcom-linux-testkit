# checkFailedServices Validation Test

## Overview

This test script checks if any mandatory service is not failed on the device. It is intended for use on platforms running systemd and is part of the Qualcomm Linux Testkit.

## Usage

1. Ensure the testkit environment is set up and the board has systemd as init manager.
2. Make the script executable if not already so:
   ```sh
   chmod +x run.sh
   ```
3. Run the test:
   ```sh
   ./run.sh
   ```
4. Check the result:
   - If the test passes, `checkFailedServices.res` will contain `checkFailedServices PASS`.
   - If the test fails, `checkFailedServices.res` will contain `checkFailedServices FAIL` and the failed services will be logged.

## Integration

This test can be invoked by the top-level runner as:
```sh
cd Runner
./run-test.sh checkFailedServices
```
The `.res` file can be parsed by CI/LAVA to determine the overall test status.

## Result Format

- **PASS**: All monitored services are present and not in failed state.
- **FAIL**: List of failed or missing monitored services.

The result is written to `checkFailedServices.res` in the same directory.

## Dependencies

- **systemctl**: Must be available and functional (systemd-based system).
- **POSIX shell**: Script is written for `/bin/sh`.

## Logging

- Uses `log_info`, `log_pass`, and `log_fail` from `functestlib.sh` for standardized output.

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear
