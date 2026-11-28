# check_esrt_mount_point

Checks that the EFI System Resource Table (ESRT) sysfs directory and required
attributes are present and readable on the DUT. It runs locally on Linux and
does not use `adb`.

## What it checks

The test requires `/sys/firmware/efi/esrt` and its `entries` directory. It
also requires readable `fw_resource_count`, `fw_resource_count_max`, and
`fw_resource_version` attributes. It logs the directory listing and attribute
values for diagnosis; it does not validate the numeric values.

## Requirements

- The DUT must expose the ESRT sysfs interface.
- Run with permission to read the ESRT attributes.
- Keep `Runner/init_env` and `Runner/utils` with the suite in a testkit
  checkout.
- The suite directory must be writable for result and diagnostic files.

## Run

From the repository root:

```sh
cd Runner/suites/System/check_esrt_mount_point
./run.sh
```

The LAVA definition is `check_esrt_mount_point.yaml` in this directory. The
script accepts no command-line options.

## Results and cleanup

- **PASS** means the ESRT directory, `entries`, and all three readable
  attributes were found.
- **FAIL** means a required path or attribute is missing, has the wrong type,
  or cannot be read.
- This suite does not currently report **SKIP**.

The result file is `check_esrt_mount_point.res`. The shared test library also
captures console output in a timestamped `*_stdout_*.log` file in the suite
directory by default. The test creates no other temporary files.
