# Boot health check

Checks that the booted image provides a root shell. Logs the running kernel,
architecture, PID 1 and root mount, then writes `Reboot_health_check.res` beside
`run.sh`. Each invocation replaces the previous result, whether launched from
Runner or directly from the suite directory.
It does not reboot, install a boot hook or maintain retry counters. Configure
boot retries in the LAVA job. The historical `setup_systemd.sh` is not needed.

```sh
cd Runner/suites/Kernel/Baseport/Reboot_health_check
./run.sh
```

A root shell is PASS, an unprivileged shell is FAIL. This result does not claim
network, peripheral or reboot-cycle validation. Systemd is not required.
