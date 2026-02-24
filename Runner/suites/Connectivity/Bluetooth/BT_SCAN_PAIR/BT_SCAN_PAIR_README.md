# Bluetooth BT_SCAN_PAIR Test

This test automates Bluetooth scanning, pairing, and post-pair verification (via l2ping) on embedded Linux devices using BlueZ and bluetoothctl. It is designed for use in the [qcom-linux-testkit](https://github.com/qualcomm-linux/qcom-linux-testkit) test suite.

## Features

- Scans for Bluetooth devices (up to `$SCAN_ATTEMPTS` retries, default 2)
- Pairs with a device by MAC or name (up to `$PAIR_RETRIES` attempts, default 3)
- Verifies connectivity via `bt_post_pair_connect` and mandatory `l2ping` link check
- Cleans up prior pairings for repeatable CI runs
- Accepts input via:
  - Command-line argument 1: device MAC or name
  - Command-line argument 2: whitelist filter (MACs/names)
  - Environment variables:
    - `BT_MAC_ENV` or `BT_NAME_ENV`
    - `BT_WHITELIST_ENV`
  - Fallback: `bt_device_list.txt`
- Generates summary and detailed logs (`scan.log`, `found_devices.log`, `pair.log`)

## Configuration & Environment Variables

| Variable            | Default | Description                                                   |
|---------------------|---------|---------------------------------------------------------------|
| `PAIR_RETRIES`      | `3`     | Max pairing attempts per device                               |
| `SCAN_ATTEMPTS`     | `2`     | Max scan retries per device before pairing                    |
| `BT_MAC_ENV`        | ―       | Overrides direct MAC (same format as CLI argument)            |
| `BT_NAME_ENV`       | ―       | Overrides device name                                         |
| `BT_WHITELIST_ENV`  | ―       | Comma-separated MACs or names allowed for pairing             |

## Usage

```sh
# Override defaults (optional):
export PAIR_RETRIES=5
export SCAN_ATTEMPTS=3
export BT_NAME_ENV="MySpeaker"
export BT_WHITELIST_ENV="00:11:22:33:44:55,Speaker2"

# Run test (direct pairing by MAC or name):
./run.sh [DEVICE_NAME_OR_MAC] [WHITELIST]
```

### Examples

```sh
# 1. Scan-only (no target):
./run.sh

# 2. Pair by name:
./run.sh MySpeaker

# 3. Pair by MAC with whitelist:
./run.sh 00:11:22:33:44:55 12:34:56:78:9A:BC,OtherName

# 4. Use command-line and environment variables:
export BT_NAME_ENV="MySpeaker"
export BT_WHITELIST_ENV="00:11:22:33:44:55,Speaker2"
./run.sh

# 5. Override MAC via environment only:
export BT_MAC_ENV="00:11:22:33:44:55"
./run.sh
```

## Whitelist Behavior

When a whitelist is specified (CLI or `BT_WHITELIST_ENV`), only devices whose MAC or name matches entries in the comma-separated list will be paired.

```sh
# Only devices matching 'JBL_Speaker' or '12:34:56:78:9A:BC'
./run.sh "" "JBL_Speaker,12:34:56:78:9A:BC"
```

## Script Flow

1. **Initialization**: locate and source `init_env` and `functestlib.sh`.
2. **Setup**:
   - Unblock and power on `hci0`.
   - Remove all existing pairings.
3. **Candidates**: build a list of one or more `(MAC, NAME)` from:
   - CLI arg
   - Env vars
   - `bt_device_list.txt`
4. **Per-Device Loop**: for each candidate:
   a. Apply whitelist filter (if any).  
   b. Up to `$SCAN_ATTEMPTS` scans to detect device.  
   c. Up to `$PAIR_RETRIES` pairing attempts via `expect`.  
   d. If paired, call `bt_post_pair_connect` then `bt_l2ping_check`.  
   e. On success: log PASS, write `BT_SCAN_PAIR PASS`, exit.  
   f. On failure: cleanup pairing, move to next candidate.  
5. **Result**: if all candidates fail, log FAIL and write `BT_SCAN_PAIR FAIL`.

## Generated Files

- `BT_SCAN_PAIR.res`: PASS / FAIL / SKIP result code
- `scan.log`: raw scan output
- `found_devices.log`: parsed found devices
- `pair.log`: detailed pairing output and errors

## Troubleshooting

- Ensure `bluetoothctl`, `rfkill`, `expect`, and `hciconfig` are installed and in PATH.
- Confirm the DUT’s Bluetooth adapter is present and powered on.
- For headless devices, ensure target is in discoverable/pairing mode.
- Inspect `scan.log` and `pair.log` for detailed errors.
- Increase `PAIR_RETRIES` or `SCAN_ATTEMPTS` for flaky environments.

## Helper Functions (in `functestlib.sh`)

- `bt_scan_devices` – performs scan and writes `found_devices_<timestamp>.log`
- `bt_in_whitelist MAC NAME` – returns 0 if `MAC` or `NAME` matches whitelist
- `bt_pair_with_mac MAC` – interactive pairing via `expect` with retries
- `bt_post_pair_connect MAC` – attempts `bluetoothctl connect` with retries
- `bt_l2ping_check MAC RES_FILE` – verifies link via `l2ping`
- `bt_cleanup_paired_device MAC` – removes existing pairing

## Integration & CI

- Place `bt_device_list.txt` alongside `run.sh` to drive test data per DUT.
- Use LAVA YAML to deploy `bt_device_list.txt` and invoke `run.sh`.

## License

SPDX-License-Identifier: BSD-3-Clause© Qualcomm Technologies, Inc. and/or its subsidiaries.
