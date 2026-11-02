# Sensors (Dynamic, DT-free)

This test validates Qualcomm SSC/ADSP sensor streaming **without relying on Device Tree**. It dynamically discovers available sensor **TYPEs** using `ssc_sensor_info` and validates selected sensors using:

- `see_workhorse` (streaming sanity / event flow)
- `ssc_drva_test` (driver validation test; optional on minimal builds)

> **Important (Overlay-only):**
> The required user-space apps (`ssc_sensor_info`, `see_workhorse`, `ssc_drva_test`) are **not** part of the base image in many builds.
> They are typically provided via a **proprietary / vendor overlay** (or equivalent overlay package).  
> This testcase is **meant to be executed only when those overlay apps are present**.

---

## Location

- `Runner/suites/Multimedia/Sensors/run.sh`
- Helper library: `Runner/utils/lib_sensors.sh` (sourced via `$TOOLS/lib_sensors.sh`)

---

## What it does

1. **Gates on ADSP remoteproc**
   - Confirms ADSP remoteproc is present and **running**
   - If not running, checks whether firmware (default `adsp.mbn`) exists
   - Uses helper functions already in `functestlib.sh`:
     - `get_remoteproc_path_by_firmware()`
     - `get_remoteproc_state()`

2. **Discovers sensors dynamically**
   - Runs `ssc_sensor_info` once and saves full output to:
     - `./logs_Sensors/ssc_sensor_info.txt` (or custom `--out`)
   - Parses **TYPE** entries where `AVAILABLE=true` (and prefers physical sensors where possible)

3. **Auto-selects sensor set**
- Default: `--profile auto`
- Auto mode selects the discovered sensor types supported by the streaming
  tools, such as `accel`, `gyro`, `mag`, and `pressure`.
- Auto mode reports SKIP when no testable data sensor is present. Service and
  test endpoint inventory is not proof of successful sensor streaming.

4. **Runs functional validation**
   - For each selected sensor TYPE:
     - runs `see_workhorse -sensor=<type> ...`
     - runs `ssc_drva_test -sensor=<type> ...` (if tool exists; otherwise SKIP that part)
   - Redirects huge tool output to per-sensor log files.
   - Prints **small progress heartbeats** to stdout for CI visibility.

5. **Writes a LAVA-friendly result file**
   - Always exits `0` (LAVA-friendly)
   - Writes `Sensors.res` with `PASS` / `FAIL` / `SKIP`

---

## Prerequisites

### Debian overlay packages and reboot

Provision `qcom-sensors-test-apps` and `sensinghub-sensors-daemon`, then reboot
before sensor discovery or streaming. This is not a Glymur-specific package
selection. The Debian mapping applies to boards using the same sensor runtime.
APT resolves the runtime dependencies and package replacements. The test does
not request development packages or manually purge the old sensor packages.

For manual image preparation using the configured Debian repositories:

```sh
sudo apt-get update
sudo apt-get install qcom-sensors-test-apps sensinghub-sensors-daemon
sudo reboot
```

For the existing opt-in testkit recovery flow, run from the Sensors directory:

```sh
./run.sh --overlay --list
# If packages were missing, the suite reports SKIP requesting a reboot.
sudo reboot
# After reconnecting, return to the same Sensors directory.
./run.sh --overlay --list
./run.sh --overlay --sensors accel,gyro --out ./logs_selected
```

Debian recovery uses the shared provider with `qli` as its default source,
matching the current public Debian package metadata. An explicit provider
source configuration still takes precedence and must supply both packages.
A complete installed package set is reused without an APT transaction. Failed
recovery reports FAIL. Without `--overlay`, Debian uses installed commands only.
Missing commands report SKIP, per-command recovery cannot bypass the explicit
package flow and its reboot tracking. Before recovery, the test records the kernel boot ID in
`.sensors-overlay-boot-id` in the testcase CWD. Same-boot reruns, even without
`--overlay` or with a different `--out`, report SKIP before discovery. Complete
an interrupted recovery with `--overlay`, then reboot and rerun. The script
never reboots the DUT itself. Preserve the state file and testcase directory
until reboot. A new checkout cannot track another checkout's installation, and
manual package changes require the operator to perform the reboot above.

On desktop distributions, an active known service is reused. Otherwise the
installed `sensors.qti.service` is preferred, with `sscrpcd.service` as the
legacy fallback. An explicit `SENSORS_SERVICE` override wins.
Inactive services are started and
checked for active state before discovery. Service startup failure reports FAIL.

Ubuntu and CentOS package mappings, and Yocto image-managed execution, are
unchanged. No sensor selection, streaming verdict, or LAVA YAML interface is
changed by the Debian packaging update.

Package references:

- [qcom-sensors Debian metadata](https://github.com/qualcomm-linux/pkg-qcom-sensors/blob/qli/debian/latest/debian/control)
- [Sensing Hub Debian metadata](https://github.com/qualcomm-linux/pkg-sensinghub/blob/qli/debian/latest/debian/control)
- [Sensing Hub daemon payload](https://github.com/qualcomm-linux/pkg-sensinghub/blob/qli/debian/latest/debian/sensinghub-sensors-daemon.install)

### Required commands (overlay apps)
- `ssc_sensor_info`
- `see_workhorse`

### Optional command
- `ssc_drva_test`  
  If missing, test still runs using `see_workhorse` and treats `ssc_drva_test` as **SKIP**.

### Common shell utilities
- `awk`, `sed`, `grep`, `sort`, `wc`, `tr`

### Files / directories
- `/etc/sensors/config` **must exist**  
  If missing, the script will **SKIP** (typically indicates a non-prop / non-overlay build).

---

## Usage

### Show help
```sh
./run.sh --help
```

### List discovered sensor TYPEs and exit
```sh
./run.sh --list
```

### Run with auto-detection (default)
```sh
./run.sh
```

### Run a profile preset
```sh
./run.sh --profile basic
./run.sh --profile vision
./run.sh --profile core
./run.sh --profile all --strict 0    # debug / long run
```

Profiles:
- `basic` / `core`: `accel,gyro`
- `vision`: `accel,gyro,mag,pressure`
- `all`: all discovered types (debug)
- `auto` (default): tests discovered supported data sensor types only

### Run an explicit list of sensors
```sh
./run.sh --sensors accel,gravity,gyro,mag,pressure
./run.sh --sensors ' accel, gyro, accel '  # trims whitespace and tests duplicates once
./run.sh --sensors accel,gyro,tilt --strict 0
```

CSV names are checked individually against the current available inventory.
Ordering is preserved, and `--sensors` overrides the profile. Empty lists, empty
fields, embedded whitespace and wildcard/path characters are rejected before
discovery or package/service operations. Names may contain letters, digits,
underscores and hyphens, and must start with a letter, digit or underscore.

For example, `--sensors accel,pressur --strict 0` tests `accel` if available and
records the misspelled `pressur` as SKIP. It does not silently substitute
`pressure`. If all requested types are missing, the result is SKIP, never PASS.
With `--strict 1`, any missing requested type makes the suite FAIL before
streaming starts. Strict mode does not require sensors in automatic mode.

### Control durations / progress heartbeat
```sh
./run.sh --see-duration 5 --drva-duration 10 --hb 5
```

### Output directory
```sh
./run.sh --out ./logs_Sensors
```

---

## Parameters

### CLI options (most common)
- `--overlay`
  Use the existing optional Sensors package-provider flow on supported desktop
  distributions. Image-managed runs continue using provisioned components.
- `--out <directory>`
  Evidence directory (default: `./logs_Sensors`, environment: `OUT_DIR`).
- `--help` / `-h`
  Show usage without running sensor validation.
- `--list`  
  List discovered sensor TYPEs and exit 0
- `--profile <auto|basic|core|vision|all>`  
  Select preset sensors list
- `--sensors <csv>`  
  Comma-separated sensor TYPEs, normalized and deduplicated as described above.
  There is no environment equivalent for this option or `--profile`/`--list`.
- `--see-duration <sec>`  
  Duration for `see_workhorse` (default: `5`)
- `--drva-duration <sec>`  
  Duration for `ssc_drva_test` (default: `10`)
- `--hb <sec>`  
  Heartbeat interval printed to stdout (default: `5`)
- `--strict <0|1>`  
  Fail when an explicitly selected or named-profile sensor is absent (default:
  `1`). Auto mode always uses the discovered present-sensor set.

### Environment overrides
- `OUT_DIR` (same as `--out`)
- `SEE_DURATION`
- `DRVA_DURATION`
- `HB_SECS`
- `STRICT_REQUIRED`
- `SENSORS_TIMEOUT_PAD_SECS`  
  Extra timeout pad added beyond duration (default is handled in lib; keep small for CI)
- `SENSORS_DISPLAY_EVENTS`  
  Passed to `see_workhorse -display_events=` (default: `1`)
- `SENSORS_DRVA_NUM_SAMPLES`  
  Extra knob for accel in `ssc_drva_test` (default set in run.sh to `325`)
- `SENSORS_SERVICE`
  Explicit service override. Otherwise reuse an active known service, prefer an
  installed `sensors.qti.service` and fall back to `sscrpcd.service`.

Examples combining existing package/service and selection options:

```sh
./run.sh --overlay --list
./run.sh --overlay --sensors accel,gyro --out ./logs_selected
STRICT_REQUIRED=0 ./run.sh --profile vision
```

---

## Output / logs

All heavy tool output is redirected to files under `--out` (default `./logs_Sensors`):

- `ssc_sensor_info.txt`
- `targets.txt`, reset after valid argument parsing and populated only with selected
  available types. Old per-tool logs may remain in a reused directory, so use
  the current target list, stdout and `Sensors.res` to identify executed checks.
- `see_workhorse_<sensor>.log` (e.g. `see_workhorse_gyro.log`)
- `ssc_drva_test_<sensor>.log` (e.g. `ssc_drva_test_accel.log`)

The console shows:
- high-level progress
- periodic heartbeat lines like:
  - `see_workhorse(accel) running... 5/5s (log: ...)`
- final summary:
  - `Summary (checks): pass=X fail=Y skip=Z (logs in ...)`
  - Counts describe individual tool checks and missing selections, not sensors.

Result file:
- `Sensors.res` in the testcase directory
  - `Sensors PASS`
  - `Sensors FAIL`
- `Sensors SKIP`

## Verdict policy

- **PASS, functional:** at least one selected sensor passes streaming validation
  and no check fails. A non-strict run may contain explicitly reported missing
  sensor SKIPs. Missing sensors are never counted as passing checks.
- **PASS, list only:** explicit `--list` completes an inventory query. Its result
  message states that streaming was not validated. This exception never applies
  to ordinary or explicit-sensor streaming runs.
- **FAIL:** a required runtime component is broken, a discovered streamable
  sensor fails functional validation, or an explicitly requested/named-profile
  sensor is absent while strict mode is enabled. Invalid CLI input, failed
  discovery, or discovery output without TYPE entries also fails.
- **SKIP:** required optional image prerequisites are unavailable, no testable
  sensors are available in automatic mode, or all selected sensors are missing
  with `--strict 0`. Inventory, package readiness and a running ADSP cannot turn
  an empty streaming selection into PASS.
- **Optional driver tool:** a missing `ssc_drva_test` is recorded as SKIP, not
  PASS. Successful `see_workhorse` streaming can still pass the suite, preserving
  minimal-image support. Driver-tool failures override earlier streaming passes.

The shared result lifecycle resets the previous result and retains FAIL
precedence. No package, service, timeout duration or YAML interface is changed
by the selection fix. Apply the same policy on Yocto, Debian, Ubuntu and CentOS.

---

## Result parsing behavior

### `see_workhorse`
The script requires successful process exit and a final PASS log marker:
- `PASS see_workhorse ...`
- `FAIL see_workhorse ...`

The log may contain duplicate markers. The last PASS/FAIL marker is used.
Empty logs, diagnostic-only output, missing markers, nonzero process status and
timeouts do not count as successful streaming, even if an earlier PASS exists.
An expired deadline remains a failure even if the client exits zero after the
timeout signal. The existing timeout duration and signal sequence are unchanged.

### `ssc_drva_test`
- If `ssc_drva_test` binary is missing → treated as **SKIP** for that sensor.
- If the log begins with `FAIL` → treated as **FAIL** (defensive).
- Otherwise, return code `0` → PASS.

---

## Troubleshooting

### `1970-01-01` timestamps
If system time is not set (no RTC sync), logs may show epoch timestamps. This does not affect functional PASS/FAIL.

### `diag: failed to connect to diag socket`
Some builds print diagnostic socket warnings in `see_workhorse` output.  
This is captured in the log file. The test still passes as long as the final PASS marker is present.

### `ssc_sensor_info` outputs nothing / parsing fails
Failed execution or output without TYPE entries is FAIL. A successful query
containing only unavailable sensors produces no streaming targets, so automatic
mode reports SKIP and an explicit strict selection reports FAIL.

Check:
- overlay apps installed and runnable
- `/etc/sensors/config` exists
- ADSP remoteproc is running (`/sys/class/remoteproc/.../state`)

---
