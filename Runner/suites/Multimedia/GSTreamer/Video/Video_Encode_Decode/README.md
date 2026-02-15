# Video_Encode_Decode (GStreamer) — Runner Test

This directory contains the **Video_Encode_Decode** validation test for Qualcomm Linux Testkit runners.

It validates video **encoding and decoding** using **GStreamer (`gst-launch-1.0`)** with V4L2 hardware-accelerated codecs:
- **v4l2h264enc** / **v4l2h264dec** (H.264/AVC)
- **v4l2h265enc** / **v4l2h265dec** (H.265/HEVC)
- **v4l2vp9dec** (VP9 decode only - uses pre-downloaded clips)

The script is designed to be **CI/LAVA-friendly**:
- Writes **PASS/FAIL/SKIP** into `Video_Encode_Decode.res`
- Always **exits 0** (even on FAIL/SKIP) to avoid terminating LAVA jobs early
- Logs the **final `gst-launch-1.0` command** to console and to log files
- Uses **videotestsrc** plugin to generate test patterns for H.264/H.265 (no external video files needed)
- For VP9: Downloads pre-encoded clips from git repo (requires network connectivity)

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
   - Tests 4K resolution (3840x2160) by default
6. **Decoding phase**:
   - Reads the previously encoded files (H.264/H.265) or downloaded clips (VP9)
   - Decodes using V4L2 hardware decoders
   - Outputs to fakesink (no display needed)
7. Collects test results and emits PASS/FAIL/SKIP

---

## Test Cases

By default, the test runs the following test cases at 4K resolution for H.264/H.265, plus VP9 decode:

### Encoding Tests
1. **encode_h264_4k** - Encode H.264 at 3840x2160 resolution
2. **encode_h265_4k** - Encode H.265 at 3840x2160 resolution

**Note:** VP9 encoding is not supported (no v4l2vp9enc available)

### Decoding Tests
1. **decode_h264_4k** - Decode H.264 4K encoded file
2. **decode_h265_4k** - Decode H.265 4K encoded file
3. **decode_vp9** - Decode VP9 pre-downloaded clip (320_240_10fps.ivf) - **runs by default**

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
- For VP9 decode tests: network connectivity unavailable or clip download failed

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
  decode_vp9.log             # VP9 decode test log
  encoded/                   # Encoded video files
    encode_h264_480p.h264
    encode_h264_4k.h264
    encode_h265_480p.h265
    encode_h265_4k.h265
  320_240_10fps.ivf          # Downloaded VP9 clip (if network available)
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
- `ivfparse` - IVF container parser (for VP9)

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

- `--mode <all|encode|decode>`
  - Default: `all` (run both encode and decode tests)
  - `encode`: Run only encoding tests
  - `decode`: Run only decoding tests (requires encoded files from previous encode run)

- `--codecs <h264,h265,vp9>`
  - Comma-separated list of codecs to test
  - Default: `h264,h265,vp9` (all three codecs run by default)
  - Examples: `h264`, `h265`, `h264,h265`, `vp9`, `h264,vp9`
  - Note: VP9 only supports decode (no encode)

- `--resolutions <480p,4k>`
  - Comma-separated list of resolutions to test
  - Default: `480p,4k`
  - Supported: `480p` (640x480), `720p` (1280x720), `1080p` (1920x1080), `4k` (3840x2160)
  - Examples: `480p`, `4k`, `480p,1080p,4k`

- `--duration <seconds>`
  - Duration for encoding (in seconds)
  - Default: `5`
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

---

## Examples

### 1) Run all tests (default - encode + decode for H.264/H.265 at 4K, plus VP9 decode)

```bash
./run.sh
```

### 2) Run only encoding tests

```bash
./run.sh --mode encode
```

### 3) Run only decoding tests (requires encoded files from previous run)

```bash
./run.sh --mode decode
```

### 4) Test only H.264 codec

```bash
./run.sh --codecs h264
```

### 5) Test only H.265 codec at 4K resolution

```bash
./run.sh --codecs h265 --resolutions 4k
```

### 6) Test all codecs at 480p only

```bash
./run.sh --resolutions 480p
```

### 7) Test with longer duration (10 seconds)

```bash
./run.sh --duration 10
```

### 8) Test with higher framerate (60fps)

```bash
./run.sh --framerate 60
```

### 9) Test multiple resolutions

```bash
./run.sh --resolutions 480p,720p,1080p,4k
```

### 10) Increase GStreamer debug verbosity

```bash
./run.sh --gst-debug 5
```

### 11) Quick test - H.264 only at 480p with 3 second duration

```bash
./run.sh --codecs h264 --resolutions 480p --duration 3
```

### 12) Test VP9 decode only (requires network connectivity)

```bash
./run.sh --codecs vp9 --mode decode
```

### 13) Test all codecs including VP9

```bash
./run.sh --codecs h264,h265,vp9
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
filesrc location=320_240_10fps.ivf 
  ! ivfparse 
  ! v4l2vp9dec 
  ! videoconvert 
  ! fakesink
```

Where:
- `ivfparse` parses IVF container format (VP9 native container)
- No `qtdemux` needed (unlike H.264/H.265 in MP4)
- Input file is pre-downloaded from git repo
- Resolution: 320x240

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
- Check if clip was downloaded: `ls -l logs/Video_Encode_Decode/320_240_10fps.ivf`
- Manually download if needed:
  ```bash
  cd logs/Video_Encode_Decode/
  wget https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz
  tar -xzf video_clips_iris.tar.gz
  ```
- Check network connectivity:
  ```bash
  ping -c 3 github.com
  ```

### I) VP9 decode fails with "ivfparse not found"
- Ensure `ivfparse` GStreamer plugin is installed:
  ```bash
  gst-inspect-1.0 ivfparse
  ```
- This is typically part of `gst-plugins-bad` package

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

- `VIDEO_TEST_MODE` - Test mode (all/encode/decode)
- `VIDEO_CODECS` - Comma-separated codec list (default: `h264,h265,vp9`)
- `VIDEO_RESOLUTIONS` - Comma-separated resolution list
- `VIDEO_DURATION` - Encoding duration in seconds
- `VIDEO_FRAMERATE` - Video framerate
- `VIDEO_STACK` - Video stack selection
- `VIDEO_GST_DEBUG` - GStreamer debug level
- `VIDEO_CLIP_URL` - URL for VP9 clip download (default: GitHub releases)
- `RUNTIMESEC` - Alternative to VIDEO_DURATION

### VP9-Specific Notes for CI/LAVA

- VP9 tests require network connectivity to download clips
- The test uses `ensure_network_online()` to establish connectivity automatically
- If network is unavailable, VP9 tests will SKIP (not FAIL)
- Downloaded clips are cached in the output directory for subsequent runs
- VP9 clip: 320_240_10fps.ivf (320x240 resolution, IVF container)

---
