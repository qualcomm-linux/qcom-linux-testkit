# GStreamer Test Suite

## Overview

This directory contains comprehensive GStreamer validation tests for Qualcomm platforms, organized into four independent test categories:

1. **Video** - Hardware-accelerated video encoding/decoding tests
2. **Audio** - Audio capture and playback tests
3. **Display** - Video display tests using Wayland
4. **Camera** - Camera capture, encoding, and snapshot tests using libcamera

Each subfolder is a standalone test suite with its own `run.sh`, YAML configuration, and README documentation. A master `run.sh` in this directory orchestrates all test suites for comprehensive validation.

## Directory Structure

```
Gstreamer/
├── README.md                    # This file
├── run.sh                       # Master test runner (runs all suites)
├── Video/                       # Video encoding/decoding tests
│   ├── run.sh                   # Video test runner
│   ├── Gstreamer_Video_Tests.yaml
│   └── README.md                # Video test documentation
├── Audio/                       # Audio capture/playback tests
│   ├── run.sh                   # Audio test runner
│   ├── Gstreamer_Audio_Tests.yaml
│   └── README.md                # Audio test documentation
├── Display/                     # Video display tests
│   ├── run.sh                   # Display test runner
│   ├── Gstreamer_Display_Tests.yaml
│   └── README.md                # Display test documentation
└── Camera/                      # Camera capture/encoding tests
    ├── run.sh                   # Camera test runner
    ├── Gstreamer_Camera_Tests.yaml
    └── README.md                # Camera test documentation
```

## Test Categories

### 1. Video Tests (`Video/`)

Hardware-accelerated video encoding and decoding using V4L2 codecs.

**Test Cases (10 total):**
- `h264-480p-encode` / `h264-4k-encode` - H.264 encoding at 480p and 4K
- `h265-480p-encode` / `h265-4k-encode` - H.265 encoding at 480p and 4K
- `h264-480p-decode` / `h264-4k-decode` - H.264 decoding (uses encode outputs)
- `h265-480p-decode` / `h265-4k-decode` - H.265 decoding (uses encode outputs)
- `vp9-480p-decode` / `vp9-4k-decode` - VP9 decoding (auto-fetches test clips)

**Key Features:**
- V4L2 hardware acceleration
- Multiple codec support (H.264, H.265, VP9)
- Multiple resolutions (480p, 4K)
- Encode-then-decode validation flow
- Automatic VP9 clip fetching from GitHub

**Quick Start:**
```bash
cd Video
./run.sh  # Runs all tests by default
```

**Documentation:** See [Video/README.md](Video/README.md)

### 2. Audio Tests (`Audio/`)

Audio capture and playback using PulseAudio.

**Test Cases (2 total):**
- `audio-encode` - Audio capture to WAV file
- `audio-decode` - WAV file playback

**Key Features:**
- PulseAudio integration
- WAV format encoding/decoding
- Controlled capture duration
- Audio device validation

**Quick Start:**
```bash
cd Audio
./run.sh  # Runs all tests by default
```

**Documentation:** See [Audio/README.md](Audio/README.md)

### 3. Display Tests (`Display/`)

Video display validation using Wayland compositor with videotestsrc.

**Test Cases (4 total):**
- `wayland-basic` - 480p SMPTE bars @ 30fps
- `wayland-videotestsrc` - 1080p moving ball @ 30fps
- `wayland-colorbar` - 4K color bars @ 30fps
- `wayland-smpte` - 720p SMPTE bars @ 60fps

**Key Features:**
- Wayland compositor integration
- videotestsrc pattern generation (no external files needed)
- Multiple resolutions (480p, 720p, 1080p, 4K)
- Multiple frame rates (30fps, 60fps)
- Wayland surface validation

**Quick Start:**
```bash
cd Display
./run.sh  # Runs all tests by default
```

**Documentation:** See [Display/README.md](Display/README.md)

### 4. Camera Tests (`Camera/`)

Camera capture, encoding, and snapshot tests using libcamera.

**Test Cases (5 total):**
- `camera-preview` - Live camera preview to Wayland
- `camera-h264-encode` - Capture and encode to H.264/MP4
- `camera-h265-encode` - Capture and encode to H.265/MP4
- `camera-snapshot` - Capture single frame as PNG
- `camera-jpeg-encode` - Capture single frame as JPEG

**Key Features:**
- libcamera source (modern camera stack)
- Hardware-accelerated encoding with V4L2 encoders
- Automatic camera detection
- Multiple output formats (MP4, PNG, JPEG)
- Real-time preview capability

**Quick Start:**
```bash
cd Camera
./run.sh  # Runs all tests by default
```

**Documentation:** See [Camera/README.md](Camera/README.md)

## Common Features

All test suites share the same validation framework and CLI interface:

### CLI Options

| Option | Description | Default |
|--------|-------------|---------|
| `--all` | Run all tests in suite | - |
| `--test <name>` | Run specific test | - |
| `--list` | List available tests | - |
| `--timeout <sec>` | Timeout per test | 120 |
| `--repeat <n>` | Repeat count | 1 |
| `--repeat-policy <all\|any>` | Pass policy | all |
| `--strict` | Fail on warnings | false |
| `--no-dmesg` | Skip dmesg scan | false |
| `--help` | Show help | - |

### Validation Framework

Each test suite uses the same validation approach:

1. **Dependency Checks** - Verify required packages and tools
2. **Pre-execution Validation** - Check hardware/software prerequisites
3. **Pipeline Execution** - Run GStreamer pipelines with timeout
4. **Output Validation** - Check for errors, warnings, and failures
5. **dmesg Scanning** - Detect kernel errors (optional)
6. **Result Reporting** - Generate .res, logs, CSV, and JUnit XML

### Result Files

Each test suite generates:
- `<TestName>.res` - Overall PASS/FAIL/SKIP status
- `logs_<TestName>/` - Detailed logs directory
  - `<test-name>.log` - Individual test logs
  - `summary.txt` - Test summary
  - `results.csv` - CSV format results
  - `.junit_cases.xml` - JUnit XML for CI
  - `dmesg_snapshot.log` - Kernel messages
  - `dmesg_errors.log` - Kernel errors (if any)

## Prerequisites

### Common Requirements

```bash
# GStreamer core
gstreamer1.0-tools
gstreamer1.0-plugins-base
gstreamer1.0-plugins-good
gstreamer1.0-plugins-bad

# System utilities
timeout
dmesg
```

### Video-Specific Requirements
- V4L2 video devices (`/dev/video*`)
- V4L2 codec drivers (qcom_iris or iris_vpu)
- Network connectivity (for VP9 clip fetching)

### Audio-Specific Requirements
- PulseAudio server running
- Audio capture device (microphone)
- Audio playback device (speakers/headphones)

### Display-Specific Requirements
- Wayland compositor (Weston, Mutter)
- Display output connected
- DRM/KMS display driver

### Camera-Specific Requirements
- libcamera installed and configured
- Camera accessible via libcamera
- V4L2 video encoder drivers (for encoding tests)
- Wayland compositor (for preview test)

## Running Tests

### Run All Test Suites (Master Runner)

The master `run.sh` in the Gstreamer directory runs all test suites:

```bash
# Run all GStreamer test suites
cd Runner/suites/Gstreamer
./run.sh

# Or using run-test.sh from Runner directory
cd Runner
./run-test.sh Gstreamer

# Run specific suite only
cd Runner/suites/Gstreamer
./run.sh --suite Video
./run.sh --suite Camera

# List available suites
./run.sh --list
```

**Master Runner Output:**
- `Gstreamer.res` - Overall PASS/FAIL status
- `logs_Gstreamer/summary.txt` - Combined results from all suites
- Individual suite results in their respective folders

### Run Individual Test Suites

```bash
# Video tests (runs all 10 tests by default)
cd Video && ./run.sh

# Audio tests (runs all 2 tests by default)
cd Audio && ./run.sh

# Display tests (runs all 4 tests by default)
cd Display && ./run.sh

# Camera tests (runs all 5 tests by default)
cd Camera && ./run.sh
```

### Run Specific Tests

```bash
# Video encoding only
cd Video && ./run.sh --test h264-480p-encode

# Audio capture only
cd Audio && ./run.sh --test audio-encode

# Display test only
cd Display && ./run.sh --test wayland-basic

# Camera preview only
cd Camera && ./run.sh --test camera-preview
```

### Run with Custom Parameters

```bash
# Increase timeout
./run.sh --all --timeout 180

# Enable strict mode
./run.sh --all --strict

# Repeat tests
./run.sh --all --repeat 3 --repeat-policy any

# Disable dmesg scanning
./run.sh --all --no-dmesg
```

## CI/CD Integration

### LAVA Test Plans

Each test suite has its own YAML definition for LAVA integration:

```yaml
# Video tests
- test:
    definitions:
      - path: Runner/suites/Gstreamer/Video/Gstreamer_Video_Tests.yaml

# Audio tests
- test:
    definitions:
      - path: Runner/suites/Gstreamer/Audio/Gstreamer_Audio_Tests.yaml

# Display tests
- test:
    definitions:
      - path: Runner/suites/Gstreamer/Display/Gstreamer_Display_Tests.yaml

# Camera tests
- test:
    definitions:
      - path: Runner/suites/Gstreamer/Camera/Gstreamer_Camera_Tests.yaml
```

### Standalone Execution

```bash
# From repository root - run all suites
cd Runner/suites/Gstreamer && ./run.sh

# Or run individual suites
cd Runner/suites/Gstreamer/Video && ./run.sh
cd Runner/suites/Gstreamer/Audio && ./run.sh
cd Runner/suites/Gstreamer/Display && ./run.sh
cd Runner/suites/Gstreamer/Camera && ./run.sh
```

## Platform Support

| Platform | Video | Audio | Display | Camera | Notes |
|----------|-------|-------|---------|--------|-------|
| QCS6490 | ✓ | ✓ | ✓ | ✓ | Full support |
| QCS8550 | ✓ | ✓ | ✓ | ✓ | Full support |
| QCS8650 | ✓ | ✓ | ✓ | ✓ | Full support |
| SA8775P | ✓ | ✓ | ✓ | ✓ | Full support |
| SA8650P | ✓ | ✓ | ✓ | ✓ | Full support |
| SA8255P | ✓ | ✓ | ✓ | ✓ | Full support |

## Troubleshooting

### Common Issues

1. **Missing Dependencies**
   ```bash
   # Install GStreamer packages
   apt-get install gstreamer1.0-tools gstreamer1.0-plugins-*
   ```

2. **Permission Errors**
   ```bash
   # Add user to video/audio groups
   sudo usermod -a -G video,audio $USER
   ```

3. **Device Not Found**
   ```bash
   # Check video devices
   ls -la /dev/video*
   
   # Check audio devices
   pactl list sources short
   pactl list sinks short
   
   # Check cameras
   libcamera-hello --list-cameras
   ```

4. **Pipeline Failures**
   ```bash
   # Enable debug output
   GST_DEBUG=3 gst-launch-1.0 <pipeline>
   
   # Check element availability
   gst-inspect-1.0 <element-name>
   ```

### Test-Specific Troubleshooting

- **Video Tests:** See [Video/README.md](Video/README.md#troubleshooting)
- **Audio Tests:** See [Audio/README.md](Audio/README.md#troubleshooting)
- **Display Tests:** See [Display/README.md](Display/README.md#troubleshooting)
- **Camera Tests:** See [Camera/README.md](Camera/README.md#troubleshooting)

## Test Dependencies

### Execution Order

For complete validation, run tests in this order:

1. **Video Tests** (independent, generates encoded files)
2. **Audio Tests** (independent)
3. **Display Tests** (independent, uses videotestsrc)
4. **Camera Tests** (independent, uses libcamera)

```bash
# Complete test sequence using master runner
cd Runner/suites/Gstreamer
./run.sh  # Runs all suites: Video, Audio, Display, Camera

# Or run individually
cd Video && ./run.sh
cd ../Audio && ./run.sh
cd ../Display && ./run.sh
cd ../Camera && ./run.sh
```

### File Dependencies

- **Video Tests**: Self-contained (encode tests generate files for decode tests)
- **Audio Tests**: Independent (no external dependencies)
- **Display Tests**: Independent (uses videotestsrc, no external files)
- **Camera Tests**: Independent (uses libcamera for capture)

## Environment Variables

### Common Variables

```bash
# GStreamer debug level (0-9)
export GST_DEBUG=3

# Test timeout (seconds)
export TIMEOUT=180

# Strict mode (fail on warnings)
export STRICT=true

# dmesg scanning
export DMESG_SCAN=true
```

### Video-Specific Variables

```bash
# Video stack (upstream/downstream/auto)
export VIDEO_STACK=auto

# Platform selection
export PLATFORM=auto

# VP9 clips URL
export VP9_CLIPS_URL="https://github.com/..."
```

### Audio-Specific Variables

```bash
# PulseAudio server
export PULSE_SERVER=unix:/run/user/1000/pulse/native

# Audio buffer size
export PULSE_LATENCY_MSEC=50
```

### Display-Specific Variables

```bash
# Wayland display
export WAYLAND_DISPLAY=wayland-0

# Runtime directory
export XDG_RUNTIME_DIR=/run/user/$(id -u)
```

### Camera-Specific Variables

```bash
# Camera device (for compatibility)
export CAMERA_DEVICE=/dev/video0

# Capture duration (seconds)
export CAPTURE_DURATION=5
```

## Performance Benchmarking

Each test suite can be used for performance analysis:

```bash
# Measure encoding performance
time ./Video/run.sh --test h264-480p-encode

# Measure with multiple iterations
./Video/run.sh --test h264-480p-encode --repeat 10

# Analyze logs for timing information
grep -i "time\|duration\|fps" logs_*/summary.txt
```

## Contributing

When adding new tests:

1. Follow the existing test structure
2. Use the common validation framework
3. Update the appropriate README
4. Add YAML configuration for LAVA
5. Test on multiple platforms
6. Document prerequisites and troubleshooting

See [CONTRIBUTING.md](../../../CONTRIBUTING.md) for detailed guidelines.

## Additional Resources

- [GStreamer Documentation](https://gstreamer.freedesktop.org/documentation/)
- [V4L2 Codec API](https://www.kernel.org/doc/html/latest/userspace-api/media/v4l/dev-codec.html)
- [PulseAudio Documentation](https://www.freedesktop.org/wiki/Software/PulseAudio/)
- [Wayland Documentation](https://wayland.freedesktop.org/)
- [libcamera Documentation](https://libcamera.org/)
- [qcom-linux-testkit Contributing Guide](../../../CONTRIBUTING.md)

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear
