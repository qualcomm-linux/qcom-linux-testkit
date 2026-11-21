# check_libion

Checks that no paths whose name begins with `libion` are present in the DUT's
filesystem outside volatile system trees. The search starts at `/` and prunes
`/proc`, `/sys`, `/dev`, and `/run`. It runs locally and does not use `adb`.

## What it checks

The test runs `find` with a 120-second deadline from `/`, pruning volatile
system trees. Any matching path fails the test. A failed or timed-out scan
also fails because the test cannot establish that no matching path exists;
scan output and errors are retained in `check_libion.find.log`.

## Requirements

- The DUT must provide `find`.
- The test needs permission to scan the filesystem; scan errors are treated
  as a failure.
- Keep `Runner/init_env` and `Runner/utils` with the suite in a testkit
  checkout.
- The suite directory must be writable for result and diagnostic files.

## Run

From the repository root:

```sh
cd Runner/suites/System/check_libion
./run.sh
```

The LAVA definition is `check_libion.yaml` in this directory. The script
accepts no command-line options.

## Results and cleanup

- **PASS** means no `libion*` paths were found outside the pruned volatile
  system trees.
- **FAIL** means a matching path was found or the scan returned an error.
- This suite does not currently report **SKIP**.

The result file is `check_libion.res`. The scan log is
`check_libion.find.log`. The shared test library also captures console output
in a timestamped `*_stdout_*.log` file in the suite directory by default.
