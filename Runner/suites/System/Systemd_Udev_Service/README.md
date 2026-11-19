# Systemd_Udev_Service

## Purpose

Checks that `systemd-udevd.service` is active on the DUT and that its main
process runs as root.

The test queries systemd for the unit's main PID and checks its effective UID.

## Requirements

- Run this test on the DUT.
- The DUT must use systemd and provide `systemctl`.
- The testkit `Runner` directory, including `init_env` and shared utilities, must be kept together.
- The test directory must be writable so the test can create its result file.

## Run

From the repository root:

```sh
cd Runner/suites/System/Systemd_Udev_Service
./run.sh
```

The LAVA result ID remains `udev_service_info`; the result file is
`Systemd_Udev_Service.res`.
