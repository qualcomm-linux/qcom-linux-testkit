# systemctl_start_stop_service

Checks local `systemctl stop` and `systemctl start` behavior using a
test-owned transient service. This test runs on-device and does not use `adb`.

## Test procedure

The test performs the following steps for one uniquely named transient unit:

1. Creates a uniquely named transient service running `sleep`.
2. Confirms the service becomes active.
3. Stops it and confirms its `ActiveState` becomes `inactive` or `failed`.
4. Starts it again and confirms it becomes active.
5. Stops the test-owned service during result cleanup, including on failure or
   interruption.

## Requirements and safety

- Run on a dedicated DUT.
- The DUT must use systemd and provide `systemctl` and `systemd-run`.
- The test requires the testkit shared `functestlib.sh` helper
  `run_with_bounded_timeout`.
- The test needs permission to create and manage a transient systemd service.
- It does not stop platform services such as journald or logind.

## Result semantics

- **PASS** when the transient unit becomes active, stops, and restarts as
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
