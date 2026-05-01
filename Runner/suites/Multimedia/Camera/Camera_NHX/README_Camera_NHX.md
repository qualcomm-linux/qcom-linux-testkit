# Camera_NHX

Camera NHX validation test for the Qualcomm CAMX proprietary camera stack. This test runs `nhx.sh`, collects generated image dumps, validates dumps (existence + non-zero size), and produces a PASS/FAIL `.res` file suitable for LAVA gating.

The test supports the legacy/default NHX flow and optional target-specific JSON selection for preview, video, preview+video, and snapshot validation.

---

## Location

- Test script: `Runner/suites/Multimedia/Camera/Camera_NHX/run.sh`
- Utilities:
  - `Runner/utils/functestlib.sh`
  - `Runner/utils/camera/lib_camera.sh`
- Target-specific NHX JSON configs:
  - `Runner/suites/Multimedia/Camera/Camera_NHX/Kodiak/*.json`
  - `Runner/suites/Multimedia/Camera/Camera_NHX/Lemans/*.json`
  - `Runner/suites/Multimedia/Camera/Camera_NHX/Monaco/*.json`
  - `Runner/suites/Multimedia/Camera/Camera_NHX/Talos/*.json`

---

## Target JSON layout

The test expects target-specific JSON files to be stored under the same directory as `run.sh`:

```text
Camera_NHX/
  run.sh
  README_Camera_NHX.md
  Camera_NHX_Preview.yaml
  Kodiak/
    Preview_YUVNV12_MaxResolution_NHX.json
    Video_YUVNV12_MaxResolution_NHX.json
    Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
    Snapshot_YUVNV12_MaxResolution_NHX.json
  Lemans/
    Preview_YUVNV12_MaxResolution_NHX.json
    Video_YUVNV12_MaxResolution_NHX.json
    Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
  Monaco/
    Preview_YUVNV12_MaxResolution_NHX.json
    Video_YUVNV12_MaxResolution_NHX.json
    Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
  Talos/
    Preview_YUVNV12_MaxResolution_NHX.json
    Video_YUVNV12_MaxResolution_NHX.json
    Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
    Snapshot_YUVNV12_MaxResolution_NHX.json
```

Snapshot JSON files are currently expected only for targets where the files are present, such as `Kodiak` and `Talos`. Do not schedule snapshot for `Lemans` or `Monaco` unless the corresponding JSON files are added.

---

## What this test does

1. **Environment setup**
   - Locates and sources `init_env`
   - Sources `functestlib.sh` and `lib_camera.sh`

2. **Dependency checks**
   - Uses `check_dependencies` from `functestlib.sh` to ensure required commands exist.

3. **CAMX proprietary prechecks**
   - Device-tree presence checks for CAMX/camera patterns, including downstream CAMX-style nodes such as:
     - `qcom,cam-sensor`
     - `qcom,cam-gmsl-sensor`
     - `qcom,cam-gmsl-deserializer`
     - `qcom,eeprom`
     - `qcom,cci`
     - `qcom,csiphy`
     - `qcom,cam-tpg1031`
     - `qcom,camera`
   - `fdtdump` scan for camera-related nodes through `lib_camera.sh`
   - Camera kernel module detection and loaded-state validation
   - ICP firmware presence check (`CAMERA_ICP`)
   - `dmesg` scan for camera warnings/errors
   - CAMX package presence check
   - Sensor presence check is warn-only because NHX may still work depending on target/test config

4. **Runs NHX**
   - Default mode runs `nhx.sh` with no argument, preserving the existing SoC-specific default behavior.
   - Optional mode accepts one selected JSON via `--json` and optionally `--target`.
   - The selected JSON is staged to the location expected by `/usr/bin/nhx.sh`.

5. **Dump validation**
   - Collects dump file list from NHX output and/or dump directory based on a marker timestamp.
   - Validates:
     - Dump list is non-empty
     - Each dump file exists
     - Each dump file size is greater than `0` bytes
   - Optionally generates checksums (`sha256sum`, `md5sum`, or `cksum`) and writes checksum files.

6. **Result decision**
   - Parses `Final Report -> [X PASSED] [Y FAILED] [Z SKIPPED]` from the NHX log.
   - FAIL if:
     - Final Report is missing or unparseable
     - NHX reports `FAILED > 0`
     - No dumps are detected
     - Any dump is missing or zero bytes
     - Dump checksum validation helper fails
   - Writes final result to: `Camera_NHX.res`

---

## NHX JSON selection

### Default behavior

```sh
./run.sh
```

This preserves the existing behavior and runs:

```sh
nhx.sh
```

`nhx.sh` then selects the default JSON based on SoC ID:

- Kodiak (`497`, `498`, `575`) -> `NHX.YUV_NV12_Prev_MaxRes`
- Lemans/Monaco (`534`, `606`, `667`, `674`, `675`, `676`) -> `NHX.YUV_NV12_Prev_MaxRes`
- Talos (`680`) -> `NHX.YUV_NV12_Prev_1920x1440`

### Run one selected JSON

Use `--json` to run exactly one selected JSON config:

```sh
./run.sh --json Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
```

```sh
./run.sh --json Kodiak/Snapshot_YUVNV12_MaxResolution_NHX.json
```

```sh
./run.sh --json Talos/Video_YUVNV12_MaxResolution_NHX.json
```

### Run by filename with target

When passing only a filename, use `--target` so the resolver can select the correct target folder:

```sh
./run.sh --json Snapshot_YUVNV12_MaxResolution_NHX.json --target Kodiak
```

```sh
./run.sh --json Video_YUVNV12_MaxResolution_NHX.json --target Monaco
```

Supported target names:

```text
Kodiak
Lemans
Monaco
Talos
```

### Environment variable style

The same selection can be done through environment variables:

```sh
NHX_JSON=Talos/Video_YUVNV12_MaxResolution_NHX.json ./run.sh
```

```sh
NHX_JSON=Snapshot_YUVNV12_MaxResolution_NHX.json NHX_TARGET=Talos ./run.sh
```

### Ambiguous filename handling

Many JSON filenames exist under multiple target folders. For example:

```sh
./run.sh --json Preview_YUVNV12_MaxResolution_NHX.json
```

is ambiguous because the same file can exist under `Kodiak`, `Lemans`, `Monaco`, and `Talos`.

In that case, pass `--target`:

```sh
./run.sh --json Preview_YUVNV12_MaxResolution_NHX.json --target Lemans
```

---

## How JSON staging works

`/usr/bin/nhx.sh` does not accept an arbitrary absolute JSON path. It expects a JSON name and internally checks:

```sh
/etc/camera/test/NHX/${JSON_FILE}.json
```

For this reason, when `--json` is used, `run.sh` resolves the source file from the test directory and stages it under:

```text
/etc/camera/test/NHX/<target>/<json-file>.json
```

Then it calls `nhx.sh` with the launcher argument without `.json`, for example:

```sh
nhx.sh Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX
```

This causes `nhx.sh` to load:

```text
/etc/camera/test/NHX/Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
```

The run log and summary include:

```text
NHX JSON requested
NHX target requested
NHX JSON resolved
NHX JSON argument
```

---

## Command usage

```sh
./run.sh [--json JSON_FILE] [--target TARGET] [--help]
```

Options:

```text
--json JSON_FILE   NHX JSON file to pass to nhx.sh.
                   Can be absolute, relative to Camera_NHX/, or relative
                   to the target folder when --target is provided.

--target TARGET    Target folder name: Kodiak, Lemans, Monaco, Talos.
                   Used to resolve/stage --json under /etc/camera/test/NHX.

--help             Show usage.
```

Examples:

```sh
./run.sh
```

```sh
./run.sh --json Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json
```

```sh
./run.sh --json Snapshot_YUVNV12_MaxResolution_NHX.json --target Kodiak
```

```sh
NHX_JSON=Talos/Video_YUVNV12_MaxResolution_NHX.json ./run.sh
```

---

## Outputs

Created under the test directory:

- Logs:
  - `logs/Camera_NHX_<timestamp>.log`
  - `logs/dmesg_<timestamp>/dmesg_snapshot.log`
  - `logs/dmesg_<timestamp>/dmesg_errors.log` when matches exist

- Out files:
  - `out/Camera_NHX_summary_<timestamp>.txt`
  - Dump list file, usually under `out/nhx_<timestamp>/`
  - Checksum file(s), when checksum tool/helper is available

- LAVA gating result:
  - `Camera_NHX.res`

---

## Dump directory

By default, the test expects NHX dumps under:

```text
/var/cache/camera/nativehaltest
```

This is referenced in `run.sh` as `DUMP_DIR`.

---

## How to run locally

From the test folder:

```sh
cd Runner/suites/Multimedia/Camera/Camera_NHX
./run.sh
cat Camera_NHX.res
```

Run a selected NHX config:

```sh
./run.sh --json Lemans/Preview_YUVNV12_MaxResolution_NHX.json
cat Camera_NHX.res
```

This script is LAVA-friendly and exits `0` even on FAIL/SKIP; gating is via `.res`.

---

## How to run in LAVA

Default NHX preview flow:

```yaml
metadata:
  name: camera_nhx_preview
  format: "Lava-Test Test Definition 1.0"
  description: "Camera NHX default validation"
  os:
    - linux
  scope:
    - functional

run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Multimedia/Camera/Camera_NHX
    - ./run.sh || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh Camera_NHX.res
```

Selected NHX config flow:

```yaml
metadata:
  name: camera_nhx_selected_config
  format: "Lava-Test Test Definition 1.0"
  description: "Camera NHX selected JSON validation"
  os:
    - linux
  scope:
    - functional

params:
  NHX_JSON: "Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX.json"

run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Multimedia/Camera/Camera_NHX
    - ./run.sh --json "${NHX_JSON}" || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh Camera_NHX.res
```

Selected filename plus target:

```yaml
params:
  NHX_JSON: "Snapshot_YUVNV12_MaxResolution_NHX.json"
  NHX_TARGET: "Kodiak"

run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Multimedia/Camera/Camera_NHX
    - ./run.sh --json "${NHX_JSON}" --target "${NHX_TARGET}" || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh Camera_NHX.res
```

---

## PASS/FAIL/SKIP semantics

### PASS

- NHX `Final Report` parsed successfully
- `FAILED=0`
- Dump list is non-empty
- All dump files exist and are non-zero
- Dump checksum validation helper did not fail, when used

### FAIL

- Any PASS condition is not met
- NHX reports one or more failed cases
- Final Report is missing/unparseable
- No dumps are detected
- Any dump is missing or zero bytes
- Dump checksum validation helper fails

### SKIP

- Missing CAMX prerequisites, such as DT patterns, camera module artifact/loaded state, ICP firmware, CAMX packages, or `nhx.sh`
- `fdtdump` is not available or camera node evidence is inconclusive
- Requested `--json` file is not found
- Requested JSON filename is ambiguous and `--target` was not supplied
- JSON staging under `/etc/camera/test/NHX` fails

---

## Notes and troubleshooting

### Timestamps show 1970-01-01

If logs show `1970-01-01`, the device clock is not set. This is common on early boot images or minimal init environments. It does not affect functional correctness, but it can make log browsing confusing.

### `nhx.sh` reports JSON file not found

If you see a message similar to:

```text
Warning: JSON file not found: /etc/camera/test/NHX/<name>.json
```

check that:

- `run.sh` logged a valid `NHX JSON resolved`
- `run.sh` logged a valid `NHX JSON argument`
- the selected JSON was staged under `/etc/camera/test/NHX`
- the argument passed to `nhx.sh` does not include an absolute `/tmp/...` path
- the argument passed to `nhx.sh` does not include the `.json` suffix

Correct expected example:

```text
NHX JSON argument: Lemans/Prev_plus_Video_YUVNV12_MaxResolution_NHX
```

### Camera_NHX SKIPs due to DT mismatch

The test checks CAMX-related DT patterns. For downstream CAMX overlays, useful matches include:

```text
qcom,cam-sensor
qcom,cam-gmsl-sensor
qcom,cam-gmsl-deserializer
qcom,eeprom
qcom,cci
qcom,csiphy
qcom,cam-tpg1031
qcom,camera
```

If the test still SKIPs, inspect the saved logs and confirm the active DT overlay exposes camera/CAMX nodes.

### No dumps detected

- Confirm NHX actually produced dumps and the dump path matches `DUMP_DIR`
- Check `logs/Camera_NHX_<timestamp>.log` for `Saving image to file:` lines
- Check permissions and free space under `/var/cache/camera/nativehaltest`

### dmesg warnings

The script scans dmesg and reports warnings, but does not fail only because camera warnings exist. Use the saved snapshot/errors logs to debug.

### CAMX bind graph not observed

If CAMX bind graph markers are not seen, the script logs a warning. This usually indicates CAMX stack did not fully initialize or relevant drivers/services did not come up.
