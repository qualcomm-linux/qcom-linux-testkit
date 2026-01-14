# GStreamer Camera Tests

**Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.**  
**SPDX-License-Identifier: BSD-3-Clause-Clear**

---

## Overview

This test suite validates GStreamer camera capture functionality on Qualcomm Linux platforms. Tests cover camera preview, hardware-accelerated encoding (H.264/H.265), and image capture (PNG/JPEG) using libcamera source and hardware encoders.

### Test Coverage

**5 Test Cases:**
- **Camera Preview**: Live camera preview to Wayland display
- **Camera H.264 Encode**: Capture and encode to H.264/MP4
- **Camera H.265 Encode**: Capture and encode to H.265/MP4
- **Camera Snapshot**: Capture single frame as PNG
- **Camera JPEG Encode**: Capture single frame as JPEG

**Key Features:**
- Uses libcamera source (`libcamerasrc`) for modern camera stack
- Hardware-accelerated encoding with V4L2 encoders
- Automatic camera detection via libcamera
- Configurable capture duration
- Multiple output formats (MP4, PNG, JPEG)
- Real-time preview capability

---

## Quick Start

```bash
cd Runner/suites/Gstreamer/Camera
./run.sh --all
```

---

## Test Pipelines

### Camera Preview (1080p @ 30fps, 5 seconds)
```bash
libcamerasrc num-buffers=150 ! \
  video/x-raw,width=1920,height=1080,framerate=30/1 ! \
  videoconvert ! \
  waylandsink
```
- **Purpose**: Validate camera capture and display pipeline
- **Duration**: 5 seconds (150 frames)
- **Output**: Live preview on Wayland display
- **Use Case**: Basic camera functionality test
- **Note**: Uses libcamera for camera access

### Camera H.264 Encode (1080p @ 30fps, 5 seconds)
```bash
libcamerasrc num-buffers=150 ! \
  video/x-raw,width=1920,height=1080,framerate=30/1 ! \
  videoconvert ! \
  video/x-raw,format=NV12 ! \
  v4l2h264enc extra-controls="controls,video_bitrate=4000000" ! \
  h264parse ! \
  qtmux ! \
  filesink location=camera_h264.mp4
```
- **Purpose**: Validate camera capture with H.264 hardware encoding
- **Duration**: 5 seconds (150 frames)
- **Bitrate**: 4 Mbps
- **Output**: `camera_h264.mp4`
- **Use Case**: Video recording with H.264 codec

### Camera H.265 Encode (1080p @ 30fps, 5 seconds)
```bash
libcamerasrc num-buffers=150 ! \
  video/x-raw,width=1920,height=1080,framerate=30/1 ! \
  videoconvert ! \
  video/x-raw,format=NV12 ! \
  v4l2h265enc extra-controls="controls,video_bitrate=4000000" ! \
  h265parse ! \
  qtmux ! \
  filesink location=camera_h265.mp4
```
- **Purpose**: Validate camera capture with H.265 hardware encoding
- **Duration**: 5 seconds (150 frames)
- **Bitrate**: 4 Mbps
- **Output**: `camera_h265.mp4`
- **Use Case**: Video recording with H.265 codec

### Camera Snapshot (1080p, single frame)
```bash
libcamerasrc num-buffers=1 ! \
  video/x-raw,width=1920,height=1080 ! \
  videoconvert ! \
  pngenc ! \
  filesink location=camera_snapshot.png
```
- **Purpose**: Capture single frame as PNG image
- **Resolution**: 1920x1080
- **Output**: `camera_snapshot.png`
- **Use Case**: Still image capture, lossless format

### Camera JPEG Encode (1080p, single frame)
```bash
libcamerasrc num-buffers=1 ! \
  video/x-raw,width=1920,height=1080 ! \
  videoconvert ! \
  jpegenc quality=90 ! \
  filesink location=camera_jpeg.jpg
```
- **Purpose**: Capture single frame as JPEG image
- **Resolution**: 1920x1080
- **Quality**: 90%
- **Output**: `camera_jpeg.jpg`
- **Use Case**: Still image capture, compressed format

---

## CLI Options

| Option | Description | Default |
|--------|-------------|---------|
| `--all` | Run all camera tests | - |
| `--test <name>` | Run specific test | - |
| `--list` | List available tests | - |
| `--timeout <sec>` | Timeout per test | 120 |
| `--camera <device>` | Camera device path | /dev/video0 |
| `--duration <sec>` | Capture duration | 5 |
| `--repeat <n>` | Repeat count | 1 |
| `--repeat-policy all\|any` | Pass policy | all |
| `--strict` | Fail on warnings | false |
| `--no-dmesg` | Skip dmesg scan | false |
| `--help` | Show help | - |

---

## Examples

### Run all tests
```bash
./run.sh --all
```

### Run specific test
```bash
./run.sh --test camera-preview
./run.sh --test camera-h264-encode
```

### Use different camera device
```bash
./run.sh --all --camera /dev/video2
```

### Longer capture duration
```bash
./run.sh --test camera-h264-encode --duration 10
```

### List available tests
```bash
./run.sh --list
```

### Run with repeat
```bash
./run.sh --test camera-snapshot --repeat 5
```

### Run with strict mode
```bash
./run.sh --all --strict
```

---

## Output Files

### Test Result
- `Gstreamer_Camera_Tests.res` - Overall PASS/FAIL/SKIP

### Logs Directory: `logs_Gstreamer_Camera_Tests/`
- `camera-preview.log` - Preview test log
- `camera-h264-encode.log` - H.264 encode test log
- `camera-h265-encode.log` - H.265 encode test log
- `camera-snapshot.log` - Snapshot test log
- `camera-jpeg-encode.log` - JPEG encode test log
- `summary.txt` - Per-test results summary
- `results.csv` - Machine-readable results
- `.junit_cases.xml` - JUnit XML for CI
- `dmesg_snapshot.log` - Kernel messages snapshot
- `dmesg_errors.log` - Kernel errors (if any)

### Captured Media Files
- `camera_h264.mp4` - H.264 encoded video (5 seconds @ 1080p)
- `camera_h265.mp4` - H.265 encoded video (5 seconds @ 1080p)
- `camera_snapshot.png` - PNG snapshot (1080p)
- `camera_jpeg.jpg` - JPEG snapshot (1080p, 90% quality)

---

## Validation Criteria

### Pass Criteria
A test PASSES if:
1. GStreamer pipeline exits with code 0
2. No ERROR patterns in log
3. No WARNING patterns (if `--strict` mode)
4. No kernel errors in dmesg (if enabled)
5. Camera device accessible and functional
6. For encoding tests: Output file created with size > 0
7. For preview test: Pipeline runs without errors

### Error Patterns Detected
- `ERROR:` - General GStreamer errors
- `failed to negotiate` - Format negotiation issues
- `could not link` - Element linking failures
- `no such element` - Missing GStreamer elements
- `failed to create element` - Element creation failures
- `cannot identify device` - Camera device not recognized
- `no such device` - Camera device not found
- `device busy` - Camera device in use by another process

---

## Dependencies

### Required GStreamer Plugins
- `libcamerasrc` - libcamera source (gstreamer1.0-libcamera)
- `videoconvert` - Format converter (gstreamer1.0-plugins-base)
- `v4l2h264enc` - H.264 hardware encoder (gstreamer1.0-plugins-good)
- `v4l2h265enc` - H.265 hardware encoder (gstreamer1.0-plugins-good)
- `h264parse` - H.264 parser (gstreamer1.0-plugins-bad)
- `h265parse` - H.265 parser (gstreamer1.0-plugins-bad)
- `qtmux` - MP4 muxer (gstreamer1.0-plugins-good)
- `pngenc` - PNG encoder (gstreamer1.0-plugins-good)
- `jpegenc` - JPEG encoder (gstreamer1.0-plugins-good)
- `waylandsink` - Wayland video sink (gstreamer1.0-plugins-bad)
- `filesink` - File output sink (gstreamer1.0-plugins-base)

### System Requirements
- libcamera installed and configured
- Camera accessible via libcamera
- V4L2 video encoder drivers loaded (for encoding tests)
- Wayland compositor running (for preview test)
- GStreamer 1.0 installed
- libcamera-apps (optional, for diagnostics with libcamera-hello)

### Verification Commands
```bash
# Check libcamera cameras
libcamera-hello --list-cameras

# Check GStreamer plugins
gst-inspect-1.0 libcamerasrc
gst-inspect-1.0 v4l2h264enc
gst-inspect-1.0 v4l2h265enc

# Test libcamera
libcamera-hello --timeout 2000

# Check camera driver
lsmod | grep -E 'video|camera'
dmesg | grep -i camera
```

---

## Troubleshooting

### Camera Not Detected by libcamera
```bash
# List cameras via libcamera
libcamera-hello --list-cameras

# Check libcamera installation
which libcamera-hello
gst-inspect-1.0 libcamerasrc

# Check camera driver
lsmod | grep -E 'video|camera|uvc'

# Check dmesg for camera
dmesg | grep -i camera

# Load camera driver if needed
modprobe uvcvideo  # For USB cameras
modprobe qcom_camss  # For Qualcomm cameras
```

### Camera Device Busy
```bash
# Check what's using the camera
lsof /dev/video0
fuser /dev/video0

# Kill processes using camera
fuser -k /dev/video0

# Check for other GStreamer processes
ps aux | grep gst-launch
```

### Permission Issues
```bash
# Check device permissions
ls -la /dev/video0

# Add user to video group
sudo usermod -a -G video $USER

# Verify group membership
groups $USER

# Set device permissions (temporary)
sudo chmod 666 /dev/video0
```

### Missing Plugins
```bash
# Check plugin availability
gst-inspect-1.0 v4l2src
gst-inspect-1.0 v4l2h264enc
gst-inspect-1.0 waylandsink

# Install packages (if missing)
apt-get install gstreamer1.0-plugins-base \
                gstreamer1.0-plugins-good \
                gstreamer1.0-plugins-bad \
                gstreamer1.0-tools \
                v4l-utils
```

### Pipeline Failures
```bash
# Run pipeline manually with verbose output
GST_DEBUG=3 gst-launch-1.0 -v libcamerasrc num-buffers=30 ! waylandsink

# Check log file
cat logs_Gstreamer_Camera_Tests/camera-preview.log

# Test simple camera capture
gst-launch-1.0 libcamerasrc ! autovideosink

# Test with libcamera directly
libcamera-hello --timeout 5000
```

### Format Negotiation Errors
```bash
# Check libcamera capabilities
libcamera-hello --list-cameras

# Try different resolution
./run.sh --test camera-preview  # Modify pipeline in run.sh if needed

# Check format capabilities
gst-inspect-1.0 libcamerasrc

# Test with libcamera-vid
libcamera-vid --timeout 5000 -o test.h264
```

### Encoding Failures
```bash
# Check if hardware encoders are available
gst-inspect-1.0 v4l2h264enc
gst-inspect-1.0 v4l2h265enc

# Check video encoder devices
ls -la /dev/video* | grep enc

# Test encoding manually
gst-launch-1.0 videotestsrc num-buffers=30 ! v4l2h264enc ! fakesink
```

### Preview Not Showing
```bash
# Check Wayland display
echo $WAYLAND_DISPLAY
echo $XDG_RUNTIME_DIR

# Start Wayland compositor
weston &

# Test with autovideosink
gst-launch-1.0 libcamerasrc ! autovideosink

# Test with libcamera-hello
libcamera-hello --timeout 5000
```

### Low Frame Rate
```bash
# Check libcamera capabilities
libcamera-hello --list-cameras

# Try lower resolution
# Modify pipeline to use 1280x720 or 640x480

# Check system load
top

# Test with libcamera-vid
libcamera-vid --width 1280 --height 720 --timeout 5000 -o test.h264
```

### Output File Empty
```bash
# Check disk space
df -h

# Check file permissions
ls -la camera_*.mp4

# Verify encoding completed
cat logs_Gstreamer_Camera_Tests/camera-h264-encode.log

# Test with longer duration
./run.sh --test camera-h264-encode --duration 10
```

---

## Supported Platforms

- **LeMans** (QCS9100, QCS9075)
- **Monaco** (QCS8300)
- **Kodiak** (QCS6490, QCM6490)
- **QCS8550, QCS8650**
- **SA8775P, SA8650P, SA8255P**

---

## Camera Detection with libcamera

### Finding Available Cameras
```bash
# List cameras via libcamera
libcamera-hello --list-cameras

# Example output shows camera index and capabilities
# Camera 0: imx219 [3280x2464]
# Camera 1: ov5647 [2592x1944]
```

### Camera Selection
libcamera automatically selects the first available camera. The `--camera` parameter is kept for compatibility but libcamera handles camera selection internally.

```bash
# Run tests (libcamera auto-selects camera)
./run.sh --all

# Set via environment variable (for compatibility)
export CAMERA_DEVICE=/dev/video0
./run.sh --all
```

### Testing Camera Access
```bash
# Test camera with libcamera-hello
libcamera-hello --timeout 5000

# Test camera with GStreamer
gst-launch-1.0 libcamerasrc num-buffers=30 ! autovideosink

# List camera properties
libcamera-hello --list-cameras --verbose
```

---

## CI/CD Integration

### LAVA Test Definition
```yaml
- test:
    definitions:
      - repository: <repo-url>
        from: git
        path: Runner/suites/Gstreamer/Camera/Gstreamer_Camera_Tests.yaml
        name: gstreamer-camera-tests
        parameters:
          TIMEOUT: "120"
          CAMERA_DEVICE: "/dev/video0"
          CAPTURE_DURATION: "5"
```

### Jenkins Pipeline
```groovy
stage('GStreamer Camera Tests') {
    steps {
        sh '''
            cd Runner/suites/Gstreamer/Camera
            ./run.sh --all --camera /dev/video0
        '''
    }
}
```

---

## Environment Variables

```bash
# Camera device
export CAMERA_DEVICE=/dev/video0

# Capture duration (seconds)
export CAPTURE_DURATION=5

# Timeout per test (seconds)
export TIMEOUT=120

# GStreamer debug level (0-9)
export GST_DEBUG=3

# Wayland display (for preview)
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/$(id -u)
```

---

## Performance Considerations

### Resolution vs Performance
- **1080p (1920x1080)**: Standard HD, good balance
- **720p (1280x720)**: Lower resource usage, faster encoding
- **4K (3840x2160)**: High quality, requires more resources

### Frame Rate Recommendations
- **30fps**: Standard video, good for most use cases
- **60fps**: Smooth motion, requires more bandwidth
- **15fps**: Low bandwidth, acceptable for monitoring

### Bitrate Guidelines
- **1080p @ 30fps**: 2-4 Mbps
- **720p @ 30fps**: 1-2 Mbps
- **4K @ 30fps**: 8-12 Mbps

---

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
