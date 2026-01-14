# GStreamer Display Tests

**Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.**  
**SPDX-License-Identifier: BSD-3-Clause-Clear**

---

## Overview

This test suite validates GStreamer video display functionality using Wayland compositor on Qualcomm Linux platforms. Tests use `videotestsrc` to generate test patterns and display them via `waylandsink`, validating the complete display pipeline including Wayland surface creation and rendering.

### Test Coverage

**4 Test Cases:**
- **Wayland Basic**: Basic 480p test pattern display (SMPTE bars)
- **Wayland Videotestsrc**: 1080p moving ball pattern
- **Wayland Colorbar**: 4K color bars pattern
- **Wayland SMPTE**: 720p SMPTE color bars at 60fps

**Key Features:**
- No external file dependencies - uses built-in test pattern generator
- Validates Wayland compositor connectivity and surface creation
- Tests multiple resolutions (480p, 720p, 1080p, 4K)
- Tests multiple frame rates (30fps, 60fps)
- Validates various test patterns (SMPTE, ball, color bars)

---

## Quick Start

```bash
cd Runner/suites/Gstreamer/Display
./run.sh --all
```

---

## Test Pipelines

### Wayland Basic (480p @ 30fps)
```bash
videotestsrc num-buffers=150 pattern=0 ! \
  video/x-raw,width=720,height=480,framerate=30/1 ! \
  waylandsink
```
- **Pattern**: SMPTE color bars (pattern=0)
- **Duration**: 5 seconds (150 frames)
- **Resolution**: 720x480 (480p)
- **Use Case**: Basic Wayland connectivity test

### Wayland Videotestsrc (1080p @ 30fps)
```bash
videotestsrc num-buffers=150 pattern=ball ! \
  video/x-raw,width=1920,height=1080,framerate=30/1 ! \
  videoconvert ! \
  waylandsink
```
- **Pattern**: Moving ball (pattern=ball)
- **Duration**: 5 seconds (150 frames)
- **Resolution**: 1920x1080 (1080p)
- **Use Case**: Dynamic content rendering test

### Wayland Colorbar (4K @ 30fps)
```bash
videotestsrc num-buffers=150 pattern=bar ! \
  video/x-raw,width=3840,height=2160,framerate=30/1 ! \
  videoconvert ! \
  waylandsink
```
- **Pattern**: Color bars (pattern=bar)
- **Duration**: 5 seconds (150 frames)
- **Resolution**: 3840x2160 (4K)
- **Use Case**: High resolution display capability test

### Wayland SMPTE (720p @ 60fps)
```bash
videotestsrc num-buffers=300 pattern=smpte ! \
  video/x-raw,width=1280,height=720,framerate=60/1 ! \
  videoconvert ! \
  waylandsink
```
- **Pattern**: SMPTE color bars (pattern=smpte)
- **Duration**: 5 seconds (300 frames)
- **Resolution**: 1280x720 (720p)
- **Use Case**: High frame rate display test

---

## CLI Options

| Option | Description | Default |
|--------|-------------|---------|
| `--all` | Run all display tests | - |
| `--test <name>` | Run specific test | - |
| `--list` | List available tests | - |
| `--timeout <sec>` | Timeout per test | 120 |
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
./run.sh --test wayland-basic
./run.sh --test wayland-colorbar
```

### List available tests
```bash
./run.sh --list
```

### Run with increased timeout
```bash
./run.sh --all --timeout 180
```

### Run with strict mode
```bash
./run.sh --all --strict
```

### Run with repeat
```bash
./run.sh --test wayland-videotestsrc --repeat 3 --repeat-policy any
```

---

## Output Files

### Test Result
- `Gstreamer_Display_Tests.res` - Overall PASS/FAIL/SKIP

### Logs Directory: `logs_Gstreamer_Display_Tests/`
- `wayland-basic.log` - Basic display test log
- `wayland-videotestsrc.log` - Videotestsrc display test log
- `wayland-colorbar.log` - Colorbar display test log
- `wayland-smpte.log` - SMPTE display test log
- `summary.txt` - Per-test results summary
- `results.csv` - Machine-readable results
- `.junit_cases.xml` - JUnit XML for CI
- `dmesg_snapshot.log` - Kernel messages snapshot
- `dmesg_errors.log` - Kernel errors (if any)

---

## Validation Criteria

### Pass Criteria
A test PASSES if:
1. GStreamer pipeline exits with code 0
2. No ERROR patterns in log
3. No WARNING patterns (if `--strict` mode)
4. No kernel errors in dmesg (if enabled)
5. Wayland surface created successfully
6. No Wayland connection errors

### Error Patterns Detected
- `ERROR:` - General GStreamer errors
- `failed to negotiate` - Format negotiation issues
- `could not link` - Element linking failures
- `no such element` - Missing GStreamer elements
- `failed to create element` - Element creation failures
- `wayland.*error` - Wayland-specific errors
- `failed to connect to wayland` - Wayland connection failures
- `no wayland display` - Wayland display not available

### Wayland-Specific Validations
- Wayland display socket exists and is accessible
- Wayland compositor is responsive (if weston-info available)
- Wayland surface creation confirmed in pipeline logs
- No Wayland connection/surface errors detected

---

## Dependencies

### Required GStreamer Plugins
- `videotestsrc` - Test pattern generator (gstreamer1.0-plugins-base)
- `videoconvert` - Format converter (gstreamer1.0-plugins-base)
- `waylandsink` - Wayland video sink (gstreamer1.0-plugins-bad)

### System Requirements
- Wayland compositor running (Weston, Mutter, etc.) - **Auto-detected and started if needed**
- Display output connected
- DRM/KMS display driver loaded

**Note**: The test suite automatically handles Wayland environment setup:
- Uses `lib_display.sh` helpers for robust Wayland socket discovery
- Automatically detects existing Wayland sockets (base or overlay configurations)
- Can start a private Weston instance if no compositor is running
- Properly sets `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` with correct permissions
- Validates Wayland connection before running tests

### Verification Commands
```bash
# Check GStreamer plugins
gst-inspect-1.0 videotestsrc
gst-inspect-1.0 waylandsink
gst-inspect-1.0 videoconvert

# Check display connection (optional - test auto-detects)
echo $WAYLAND_DISPLAY
echo $XDG_RUNTIME_DIR

# Check Wayland socket (optional - test auto-discovers)
ls -la $XDG_RUNTIME_DIR/wayland-* 2>/dev/null || \
ls -la /run/user/*/wayland-*

# Check compositor (optional - test can start one)
ps aux | grep -E 'weston|mutter|kwin'

# Test Wayland connectivity (optional)
weston-info
```

---

## Troubleshooting

### Wayland Not Available
**The test suite automatically handles Wayland setup**, but if you encounter issues:

```bash
# Check if lib_display.sh helpers are available
grep -l "discover_wayland_socket_anywhere" $TOOLS/lib_display.sh

# Manually check for Wayland sockets
find /run/user -name "wayland-*" -type s 2>/dev/null

# If no sockets found, manually start Weston
weston &
sleep 2

# Re-run tests (they will auto-detect the new socket)
./run.sh --all
```

### Display Socket Not Found
**The test automatically discovers sockets**, but for manual verification:

```bash
# Check all possible socket locations
find /run/user -name "wayland-*" -type s 2>/dev/null
find /tmp -name "wayland-*" -type s 2>/dev/null

# Check if lib_display.sh can find sockets
if command -v discover_wayland_socket_anywhere >/dev/null 2>&1; then
    discover_wayland_socket_anywhere
fi

# The test will automatically:
# 1. Search for existing sockets
# 2. Adopt the socket's environment
# 3. Start Weston if no socket found
# 4. Validate the connection
```

### Missing Plugins
```bash
# Check plugin availability
gst-inspect-1.0 videotestsrc
gst-inspect-1.0 waylandsink
gst-inspect-1.0 videoconvert

# Install packages (if missing)
apt-get install gstreamer1.0-plugins-base \
                gstreamer1.0-plugins-bad \
                gstreamer1.0-tools
```

### Permission Issues
```bash
# Add user to video group
sudo usermod -a -G video $USER

# Verify group membership
groups $USER

# Check device permissions
ls -la /dev/dri/*
```

### Pipeline Failures
```bash
# Run pipeline manually with verbose output
GST_DEBUG=3 gst-launch-1.0 -v videotestsrc num-buffers=150 ! waylandsink

# Check log file
cat logs_Gstreamer_Display_Tests/wayland-basic.log

# Test simple pipeline
gst-launch-1.0 videotestsrc ! waylandsink
```

### Compositor Not Responsive
**The test suite can start its own compositor**, but for manual troubleshooting:

```bash
# Check compositor status
ps aux | grep weston

# Kill existing compositor
killall weston
sleep 1

# Let the test start a new one, or start manually
weston &
sleep 2

# Verify with test
./run.sh --test wayland-basic

# The test will automatically:
# 1. Detect if compositor is responsive
# 2. Start a private Weston instance if needed
# 3. Validate the connection before running tests
```

### Display Not Showing
```bash
# Check display output
weston-info

# Verify DRM/KMS
ls -la /dev/dri/card*
dmesg | grep -i drm

# Check display connection
cat /sys/class/drm/card*/status
```

### 4K Test Failures
```bash
# Check memory availability
free -h

# Increase timeout for 4K tests
./run.sh --test wayland-colorbar --timeout 240

# Check for memory errors
dmesg | grep -i "out of memory"
```

---

## Supported Platforms

- **LeMans** (QCS9100, QCS9075)
- **Monaco** (QCS8300)
- **Kodiak** (QCS6490, QCM6490)
- **QCS8550, QCS8650**
- **SA8775P, SA8650P, SA8255P**

---

## CI/CD Integration

### LAVA Test Definition
```yaml
- test:
    definitions:
      - repository: <repo-url>
        from: git
        path: Runner/suites/Gstreamer/Display/Gstreamer_Display_Tests.yaml
        name: gstreamer-display-tests
        parameters:
          TIMEOUT: "120"
          STRICT: "false"
          DMESG_SCAN: "true"
```

### Jenkins Pipeline
```groovy
stage('GStreamer Display Tests') {
    steps {
        sh '''
            cd Runner/suites/Gstreamer/Display
            ./run.sh --all
        '''
    }
}
```

---

## Environment Variables

**Note**: Wayland environment variables are automatically set by the test suite using `lib_display.sh` helpers. Manual configuration is typically not needed.

### Automatic Configuration (Recommended)
The test suite automatically:
- Discovers Wayland sockets using `discover_wayland_socket_anywhere()`
- Sets `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR` via `adopt_wayland_env_from_socket()`
- Fixes permissions on `XDG_RUNTIME_DIR` if needed
- Starts a private Weston instance if no compositor is running

### Manual Override (Advanced)
If you need to override the automatic detection:

```bash
# Wayland display (auto-detected by default)
export WAYLAND_DISPLAY=wayland-0

# Runtime directory (auto-configured by default)
export XDG_RUNTIME_DIR=/run/user/$(id -u)

# GStreamer debug level (0-9)
export GST_DEBUG=3

# Force software rendering (if needed)
export LIBGL_ALWAYS_SOFTWARE=1
```

### Debug Environment Detection
```bash
# Enable debug output for Wayland detection
export GST_DEBUG=3

# Run test to see auto-detection in action
./run.sh --test wayland-basic

# Check logs for Wayland socket discovery
grep -i "wayland socket" logs_Gstreamer_Display_Tests/*.log
```

---

## Test Pattern Reference

### Available videotestsrc Patterns
- `pattern=0` or `pattern=smpte` - SMPTE color bars
- `pattern=ball` - Moving ball
- `pattern=bar` - Color bars
- `pattern=snow` - Random noise
- `pattern=black` - Black screen
- `pattern=white` - White screen
- `pattern=circular` - Circular pattern
- `pattern=blink` - Blinking pattern

### Pattern Selection Rationale
- **SMPTE bars**: Standard broadcast test pattern, good for basic validation
- **Moving ball**: Dynamic content, tests motion rendering
- **Color bars**: Simple static pattern, good for color accuracy
- **60fps SMPTE**: Tests high frame rate capability

---

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
