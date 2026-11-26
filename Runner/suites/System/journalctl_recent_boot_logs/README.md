# journalctl_recent_boot_logs

Validates that `systemd-journald.service` is active and that recent system
journal logs can be retrieved using `journalctl`. The test runs locally on the
DUT.

## What this test checks

1. Runs `systemctl status systemd-journald`.
2. Runs `systemctl status systemd-journald.service`.
3. Uses bounded `systemctl show` output to verify that
   `systemd-journald.service` is loaded and active.
4. Retrieves up to 50 recent current-boot log entries with:
   `journalctl --boot --no-pager --lines=50`.

Each systemctl and journalctl command has a 30-second deadline using the
shared `run_with_bounded_timeout` helper. Command output is retained in the
suite directory for diagnosis. If the test receives a signal while a command
is running, it cancels the command and records a FAIL result.

## Requirements

- The target must have booted with systemd.
- `systemctl`, `journalctl`, and the testkit shared utilities must be available.
- Run with permissions that allow systemd status and journal access. In the
  intended LAVA setup, run the test as root.
- The suite directory must be writable for result, log, and artifact files.

## Result semantics

- **PASS** when both status commands succeed, `systemd-journald.service` is
  present and active, and `journalctl` retrieves non-empty current-boot logs.
- **FAIL** if a required command is missing or fails, a command times out, the
  service is unavailable or inactive, or no journal entries can be retrieved.

The test does not start, stop, or modify the journald service.

## Output

The testcase result is written to:

`journalctl_recent_boot_logs.res`

Expected result format:

```text
journalctl_recent_boot_logs PASS
journalctl_recent_boot_logs FAIL
```
