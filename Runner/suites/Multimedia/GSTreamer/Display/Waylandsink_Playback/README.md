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

- `--duration <seconds>` - Playback duration (default: 10)
- `--pattern <smpte|snow|ball|etc>` - videotestsrc pattern (default: smpte)
- `--width <pixels>` - Video width (default: 1920)
- `--height <pixels>` - Video height (default: 1080)
- `--framerate <fps>` - Video framerate (default: 30)
- `--gst-debug <level>` - GStreamer debug level 1-9 (default: 2)

---

## Examples

```bash
# Run default test (1920x1080 SMPTE for 30s)
./run.sh

# Run with 30 second duration
./run.sh --duration 30

# Run with ball pattern
./run.sh --pattern ball

# Run with custom resolution
./run.sh --width 1280 --height 720
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

- `VIDEO_DURATION` - Playback duration
- `VIDEO_PATTERN` - videotestsrc pattern
- `VIDEO_WIDTH` - Video width
- `VIDEO_HEIGHT` - Video height
- `VIDEO_FRAMERATE` - Video framerate
- `VIDEO_GST_DEBUG` - GStreamer debug level
- `RUNTIMESEC` - Alternative to VIDEO_DURATION
