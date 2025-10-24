# systemctlStartStop

## Overview

This script tests the ability to stop and start the `systemd-user-sessions.service` using `systemctl`. It is intended for use on platforms running systemd and is part of the Qualcomm Linux Testkit.

## How It Works

- The script robustly locates and sources the `init_env` environment setup file.
- It sources `functestlib.sh` for logging and utility functions.
- It checks if `systemd-user-sessions.service` is active.
- It attempts to stop the service and verifies it is stopped.
- It then starts the service again and verifies it is running.
- Results are logged and written to `systemctlStartStop.res`.

## Usage

1. Ensure the testkit environment is set up and the board is running systemd.
2. Make the script executable if not already so:
   ```sh
   chmod +x run.sh
   ```
3. Run the test(requires sudo access):
   ```sh
   ./run.sh
   ```
4. Check the result in `systemctlStartStop.res`:
   - `systemctlStartStop PASS` if the service was stopped and started successfully.
   - `systemctlStartStop FAIL` if any step failed.

## Integration

This test can be invoked by the top-level runner as:
```sh
cd Runner
./run-test.sh systemctlStartStop
```
The `.res` file will be parsed by CI/LAVA to determine the overall test status.

## Dependencies

- `systemctl` (systemd-based system)
- POSIX shell (`/bin/sh`)
- `init_env` and `functestlib.sh` from the testkit

## Logging

- Uses `log_info`, `log_pass`, and `log_fail` from `functestlib.sh` for standardized output.

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear
