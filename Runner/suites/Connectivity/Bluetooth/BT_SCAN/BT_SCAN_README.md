# BT_SCAN

## Overview

`BT_SCAN` validates Bluetooth scan functionality on a Linux target.

The test verifies that:

1. `bluetoothd` is running.
2. A Bluetooth HCI adapter is available.
3. The adapter is visible to `bluetoothctl`.
4. The adapter can be powered on.
5. Bluetooth scan can discover nearby devices.

The test supports two modes:

- Generic scan mode: pass if any valid Bluetooth device is discovered.
- Target MAC mode: pass only if the requested target MAC address is discovered.

This test uses common Bluetooth helpers from:

```text
Runner/utils/lib_bluetooth.sh
```

## Test location

```text
Runner/suites/Connectivity/Bluetooth/BT_SCAN/
```

## Files

```text
BT_SCAN/
├── BT_SCAN.yaml
├── README.md
└── run.sh
```

## Dependencies

Required tools:

```text
bluetoothctl
pgrep
```

Required service:

```text
bluetoothd
```

Required runtime support:

```text
/sys/class/bluetooth/hci*
```

On CentOS, direct execution verifies `bluez`, `atheros-firmware`, and `expect`
before validation. If an attached controller exposes an all-zero address, the
shared helper uses `btmgmt public-addr` with an authoritative address from
device tree or the exact Qualcomm NVM firmware selected by the kernel. It does
not hardcode or generate a Bluetooth address.

The test automatically skips if no HCI adapter is found.

## Basic usage

Run from the test directory:

```sh
./run.sh
```

Run from anywhere inside the testkit repository:

```sh
Runner/suites/Connectivity/Bluetooth/BT_SCAN/run.sh
```

## Generic scan mode

When no target MAC is provided, the test checks generic device visibility.

```sh
./run.sh
```

Expected behavior:

```text
PASS: at least one valid Bluetooth device MAC is discovered.
FAIL: no valid Bluetooth device is discovered after scan attempts.
SKIP: no adapter/controller is available.
```

This mode is useful for basic scan sanity validation, but it depends on at least one discoverable or advertising Bluetooth device being nearby.

## Target MAC mode

To validate discovery of a specific Bluetooth device:

```sh
./run.sh --target-mac AA:BB:CC:DD:EE:FF
```

Or using environment variables:

```sh
BT_SCAN_TARGET_MAC=AA:BB:CC:DD:EE:FF ./run.sh
```

Alternative supported variable:

```sh
BT_TARGET_MAC=AA:BB:CC:DD:EE:FF ./run.sh
```

Priority:

```text
BT_SCAN_TARGET_MAC > BT_TARGET_MAC
```

Expected behavior:

```text
PASS: requested MAC is discovered.
FAIL: requested MAC is not discovered after scan attempts.
```

## Adapter selection

By default, the test auto-detects the adapter using Bluetooth helper logic.

To force a specific adapter:

```sh
./run.sh --adapter hci0
```

Or:

```sh
BT_ADAPTER=hci0 ./run.sh
```

## Scan tuning

The updated scan flow supports retries to reduce CI flakiness.

Default values:

```text
BT_SCAN_SECONDS=15
BT_SCAN_RETRIES=3
BT_SCAN_RETRY_DELAY=2
```

These values mean:

```text
Run up to 3 scan attempts.
Each scan attempt lasts 15 seconds.
Wait 2 seconds between attempts.
```

### Environment tuning

```sh
BT_SCAN_SECONDS=20 BT_SCAN_RETRIES=5 BT_SCAN_RETRY_DELAY=3 ./run.sh
```

### CLI tuning

```sh
./run.sh --scan-seconds 20 --scan-retries 5 --scan-retry-delay 3
```

## Supported options

```text
--adapter <hciX>
    Select Bluetooth adapter manually.
    Example: --adapter hci0

--target-mac <MAC>
    Validate that a specific target MAC is discovered.
    Example: --target-mac AA:BB:CC:DD:EE:FF

--scan-seconds <N>
    Scan duration per attempt in seconds.
    Default: 15

--scan-retries <N>
    Number of scan attempts before failing.
    Default: 3

--scan-retry-delay <N>
    Delay between scan attempts in seconds.
    Default: 2
```

## Supported environment variables

```text
BT_ADAPTER
    Bluetooth adapter to use.
    Example: hci0

BT_SCAN_TARGET_MAC
    Target MAC for scan validation.
    Highest priority target MAC variable.

BT_TARGET_MAC
    Alternative target MAC variable.

BT_SCAN_SECONDS
    Scan window per attempt.
    Default: 15

BT_SCAN_RETRIES
    Number of scan attempts.
    Default: 3

BT_SCAN_RETRY_DELAY
    Delay between scan attempts.
    Default: 2
```

## Result file

The test writes:

```text
BT_SCAN.res
```

Possible contents:

```text
BT_SCAN PASS
BT_SCAN FAIL
BT_SCAN SKIP
```

LAVA consumes this result file through:

```sh
$REPO_PATH/Runner/utils/send-to-lava.sh BT_SCAN.res
```

## PASS criteria

### Generic scan mode

The test passes if any valid Bluetooth MAC address is discovered during scan attempts.

Examples of acceptable discovery:

```text
AA:BB:CC:DD:EE:FF DeviceName
AA:BB:CC:DD:EE:FF <unknown>
```

A MAC-only discovery is accepted because name resolution can be delayed or unavailable on minimal images.

### Target MAC mode

The test passes only if the requested target MAC is discovered.

Matching is case-insensitive:

```text
aa:bb:cc:dd:ee:ff
AA:BB:CC:DD:EE:FF
```

Both are treated as the same MAC.

## FAIL criteria

The test fails if:

- `bluetoothd` is not running after retries.
- Adapter power-on fails.
- Target MAC is provided but not discovered.
- No Bluetooth device is discovered in generic mode after all scan attempts.

## SKIP criteria

The test skips if:

- Required dependencies are missing.
- No HCI adapter is found.
- Adapter is not visible to `bluetoothctl`.

## LAVA usage

Current YAML runs the test with defaults:

```yaml
run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Connectivity/Bluetooth/BT_SCAN/
    - ./run.sh || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh BT_SCAN.res
```

No YAML change is required for the default retry behavior.

## LAVA usage with target MAC

If a board has a known nearby Bluetooth peer, YAML can optionally export a target MAC:

```yaml
run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Connectivity/Bluetooth/BT_SCAN/
    - BT_SCAN_TARGET_MAC=AA:BB:CC:DD:EE:FF ./run.sh || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh BT_SCAN.res
```

## LAVA usage with scan tuning

Optional tuning example:

```yaml
run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Connectivity/Bluetooth/BT_SCAN/
    - BT_SCAN_SECONDS=20 BT_SCAN_RETRIES=5 BT_SCAN_RETRY_DELAY=3 ./run.sh || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh BT_SCAN.res
```

## Debugging

### Check adapter

```sh
ls /sys/class/bluetooth
```

Expected:

```text
hci0
```

### Check bluetoothd

```sh
pgrep bluetoothd
```

### Check controller visibility

```sh
bluetoothctl list
```

On some minimal images, non-interactive `bluetoothctl list` may return no controllers even when interactive `bluetoothctl` works. The test handles this using helper logic.

### Manual scan

```sh
bluetoothctl
power on
scan on
devices
scan off
quit
```

### Non-interactive scan

```sh
bluetoothctl --timeout 15 scan on
bluetoothctl devices
bluetoothctl scan off
```

## Notes

- Generic scan mode is useful for sanity testing, but it depends on nearby Bluetooth advertisements.
- Target MAC mode is more deterministic for CI.
- Some devices advertise without a resolved name. The test accepts MAC-only discovery.
- BlueZ device cache can be delayed. The updated scan helper checks both live scan output and cached device output across retries.
