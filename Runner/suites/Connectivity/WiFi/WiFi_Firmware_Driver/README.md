# WiFi Firmware Driver

## Overview

`WiFi_Firmware_Driver` validates that the target has WiFi firmware available, that the expected driver/module visibility is present, and that the kernel log does not show WiFi probe or runtime failures.

This test is useful for verifying basic WiFi firmware and driver readiness before running connection tests.

## What the test validates

- Required command-line utilities are available.
- The SoC model is detected from device tree when available.
- WiFi firmware is found under `/lib/firmware`, including readable symlinks
  and kernel-supported `.xz` or `.zst` compressed files.
- The WiFi firmware family is detected.
- Family-specific runtime preparation succeeds.
- Family-specific modules are visible.
- Firmware load or use evidence exists in the kernel log.
- Kernel logs do not show WiFi probe/runtime failures.

## Dependencies

The target should provide:

- `find`
- `grep`
- `modprobe`
- `lsmod`
- `cat`
- `stat`
- `awk`

The script sources the common test environment through `init_env`, then uses helpers from:

- `functestlib.sh`
- `lib_connectivity.sh`

## Usage

Run from the test directory:

```sh
./run.sh
```

No mandatory CLI arguments are required.

## Optional environment variables

| Variable | Default | Description |
|---|---|---|
| `WIFI_FW_PROBE_LOG_DIR` | `./wifi_firmware_driver_dmesg` | Directory used for WiFi probe/runtime log evidence |
| `WIFI_FW_PROBE_LOG_TAG` | `WiFi_Firmware_Driver/probe` | Log tag used when reporting probe checks |
| `WIFI_FW_LOAD_LOG_TAG` | `WiFi_Firmware_Driver/firmware` | Log tag used when reporting firmware load checks |

Example:

```sh
WIFI_FW_PROBE_LOG_DIR=./fw_probe_logs ./run.sh
```

## LAVA usage

The YAML runs the test directly:

```sh
./run.sh || true
```

The final test result is emitted through:

```sh
$REPO_PATH/Runner/utils/send-to-lava.sh WiFi_Firmware_Driver.res
```

## Output files

The test writes the result file:

```text
WiFi_Firmware_Driver.res
```

Depending on helper behavior and failure mode, WiFi probe/runtime log artifacts may be collected under the configured probe log directory.

## PASS criteria

The test passes when:

1. Required tools are available.
2. WiFi firmware is detected.
3. Family-specific preparation and module checks pass.
4. Firmware load/use evidence is found.
5. No WiFi probe/runtime failures are detected.

## SKIP criteria

The test skips when:

- Required tools are missing.
- No supported uncompressed, `.xz`, or `.zst` WiFi firmware file or readable
  symlink is found under `/lib/firmware`.

## FAIL criteria

The test fails when:

- Family-specific runtime preparation fails.
- Expected family modules are not visible.
- Firmware load/use evidence is not found.
- WiFi probe/runtime failures are detected in the kernel log.

## Notes

- The test currently detects ath12k, ath11k, and ath10k firmware families through common connectivity helpers.
- This test does not validate association to an access point or IP assignment. Use `WiFi_Dynamic_IP` or `WiFi_Manual_IP` for connection validation.
