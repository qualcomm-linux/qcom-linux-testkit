# systemctl_unloaded_unit

Checks that a test-owned, deliberately nonexistent unit name is not found by
systemd on the DUT. The test runs locally on the DUT.

## What this test checks

The test checks the structured `LoadState` property rather than matching
localized status text:

```sh
systemctl show qcom-linux-testkit-unloaded-unit-test.service \
  --property=LoadState --no-pager
```

PASS requires `LoadState=not-found`. The query has a 5-second deadline, and its
output is saved to `systemctl_unloaded_unit.systemctl.log` in the invocation's
current directory. The test SKIPs on images that do not run systemd.

## Run and result

Run `./run.sh` from this directory. The result is written to
`systemctl_unloaded_unit.res`. The test does not inspect or modify desktop
services.
