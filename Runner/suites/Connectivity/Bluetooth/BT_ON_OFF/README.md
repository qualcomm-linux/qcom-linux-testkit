# Bluetooth power-cycle validation

`BT_ON_OFF` verifies that a BlueZ controller can transition from powered on to
powered off and back on without changing the selected adapter.

## Usage

Run with automatic adapter discovery:

```sh
./run.sh
```

Select an adapter and tune the retry delays:

```sh
./run.sh \
    --adapter hci0 \
    --power-cycle-delay 10 \
    --power-on-attempts 2 \
    --power-on-retry-delay 10 \
    --restart-service-on-retry 1
```

The command-line adapter overrides `BT_ADAPTER`. When neither is set, the
shared Bluetooth helper selects a usable runtime controller.

On CentOS, direct execution verifies the minimal `bluez`, `atheros-firmware`,
and `expect` package set before runtime validation. Existing complete images
avoid package-manager and network work. Debian and Ubuntu retain their existing
preparation behavior, while Yocto continues to use image-provided components.

## Validation contract

The test uses the exact BlueZ `Powered: yes|no` property as its power-state
evidence. A transition passes only after two consecutive observations match the
requested state. This avoids accepting a transient or stale response while
BlueZ and the UART controller are settling.

`PowerState` and `hciconfig` state are retained as diagnostics only. For
example, `PowerState: on` or `UP RUNNING` can be present while BlueZ reports
`Powered: no`, so neither is accepted as proof of a successful power-on.

Expected success markers include:

```text
Power OFF completed with consecutive Powered=no confirmations
Power ON completed with consecutive Powered=yes confirmations
```

The test fails when the requested stable state is not observed within the
bounded helper attempts. If a power-on attempt fails, the suite records
diagnostics and can perform the configured controlled recovery before retrying.
An all-zero runtime BD address remains a failure. Recovery uses
`btmgmt public-addr` with an authoritative address read from the adapter
device-tree node or from the exact Qualcomm NVM firmware selected by the kernel.
It never hardcodes or generates an address. If firmware was newly provisioned
and the HCI controller remains at `00:00:00:00:00:00`, reboot the target and
rerun the test.

## LAVA

The packaged definition exposes these parameters:

- `BT_ADAPTER`
- `BT_POWER_CYCLE_DELAY`
- `BT_POWER_ON_ATTEMPTS`
- `BT_POWER_ON_RETRY_DELAY`
- `BT_RESTART_SERVICE_ON_RETRY`
- `BT_RUNTIME_READY_WAIT`
- `BT_RUNTIME_RECOVERY_WAIT`
- `BT_RUNTIME_RECOVERY_ATTEMPTS`

The result is written to `BT_ON_OFF.res` and sent to LAVA as `BT_ON_OFF`.

## Running without systemd

An installed systemctl binary does not imply a running systemd manager. On a
non-systemd boot, the test reuses healthy image-provided D-Bus/BlueZ or makes
one daemon startup attempt. Missing daemon assets produce SKIP. A failed startup
or an unusable declared controller remains FAIL. The test never applies a zero
Bluetooth address.

Only daemon processes started by this invocation are stopped during cleanup.
Existing daemons and sockets are retained. Startup logs are stored in a unique
`bluetooth-runtime.*` directory in CWD and printed if readiness fails. The kbdev
plan sets `TESTKIT_IMAGE_ONLY=1` to disable package installation and recovery.

Validation restores the selected adapter's original power/discovery state and
recorded Bluetooth rfkill soft state. Healthy unchanged state is reused.
Confirmed failure to stop discovery or restore owned state fails the final
result. Minimal images with unavailable optional discovery state report it as
unverified. Paired devices and the persistent peer cache are preserved.
Discovery requires a fresh observation or an address newly added during the
scan, an unchanged cached peer cannot satisfy the test. Confirmed fatal firmware
or kernel fault evidence is retained separately from missing success markers.
