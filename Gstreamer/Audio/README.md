# GStreamer Audio Tests

## Overview

This test suite validates GStreamer audio pipelines using PulseAudio for capture and playback on Qualcomm platforms. It tests audio encoding (capture to WAV) and decoding (WAV playback) functionality.

## Test Cases

### 1. audio-encode
**Pipeline:**
```bash
gst-launch-1.0 pulsesrc ! audioconvert ! audioresample ! identity eos-after=2000 ! wavenc ! filesink location=./output_audio.wav
```

**Description:**
- Captures audio from PulseAudio source
- Converts and resamples audio format
- Uses identity element with eos-after=2000 (2 seconds) for controlled capture
- Encodes to WAV format
- Saves to output_audio.wav

**Validation:**
- Pipeline completes without errors
- Output file is created
- No ERROR/WARNING messages in GStreamer output
- No dmesg errors (if DMESG_SCAN enabled)

### 2. audio-decode
**Pipeline:**
```bash
gst-launch-1.0 filesrc location=./output_audio.wav ! wavparse ! audioconvert ! audioresample ! pulsesink
```

**Description:**
- Reads WAV file created by audio-encode test
- Parses WAV format
- Converts and resamples audio
- Plays back through PulseAudio sink

**Validation:**
- Pipeline completes without errors
- Audio playback successful
- No ERROR/WARNING messages in GStreamer output
- No dmesg errors (if DMESG_SCAN enabled)

## Prerequisites

### Required Packages
```bash
# GStreamer core and plugins
gstreamer1.0-tools
gstreamer1.0-plugins-base
gstreamer1.0-plugins-good

# PulseAudio support
pulseaudio
gstreamer1.0-pulseaudio
```

### Audio Hardware
- Working audio capture device (microphone)
- Working audio playback device (speakers/headphones)
- PulseAudio server running

### Verification
```bash
# Check PulseAudio status
pulseaudio --check
echo $?  # Should return 0

# List audio sources
pactl list sources short

# List audio sinks
pactl list sinks short

# Test audio capture
gst-launch-1.0 pulsesrc ! fakesink

# Test audio playback
gst-launch-1.0 audiotestsrc ! pulsesink
```

## Usage

### Run All Tests
```bash
./run.sh --all
```

### Run Specific Test
```bash
./run.sh --test audio-encode
./run.sh --test audio-decode
```

### List Available Tests
```bash
./run.sh --list
```

### Custom Timeout
```bash
./run.sh --all --timeout 180
```

### Enable Strict Mode
```bash
./run.sh --all --strict
```

### Disable dmesg Scanning
```bash
./run.sh --all --no-dmesg
```

## CLI Options

| Option | Description | Default |
|--------|-------------|---------|
| `--all` | Run all audio tests | - |
| `--test <name>` | Run specific test | - |
| `--list` | List available tests | - |
| `--timeout <sec>` | Timeout per test | 120 |
| `--repeat <n>` | Repeat count | 1 |
| `--repeat-policy <all\|any>` | Pass policy | all |
| `--strict` | Fail on warnings | false |
| `--no-dmesg` | Skip dmesg scan | false |
| `--help` | Show help | - |

## Output Files

### Result Files
- `Gstreamer_Audio_Tests.res` - Overall PASS/FAIL/SKIP status
- `logs_Gstreamer_Audio_Tests/` - Detailed logs directory
  - `audio-encode.log` - Encode test output
  - `audio-decode.log` - Decode test output
  - `summary.txt` - Test summary
  - `results.csv` - CSV format results
  - `.junit_cases.xml` - JUnit XML for CI
  - `dmesg_snapshot.log` - Kernel messages
  - `dmesg_errors.log` - Kernel errors (if any)

### Generated Files
- `output_audio.wav` - Audio file created by encode test

## Validation Criteria

### Pass Criteria
✓ Pipeline executes without errors  
✓ Output files created successfully  
✓ No ERROR messages in GStreamer output  
✓ No WARNING messages (if --strict enabled)  
✓ No kernel errors in dmesg (if DMESG_SCAN enabled)  
✓ Exit code 0 from gst-launch-1.0  

### Fail Criteria
✗ Pipeline execution fails  
✗ ERROR messages in GStreamer output  
✗ WARNING messages (in strict mode)  
✗ Timeout exceeded  
✗ Output file not created  
✗ Kernel errors detected  

## Troubleshooting

### PulseAudio Not Running
```bash
# Start PulseAudio
pulseaudio --start

# Check status
pulseaudio --check
```

### No Audio Devices
```bash
# List available sources
pactl list sources short

# List available sinks
pactl list sinks short

# Set default source/sink
pactl set-default-source <source-name>
pactl set-default-sink <sink-name>
```

### Permission Issues
```bash
# Add user to audio group
sudo usermod -a -G audio $USER

# Verify group membership
groups $USER
```

### Audio Capture Fails
```bash
# Test with audiotestsrc instead
gst-launch-1.0 audiotestsrc ! audioconvert ! audioresample ! wavenc ! filesink location=test.wav

# Check microphone permissions
ls -la /dev/snd/

# Test with arecord
arecord -d 2 -f cd test.wav
```

### Audio Playback Fails
```bash
# Test with speaker-test
speaker-test -t sine -f 440 -c 2

# Test with aplay
aplay test.wav

# Check volume levels
pactl list sinks | grep -i volume
```

### Pipeline Negotiation Errors
```bash
# Enable debug output
GST_DEBUG=3 gst-launch-1.0 pulsesrc ! audioconvert ! audioresample ! wavenc ! filesink location=test.wav

# Check supported formats
gst-inspect-1.0 pulsesrc
gst-inspect-1.0 wavenc
```

### Common Error Messages

**"Could not open audio device for recording"**
- PulseAudio not running or no capture device available
- Check: `pactl list sources short`

**"Could not open audio device for playback"**
- PulseAudio not running or no playback device available
- Check: `pactl list sinks short`

**"Failed to connect stream"**
- PulseAudio server connection issue
- Restart: `pulseaudio --kill && pulseaudio --start`

**"No space left on device"**
- Insufficient disk space for output file
- Check: `df -h .`

## Environment Variables

```bash
# GStreamer debug level (0-9)
export GST_DEBUG=3

# PulseAudio server
export PULSE_SERVER=unix:/run/user/1000/pulse/native

# Audio buffer size
export PULSE_LATENCY_MSEC=50
```

## CI/CD Integration

### LAVA Integration
```yaml
- test:
    definitions:
      - repository: https://git.codelinaro.org/clo/le/le-test-automation/qcom-linux-testkit
        from: git
        path: Runner/suites/Gstreamer/Audio/Gstreamer_Audio_Tests.yaml
        name: gstreamer-audio-tests
        parameters:
          TIMEOUT: "120"
          STRICT: "false"
          DMESG_SCAN: "true"
```

### Standalone Execution
```bash
# Basic run
cd /path/to/qcom-linux-testkit/Runner/suites/Gstreamer/Audio
./run.sh --all

# With custom parameters
TIMEOUT=180 STRICT=true ./run.sh --all
```

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| QCS6490 | ✓ Supported | Full audio support |
| QCS8550 | ✓ Supported | Full audio support |
| QCS8650 | ✓ Supported | Full audio support |
| SA8775P | ✓ Supported | Full audio support |
| SA8650P | ✓ Supported | Full audio support |
| SA8255P | ✓ Supported | Full audio support |

## Known Issues

1. **PulseAudio Latency**: Some platforms may experience audio latency
   - Workaround: Adjust `PULSE_LATENCY_MSEC` environment variable

2. **Device Busy**: Audio device may be in use by another application
   - Workaround: Stop other audio applications or use `fuser -k /dev/snd/*`

3. **Sample Rate Mismatch**: Some devices may not support default sample rates
   - Workaround: Explicitly set sample rate in pipeline with `audio/x-raw,rate=48000`

## Additional Resources

- [GStreamer Documentation](https://gstreamer.freedesktop.org/documentation/)
- [PulseAudio Documentation](https://www.freedesktop.org/wiki/Software/PulseAudio/)
- [GStreamer PulseAudio Plugin](https://gstreamer.freedesktop.org/documentation/pulseaudio/)
- [Audio Debugging Guide](https://wiki.archlinux.org/title/PulseAudio/Troubleshooting)

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear
