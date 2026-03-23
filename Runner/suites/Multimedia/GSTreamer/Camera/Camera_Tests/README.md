e# Camera Tests - Comprehensive GStreamer Camera Validation

## Overview

This test suite provides comprehensive validation of camera functionality using GStreamer with Qualcomm's qtiqmmfsrc plugin (downstream) or libcamerasrc (upstream). Tests run in a specific sequence to validate different camera capabilities progressively.

## Camera Source Detection

The test suite automatically detects which camera source plugin is available:

1. **qtiqmmfsrc (Qualcomm CAMX downstream)**: Runs 11 comprehensive tests
   - Priority: Used when both qtiqmmfsrc and libcamerasrc are detected
2. **libcamerasrc (upstream)**: Runs 2 basic tests (preview + encode)
   - Used only when qtiqmmfsrc is not available
3. **Neither detected**: Test skipped

**Note:** If both camera sources are detected, qtiqmmfsrc is prioritized as it provides Qualcomm-specific optimizations and more comprehensive test coverage.

## Test Sequence

Tests execute in the following order:

1. **Fakesink** - Basic camera capture validation (no encoding)
2. **Preview** - Camera preview on Weston display
3. **Encode** - Camera capture with H.264 hardware encoding
4. **Snapshot** - Simultaneous video encoding and JPEG snapshot capture

## Test Cases (11 Total)

### 1. Fakesink Tests (2 tests)
Tests basic camera capture without encoding to validate camera functionality.

| Test Name | Format | Resolution | Command |
|-----------|--------|------------|---------|
| fakesink_ubwc | UBWC (NV12_Q08C) | 720p | `qtiqmmfsrc video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=1280,height=720 ! fakesink` |
| fakesink_nv12 | NV12 | 720p | `qtiqmmfsrc ! video/x-raw,format=NV12,width=1280,height=720 ! fakesink` |

### 2. Preview Tests (2 tests)
Tests camera preview display on Weston compositor at 4K resolution.

| Test Name | Format | Resolution | Command |
|-----------|--------|------------|---------|
| preview_ubwc_4k | UBWC (NV12_Q08C) | 4K (3840x2160) | `qtiqmmfsrc video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=3840,height=2160 ! waylandsink fullscreen=true` |
| preview_nv12_4k | NV12 | 4K (3840x2160) | `qtiqmmfsrc ! video/x-raw,format=NV12,width=3840,height=2160 ! waylandsink fullscreen=true` |

### 3. Encode Tests (6 tests)
Tests camera capture with H.264 hardware encoding at multiple resolutions.

| Test Name | Format | Resolution | Command |
|-----------|--------|------------|---------|
| encode_ubwc_4k | UBWC (NV12_Q08C) | 4K (3840x2160) | `qtiqmmfsrc video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=3840,height=2160 ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! filesink` |
| encode_ubwc_1080p | UBWC (NV12_Q08C) | 1080p (1920x1080) | `qtiqmmfsrc video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=1920,height=1080 ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! filesink` |
| encode_ubwc_720p | UBWC (NV12_Q08C) | 720p (1280x720) | `qtiqmmfsrc video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=1280,height=720 ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! filesink` |
| encode_nv12_4k | NV12 | 4K (3840x2160) | `qtiqmmfsrc ! video/x-raw,format=NV12,width=3840,height=2160 ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! filesink` |
| encode_nv12_1080p | NV12 | 1080p (1920x1080) | `qtiqmmfsrc ! video/x-raw,format=NV12,width=1920,height=1080 ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! filesink` |
| encode_nv12_720p | NV12 | 720p (1280x720) | `qtiqmmfsrc ! video/x-raw,format=NV12,width=1280,height=720 ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! filesink` |

### 4. Snapshot Test (1 test)
Tests simultaneous video encoding and JPEG snapshot capture.

| Test Name | Format | Resolution | Command |
|-----------|--------|------------|---------|
| snapshot_nv12_720p | NV12 | 720p (1280x720) | `gst-pipeline-app qtiqmmfsrc ! video/x-raw,format=NV12,width=1280,height=720 ! v4l2h264enc ! h264parse ! mp4mux ! filesink camsrc.image_1 ! image/jpeg ! multifilesink` |

## Format Details

### NV12 (Linear Format)
- Standard uncompressed YUV 4:2:0 format
- Higher memory bandwidth usage
- Universal hardware support
- GStreamer format string: `NV12`
- Pipeline: `qtiqmmfsrc ! video/x-raw,format=NV12 ! ...`

### UBWC (Universal Bandwidth Compression)
- Qualcomm's proprietary compressed format
- Reduced memory bandwidth (optimized)
- Qualcomm-specific hardware support
- GStreamer format string: `NV12_Q08C`
- Pipeline: `qtiqmmfsrc video_0::type=preview ! video/x-raw,format=NV12_Q08C ! ...`
- **Note:** UBWC format requires `video_0::type=preview` in qtiqmmfsrc

## Parameters

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CAMERA_ID` | Camera device ID | 0 |
| `CAMERA_TEST_MODES` | Test modes to run (comma-separated) | fakesink,preview,encode,snapshot |
| `CAMERA_FORMATS` | Formats to test (comma-separated) | nv12,ubwc |
| `CAMERA_RESOLUTIONS` | Resolutions for encode tests | 720p,1080p,4k |
| `CAMERA_FRAMERATE` | Capture framerate (fps) | 30 |
| `CAMERA_DURATION` | Test duration (seconds) | 10 |
| `CAMERA_GST_DEBUG` | GStreamer debug level (1-9) | 2 |

### Command Line Options

```bash
./run.sh [OPTIONS]

OPTIONS:
  --camera-id <id>        Camera device ID (default: 0)
  --test-modes <list>     Test modes: fakesink,preview,encode,snapshot (default: all)
  --formats <list>        Formats: nv12,ubwc (default: both)
  --resolutions <list>    Resolutions: 720p,1080p,4k (default: all)
  --framerate <fps>       Framerate in fps (default: 30)
  --duration <seconds>    Test duration in seconds (default: 10)
  --gst-debug <level>     GStreamer debug level 1-9 (default: 2)
  -h, --help              Display help message
```

## Usage Examples

### Run All Tests (Default)
```bash
./run.sh
```
Runs all 11 tests in sequence with default settings.

### Run Specific Test Modes
```bash
# Run only fakesink tests (2 tests)
./run.sh --test-modes fakesink

# Run fakesink and encode tests (8 tests)
./run.sh --test-modes fakesink,encode

# Run encode and snapshot tests (7 tests)
./run.sh --test-modes encode,snapshot
```

### Test Specific Formats
```bash
# Test only NV12 format (6 tests: 2 fakesink + 2 preview + 3 encode + 1 snapshot)
./run.sh --formats nv12

# Test only UBWC format (5 tests: 2 fakesink + 2 preview + 3 encode, no snapshot)
./run.sh --formats ubwc
```

### Test Specific Resolutions
```bash
# Test only 720p resolution for encode tests
./run.sh --resolutions 720p

# Test 720p and 1080p only
./run.sh --resolutions 720p,1080p
```

### Combined Options
```bash
# Test NV12 format at 720p and 1080p for 20 seconds each
./run.sh --formats nv12 --resolutions 720p,1080p --duration 20

# Run only encode tests with UBWC at 4K
./run.sh --test-modes encode --formats ubwc --resolutions 4k

# Use camera 1 with custom settings
./run.sh --camera-id 1 --duration 15 --framerate 60
```

### Using Environment Variables
```bash
export CAMERA_ID=1
export CAMERA_FORMATS="nv12"
export CAMERA_RESOLUTIONS="720p,1080p"
export CAMERA_DURATION=20
./run.sh
```

## Prerequisites

### Required Tools
- `gst-launch-1.0` - GStreamer command-line tool
- `gst-inspect-1.0` - GStreamer plugin inspector
- `gst-pipeline-app` - For snapshot test (optional)

### Required GStreamer Plugins
- `qtiqmmfsrc` - Qualcomm camera source plugin
- `v4l2h264enc` - V4L2 H.264 hardware encoder (for encode/snapshot tests)
- `waylandsink` - Wayland display sink (for preview tests)

### Hardware Requirements
- Qualcomm camera hardware
- Weston display server (for preview tests)
- Write permissions to output directories

## Test Output

### Result Files
- **Camera_Tests.res** - Overall test result (PASS/FAIL/SKIP)

### Log Directory Structure
```
logs/Camera_Tests/
├── fakesink_nv12.log
├── fakesink_ubwc.log
├── preview_nv12_4k.log
├── preview_ubwc_4k.log
├── encode_nv12_720p.log
├── encode_nv12_1080p.log
├── encode_nv12_4k.log
├── encode_ubwc_720p.log
├── encode_ubwc_1080p.log
├── encode_ubwc_4k.log
├── snapshot_nv12_720p.log
├── gst.log (GStreamer debug log)
├── dmesg/ (kernel message logs)
└── encoded/ (output video files and snapshots)
    ├── encode_nv12_720p.mp4
    ├── encode_nv12_1080p.mp4
    ├── encode_nv12_4k.mp4
    ├── encode_ubwc_720p.mp4
    ├── encode_ubwc_1080p.mp4
    ├── encode_ubwc_4k.mp4
    ├── mux_avc.mp4 (snapshot test video)
    └── frame*.jpg (snapshot test JPEG files)
```

## Success Criteria

### Fakesink Tests
- Pipeline executes without errors
- No GStreamer errors in logs
- Exit code is 0

### Preview Tests
- Pipeline executes without errors
- Video displays on Weston screen
- No GStreamer errors in logs
- Exit code is 0

### Encode Tests
- Pipeline executes without errors
- Output MP4 file is created
- File size > 1000 bytes
- No GStreamer errors in logs

### Snapshot Test
- Pipeline executes without errors
- Video MP4 file is created (size > 1000 bytes)
- At least one JPEG snapshot file is created
- No GStreamer errors in logs

## Troubleshooting

### Test Skipped

**qtiqmmfsrc plugin not available**
- Install GStreamer qtiqmmfsrc plugin
- Verify plugin: `gst-inspect-1.0 qtiqmmfsrc`

**v4l2h264enc plugin not available**
- Ensure V4L2 encoder support is enabled
- Verify plugin: `gst-inspect-1.0 v4l2h264enc`

**waylandsink plugin not available**
- Install GStreamer Wayland plugin
- Verify plugin: `gst-inspect-1.0 waylandsink`

**gst-pipeline-app not available**
- Install gst-pipeline-app tool
- Snapshot test will be skipped if not available

### Test Failed

**No output file created**
- Check camera permissions and availability
- Verify camera device: `ls -l /dev/video*`
- Check output directory write permissions

**File too small**
- Verify camera is functioning and capturing frames
- Check camera connection and power
- Review GStreamer logs for errors

**GStreamer errors**
- Check logs in `logs/Camera_Tests/` directory
- Review `gst.log` for detailed GStreamer debug output
- Check `dmesg/` for kernel-level errors

**Preview not displaying**
- Verify Weston is running: `echo $WAYLAND_DISPLAY`
- Check XDG_RUNTIME_DIR is set
- Ensure display permissions are correct

### Common Issues

1. **Camera not detected**
   - Verify camera hardware is connected
   - Check kernel logs: `dmesg | grep camera`
   - List video devices: `ls -l /dev/video*`

2. **Permission denied**
   - Add user to video group: `sudo usermod -a -G video $USER`
   - Check device permissions: `ls -l /dev/video*`
   - Verify output directory permissions

3. **Format not supported**
   - Check camera capabilities: `v4l2-ctl --list-formats-ext`
   - Verify format support in qtiqmmfsrc
   - Some cameras may not support UBWC format

4. **Weston not running**
   - Start Weston compositor
   - Set WAYLAND_DISPLAY environment variable
   - Preview tests will be skipped if Weston is not available

## Performance Notes

- **UBWC format** provides better memory bandwidth efficiency compared to linear NV12
- **Encode tests** use `capture-io-mode=4` and `output-io-mode=5` for optimal performance with Qualcomm hardware
- **Test duration** can be adjusted based on validation requirements (shorter for quick checks, longer for stability testing)
- **4K tests** require more processing power and may take longer to complete

## Integration with LAVA

This test suite is LAVA-compatible:
- Uses YAML test definition format
- Emits PASS/FAIL/SKIP results to .res file
- Always exits with code 0 (LAVA-friendly)
- Supports environment variable configuration
- Provides comprehensive logging

## Notes

- Tests run sequentially in the order: fakesink → preview → encode → snapshot
- Each test category can be run independently using `--test-modes`
- UBWC format requires `video_0::type=preview` in qtiqmmfsrc pipeline
- NV12 format does not use `video_0::type=preview`
- Snapshot test uses `gst-pipeline-app` instead of `gst-launch-1.0`
- All tests automatically clean up GStreamer processes on exit
