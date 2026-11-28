# adsprpcd_service

Validates stop/start behavior for `adsprpcd.service` on the DUT. It runs
locally on a systemd-based Linux device and does not use `adb`.

## What it checks

The test verifies that the unit exists and is initially `active/running`,
stops it and checks for `inactive/dead`, then starts it and checks that it
returns to `active/running`. Unit property queries have a 5-second timeout,
command submission has a 10-second timeout, and transaction polling has a
30-second timeout. If a check fails or the runner receives a signal,
shared result cleanup cancels any owned command, restores the service when
needed, and verifies that it is active/running before cleanup completes.

## Requirements

- The DUT must use systemd and provide `systemctl` and
  `adsprpcd.service`.
- Run on a dedicated test device. Stopping this service can affect
  DSP-related functionality during the test.
- Keep `Runner/init_env` and `Runner/utils` with the suite in a testkit
  checkout.
- The suite directory must be writable for result and diagnostic files.

## Run

From the repository root:

```sh
cd Runner/suites/System/check_systemctl_start_stop_services
./run.sh
```

The LAVA definition is
`check_systemctl_start_stop_services.yaml` in this directory. The script
accepts no command-line options.

## Results, logs, and cleanup

- **PASS** means the service was active before the test, stopped successfully,
  and returned to active/running after restart.
- **FAIL** means a required state transition or command failed.
- This suite does not currently report **SKIP**.

The result file is `adsprpcd_service.res`. Command output is retained in
`adsprpcd_service.state.command.log`; the shared test library also captures console
output in a timestamped `*_stdout_*.log` file in the suite directory by
default. On detected failures or interruption after the initial state check,
cleanup verifies or restores the service and records cleanup failure if it
cannot confirm the service is active/running.
