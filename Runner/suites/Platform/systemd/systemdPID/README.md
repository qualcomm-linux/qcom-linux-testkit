# systemdPID

## Overview

This script verifies that the `systemd` process is running as PID 1 on the device. It is intended for use on platforms running systemd and is part of the Qualcomm Linux Testkit.

## How It Works

- The script robustly locates and sources the `init_env` environment setup file.
- It sources `functestlib.sh` for logging and utility functions.
- It checks if the process with PID 1 is `systemd` using `ps`.
- If `systemd` is PID 1, the test passes; otherwise, it fails.

## Usage

1. Ensure the testkit environment is set up and the board is having systemd as init manager.
2. Make the script executable if not already so:
   ```sh
   chmod +x run.sh
   ```
3. Run the test:
   ```sh
   ./run.sh
   ```
4. Check the result in `systemdPID.res`:
   - `systemdPID PASS` if `systemd` is PID 1.
   - `systemdPID FAIL` if not.

## Integration

This test can be invoked by the top-level runner as:
```sh
cd Runner
./run-test.sh systemdPID
```
The `.res` file can be parsed by CI/LAVA to determine the overall test status.

## Dependencies

- `ps`
- POSIX shell (`/bin/sh`)
- `init_env` and `functestlib.sh` from the testkit

## Logging

- Uses `log_info`, `log_pass`, and `log_fail` from `functestlib.sh` for standardized output.

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear
