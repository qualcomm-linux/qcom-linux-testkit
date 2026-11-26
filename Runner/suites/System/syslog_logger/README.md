# syslog_logger

Verifies that a message written with `logger` is recorded in
`/var/log/messages`. The test runs locally on the DUT and does not use `adb`.

## What this test checks

The test writes a uniquely identifiable message using the tag:

```text
syslog logger
```

The test waits up to 15 seconds for that message, including its unique run
token, to appear in `/var/log/messages`.

## Requirements

- `logger`, `awk`, and `/var/log/messages` must be available to the test.
- Run with permissions that allow writing a logger message and reading the
  log file.

## Result semantics

- **PASS** when the message created by this run is found in the log file.
- **FAIL** when the message cannot be written or is not found before timeout.

## Output

The test writes `syslog_logger.res` in the suite directory.
