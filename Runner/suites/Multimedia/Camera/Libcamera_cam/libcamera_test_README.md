# Libcamera Camera Test Runner

This repository contains a **POSIX shell** test harness for exercising `libcamera` via its `cam` utility, with robust post‑capture validation and device‑tree (DT) checks. It is designed to run on embedded Linux targets (BusyBox-friendly), including Qualcomm RB platforms.

---

## What this test does

1. **Discovers repo context** (finds `init_env`, sources `functestlib.sh`, and the camera helpers `Runner/utils/camera/lib_camera.sh`).  
2. **Checks DT readiness** using `dt_confirm_node_or_compatible` for:
   - Sensor compatible(s), e.g. `sony,imx577`
   - ISP / camera blocks, e.g. `isp`, `cam`, `camss`
3. **Lists available cameras** with `cam -l` (warning/error lines are tolerated when camera listing succeeds).
4. **Captures frames** with `cam` for one or multiple indices, storing artifacts per camera under `OUT_DIR`.
5. **Validates output**: sequence continuity, content sanity (PPM/BIN), duplicate detection, and log scanning with noise suppression.
6. **Summarizes per‑camera PASS/FAIL**, with overall suite verdict and exit code.

---

## Requirements

- `cam` (from libcamera)
- Standard tools: `awk`, `sed`, `grep`, `sort`, `cut`, `tr`, `wc`, `find`, `stat`, `head`, `tail`, `dd`
- Optional: `sha256sum` or `md5sum` (for duplicate BIN detection)
- **BusyBox compatibility**:
  - We avoid `find -printf` and `od -A` options (not available on BusyBox).

> The harness tolerates noisy `cam -l` / `cam -I` output (WARN/ERROR lines). It only requires that cameras and/or stream info are ultimately reported.

---

## Quick start

From the test directory (e.g. `Runner/suites/Multimedia/Camera/Libcamera_cam/`):

```sh
./run.sh
```

Default behavior:
- Auto‑detect first camera index (`cam -l`).
- Capture **10 frames** per selected camera.
- Write outputs under `./cam_out/` (per‑camera subfolders `cam#`).
- Validate and print a summary.

### Common options

```text
--index N|all|n,m     Camera index (default: auto from `cam -l`; `all` = run on every camera)
--count N             Frames to capture (default: 10)
--out DIR             Output directory (default: ./cam_out)
--ppm                 Save frames as PPM files (frame-#.ppm)
--bin                 Save frames as BIN files (default; frame-#.bin)
--args "STR"          Extra args passed to `cam`
--strict              Enforce strict validation (default)
--no-strict           Relax validation (no seq/err strictness)
--dup-max-ratio R     Fail if max duplicate bucket/total > R (default: 0.5)
--bin-tol-pct P       BIN size tolerance vs bytesused in % (default: 5)
-h, --help            Help
```

Examples:
```sh
# Run default capture (first detected camera, 10 frames)
./run.sh

# Run on all cameras, 20 frames, save PPM
./run.sh --index all --count 20 --ppm

# Run on cameras 0 and 2, pass explicit stream config to cam
./run.sh --index 0,2 --args "-s width=1920,height=1080,role=viewfinder"
```

---

## Device‑tree checks

The runner verifies DT node presence **before** capture:

- First it looks for known sensor compatibles (e.g. `sony,imx577`).  
- If the sensor isn’t found, it looks for ISP / camera nodes (e.g. `isp`, `cam`, `camss`).  
- Matching entries are printed cleanly (name, path, compatible).

If neither sensor nor ISP/camera blocks are found, the test **SKIPs** with a message:
```
SKIP – No ISP/camera node/compatible found in DT
```

> On large DTs, this scan can take time. The log prints “Verifying the availability of DT nodes, this process may take some time.”

---

## IPA file workaround (simple pipeline)

On some builds, allocation may fail if `uncalibrated.yaml` exists for the `simple` IPA. The runner guards this by **renaming** it pre‑run:

```sh
if [ -f /usr/share/libcamera/ipa/simple/uncalibrated.yaml ]; then
  mv /usr/share/libcamera/ipa/simple/uncalibrated.yaml \
     /usr/share/libcamera/ipa/simple/uncalibrated.yaml.bk
fi
```

It’s restored automatically at the end (if it was present).

---

## Output & artifacts

Per‑camera subfolder under `OUT_DIR`:
- `cam-run-<ts>-camX.log` – raw cam output
- `cam-info-<ts>-camX.log` – `cam -l` and `cam -I` info
- `frame-...` files (`.bin` or `.ppm`) – captured frames
- `.file_seq_map.txt`, `.bytesused.txt`, etc. – validation sidecar files
- `summary.txt` – per‑camera PASS/FAIL

Console prints a **per‑camera** and **overall** summary. Exit codes:
- `0` PASS
- `1` FAIL
- `2` SKIP

---

## Validation details

- **Sequence integrity**: checks that frame sequence numbers are contiguous (unless `--no-strict`).
- **PPM sanity**: header/magic checks and basic content entropy (sampled).
- **BIN sanity**: size compared to `bytesused` (±`BIN_TOL_PCT`), entropy sample, duplicate detection via hashes.
- **Error scan**: scans `cam` logs for fatal indicators, then applies **noise suppression** to ignore known benign warnings from `simple` pipeline and sensors like `imx577`.

You can relax strictness with `--no-strict` (skips contiguous sequence enforcement and strict error gating).

---

## Multicamera behavior

- `--index all`: detects all indices from `cam -l` and iterates.  
- `--index 0,2,5`: runs each listed index.  
- Each index is independently validated and reported: if **any** camera fails, the **overall** result is **FAIL**. The summary lists which indices passed/failed.

---

## Environment overrides

- `INIT_ENV`: If set, the runner uses it instead of walking upward to find `init_env`.
- `LIBCAM_PATH`: If set, the runner sources this path for `lib_camera.sh` helper functions.
- Otherwise, the runner searches typical repo locations:
  - `Runner/utils/camera/lib_camera.sh`
  - `Runner/utils/lib_camera.sh`
  - `utils/camera/lib_camera.sh`
  - `utils/lib_camera.sh`

---

## Troubleshooting

- **`cam -l` prints WARN/ERROR but lists cameras**: This is tolerated. The runner parses indices from the “Available cameras” section.
- **BusyBox `find`/`od` compatibility**: We avoid GNU-only flags; if you see issues, ensure BusyBox provides the required applets mentioned above.
- **No DT matches**: Ensure your DT exposes sensor compatibles (e.g. `sony,imx577`) or ISP/camera nodes (`isp`, `cam`, `camss`). On dev boards, DT overlays may need to be applied.
- **Content flagged “near‑constant”**: This typically indicates all-same bytes in sampled regions. Verify the lens cap, sensor mode, or try `--args` with a smaller resolution/role to confirm live changes.
- **IPA config missing**: See the **IPA file workaround** above.

---

## Maintainers

- Multimedia/Camera QA
- Platform Integration

Please submit issues and PRs with logs from `cam-run-*.log`, `cam-info-*.log`, and `summary.txt`.
