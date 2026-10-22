# Libcamera Camera Test Runner

This repository contains a **POSIX shell** test harness for exercising `libcamera` via its `cam` utility, with robust post‑capture validation and device‑tree (DT) checks. It is designed to run on embedded Linux targets (BusyBox-friendly), including Qualcomm RB platforms.

---

## What this test does

1. **Discovers repo context** (finds `init_env`, sources `functestlib.sh`, and the camera helpers `Runner/utils/camera/lib_camera.sh`).  
2. **Checks DT applicability** by discovering enabled Qualcomm CAMSS pipeline nodes in the runtime device tree. Disabled nodes from inactive overlays are ignored.
3. **Lists available cameras** with `cam -l`, retains the complete output, and accepts both `[0] ...` and `0: ...` camera entry formats.
4. **Captures frames** with `cam` for one or multiple indices, storing artifacts per camera under `OUT_DIR`.
5. **Validates output**: sequence continuity, content sanity (PPM/BIN), duplicate detection, and log scanning with noise suppression.
6. **Summarizes per‑camera PASS/FAIL**, with overall suite verdict and exit code.

---

## Requirements

- Image-provided `cam` utility from libcamera
- Standard tools: `awk`, `sed`, `grep`, `sort`, `cut`, `tr`, `wc`, `find`, `stat`, `head`, `tail`, `dd`
- Optional: `sha256sum` or `md5sum` (for duplicate BIN detection)
- **BusyBox compatibility**:
  - We avoid `find -printf` and `od -A` options (not available on BusyBox).

The test does not install packages at runtime. If `cam` or another required
utility is absent from the image, it reports a clean SKIP with the missing
prerequisite.

> The harness tolerates noisy `cam -l` / `cam -I` output when cameras and stream information are ultimately reported. A nonzero `cam -l` status or zero enumerated cameras is a failure when an enabled CAMSS pipeline is present.

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

The runner determines applicability **before** capture by finding enabled
Qualcomm compatibles containing `camss` in the live device tree. The shared
device-tree helper resolves runtime root symlinks, searches both standard roots,
and ignores nodes whose status is `disabled`, `fail`, or `failed`.

- No enabled CAMSS pipeline: **SKIP** because the upstream libcamera path is not applicable to the active image or overlay.
- Enabled CAMSS pipeline and `cam -l` fails: **FAIL** and retain the command output.
- Enabled CAMSS pipeline and `cam -l` reports zero cameras: **FAIL** because the image needs matching libcamera pipeline-handler and sensor support.

---

## IPA file workaround (simple pipeline)

On some builds, allocation may fail if `uncalibrated.yaml` exists for the
`simple` IPA. The runner temporarily moves it to a test-owned backup path:

```sh
if [ -f /usr/share/libcamera/ipa/simple/uncalibrated.yaml ]; then
  mv /usr/share/libcamera/ipa/simple/uncalibrated.yaml \
     /usr/share/libcamera/ipa/simple/uncalibrated.yaml.qcom-testkit-backup
fi
```

The EXIT trap restores only the file moved by the current test run. If the
backup path already exists, the test leaves both files unchanged.

---

## Output & artifacts

Directly under `OUT_DIR`:

- `cam-list-<ts>.log` – retained initial `cam -l` output used for applicability validation and index selection
- `summary.txt` – per‑camera PASS/FAIL

Per‑camera subfolder under `OUT_DIR`:

- `cam-run-<ts>-camX.log` – raw cam output
- `cam-info-<ts>-camX.log` – `cam -l` and `cam -I` info
- `frame-...` files (`.bin` or `.ppm`) – captured frames
- `.file_seq_map.txt`, `.bytesused.txt`, etc. – validation sidecar files

Console prints a **per‑camera** and **overall** summary.
The `.res` file is the authoritative result. The runner exits `0` after
publishing PASS, FAIL, or SKIP so LAVA can consume that result.

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

## Repository integration

The runner locates `init_env` by walking upward from its own directory and
loads `Runner/utils/camera/lib_camera.sh` through the repository `TOOLS` path.
No environment override is required.

---

## Troubleshooting

- **`cam -l` prints WARN/ERROR but lists cameras**: This is tolerated. The runner parses indices from the “Available cameras” section.
- **BusyBox `find`/`od` compatibility**: We avoid GNU-only flags; if you see issues, ensure BusyBox provides the required applets mentioned above.
- **No enabled CAMSS node**: Ensure the active runtime DT selects the upstream CAMSS image or overlay. Camera nodes from disabled overlays do not make this test applicable.
- **Enabled CAMSS but zero cameras**: Inspect `cam-list-<ts>.log` and provide a libcamera build with the matching Qualcomm pipeline handler and sensor support.
- **Content flagged “near‑constant”**: This typically indicates all-same bytes in sampled regions. Verify the lens cap, sensor mode, or try `--args` with a smaller resolution/role to confirm live changes.
- **IPA config missing**: See the **IPA file workaround** above.

---

## Maintainers

- Multimedia/Camera QA
- Platform Integration

Please submit issues and PRs with logs from `cam-run-*.log`, `cam-info-*.log`, and `summary.txt`.
