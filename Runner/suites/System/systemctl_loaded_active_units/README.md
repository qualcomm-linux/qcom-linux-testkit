# systemctl_loaded_active_units

Checks that `systemd-journald.service` is loaded and active (running) on the
DUT. The test runs locally on the DUT using `systemctl`. It SKIPs when systemd
or the journal unit is not provided by the image.

## What this test checks

The test checks:

- `LoadState=loaded`
- `ActiveState=active`
- `SubState=running`

The test records the structured property output from:

```sh
systemctl show systemd-journald.service --property=LoadState \
  --property=ActiveState --property=SubState --no-pager
```

The query has a 5-second deadline. Output is saved to
`systemctl_loaded_active_units.systemctl.log` in the invocation's current
directory.

## Run and result

Run `./run.sh` from this directory. The result is written to
`systemctl_loaded_active_units.res`.
