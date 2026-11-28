# systemctl_kmod_static_nodes_state

Checks that `kmod-static-nodes.service` completed, leaving it `active (exited)`.
If an installed upstream capability or modules.devname condition prevented the
one-shot operation from running, the test reports SKIP. It also SKIPs when the
unit or systemd is unavailable in the image.

The test runs locally on the DUT.

## What this test checks

The test queries systemd for these properties:

```text
LoadState=loaded
ActiveState=active
SubState=exited
```

The service uses `RemainAfterExit=yes`, so a completed one-shot service remains
active with the `exited` substate.

## Run and result

Run `./run.sh` from this directory. The systemd query has a 5-second deadline;
its output is saved to `systemctl_kmod_static_nodes_state.systemctl.log` in
the invocation's current directory. The result is written to
`systemctl_kmod_static_nodes_state.res`.
