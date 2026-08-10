# Video_Encode_Decode (GStreamer) — Runner Test

This directory contains the **Video_Encode_Decode** validation test for Qualcomm Linux Testkit runners.

It validates video **encoding and decoding** using **GStreamer (`gst-launch-1.0`)** with V4L2 hardware-accelerated codecs:
- **v4l2h264enc** / **v4l2h264dec** (H.264/AVC)
- **v4l2h265enc** / **v4l2h265dec** (H.265/HEVC)
- **v4l2vp9dec** (VP9 decode only - uses pre-downloaded WebM clips)

The script is designed to be **CI/LAVA-friendly**:
- Writes **PASS/FAIL/SKIP** into `Video_Encode_Decode.res`
- Always **exits 0** (even on FAIL/SKIP) to avoid terminating LAVA jobs early
- Logs the **final `gst-launch-1.0` command** to console and to log files
- Uses **videotestsrc** plugin to generate test patterns for H.264/H.265 (no external video files needed)
- For VP9: Downloads WebM clips from git repo (requires network connectivity)

---

## Location in repo

Expected path:

```
Runner/suites/Multimedia/GSTreamer/Video/Video_Encode_Decode/run.sh
```

Required shared utils (sourced from `Runner/utils` via `init_env`):
- `functestlib.sh`
- `lib_gstreamer.sh` - **Contains reusable V4L2 video helpers** (see Library Functions section below)
- optional: `lib_video.sh` (for video stack management)

---

## What this test does

At a high level, the test:

1. Finds and sources `init_env`
2. Sources:
   - `$TOOLS/functestlib.sh`
   - `$TOOLS/lib_gstreamer.sh`
   - optionally `$TOOLS/lib_video.sh`
3. Checks for required GStreamer elements (v4l2h264enc, v4l2h265enc, v4l2h264dec, v4l2h265dec, v4l2vp9dec)
4. **Network connectivity check** (for VP9):
   - Checks network connectivity using `ensure_network_online()`
   - Downloads VP9 clips from git repo if not already present
   - URL: https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz
5. **Encoding phase**:
   - Uses `videotestsrc` to generate test video patterns (SMPTE color bars)
   - Encodes to H.264 or H.265 using V4L2 hardware encoders
   - Saves encoded files to `logs/Video_Encode_Decode/encoded/`
   - Tests 480p resolution (640x480) by default
6. **Decoding phase**:
   - Reads the previously encoded files (H.264/H.265) or downloaded clips (VP9)
   - Decodes using V4L2 hardware decoders
   - Outputs to fakesink (no display needed)
7. Collects test results and emits PASS/FAIL/SKIP

---

## Test Cases

By default, the test runs the following test cases at 4K resolution for H.264/H.265, plus VP9 decode:

### Encoding Tests
1. **encode_h264_4k** - Encode H.264 at 3840x2160 resolution for 30 seconds
2. **encode_h265_4k** - Encode H.265 at 3840x2160 resolution for 30 seconds

**Note:** VP9 encoding is not supported (no v4l2vp9enc available)

### Decoding Tests
1. **decode_h264_4k** - Decode H.264 4K encoded file
2. **decode_h265_4k** - Decode H.265 4K encoded file
3. **decode_vp9_320p** - Decode VP9 pre-downloaded clip (converted to WebM: vp9_test_320p.webm) - **runs by default**

---

## Advanced Test Cases

The test suite includes 9 advanced test cases that can be run using the `--test-type` parameter. These tests validate specific video features and scenarios.

### Test Type: UVC Camera Preview

**Test: UVC_Live_Preview_1080p (PR76474)**
- **Description**: UVC camera live preview at 1080p@5fps with Wayland display output
- **Requirements**: UVC camera device, Wayland compositor
- **Pipeline**: `v4l2src → videoconvert → qtivtransform (optional) → waylandsink`
- **Usage**: `./run.sh --test-type uvc --duration 30`
- **Features**:
  - Automatic UVC camera detection
  - Wayland display setup (auto-starts Weston if needed)
  - Optional rotation support via qtivtransform

### Test Type: Dynamic Resolution Change (DRC)

**Test: DRC_H264_Decode_1080p_720p (FR82787)**
- **Description**: Validates dynamic resolution change during H.264 decode (1080p → 720p)
- **Requirements**: Special DRC test clip, Wayland display, fpsdisplaysink
- **Pipeline**: `filesrc → qtdemux → h264parse → v4l2h264dec → fpsdisplaysink → waylandsink`
- **Usage**: `./run.sh --test-type drc --clip-path /path/to/clips`
- **Test Clip**: `1080_720_h264.mp4` (automatically downloaded or copied from --clip-path)
- **Features**:
  - Monitors FPS and resolution changes during playback
  - Validates seamless resolution transitions

### Test Type: Concurrent Decode

**Concurrency Tests (PR43865, PR43866, FR98277)**

These tests validate concurrent decode sessions using qtivcomposer for multi-stream composition.

**1. H264_Decode_Concurrency_8x480p (PR43865)**
- **Description**: 8 concurrent H.264 480p@30fps decode sessions
- **Requirements**: qtivcomposer, Wayland display
- **Test Clip**: `H264_480p_30fps.mp4`
- **Pipeline (per session)**: `filesrc → qtdemux → h264parse → v4l2h264dec → qtivcomposer → waylandsink`

**2. H265_Decode_Concurrency_8x480p (PR43866)**
- **Description**: 8 concurrent H.265 480p decode sessions
- **Requirements**: qtivcomposer, Wayland display
- **Test Clip**: `H265_480p_30fps.mp4`
- **Pipeline (per session)**: `filesrc → qtdemux → h265parse → v4l2h265dec → qtivcomposer → waylandsink`

**3. MJPEG_Decode_Concurrency_2x1080p (FR98277)**
- **Description**: 2 concurrent MJPEG 1080p decode sessions
- **Requirements**: jpegdec (software decoder), qtivcomposer, Wayland display
- **Test Clip**: `mjpeg1.avi`
- **Pipeline (per session)**: `filesrc → avidemux → jpegdec → qtivcomposer → waylandsink`

**Usage**:
```bash
# Run all 3 concurrency tests
./run.sh --test-type concurrency --clip-path /path/to/clips
```

**Features**:
- Fixed session counts: 8 for H.264/H.265, 2 for MJPEG
- Single pipeline with qtivcomposer for multi-stream composition
- Comprehensive error checking and validation

### Test Type: Advanced Encoding (Downstream Only)

**Advanced Encoding Tests (FR74943, FR82773, FR82771, FR72846)**

These tests require downstream video driver (Config2) and Qualcomm camera source (qtiqmmfsrc).

**1. HEVC_Encode_Smart_Bitrate_FPS_720p (FR74943)**
- **Description**: HEVC 720p encode with smart FPS and bitrate adaptation using dual camera streams
- **Requirements**: Downstream driver, qtiqmmfsrc, qtismartvencbin
- **Pipeline**: `qtiqmmfsrc (dual streams: video + control) → qtismartvencbin (smart-fps=true, smart-bitrate=true, smart-gop=false) → h265parse → mp4mux → filesink`
- **Features**:
  - Adaptive FPS and bitrate control
  - Dual camera streams (720p video + 480p control)
  - Noise reduction (noise-reduction=2)
  - Extra buffers (extra-buffers=20)
  - Control sink for smart encoding decisions

**2. HEVC_Encode_1080p_Cyclic_IR (FR82773)**
- **Description**: HEVC 1080p (1920x1080) encode with Cyclic Intra Refresh and CBR mode
- **Requirements**: Downstream driver, qtiqmmfsrc, v4l2h265enc
- **Pipeline**: `qtiqmmfsrc → v4l2h265enc (intra_refresh_period_type=1, intra_refresh_period=20, CBR mode, comprehensive QP controls) → h265parse → mp4mux → filesink`
- **Features**: 
  - Cyclic intra refresh mode for error resilience (period=20)
  - Constant Bitrate (CBR) mode with 5 Mbps target
  - Comprehensive QP (Quantization Parameter) controls for I/P/B frames
  - GOP size control (29 frames)

**3. H264_Encode_Slice_MB_VGA (FR82771)**
- **Description**: H.264 VGA (640x480) encode with Slice MB mode
- **Requirements**: Downstream driver, qtiqmmfsrc, v4l2h264enc
- **Pipeline**: `qtiqmmfsrc → v4l2h264enc (slice_partitioning_method=1, number_of_mbs_in_a_slice=368) → h264parse → mp4mux → filesink`
- **Features**: Macroblock-based slice partitioning

**4. HEVC_Encode_1080p_Rotate90 (FR72846)**
- **Description**: HEVC 1080p (1920x1080) encode with 90° VPU rotation and VBR mode
- **Requirements**: qtiqmmfsrc, v4l2h265enc (rotate control requires downstream driver)
- **Pipeline**: `qtiqmmfsrc → v4l2h265enc (rotate=90, VBR mode, comprehensive QP controls) → h265parse → mp4mux → filesink`
- **Features**: 
  - Hardware-accelerated rotation during encoding
  - Variable Bitrate (VBR) mode with 2.2 Mbps target
  - Comprehensive QP (Quantization Parameter) controls for I/P/B frames
  - GOP size control (29 frames)

**Usage**:
```bash
# Run all 4 advanced encoding tests (requires downstream driver + camera)
./run.sh --test-type advanced-encode --stack downstream --duration 30
```

**Note**: These tests will automatically skip if:
- Downstream video driver is not detected
- Camera source (qtiqmmfsrc) is not available
- Required encoder elements are missing

---

## Test Clip Requirements

### Automatic Download

Test clips are automatically downloaded from the configured URL (default: GitHub releases) or copied from a local path if provided via `--clip-path`.

### Required Clips by Test Type

| Test Type | Clips Required | Auto-Download |
|-----------|----------------|---------------|
| basic | VP9_640x480_10s.webm | ✅ Yes |
| uvc | None (uses camera) | N/A |
| drc | 1080_720_h264.mp4 | ✅ Yes |
| concurrency | H264_480p_30fps.mp4<br>H265_480p_30fps.mp4<br>mjpeg1.avi | ✅ Yes |
| advanced-encode | None (uses camera) | N/A |
| all (default) | All clips above | ✅ Yes |

### Clip Download Behavior

1. **Check if clip exists** in output directory
2. **Try local path** if `--clip-path` is provided
3. **Download from URL** if not found locally
4. **Skip test** if download fails (offline mode)

### Manual Clip Provision

If you have clips locally, provide the path:

```bash
./run.sh --test-type concurrency --clip-path /path/to/clips
```

The script will look for clips in the specified directory and copy them to the output directory.

---

## Advanced Test Examples

### 1) Run UVC camera preview for 60 seconds

```bash
./run.sh --test-type uvc --duration 60
```

### 2) Run DRC test with local clips

```bash
./run.sh --test-type drc --clip-path /mnt/test_clips
```

### 3) Run concurrency tests

```bash
./run.sh --test-type concurrency --clip-path /opt
```

### 4) Run all advanced encoding tests (downstream only)

```bash
./run.sh --test-type advanced-encode --stack downstream
```

### 5) Run basic tests with custom settings

```bash
./run.sh --test-type basic --codecs h264,h265 --resolutions 480p,1080p --duration 10
```

---

## PASS / FAIL / SKIP criteria

### PASS
- **Encoding**: Output file is created and has size > 1000 bytes
- **Decoding**: Pipeline completes successfully (exit code 0 or "Setting pipeline to NULL" in log)
- **Overall**: At least one test passes and no tests fail

### FAIL
- **Encoding**: No output file created or file size too small
- **Decoding**: Pipeline fails or crashes
- **Overall**: One or more tests fail

### SKIP
- Missing required tools (`gst-launch-1.0`, `gst-inspect-1.0`)
- Required V4L2 encoder/decoder elements not available
- For H.264/H.265 decode tests: corresponding encoded file not found (encode must run first)
- For VP9 decode tests: network connectivity unavailable, clip download failed, or IVF to WebM conversion failed

**Note:** The test always exits `0` even for FAIL/SKIP. The `.res` file is the source of truth.

---

## Logs and artifacts

By default, logs are written relative to the script working directory:

```
./Video_Encode_Decode.res
./logs/Video_Encode_Decode/
  gst.log                    # GStreamer debug output
  encode_h264_480p.log       # Individual test logs
  encode_h264_4k.log
  encode_h265_480p.log
  encode_h265_4k.log
  decode_h264_480p.log
  decode_h264_4k.log
  decode_h265_480p.log
  decode_h265_4k.log
  decode_vp9_480p.log        # VP9 decode test log
  encoded/                   # Encoded video files
    encode_h264_480p.mp4
    encode_h264_4k.mp4
    encode_h265_480p.mp4
    encode_h265_4k.mp4
  VP9_640x480_10s.webm      # Downloaded VP9 clip (WebM format)
  dmesg/                     # dmesg scan outputs (if available)
```

---

## Dependencies

### Required
- `gst-launch-1.0`
- `gst-inspect-1.0`
- `videotestsrc` GStreamer plugin
- `videoconvert` GStreamer plugin

### V4L2 Encoder/Decoder Elements
- `v4l2h264enc` - H.264 hardware encoder
- `v4l2h265enc` - H.265 hardware encoder
- `v4l2h264dec` - H.264 hardware decoder
- `v4l2h265dec` - H.265 hardware decoder
- `v4l2vp9dec` - VP9 hardware decoder

### Parser Elements
- `h264parse` - H.264 stream parser
- `h265parse` - H.265 stream parser
- `matroskademux` - WebM/Matroska container demuxer (for VP9)

### Network Requirements (for VP9)
- Network connectivity (Ethernet or WiFi)
- Access to GitHub releases: https://github.com/qualcomm-linux/qcom-linux-testkit/releases/

---

## Usage

Run:

```bash
./run.sh [options]
```

Help:

```bash
./run.sh --help
```

### Options

- `--test-type <basic|uvc|drc|concurrency|advanced-encode|all>`
  - Default: `basic` (standard encode/decode tests only - backward compatible)
  - `basic`: Standard encode/decode tests only (H.264, H.265, VP9)
  - `all`: Run ALL tests (basic + uvc + drc + concurrency + advanced-encode)
  - `uvc`: UVC camera live preview test
  - `drc`: Dynamic Resolution Change H.264 decode test
  - `concurrency`: Concurrent decode tests (H.264, H.265, MJPEG)
  - `advanced-encode`: Advanced encoding tests (downstream only)

- `--mode <all|encode|decode>`
  - Default: `all` (run both encode and decode tests)
  - `encode`: Run only encoding tests
  - `decode`: Run only decoding tests (requires encoded files from previous encode run)

- `--codecs <h264,h265,vp9>`
  - Comma-separated list of codecs to test
  - Default: `h264,h265,vp9` (all three codecs run by default)
  - Examples: `h264`, `h265`, `h264,h265`, `vp9`, `h264,vp9`
  - Note: VP9 only supports decode (no encode)

- `--resolutions <480p,720p,1080p,4k>`
  - Comma-separated list of resolutions to test
  - Default: `480p`
  - Supported: `480p` (640x480), `720p` (1280x720), `1080p` (1920x1080), `4k` (3840x2160)
  - Examples: `480p`, `4k`, `480p,1080p,4k`

- `--clip-path <path>`
  - Local path to test video files
  - Overrides --clip-url if files exist
  - Example: `--clip-path /opt` or `--clip-path /mnt/test_clips`

- `--clip-url <url>`
  - URL to download test video files
  - Default: GitHub release URL
  - Example: `--clip-url https://example.com/clips.tar.gz`

- `--duration <seconds>`
  - Duration for encoding (in seconds)
  - Default: `30`
  - This determines how many frames are generated (duration × framerate)

- `--framerate <fps>`
  - Framerate for video generation
  - Default: `30`

- `--stack <auto|upstream|downstream>`
  - Video stack selection (uses lib_video.sh if available)
  - Default: `auto`

- `--gst-debug <level>`
  - Sets `GST_DEBUG=<level>` (1-9)
  - Values:
    - `1` ERROR
    - `2` WARNING (default)
    - `3` FIXME
    - `4` INFO
    - `5` DEBUG
    - `6` LOG
    - `7` TRACE
    - `8` MEMDUMP
    - `9` MEMDUMP
  - Default: `2`

- `--lava-testcase-id <name>`
  - Override the test case name reported to LAVA in the `.res` file
  - Default: `Video_Encode_Decode`
  - Used by LAVA to match expected test case names
  - Example: `--lava-testcase-id "GStreamer_Video_Decode_h265_480p"`
  - **Note:** This is typically set automatically by LAVA job definitions and should not be used for local testing

---

## Examples

### 1) Run basic tests (default - backward compatible)

```bash
./run.sh
```

**Note:** Default behavior (`--test-type basic`) runs only basic encode/decode tests:
- H.264 encode/decode at 480p for 30 seconds
- H.265 encode/decode at 480p for 30 seconds
- VP9 decode at 480p (if clip available)

This is backward compatible with existing LAVA jobs and nightly runs.

### 2) Run ALL tests (basic + advanced)

```bash
./run.sh --test-type all
```

**Note:** `--test-type all` runs ALL 9+ tests:
- Basic encode/decode tests (H.264, H.265, VP9)
- UVC camera preview (if camera available)
- DRC H.264 decode (if clip available)
- Concurrency tests: 8x H.264, 8x H.265, 2x MJPEG (if clips available)
- Advanced encode tests (if downstream stack + camera available)

Tests that require missing hardware or clips will be gracefully skipped.

### 3) Run only basic encode/decode tests (explicit)

```bash
./run.sh --test-type basic
```

### 4) Run only UVC camera test

```bash
./run.sh --test-type uvc --duration 60
```

### 5) Run only concurrency tests

```bash
./run.sh --test-type concurrency --clip-path /opt
```

### 6) Run only advanced encoding tests (downstream only)

```bash
./run.sh --test-type advanced-encode --stack downstream
```

### 7) Run basic tests with specific codecs and resolutions

```bash
./run.sh --test-type basic --codecs h264,h265 --resolutions 480p,1080p
```

### 8) Run only encoding tests

```bash
./run.sh --mode encode
```

### 9) Run only decoding tests (requires encoded files from previous run)

```bash
./run.sh --mode decode
```

### 10) Test only H.264 codec

```bash
./run.sh --test-type basic --codecs h264
```

### 11) Test with shorter duration (10 seconds)

```bash
./run.sh --duration 10
```

### 12) Test with higher framerate (60fps)

```bash
./run.sh --test-type basic --framerate 60
```

### 13) Test multiple resolutions

```bash
./run.sh --test-type basic --resolutions 480p,720p,1080p,4k
```

### 14) Increase GStreamer debug verbosity

```bash
./run.sh --gst-debug 5
```

### 15) Quick test - H.264 only at 480p with 3 second duration

```bash
./run.sh --test-type basic --codecs h264 --resolutions 480p --duration 3
```

### 16) Test VP9 decode only (requires network connectivity)

```bash
./run.sh --test-type basic --codecs vp9 --mode decode
```

### 17) Provide local test clips

```bash
./run.sh --clip-path /opt
```

---

## Pipeline Details

### Encoding Pipeline

```
videotestsrc num-buffers=<N> pattern=smpte
  ! video/x-raw,width=<W>,height=<H>,format=NV12,framerate=<FPS>/1
  ! v4l2h264enc extra-controls="controls,video_bitrate=<BITRATE>" (or v4l2h265enc)
  ! h264parse (or h265parse)
  ! filesink location=<output_file>
```

Where:
- `num-buffers` = duration × framerate
- `pattern=smpte` generates SMPTE color bars test pattern
- `format=NV12` specifies the native format for V4L2 encoders (no videoconvert needed)
- `extra-controls="controls,video_bitrate=<BITRATE>"` sets encoder bitrate
  - 480p: 1 Mbps (1000000)
  - 720p: 2 Mbps (2000000)
  - 1080p: 4 Mbps (4000000)
  - 4K: 8 Mbps (8000000)
- Parser element ensures proper format negotiation

### Decoding Pipeline (H.264/H.265)

```
filesrc location=<input_file>
  ! h264parse (or h265parse)
  ! v4l2h264dec (or v4l2h265dec)
  ! videoconvert
  ! fakesink
```

Where:
- Parser ensures proper stream format
- `fakesink` discards output (no display needed for validation)

### Decoding Pipeline (VP9)

```
filesrc location=VP9_640x480_10s.webm
  ! matroskademux
  ! v4l2vp9dec
  ! videoconvert
  ! fakesink
```

Where:
- `matroskademux` parses WebM/Matroska container format
- Input file is the downloaded WebM file
- Resolution: 640x480

---

## Troubleshooting

### A) "SKIP: Missing gstreamer runtime"
- Ensure `gst-launch-1.0` and `gst-inspect-1.0` are installed in the image.

### B) "Encoder not available for h264/h265"
- Check if V4L2 encoder elements are available:
  ```bash
  gst-inspect-1.0 v4l2h264enc
  gst-inspect-1.0 v4l2h265enc
  ```
- Ensure video hardware acceleration drivers are loaded
- Check video stack configuration (upstream vs downstream)

### C) "Decoder not available for h264/h265/vp9"
- Check if V4L2 decoder elements are available:
  ```bash
  gst-inspect-1.0 v4l2h264dec
  gst-inspect-1.0 v4l2h265dec
  gst-inspect-1.0 v4l2vp9dec
  ```

### D) Decode tests skip with "Input file not found"
- Run encode tests first: `./run.sh --mode encode`
- Or run all tests: `./run.sh --mode all`

### E) Encoding fails or produces small files
- Check available memory (4K encoding requires significant memory)
- Check `logs/Video_Encode_Decode/encode_*.log` for errors
- Try with lower resolution: `./run.sh --resolutions 480p`
- Increase debug level: `./run.sh --gst-debug 5`

### F) "FAIL: file too small"
- Encoding may have failed silently
- Check individual test logs in `logs/Video_Encode_Decode/`
- Verify V4L2 video devices exist: `ls -l /dev/video*`

### G) Video stack issues
- Check loaded modules:
  ```bash
  lsmod | grep -E 'iris|venus|video'
  ```
- Try forcing stack: `./run.sh --stack upstream` or `./run.sh --stack downstream`

### H) VP9 decode fails with "Input file not found"
- Ensure network connectivity is available
- Check if clip was downloaded: `ls -l logs/Video_Encode_Decode/VP9_640x480_10s.webm`
- Manually download if needed:
  ```bash
  cd logs/Video_Encode_Decode/
  wget https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/GST-Video-Files-v1.0/video_clips_gst.tar.gz
  tar -xzf video_clips_gst.tar.gz
  ```
### I) VP9 decode fails with "matroskademux not found"
- Ensure `matroskademux` GStreamer plugin is installed:
  ```bash
  gst-inspect-1.0 matroskademux
  ```
- This is typically part of `gst-plugins-good` package

---

## Library Functions (Runner/utils/lib_gstreamer.sh)

This test uses reusable helper functions from `lib_gstreamer.sh` that other GStreamer tests can leverage:

### Resolution and Codec Helpers

**`gstreamer_resolution_to_wh <resolution>`**
- Converts resolution names to width/height
- Input: `480p`, `720p`, `1080p`, `4k`
- Output: `"<width> <height>"` (e.g., `"1920 1080"`)
- Example:
  ```sh
  params=$(gstreamer_resolution_to_wh "1080p")
  width=$(printf '%s' "$params" | awk '{print $1}')   # 1920
  height=$(printf '%s' "$params" | awk '{print $2}')  # 1080
  ```

**`gstreamer_v4l2_encoder_for_codec <codec>`**
- Returns V4L2 encoder element for codec
- Input: `h264`, `h265`/`hevc`
- Output: `v4l2h264enc` or `v4l2h265enc` (or empty if not available)
- Example:
  ```sh
  encoder=$(gstreamer_v4l2_encoder_for_codec "h264")  # v4l2h264enc
  ```

**`gstreamer_v4l2_decoder_for_codec <codec>`**
- Returns V4L2 decoder element for codec
- Input: `h264`, `h265`/`hevc`, `vp9`
- Output: `v4l2h264dec`, `v4l2h265dec`, or `v4l2vp9dec` (or empty if not available)
- Example:
  ```sh
  decoder=$(gstreamer_v4l2_decoder_for_codec "vp9")  # v4l2vp9dec
  ```

**`gstreamer_container_ext_for_codec <codec>`**
- Returns file extension for codec
- Input: `h264`, `h265`, `vp9`
- Output: `mp4` (for h264/h265) or `ivf` (for vp9)
- Example:
  ```sh
  ext=$(gstreamer_container_ext_for_codec "h264")  # mp4
  ```

### Bitrate and File Size Helpers

**`gstreamer_bitrate_for_resolution <width> <height>`**
- Calculates recommended bitrate based on resolution
- Returns bitrate in bps
- Bitrate mapping:
  - ≤640px width: 1 Mbps (1000000 bps)
  - ≤1280px width: 2 Mbps (2000000 bps)
  - ≤1920px width: 4 Mbps (4000000 bps)
  - >1920px width: 8 Mbps (8000000 bps)
- Example:
  ```sh
  bitrate=$(gstreamer_bitrate_for_resolution 1920 1080)  # 4000000
  ```

**`gstreamer_file_size_bytes <filepath>`**
- Returns file size in bytes (portable across BSD/GNU stat)
- Returns `0` if file doesn't exist
- Example:
  ```sh
  size=$(gstreamer_file_size_bytes "/tmp/video.mp4")
  if [ "$size" -gt 1000 ]; then
    echo "File is valid"
  fi
  ```

### Pipeline Builders

**`gstreamer_build_v4l2_encode_pipeline <codec> <width> <height> <duration> <framerate> <bitrate> <output_file> <video_stack>`**
- Builds complete V4L2 encode pipeline with videotestsrc
- Parameters:
  - `codec`: `h264` or `h265`
  - `width`, `height`: Video dimensions
  - `duration`: Duration in seconds
  - `framerate`: Frames per second
  - `bitrate`: Bitrate in bps
  - `output_file`: Output file path
  - `video_stack`: `upstream` or `downstream` (adds IO mode parameters for downstream)
- Returns: Complete pipeline string (or empty if encoder not available)
- Example:
  ```sh
  pipeline=$(gstreamer_build_v4l2_encode_pipeline \
    "h264" 1920 1080 30 30 4000000 "/tmp/test.mp4" "upstream")
  gstreamer_run_gstlaunch_timeout 40 "$pipeline"
  ```

**`gstreamer_build_v4l2_decode_pipeline <codec> <input_file> <video_stack>`**
- Builds complete V4L2 decode pipeline
- Parameters:
  - `codec`: `h264`, `h265`, or `vp9`
  - `input_file`: Input file path
  - `video_stack`: `upstream` or `downstream`
- Returns: Complete pipeline string (or empty if decoder not available)
- Automatically handles:
  - Container format (MP4 for h264/h265, IVF for vp9)
  - Parser selection (h264parse, h265parse, ivfparse)
  - IO mode parameters for downstream stack
- Example:
  ```sh
  pipeline=$(gstreamer_build_v4l2_decode_pipeline \
    "h264" "/tmp/test.mp4" "upstream")
  gstreamer_run_gstlaunch_timeout 40 "$pipeline"
  ```

#### 5. `gstreamer_build_uvc_preview_pipeline`

Build pipeline for UVC camera live preview (used by UVC test).

- **Parameters**:
  - `device`: UVC device path (e.g., `/dev/video2`)
  - `width`: Video width (default: 1920)
  - `height`: Video height (default: 1080)
  - `framerate`: Framerate (default: 5)
- Returns: Complete pipeline string for UVC preview
- Automatically includes `qtivtransform` if available
- Example:
  ```sh
  uvc_dev=$(gstreamer_detect_uvc_camera)
  pipeline=$(gstreamer_build_uvc_preview_pipeline "$uvc_dev" "1920" "1080" "5")
  gstreamer_run_gstlaunch_timeout 30 "$pipeline"
  ```

#### 6. `gstreamer_build_drc_decode_pipeline`

Build pipeline for Dynamic Resolution Change H.264 decode test.

- **Parameters**:
  - `clip_path`: Path to DRC test clip
  - `video_stack`: `upstream` or `downstream`
- Returns: Complete pipeline string with fpsdisplaysink wrapper
- Example:
  ```sh
  pipeline=$(gstreamer_build_drc_decode_pipeline "/tmp/drc_clip.mp4" "downstream")
  gstreamer_run_gstlaunch_timeout 60 "$pipeline"
  ```

#### 7. `gstreamer_build_concurrency_decode_pipeline`

Build pipeline for concurrent decode tests with qtivcomposer and dynamic grid layouts.

- **Parameters**:
  - `codec`: `h264`, `h265`, or `mjpeg`
  - `clip_path`: Path to test clip
  - `video_stack`: `upstream` or `downstream`
  - `session_count`: Number of concurrent sessions (must be `2` or `8`)
- **Supported Session Layouts**:
  - **8 sessions** (required for H.264/H.265): 4x2 grid (480x540 per tile on 1920x1080 display)
  - **2 sessions** (required for MJPEG): 2x1 grid (960x1080 per tile on 1920x1080 display)
- **Codec-Specific Requirements**:
  - H.264/H.265: Must use exactly 8 sessions (enforced by validation)
  - MJPEG: Must use exactly 2 sessions (enforced by validation)
- Returns: Complete pipeline string with qtivcomposer grid layout, or empty on error
- Automatically handles:
  - Codec-specific decode chains (v4l2h264dec, v4l2h265dec, jpegdec)
  - Stack-dependent decoder arguments (IO modes for downstream)
  - Dynamic grid positioning based on session count
- Example (H.264 with 8 sessions):
  ```sh
  pipeline=$(gstreamer_build_concurrency_decode_pipeline \
    "h264" "/tmp/test.mp4" "downstream" "8")
  gstreamer_run_gstlaunch_timeout 40 "$pipeline"
  ```
- Example (MJPEG with 2 sessions):
  ```sh
  pipeline=$(gstreamer_build_concurrency_decode_pipeline \
    "mjpeg" "/tmp/test.avi" "upstream" "2")
  gstreamer_run_gstlaunch_timeout 40 "$pipeline"
  ```

#### 8. `gstreamer_build_smart_encode_pipeline`

Build pipeline for HEVC Smart Encode with dual camera streams.

- **Parameters**:
  - `output_file`: Output file path
- Returns: Complete pipeline string with qtismartvencbin
- Requires: qtiqmmfsrc, qtismartvencbin (downstream only)
- Example:
  ```sh
  pipeline=$(gstreamer_build_smart_encode_pipeline "/tmp/output.mp4")
  gstreamer_run_gstlaunch_timeout 40 "$pipeline"
  ```

#### 9. `gstreamer_build_camera_encode_pipeline`

Build pipeline for camera-based encoding with custom controls.

- **Parameters**:
  - `codec`: `h264` or `h265`
  - `width`: Video width
  - `height`: Video height
  - `output_file`: Output file path
  - `extra_controls`: Custom encoder controls string (optional)
  - `video_stack`: `upstream` or `downstream`
- Returns: Complete pipeline string with qtiqmmfsrc
- Example:
  ```sh
  controls="controls,video_bitrate=8000000,intra_refresh_period_type=1"
  pipeline=$(gstreamer_build_camera_encode_pipeline \
    "h265" "1920" "1080" "/tmp/output.mp4" "$controls" "downstream")
  gstreamer_run_gstlaunch_timeout 40 "$pipeline"
  ```

### Usage in Other Tests

To use these functions in your GStreamer test:

```sh
#!/bin/sh
# Source init_env and lib_gstreamer.sh
. "$INIT_ENV"
. "$TOOLS/functestlib.sh"
. "$TOOLS/lib_gstreamer.sh"

# Use the helpers
params=$(gstreamer_resolution_to_wh "4k")
width=$(printf '%s' "$params" | awk '{print $1}')
height=$(printf '%s' "$params" | awk '{print $2}')

bitrate=$(gstreamer_bitrate_for_resolution "$width" "$height")

pipeline=$(gstreamer_build_v4l2_encode_pipeline \
  "h264" "$width" "$height" 10 30 "$bitrate" "/tmp/output.mp4" "upstream")

if [ -n "$pipeline" ]; then
  gstreamer_run_gstlaunch_timeout 20 "$pipeline"
fi
```

### Testing Pipeline Builders

A test script is provided to verify the pipeline builders:

```bash
cd Runner/suites/Multimedia/GSTreamer/Video/Video_Encode_Decode
sh test_pipeline_builders.sh
```

This will output example pipelines for various codecs, resolutions, and video stacks.

---

## Notes for CI / LAVA

- The test always exits `0`.
- Use the `.res` file for result:
  - `PASS` - All tests passed
  - `FAIL` - One or more tests failed
  - `SKIP` - No tests executed or all skipped
- Test summary is logged showing pass/fail/skip counts
- Individual test logs are available in `logs/Video_Encode_Decode/`
- Encoded files are preserved in `logs/Video_Encode_Decode/encoded/` for debugging

### LAVA Environment Variables

The test supports these environment variables (can be set in LAVA job definition):

- `VIDEO_TEST_TYPE` - Test type (all/basic/uvc/drc/concurrency/advanced-encode) (default: all)
- `VIDEO_TEST_MODE` - Test mode (all/encode/decode) (default: all)
- `VIDEO_CODECS` - Comma-separated codec list (default: `h264,h265,vp9`)
- `VIDEO_RESOLUTIONS` - Comma-separated resolution list (default: `480p`)
- `VIDEO_DURATION` - Encoding duration in seconds (default: 30)
- `RUNTIMESEC` - Alternative to VIDEO_DURATION
- `VIDEO_FRAMERATE` - Video framerate (default: 30)
- `VIDEO_STACK` - Video stack selection (auto/upstream/downstream) (default: auto)
- `VIDEO_GST_DEBUG` - GStreamer debug level (default: 2)
- `GST_DEBUG_LEVEL` - Alternative to VIDEO_GST_DEBUG
- `VIDEO_CLIP_URL` - URL for test clip download (default: GitHub releases)
- `VIDEO_CLIP_PATH` - Local path to test clips (overrides VIDEO_CLIP_URL)
- `LAVA_TESTCASE_ID` - Override test case name for LAVA reporting (default: Video_Encode_Decode)

**Priority order for duration**: `VIDEO_DURATION` > `RUNTIMESEC` > default (30)

### LAVA Test Case Naming

The test supports flexible test case naming for LAVA integration:

- **Default behavior**: Reports results as `Video_Encode_Decode` in the `.res` file
- **LAVA override**: Set `LAVA_TESTCASE_ID` parameter in the YAML definition to match LAVA's expected test case name
- **Example YAML configuration**:
  ```yaml
  params:
    VIDEO_TEST_MODE: decode
    VIDEO_CODECS: h265
    VIDEO_RESOLUTIONS: 480p
    LAVA_TESTCASE_ID: "GStreamer_Video_Decode_h265_480p"  # Matches LAVA expected name
  ```
- This ensures LAVA correctly matches test results with expected test case names, avoiding "Unexpected test result" errors

### VP9-Specific Notes for CI/LAVA

- VP9 tests require network connectivity to download clips
- The test uses `ensure_network_online()` to establish connectivity automatically
- If network is unavailable, VP9 tests will SKIP (not FAIL)
- Downloaded clips are cached in the output directory for subsequent runs
- VP9 clip: VP9_640x480_10s.webm (640x480 resolution, WebM container)

---
