# boot_device_to_shell

Checks from the connected LAVA shell that systemd is PID 1 and reports the
system state as `running`, `degraded`, or `starting`. This confirms shell access
and systemd presence; it does not assert full boot readiness or that a
particular systemd target is active. A shell can be available while the target
image is still completing systemd startup.

## Run

From this directory, run:

```sh
./run.sh
```

The systemd query has a 5-second deadline. Its output is saved to
`boot_device_to_shell.systemctl.log` in the invocation's current directory.

## Result

The result is written to `boot_device_to_shell.res`. PASS requires PID 1 to be
`systemd` and `systemctl is-system-running` to report `running`, `degraded`, or
`starting`.
