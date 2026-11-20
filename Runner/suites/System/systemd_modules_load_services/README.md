# systemd_modules_load_service

Validates that `systemd-modules-load.service` completed successfully during
the current boot.

## What this test checks

The test verifies that:

- `systemd-modules-load.service` is loaded.
- Its active state is `active` and sub-state is `exited`.
- Its result is `success`.
- Its `ExecMainStatus` is `0`.
- Current-boot service status and journal output are captured for diagnostics;
  the verdict comes from the service properties above.

## Validation method

The test runs on the DUT and uses `systemctl show`, `systemctl status`, and
`journalctl` when available. It does not use `adb`.

The test fails if the service is missing, not active in the expected
`active (exited)` state, has an unsuccessful result, or has a nonzero main
process status. The rendered journal wording is not part of the verdict.

## Requirements

- The DUT must use systemd and provide `systemctl`.
- The test runs with permissions that can inspect the service and its logs.
- The testkit `Runner` directory, including `init_env` and shared utilities,
  must be kept together.
- The test directory must be writable for result and log files.

## Result semantics

- **PASS** when all required service-property checks succeed.
- **FAIL** when any required check fails.

Some systemd configurations may leave this service inactive because its
start conditions are unmet, such as when no module-load configuration is
present. Under this test's stated expected result, that state is reported as
FAIL.

## Output

The test writes its result to:

```text
systemd_modules_load_service.res
```

The shared test library also captures console output in a timestamped
`*_stdout_*.log` file in the suite directory by default. The script accepts no
command-line options.

## Run

From the repository root:

```sh
cd Runner/suites/System/systemd_modules_load_services
./run.sh
```

The LAVA definition is `systemd_modules_load_service.yaml` in this directory.
