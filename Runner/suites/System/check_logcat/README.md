# check_logcat

Checks that the `logcat` command is unavailable on the DUT. It runs locally on
Linux and does not use `adb`.

## What it checks

The test first checks whether `logcat` is available in `PATH`. If it is
present, the test fails without starting it. Otherwise, it invokes `logcat`
through `sh`, captures the output and exit status, and confirms the shell
returned status 127. It does not depend on localized command-not-found text.

## Requirements

- The DUT must provide a POSIX-style `sh`.
- Keep `Runner/init_env` and `Runner/utils` with the suite in a testkit
  checkout.
- The suite directory must be writable for result and diagnostic files.

## Run

From the repository root:

```sh
cd Runner/suites/System/check_logcat
./run.sh
```

The LAVA definition is `check_logcat.yaml` in this directory. The script
accepts no command-line options.

## Results and cleanup

- **PASS** means `logcat` is absent from `PATH` and the shell returns status
  127 when asked to run it.
- **FAIL** means `logcat` is present or the attempt returns another status.
- This suite does not currently report **SKIP**.

The result file is `check_logcat.res`. The shared test library captures
console output in a timestamped `*_stdout_*.log` file in the suite directory
by default. The test creates no other temporary files.
