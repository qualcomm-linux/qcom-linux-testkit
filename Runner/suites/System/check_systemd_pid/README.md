# check_systemd_pid

Checks that the systemd init manager is running as PID 1 on the DUT. It runs
locally on Linux and does not require `adb`.

## What it checks

The test reads `/proc/1/comm` and requires its process name to be exactly
`systemd`.

## Requirements

- The DUT must expose a readable `/proc/1/comm`.
- Keep `Runner/init_env` and `Runner/utils` with the suite in a testkit
  checkout.
- The suite directory must be writable for the result file.

## Run

From the repository root:

```sh
cd Runner/suites/System/check_systemd_pid
./run.sh
```

The LAVA definition is `check_systemd_pid.yaml` in this directory. The script
accepts no command-line options.

## Results and cleanup

- **PASS** means `/proc/1/comm` contains `systemd`.
- **FAIL** means the file cannot be read or PID 1 has another process name.
- This suite does not currently report **SKIP**.

The result file is `check_systemd_pid.res`. The shared test library captures
console output in a timestamped `*_stdout_*.log` file in the suite directory
by default. The test creates no other temporary files.
