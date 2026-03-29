# Camera Tests - Comprehensive GStreamer Camera Validation

## Overview

This test suite provides comprehensive validation of camera functionality using GStreamer with two camera source plugins:
- **qtiqmmfsrc** (Qualcomm CAMX downstream) - 11 tests
- **libcamerasrc** (upstream) - 10 tests

Tests run in a specific sequence to validate different camera capabilities progressively.

## Camera Source Detection

The test suite automatically detects which camera source plugin is available:

1. **qtiqmmfsrc (Qualcomm CAMX downstream)**: Runs 11 tests
   - Fakesink (2) + Preview (2) + Encode (6) + Snapshot (1)
   - Priority: Used by default when both plugins are detected
   - Supports NV12 and UBWC formats
   
2. **libcamerasrc (upstream)**: Runs 10 tests
   - Fakesink (2) + Preview (3) + Encode (3) + 2A Features (2)
   - Used when qtiqmmfsrc is not available or explicitly requested
   - Supports NV12 format only
   
3. **Neither detected**: Test skipped

### Explicit Plugin Selection

Use `--plugin` option to explicitly select which camera source to test:

```bash
# Test qtiqmmfsrc explicitly (11 tests)
./run.sh --plugin qtiqmmfsrc

# Test libcamerasrc explicitly (10 tests)
./run.sh --plugin libcamerasrc

# Auto-detect (default - prioritizes qtiqmmfsrc)
./run.sh --plugin auto
```

## Test Cases

### qtiqmmfsrc Tests (11 Total)

#### 1. Fakesink Tests (2 tests)
Tests basic camera capture without encoding.

| Test Name | Format | Resolution | Command |
|-----------|--------|------------|---------|
| fakesink_nv12 | NV12 | 720p | `qtiqmmfsrc camera=0 ! video/x-raw,format=NV12,width=1280,height=720 ! queue ! fakesink` |
| fakesink_ubwc | UBWC | 720p | `qtiqmmfsrc camera=0 video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=1280,height=720 ! queue ! fakesink` |

#### 2. Preview Tests (2 tests)
Tests camera preview display on Weston at 4K.

| Test Name | Format | Resolution | Command |
|-----------|--------|------------|---------|
| preview_nv12_4k | NV12 | 4K | `qtiqmmfsrc camera=0 ! video/x-raw,format=NV12,width=3840,height=2160 ! waylandsink fullscreen=true async=true sync=false` |
| preview_ubwc_4k | UBWC | 4K | `qtiqmmfsrc camera=0 video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=3840,height=2160 ! waylandsink fullscreen=true async=true sync=false` |

#### 3. Encode Tests (6 tests)
Tests camera capture with H.264 hardware encoding.

| Test Name | Format | Resolution | Command |
|-----------|--------|------------|---------|
| encode_nv12_720p | NV12 | 720p | `qtiqmmfsrc camera=0 ! video/x-raw,format=NV12,width=1280,height=720 ! queue ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! queue ! filesink` |
| encode_nv12_1080p | NV12 | 1080p | `qtiqmmfsrc camera=0 ! video/x-raw,format=NV12,width=1920,height=1080 ! queue ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! queue ! filesink` |
| encode_nv12_4k | NV12 | 4K | `qtiqmmfsrc camera=0 ! video/x-raw,format=NV12,width=3840,height=2160 ! queue ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! queue ! filesink` |
| encode_ubwc_720p | UBWC | 720p | `qtiqmmfsrc camera=0 video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=1280,height=720 ! queue ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! queue ! filesink` |
| encode_ubwc_1080p | UBWC | 1080p | `qtiqmmfsrc camera=0 video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=1920,height=1080 ! queue ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! queue ! filesink` |
| encode_ubwc_4k | UBWC | 4K | `qtiqmmfsrc camera=0 video_0::type=preview ! video/x-raw,format=NV12_Q08C,width=3840,height=2160 ! queue ! v4l2h264enc capture-io-mode=4 output-io-mode=5 ! h264parse ! mp4mux ! queue ! filesink` |

#### 4. Snapshot Test (1 test)
Tests simultaneous video encoding and JPEG snapshot capture.

| Test Name | Format | Resolution | Command |
|-----------|--------|------------|---------|
| snapshot_nv12_720p | NV12 | 720p | `gst-pipeline-app qtiqmmfsrc camera=0 ! video/x-raw,format=NV12,width=1280,height=720 ! v4l2h264enc ! h264parse ! mp4mux ! filesink camsrc.image_1 ! image/jpeg ! multifilesink` |

---

### libcamerasrc Tests (10 Total)

#### 1. Fakesink Tests (2 tests)
Tests basic camera capture without encoding.

| Test Name | Resolution | Command |
|-----------|------------|---------|
| libcam_Default_Fakesink | Default | `libcamerasrc ! fakesink` |
| libcam_720p_Fakesink | 720p | `libcamerasrc ! video/x-raw,width=1280,height=720,framerate=30/1 ! fakesink` |

#### 2. Preview Tests (3 tests)
Tests camera preview display on Weston.

| Test Name | Resolution | Command |
|-----------|------------|---------|
| libcam_Default_Preview | Default | `libcamerasrc ! videoconvert ! waylandsink fullscreen=true` |
| libcam_720p_Preview | 720p | `libcamerasrc ! video/x-raw,width=1280,height=720,framerate=30/1 ! videoconvert ! waylandsink fullscreen=true` |
| libcam_1080p_Preview | 1080p | `libcamerasrc ! video/x-raw,width=1920,height=1080,framerate=30/1 ! videoconvert ! waylandsink fullscreen=true` |

#### 3. Encode Tests (3 tests)
Tests camera capture with H.264 hardware encoding.

| Test Name | Resolution | Command |
|-----------|------------|---------|
| libcam_720p_NV12_Encode | 720p | `libcamerasrc ! videoconvert ! video/x-raw,format=NV12,width=1280,height=720,framerate=30/1 ! v4l2h264enc capture-io-mode=4 output-io-mode=4 ! h264parse ! mp4mux ! filesink location=/opt/sample_720p.mp4` |
| libcam_1080p_NV12_Encode | 1080p | `libcamerasrc ! videoconvert ! video/x-raw,format=NV12,width=1920,height=1080,framerate=30/1 ! v4l2h264enc capture-io-mode=4 output-io-mode=4 ! h264parse ! mp4mux ! filesink location=/opt/sample_1080p.mp4` |
| libcam_4k_NV12_Encode | 4K | `libcamerasrc ! videoconvert ! video/x-raw,format=NV12,width=3840,height=2160,framerate=30/1 ! v4l2h264enc capture-io-mode=4 output-io-mode=4 ! h264parse ! mp4mux ! filesink location=/opt/sample_4k.mp4` |

#### 4. 2A Features Tests (2 tests)
Tests camera 2A (Auto Exposure/Auto White Balance) features.

| Test Name | Feature | Command |
|-----------|---------|---------|
| libcam_Disable_AE_AWB | Disable AE/AWB | `libcamerasrc ae-enable=false awb-enable=false ! videoconvert ! waylandsink` |
| libcam_Manual_Exposure_Gain | Manual Exposure/Gain | `libcamerasrc exposure-time-mode=manual exposure-time=10000 analogue-gain-mode=manual analogue-gain=2.0 ! videoconvert ! waylandsink` |

---

## Format Details

### NV12 (Linear Format)
- Standard uncompressed YUV 4:2:0 format
- Higher memory bandwidth usage
- Universal hardware support
- Supported by both qtiqmmfsrc and libcamerasrc
- GStreamer format string: `NV12`

### UBWC (Universal Bandwidth Compression)
- Qualcomm's proprietary compressed format
- Reduced memory bandwidth (optimized)
- Qualcomm-specific hardware support
- **Only supported by qtiqmmfsrc**
- GStreamer format string: `NV12_Q08C`
- **Note:** UBWC format requires `video_0::type=preview` in qtiqmmfsrc

## Parameters

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CAMERA_ID` | Camera device ID (qtiqmmfsrc only) | 0 |
| `CAMERA_PLUGIN` | Camera plugin: qtiqmmfsrc, libcamerasrc, auto | auto |
| `CAMERA_TEST_NAME` | Specific test name to run | (all) |
| `CAMERA_TEST_MODES` | Test modes (comma-separated) | fakesink,preview,encode,snapshot |
| `CAMERA_FORMATS` | Formats (qtiqmmfsrc only) | nv12,ubwc |
| `CAMERA_RESOLUTIONS` | Resolutions for tests | default,720p,1080p,4k |
| `CAMERA_FEATURE` | 2A feature (libcamerasrc only) | (all) |
| `CAMERA_FRAMERATE` | Capture framerate (fps) | 30 |
| `CAMERA_DURATION` | Test duration (seconds) | 10 |
| `CAMERA_GST_DEBUG` | GStreamer debug level (1-9) | 2 |

### Command Line Options

```bash
./run.sh [OPTIONS]

OPTIONS:
  --camera-id <id>        Camera device ID (qtiqmmfsrc only, default: 0)
  --plugin <name>         Camera plugin: qtiqmmfsrc, libcamerasrc, auto (default: auto)
  --test-name <name>      Specific test name to run
  --test-modes <list>     Test modes: fakesink,preview,encode,snapshot,features (default: all)
  --formats <list>        Formats: nv12,ubwc (qtiqmmfsrc only, default: both)
  --resolutions <list>    Resolutions: default,720p,1080p,4k (default: all)
                          default - Camera default resolution (no caps filter)
                          Note: libcamerasrc fakesink/preview support default
  --feature <name>        2A feature: disable_ae_awb, manual_exposure_gain (libcamerasrc only)
  --framerate <fps>       Framerate in fps (default: 30)
  --duration <seconds>    Test duration in seconds (default: 10)
  --gst-debug <level>     GStreamer debug level 1-9 (default: 2)
  -h, --help              Display help message
```

## Usage Examples

### Run All Tests (Auto-detect)
```bash
./run.sh
```
Runs all tests for the detected camera plugin (prioritizes qtiqmmfsrc if both available).

### Explicit Plugin Selection
```bash
# Test qtiqmmfsrc explicitly (11 tests)
./run.sh --plugin qtiqmmfsrc

# Test libcamerasrc explicitly (10 tests)
./run.sh --plugin libcamerasrc
```

### Run Specific Test Modes

#### qtiqmmfsrc Examples
```bash
# Run only fakesink tests (2 tests)
./run.sh --plugin qtiqmmfsrc --test-modes fakesink

# Run fakesink and encode tests (8 tests)
./run.sh --plugin qtiqmmfsrc --test-modes fakesink,encode

# Test only NV12 format (6 tests)
./run.sh --plugin qtiqmmfsrc --formats nv12

# Test only UBWC format (5 tests, no snapshot)
./run.sh --plugin qtiqmmfsrc --formats ubwc

# Test specific resolutions
./run.sh --plugin qtiqmmfsrc --resolutions 720p,1080p
```

#### libcamerasrc Examples
```bash
# Run only fakesink tests (2 tests)
./run.sh --plugin libcamerasrc --test-modes fakesink

# Run preview tests (3 tests)
./run.sh --plugin libcamerasrc --test-modes preview

# Run encode tests (3 tests)
./run.sh --plugin libcamerasrc --test-modes encode

# Run 2A features tests (2 tests)
./run.sh --plugin libcamerasrc --test-modes features

# Run specific 2A feature test
./run.sh --plugin libcamerasrc --test-modes features --feature disable_ae_awb
./run.sh --plugin libcamerasrc --test-modes features --feature manual_exposure_gain

# Test specific resolutions
./run.sh --plugin libcamerasrc --test-modes encode --resolutions 720p,1080p
```

### Combined Options
```bash
# qtiqmmfsrc: Test NV12 at 720p and 1080p for 20 seconds
./run.sh --plugin qtiqmmfsrc --formats nv12 --resolutions 720p,1080p --duration 20

# libcamerasrc: Test encode at 4K for 15 seconds
./run.sh --plugin libcamerasrc --test-modes encode --resolutions 4k --duration 15

# Use camera 1 with custom settings (qtiqmmfsrc only)
./run.sh --plugin qtiqmmfsrc --camera-id 1 --duration 15 --framerate 60
```

### Using Environment Variables
```bash
# qtiqmmfsrc
export CAMERA_PLUGIN="qtiqmmfsrc"
export CAMERA_ID=1
export CAMERA_FORMATS="nv12"
export CAMERA_RESOLUTIONS="720p,1080p"
export CAMERA_DURATION=20
./run.sh

# libcamerasrc
export CAMERA_PLUGIN="libcamerasrc"
export CAMERA_TEST_MODES="fakesink,preview,encode"
export CAMERA_DURATION=15
./run.sh
```

## Prerequisites

### Required Tools
- `gst-launch-1.0` - GStreamer command-line tool
- `gst-inspect-1.0` - GStreamer plugin inspector
- `gst-pipeline-app` - For qtiqmmfsrc snapshot test (optional)

### Required GStreamer Plugins

#### For qtiqmmfsrc (11 tests)
- `qtiqmmfsrc` - Qualcomm camera source plugin
- `v4l2h264enc` - V4L2 H.264 hardware encoder (for encode/snapshot tests)
- `waylandsink` - Wayland display sink (for preview tests)

#### For libcamerasrc (10 tests)
- `libcamerasrc` - Upstream camera source plugin
- `videoconvert` - Video format converter (required)
- `v4l2h264enc` - V4L2 H.264 hardware encoder (for encode tests)
- `waylandsink` - Wayland display sink (for preview/2A tests)

### Hardware Requirements
- Camera hardware (Qualcomm camera for qtiqmmfsrc, generic for libcamerasrc)
- Weston display server (for preview/2A tests)
- Write permissions to output directories

## Test Output

### Result Files
- **Camera_Tests.res** - Overall test result (PASS/FAIL/SKIP)

### Log Directory Structure

#### qtiqmmfsrc Logs
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
├── gst.log
├── dmesg/
└── encoded/
    ├── encode_nv12_720p.mp4
    ├── encode_nv12_1080p.mp4
    ├── encode_nv12_4k.mp4
    ├── encode_ubwc_720p.mp4
    ├── encode_ubwc_1080p.mp4
    ├── encode_ubwc_4k.mp4
    ├── mux_avc.mp4
    └── frame*.jpg
```

#### libcamerasrc Logs
```
logs/Camera_Tests/
├── libcam_Default_Fakesink.log
├── libcam_720p_Fakesink.log
├── libcam_Default_Preview.log
├── libcam_720p_Preview.log
├── libcam_1080p_Preview.log
├── libcam_720p_NV12_Encode.log
├── libcam_1080p_NV12_Encode.log
├── libcam_4k_NV12_Encode.log
├── libcam_Disable_AE_AWB.log
├── libcam_Manual_Exposure_Gain.log
├── gst.log
├── dmesg/
└── encoded/
    ├── sample_720p.mp4
    ├── sample_1080p.mp4
    └── sample_4k.mp4
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

### Snapshot Test (qtiqmmfsrc only)
- Pipeline executes without errors
- Video MP4 file is created (size > 1000 bytes)
- At least one JPEG snapshot file is created
- No GStreamer errors in logs

### 2A Features Tests (libcamerasrc only)
- Pipeline executes without errors
- Video displays on Weston screen with expected behavior
- No GStreamer errors in logs
- Exit code is 0

## Troubleshooting

### Test Skipped

**Camera plugin not available**
- qtiqmmfsrc: `gst-inspect-1.0 qtiqmmfsrc`
- libcamerasrc: `gst-inspect-1.0 libcamerasrc`

**v4l2h264enc plugin not available**
- Verify plugin: `gst-inspect-1.0 v4l2h264enc`

**waylandsink plugin not available**
- Verify plugin: `gst-inspect-1.0 waylandsink`

**videoconvert plugin not available (libcamerasrc)**
- Verify plugin: `gst-inspect-1.0 videoconvert`

### Test Failed

**No output file created**
- Check camera permissions: `ls -l /dev/video*`
- Verify camera device availability
- Check output directory write permissions

**File too small**
- Verify camera is capturing frames
- Check camera connection and power
- Review GStreamer logs for errors

**GStreamer errors**
- Check logs in `logs/Camera_Tests/` directory
- Review `gst.log` for detailed debug output
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
   - Check device permissions
   - Verify output directory permissions

3. **Format not supported**
   - qtiqmmfsrc: Check camera capabilities with `v4l2-ctl --list-formats-ext`
   - libcamerasrc: Only supports NV12 format
   - UBWC is qtiqmmfsrc-specific

4. **Weston not running**
   - Start Weston compositor
   - Set WAYLAND_DISPLAY environment variable
   - Preview/2A tests will be skipped if Weston is not available

## Performance Notes

### qtiqmmfsrc
- UBWC format provides better memory bandwidth efficiency
- Uses `output-io-mode=5` for optimal performance
- Supports camera ID selection for multi-camera systems

### libcamerasrc
- Uses `videoconvert` for format conversion
- Uses `output-io-mode=4` for standard V4L2 operation
- Supports 2A features (AE/AWB control)
- No camera ID support (uses default camera)

## Integration with LAVA

This test suite is LAVA-compatible:
- Uses YAML test definition format
- Emits PASS/FAIL/SKIP results to .res file
- Always exits with code 0 (LAVA-friendly)
- Supports environment variable configuration
- Provides comprehensive logging

## Notes

- Auto-detection prioritizes qtiqmmfsrc when both plugins are available
- Use `--plugin` to explicitly select which camera source to test
- qtiqmmfsrc supports NV12 and UBWC formats
- libcamerasrc supports NV12 format only
- UBWC format requires `video_0::type=preview` in qtiqmmfsrc
- libcamerasrc requires `videoconvert` element
- qtiqmmfsrc snapshot test uses `gst-pipeline-app`
- All tests automatically clean up GStreamer processes on exit
- Individual test run capability maintained for both plugins
