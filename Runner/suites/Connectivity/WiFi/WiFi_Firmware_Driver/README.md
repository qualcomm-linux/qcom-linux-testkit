# WiFi Firmware Driver

## Overview

`WiFi_Firmware_Driver` validates that the target has WiFi firmware available, that the expected driver/module visibility is present, and that the kernel log does not show WiFi probe or runtime failures.

This test is useful for verifying basic WiFi firmware and driver readiness before running connection tests.

## What the test validates

- Required command-line utilities are available.
- WiFi firmware is found under `/lib/firmware`, including readable symlinks
  and kernel-supported `.xz` or `.zst` compressed files.
- Each WiFi family is discovered from bound runtime drivers or matching device
  aliases in the running kernel metadata, including DT-instantiated devices.
  Installed firmware directories alone never select a family.
- Family-specific runtime preparation succeeds.
- The family has a bound driver, including built-in drivers without lsmod entries.
- A PHY bound to that family appears within the readiness timeout, default 60 seconds.
  Generic firmware messages or a sibling radio do not prove readiness.
- Kernel logs do not show WiFi probe/runtime failures.

## Dependencies

The target should provide:

- `find`
- `grep`
- `readlink`, `sort`, `mktemp`, `tr`
- `modprobe` only when an unloaded runtime driver needs activation
- `cat`
- `stat`
- `awk`
- `iw` when a captured driver country-rejection fallback needs validation

The script sources the common test environment through `init_env`, then uses helpers from:

- `functestlib.sh`
- `lib_connectivity.sh`

## Usage

Run from the test directory:

```sh
./run.sh
```

No mandatory CLI arguments are required.

The test continues as soon as the radio is ready. For slower startup, use
`./run.sh --wait-timeout 120` or set `WAIT_TIMEOUT` in the LAVA definition.
The timeout accepts whole seconds from 1 to 3600. Missing readiness at the
deadline and captured driver faults remain failures.

## Optional environment variables

| Variable | Default | Description |
|---|---|---|
| `WIFI_FW_PROBE_LOG_DIR` | Unique `wifi-firmware.*` directory in CWD | Directory used for WiFi probe/runtime log evidence |
| `WIFI_FW_PROBE_LOG_TAG` | `WiFi_Firmware_Driver/probe` | Log tag used when reporting probe checks |
| `WIFI_FW_LOAD_LOG_TAG` | `WiFi_Firmware_Driver/firmware` | Log tag used when reporting firmware load checks |

Example:

```sh
WIFI_FW_PROBE_LOG_DIR=./fw_probe_logs ./run.sh
```

## LAVA usage

The YAML runs the test directly:

```sh
./run.sh --wait-timeout "${WAIT_TIMEOUT}" || true
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

The result remains beside `run.sh` for both Runner-directory launches and
direct suite-directory execution. Each invocation clears the previous result.
Logs and scratch files remain under the invocation CWD.

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
- No supported WiFi family is identified from runtime drivers or device aliases.
- Required kernel health or regulatory fallback evidence is unavailable.

## FAIL criteria

The test fails when:

- A runtime WiFi family has no readable provisioned firmware asset.
- Family-specific runtime preparation fails.
- Expected family modules are not visible.
- Firmware load/use evidence is not found.
- WiFi probe/runtime failures are detected in the kernel log.

## Notes

- The test currently detects ath12k, ath11k, and ath10k firmware families through common connectivity helpers.
- This test does not validate association to an access point or IP assignment. Use `WiFi_Dynamic_IP` or `WiFi_Manual_IP` for connection validation.

An unavailable global `regulatory.db` lookup is retained in
`wifi_regulatory_warnings.log` and printed as `WIFI-REGULATORY`. cfg80211 can
use its world regulatory domain, so this message alone does not stop driver
and PHY validation. A malformed database, device firmware failure or captured
driver crash remains a failure. A runtime PHY confirms driver readiness,
it does not prove that the regulatory database loaded or that association works.
The original messages remain in `dmesg_errors.log` and the general probe suite
can report the image provisioning gap independently.

Documented country-setting or random-MAC fallbacks pass only when the affected
radio has a bound driver, PHY and valid MAC. Country-setting fallback also
requires usable regulatory channels. The test does not change the country.
Confirmed driver crashes remain FAIL even after recovery.
