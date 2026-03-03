# Waylandsink_Playback (GStreamer) — Runner Test

This directory contains the **Waylandsink_Playback** validation test for Qualcomm Linux Testkit runners.

It validates **Wayland display** using **GStreamer waylandsink** with:
- Weston/Wayland server connectivity checks
- DRM display connectivity validation
- Video playback using `waylandsink` element
- Uses `videotestsrc` to generate test patterns

The script is designed to be **CI/LAVA-friendly**:
- Writes **PASS/FAIL/SKIP** into `Waylandsink_Playback.res`
- Always **exits 0** (even on FAIL/SKIP)
- Comprehensive Weston/Wayland environment detection
- Automatic Weston startup if needed

---

## What this test does

1. Sources framework utilities (`functestlib.sh`, `lib_gstreamer.sh`, `lib_display.sh`)
2. **Display connectivity check**: Verifies connected DRM display via sysfs
3. **Weston/Wayland server check**:
   - Discovers existing Wayland socket
   - Attempts to start Weston if no socket found
   - Validates Wayland connection
4. **waylandsink element check**: Verifies GStreamer waylandsink is available
5. **Playback test**: Runs videotestsrc → videoconvert → waylandsink pipeline
6. **Validation**: Checks playback duration and exit code

---

## PASS / FAIL / SKIP criteria

### PASS
- Playback completes successfully (exit code 0 or 143)
- Elapsed time ≥ (duration - 2) seconds

### FAIL
- Playback exits with error code (not 0 or 143)
- Playback exits too quickly (< duration - 2 seconds)

### SKIP
- Missing GStreamer tools (`gst-launch-1.0`, `gst-inspect-1.0`)
- No connected DRM display found
- No Wayland socket found (and cannot start Weston)
- Wayland connection test fails
- `waylandsink` element not available

---

## Dependencies

### Required
- `gst-launch-1.0`
- `gst-inspect-1.0`
- `videotestsrc` GStreamer plugin
- `videoconvert` GStreamer plugin
- `waylandsink` GStreamer plugin

### Display/Wayland
- Weston compositor (running or startable)
- Connected DRM display
- Wayland socket (`/run/user/*/wayland-*` or `/dev/socket/weston/wayland-*`)

---

## Usage

```bash
./run.sh [options]
```

### Options

- `--resolution <WIDTHxHEIGHT>` - Video resolution (e.g., 1920x1080, 3840x2160) (default: 1920x1080)
- `--duration <seconds>` - Playback duration (default: 30)
- `--pattern <smpte|snow|ball|etc>` - videotestsrc pattern (default: smpte)
- `--width <pixels>` - Video width (alternative to --resolution) (default: 1920)
- `--height <pixels>` - Video height (alternative to --resolution) (default: 1080)
- `--framerate <fps>` - Video framerate (default: 30)
- `--gst-debug <level>` - GStreamer debug level 1-9 (default: 2)

---

## Examples

```bash
# Run default test (1920x1080 SMPTE for 30s)
./run.sh

# Run with custom resolution using --resolution
./run.sh --resolution 3840x2160

# Run with custom resolution and duration
./run.sh --resolution 3840x2160 --duration 20

# Run with ball pattern
./run.sh --pattern ball

# Run with custom resolution using separate width/height
./run.sh --width 1280 --height 720

# Run with different framerate
./run.sh --framerate 60

# Run with higher debug level
./run.sh --gst-debug 5
```

---

## Pipeline

```
videotestsrc num-buffers=<N> pattern=<pattern>
  ! video/x-raw,width=<W>,height=<H>,framerate=<FPS>/1
  ! videoconvert
  ! waylandsink
```

---

## Logs

```
./Waylandsink_Playback.res
./logs/Waylandsink_Playback/
  gst.log      # GStreamer debug output
  run.log      # Pipeline execution log
```

---

## Troubleshooting

### "SKIP: No connected DRM display found"
- Check physical display connection
- Verify DRM drivers loaded: `ls -l /dev/dri/`

### "SKIP: No Wayland socket found"
- Check if Weston is running: `pgrep weston`
- Try starting Weston manually
- Check `XDG_RUNTIME_DIR` and `WAYLAND_DISPLAY` environment variables

### "SKIP: waylandsink element not available"
- Install GStreamer Wayland plugin
- Check: `gst-inspect-1.0 waylandsink`

### "FAIL: Playback failed"
- Check logs in `logs/Waylandsink_Playback/`
- Increase debug level: `./run.sh --gst-debug 5`
- Verify Weston is running properly

---

## LAVA Environment Variables

The test supports these environment variables (can be set in LAVA job definition):

- `VIDEO_DURATION` - Playback duration in seconds (default: 30)
- `RUNTIMESEC` - Alternative to VIDEO_DURATION
- `VIDEO_PATTERN` - videotestsrc pattern (default: smpte)
- `VIDEO_WIDTH` - Video width (default: 1920)
- `VIDEO_HEIGHT` - Video height (default: 1080)
- `VIDEO_FRAMERATE` - Video framerate (default: 30)
- `VIDEO_GST_DEBUG` - GStreamer debug level (default: 2)
- `GST_DEBUG_LEVEL` - Alternative to VIDEO_GST_DEBUG

**Priority order for duration**: `VIDEO_DURATION` > `RUNTIMESEC` > default (30)
