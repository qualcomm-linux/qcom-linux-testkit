# Camera RDI Frame Capture Test

This test validates functional camera RDI (Raw Dump Interface) pipelines by:

- Dynamically detecting all camera pipelines using `media-ctl`
- Parsing valid RDI pipelines with a Python helper script
- Streaming frames using `yavta` from detected working pipelines
- Supporting manual override of video format and frame count

## 📁 Test Directory Structure

```
Camera_RDI_FrameCapture/
├── run.sh
├── parse_media_topology.py
└── init_env
```

## 🧠 How It Works

1. Detects media device node dynamically
2. Dumps the topology to a temporary file
3. Parses pipeline details using `parse_media_topology.py`
4. For each detected pipeline:
   - Applies correct media-ctl `-V` and `-l` configuration
   - Sets V4L2 controls pre-/post-streaming via `yavta`
   - Attempts frame capture using `yavta`
5. Logs PASS/FAIL/SKIP per pipeline
6. Generates a `.res` file with final test result

## ⚙️ Dependencies

Make sure the following tools are available in the target filesystem:

- `media-ctl`
- `yavta`
- `v4l2-ctl`
- `python3`
- Kernel module: `qcom_camss`
- Required DT nodes for `camss`, `isp`, or `camera` compatible strings

## 🧪 Usage

```sh
./run.sh [--format <fourcc>] [--frames <count>]
```

### Examples:

- Auto-detect and capture 10 frames per working RDI pipeline:
  ```sh
  ./run.sh
  ```

- Force UYVY format and capture 5 frames:
  ```sh
  ./run.sh --format UYVY --frames 5
  ```

## 📦 Output

- Captured frame files: `frame-#.bin` in current directory
- Result summary: `Camera_RDI_FrameCapture.res`
- Detailed logs through `functestlib.sh`-based `log_info`, `log_pass`, etc.

## ✅ Pass Criteria

- At least one pipeline successfully captures frames
- Logs include `"Captured <n> frames"` for at least one working video node

## ❌ Fail/Skip Criteria

- If pipeline configuration fails or no frames captured, it is marked FAIL
- If no working pipelines are found or prerequisites are unmet, test is SKIPPED

## 🧼 Cleanup

Temporary files created:
- `/tmp/v4l2_camera_RDI_dump_topo.*`
- `/tmp/v4l2_camera_RDI_dump_pipelines.*`

They are auto-removed at the end of the test.

## 📝 Notes

- The test is dynamic and supports multiple pipelines per board
- Python script only outputs **valid** working pipelines (validated via `v4l2-ctl`)
- `run.sh` is robust, CI-ready, and skips flaky or unsupported configurations gracefully

---

© Qualcomm Technologies, Inc. – All rights reserved