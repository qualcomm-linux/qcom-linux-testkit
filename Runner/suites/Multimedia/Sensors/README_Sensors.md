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
   - If `mag` or `pressure` is present → **Vision-like** profile: `accel,gyro,mag,pressure`
   - Else → **Core-like** profile: `accel,gyro`

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
- `auto` (default): picks core/vision based on presence of `mag`/`pressure`

### Run an explicit list of sensors
```sh
./run.sh --sensors accel,gyro,tilt --strict 0
```

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
- `--list`  
  List discovered sensor TYPEs and exit 0
- `--profile <auto|basic|core|vision|all>`  
  Select preset sensors list
- `--sensors <csv>`  
  Comma-separated list of sensor TYPEs to test
- `--see-duration <sec>`  
  Duration for `see_workhorse` (default: `5`)
- `--drva-duration <sec>`  
  Duration for `ssc_drva_test` (default: `10`)
- `--hb <sec>`  
  Heartbeat interval printed to stdout (default: `5`)
- `--strict <0|1>`  
  Require `accel` and `gyro` to exist (default: `1`)

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

---

## Output / logs

All heavy tool output is redirected to files under `--out` (default `./logs_Sensors`):

- `ssc_sensor_info.txt`
- `see_workhorse_<sensor>.log` (e.g. `see_workhorse_gyro.log`)
- `ssc_drva_test_<sensor>.log` (e.g. `ssc_drva_test_accel.log`)

The console shows:
- high-level progress
- periodic heartbeat lines like:
  - `see_workhorse(accel) running... 5/5s (log: ...)`
- final summary:
  - `Summary: pass=X fail=Y skip=Z (logs in ...)`

Result file:
- `Sensors.res` in the testcase directory
  - `Sensors PASS`
  - `Sensors FAIL`
  - `Sensors SKIP`

---

## Result parsing behavior

### `see_workhorse`
The script determines PASS/FAIL primarily from log markers:
- `PASS see_workhorse ...`
- `FAIL see_workhorse ...`

The log may contain duplicate PASS lines; verdict is based on the **last PASS/FAIL marker**.

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
This is treated as **SKIP** (no usable inventory → no further tests).

Check:
- overlay apps installed and runnable
- `/etc/sensors/config` exists
- ADSP remoteproc is running (`/sys/class/remoteproc/.../state`)

---
