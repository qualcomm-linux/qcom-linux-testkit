# Camera_NHX

Camera NHX validation test for Qualcomm CAMX proprietary camera stack. This test runs `nhx.sh`, collects the generated image dumps, validates dumps (existence + non-zero size), and produces a PASS/FAIL `.res` file suitable for LAVA gating.

---

## Location

- Test script: `Runner/suites/Multimedia/Camera/Camera_NHX/run.sh`
- Utilities:
  - `Runner/utils/functestlib.sh`
  - `Runner/utils/camera/lib_camera.sh`

---

## What this test does

1. **Environment setup**
   - Locates and sources `init_env`
   - Sources `functestlib.sh` and `lib_camera.sh`

2. **Dependency checks**
   - Uses `check_dependencies` from `functestlib.sh` to ensure required commands exist.

3. **CAMX proprietary prechecks (gate where required)**
   - Device-tree presence checks for camera/CAMX patterns
   - `fdtdump` scan for camera-related nodes (via helper)
   - Camera kernel module detection + “loaded” validation
   - ICP firmware presence check (CAMERA_ICP)
   - `dmesg` scan for camera warnings/errors (warn-only)
   - Gate on “bind graph observed” markers

4. **Runs NHX**
   - Executes `nhx.sh` and captures all output to a timestamped log.

5. **Dump validation**
   - Collects dump file list from NHX output and/or dump directory based on a marker timestamp.
   - Validates:
     - Dump list is non-empty
     - Each dump file exists
     - Each dump file size is **> 0 bytes**
   - Optionally generates checksums (sha256sum/md5sum/cksum) and writes checksum files.

6. **Result decision**
   - Parses `Final Report -> [X PASSED] [Y FAILED] [Z SKIPPED]` from the NHX log
   - FAIL if:
     - Final Report missing/unparseable
     - NHX reports FAILED > 0
     - No dumps detected
     - Any dump missing/zero bytes
     - Dump checksum validation helper fails
   - Writes final result to: `Camera_NHX.res`

---

## Outputs

Created under the test directory:

- Logs:
  - `logs/Camera_NHX_<timestamp>.log`
  - `logs/dmesg_<timestamp>/dmesg_snapshot.log`
  - `logs/dmesg_<timestamp>/dmesg_errors.log` (if any matches)

- Out files:
  - `out/Camera_NHX_summary_<timestamp>.txt`
  - Dump list file (path depends on `lib_camera.sh` helper output; typically under `out/`)
  - Checksum file(s) (if enabled by helper/tool availability)

- LAVA gating result:
  - `Camera_NHX.res`

---

## Dump directory

By default the test expects NHX dumps under:

- `/var/cache/camera/nativehaltest`

(Referenced in `run.sh` as `DUMP_DIR`.)

---

## How to run locally

From the test folder:

```sh
cd Runner/suites/Multimedia/Camera/Camera_NHX
./run.sh
cat Camera_NHX.res
```

This script is LAVA-friendly and exits `0` even on FAIL/SKIP; gating is via `.res`.

---

## How to run in LAVA

Example Lava-Test definition:

```yaml
metadata:
  name: camera_nhx
  format: "Lava-Test Test Definition 1.0"
  description: "Camera NHX validation"
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

---

## PASS/FAIL/SKIP semantics

- **PASS**
  - NHX `Final Report` parsed successfully
  - `FAILED=0`
  - Dump list is non-empty
  - All dump files exist and are **non-zero**
  - Dump checksum validation helper did not fail (if used)

- **FAIL**
  - Any PASS condition not met (including missing/zero dumps)

- **SKIP**
  - Missing CAMX prerequisites (DT patterns, camera module artifact/loaded, ICP firmware, CAMX packages, etc.)
  - `nhx.sh` not found in PATH
  - `fdtdump` not available / inconclusive camera node evidence (as per helper return codes)

---

## Notes / Troubleshooting

### Timestamps show 1970-01-01

If logs show `1970-01-01`, the device clock is not set (common on early boot images or minimal init). This doesn’t affect functional correctness, but it can make log browsing confusing. Consider enabling NTP or setting RTC/time before running.

### No dumps detected

- Confirm NHX actually produced dumps and the dump path matches `DUMP_DIR`
- Check `logs/Camera_NHX_<ts>.log` for `Saving image to file:` lines
- Check permissions and free space under `/var/cache/camera/nativehaltest`

### dmesg warnings

The script scans dmesg and reports warnings, but does **not** SKIP just because camera warnings exist. Use the saved snapshot/errors logs to debug.

### CAMX bind graph not observed (SKIP)

If the bind graph markers are not seen enough times, the script SKIPs. This usually indicates CAMX stack did not fully initialize or relevant drivers/services didn’t come up.
