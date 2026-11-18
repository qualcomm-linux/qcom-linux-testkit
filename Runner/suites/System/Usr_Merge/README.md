# Usr_Merge

## Purpose

Checks the DUT's root and `/usr` directory layout.

The test runs locally on the DUT and verifies that:

- `/bin`, `/sbin`, and `/lib` are symbolic links.
- `/usr/bin`, `/usr/sbin`, and `/usr/lib` exist as directories.

It also logs the output of `ls -l /` and `ls -l /usr`.

## Requirements

- Run the test on the DUT.
- The DUT must provide `ls`.
- The testkit `Runner` directory, including `init_env` and shared utilities.

## Run

From the repository root:

```sh
cd Runner/suites/System/Usr_Merge
./run.sh
```

The LAVA result ID and result file remain `check_usr_dir` and
`check_usr_dir.res`.
