# CAN internal loopback validation

`CAN_Internal_Loopback_Validation` sends and receives exact SocketCAN frames
through an auto-detected or explicitly selected physical CAN controller in
internal-loopback mode.

For safety, the suite requires the interface to be initially down. It configures
the selected interface with a default 500 kbit/s arbitration bitrate and a
2 Mbit/s CAN FD data bitrate. An active CAN interface is never taken over
automatically. A unique physical interface meeting these readiness conditions
is selected automatically. Multiple eligible interfaces require an explicit
override.

The suite restores the interface to down and restores the original bitrate,
data bitrate, CAN FD, and loopback settings when they were initially exposed.
Linux does not provide a portable operation to return a previously unconfigured
physical CAN interface to an unconfigured timing state. In that case the test
leaves the interface down with the test bitrate configured and reports that
state in stdout.

Classic mode validates both an 11-bit identifier and a 29-bit extended
identifier. Automatic mode attempts a CAN-FD frame using the default data
bitrate and records a clean skip when the controller rejects CAN FD. Every case
requires RX and TX packet counters to increase and error counters not to
increase when sysfs exposes those counters.

## Prepare and run

Run automatic CAN loopback with the default bitrates:

```sh
cd Runner/suites/Kernel/Baseport/CAN_Internal_Loopback_Validation
./run.sh
```

Override the selected interface or timing when required:

```sh
./run.sh --interface can0 --mode auto --bitrate 500000 --dbitrate 2000000
```

Use `--interface` or `CAN_INTERFACE` to override automatic discovery.
`CAN_BITRATE` and `CAN_DBITRATE` override the timing defaults. CLI options take
precedence over environment variables.

On Debian, Ubuntu, and CentOS, the runner recovers the mapped `can-utils` and
IP-route packages when they are missing. Yocto and qcom-distro remain
image-managed: the runner does not install packages there and skips cleanly
when `candump`, `cansend`, or `ip` is absent.

The suite first discovers a unique, down physical CAN interface before it
attempts host-distro package recovery, so targets without CAN hardware do not
trigger package-manager or network work.

Temporary command and frame evidence is removed when the run finishes. The
live log retains the per-object failure analysis needed for remote debugging.

## Result policy

- `PASS`: all applicable exact frames are observed, packet counters increase,
  error counters remain stable, and state restoration succeeds.
- `FAIL`: the selected object is not physical CAN hardware, configuration,
  transfer, frame validation, or restoration fails.
- `SKIP`: no unique ready physical interface is discovered and no override is
  provided, required tools cannot be recovered, the interface is active, or
  CAN FD is unavailable during automatic mode.

Reference: [Qualcomm Linux CAN guide](https://docs.qualcomm.com/doc/80-70023-8/topic/can.html)
