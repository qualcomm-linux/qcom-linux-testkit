# systemctl_start_stop_service

Checks local `systemctl stop` and `systemctl start` behavior using a
uniquely named, test-owned temporary systemd unit file. This test runs on the
DUT.

## Test procedure

The test performs the following steps for one uniquely named temporary unit:

1. Writes a unit file under `/run/systemd/system` for a service running
   `sleep`.
2. Runs `systemctl daemon-reload`, starts the service, and confirms it becomes
   active and running.
3. Stops it and confirms its `ActiveState` is `inactive` and its `SubState` is
   `dead`.
4. Starts it again and confirms it becomes active and running.
5. Stops the test-owned service, removes its unit file, and reloads systemd
   during cleanup, including on failure or interruption.

## Requirements and safety

- Run on a dedicated DUT.
- The DUT must use systemd and provide `systemctl` and `sleep`.
- The test needs permission to write to `/run/systemd/system`.
- The test requires the testkit shared `functestlib.sh` helper
  `run_with_bounded_timeout`.
- It does not stop platform services such as journald or logind.

## Result semantics

- **PASS** when the temporary unit becomes active, stops, and restarts as
  expected.
- **FAIL** if required commands are unavailable, a command fails or times out,
  or the unit does not reach the expected state.

## Output

The test writes its final result to:

```text
systemctl_start_stop_service.res
```

Expected result format:

```text
systemctl_start_stop_service PASS
systemctl_start_stop_service FAIL
```
