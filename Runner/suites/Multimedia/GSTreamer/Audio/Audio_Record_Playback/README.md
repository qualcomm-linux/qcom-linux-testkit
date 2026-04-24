# Audio_Record_Playback (GStreamer) — Runner Test

This directory contains the **Audio_Record_Playback** validation test for Qualcomm Linux Testkit runners.

It validates audio **recording and playback** using **GStreamer (`gst-launch-1.0`)** with:
- **audiotestsrc** - Synthetic audio generation (no microphone needed)
- **pulsesrc** - Hardware audio capture (microphone/line-in)
- **pulsesink** - PulseAudio playback
- **wavenc** / **flacenc** - Audio encoding
- **wavparse** / **flacparse + flacdec** - Audio decoding

The script is designed to be **CI/LAVA-friendly**:
- Writes **PASS/FAIL/SKIP** into `Audio_Record_Playback.res`
- Always **exits 0** (even on FAIL/SKIP) to avoid terminating LAVA jobs early
- Logs the **final `gst-launch-1.0` command** to console and to log files
- Supports both synthetic audio (audiotestsrc) and hardware capture (pulsesrc)
- Dynamically calculates buffer count based on duration for audiotestsrc
- Uses timeout mechanism for pulsesrc duration control

---

## Location in repo

Expected path:

```
Runner/suites/Multimedia/GSTreamer/Audio/Audio_Record_Playback/run.sh
```

Required shared utils (sourced from `Runner/utils` via `init_env`):
- `functestlib.sh`
- `lib_gstreamer.sh` - **Contains reusable audio pipeline builders** (see Library Functions section below)

---

## What this test does

At a high level, the test:

1. Finds and sources `init_env`
2. Sources:
   - `$TOOLS/functestlib.sh`
   - `$TOOLS/lib_gstreamer.sh`
3. Checks for required GStreamer elements (audiotestsrc, pulsesrc, pulsesink, wavenc, flacenc, wavparse, flacparse, flacdec)
4. **Recording phase (ENCODE - 4 tests)**:
   - **audiotestsrc tests**: Generates sine wave at 440Hz, encodes to WAV/FLAC
   - **pulsesrc tests**: Captures from hardware audio input, encodes to WAV/FLAC
   - Saves recorded files to shared directory (via `AUDIO_SHARED_RECORDED_DIR` / `gstreamer_shared_recorded_dir()`)
     - CI/LAVA runs: `<repo_root>/shared/audio-record-playback/`
     - Local/manual runs: `logs/Audio_Record_Playback/recorded/` (fallback)
   - Duration control:
     - audiotestsrc: Buffer count calculated dynamically: `(44100 * duration) / 1024`
     - pulsesrc: Uses timeout command to stop recording after specified duration
5. **Playback phase (DECODE - 6 tests)**:
   - Reads the previously recorded files (both audiotestsrc and pulsesrc recordings)
   - Decodes and plays back using pulsesink
   - Plays back external test files (OGG/MP3 formats)
6. Collects test results and emits PASS/FAIL/SKIP

---

## Test Cases

By default, the test runs **10 test cases** with 10 second duration:

### ENCODE PHASE (4 tests)

#### Recording Tests - audiotestsrc (Synthetic Audio)
1. **record_wav** - Record WAV format using audiotestsrc → audioconvert → wavenc
2. **record_flac** - Record FLAC format using audiotestsrc → audioconvert → flacenc

#### Recording Tests - pulsesrc (Hardware Audio Capture)
3. **record_pulsesrc_wav** - Record WAV format using pulsesrc → audioconvert → wavenc
4. **record_pulsesrc_flac** - Record FLAC format using pulsesrc → audioconvert → flacenc

### DECODE PHASE (6 tests)

#### Playback Tests - audiotestsrc recordings
5. **playback_wav** - Playback WAV file using filesrc → wavparse → audioconvert → pulsesink
6. **playback_flac** - Playback FLAC file using filesrc → flacparse → flacdec → pulsesink

#### Playback Tests - pulsesrc recordings
7. **playback_pulsesrc_wav** - Playback WAV file using filesrc → wavparse → audioconvert → pulsesink
8. **playback_pulsesrc_flac** - Playback FLAC file using filesrc → flacparse → flacdec → pulsesink

#### Playback Tests - External Test Files (OGG/MP3)
9. **playback_sample_ogg** - Playback OGG file using filesrc → oggdemux → vorbisdec → pulsesink
10. **playback_sample_mp3** - Playback MP3 file using filesrc → mpegaudioparse → mpg123audiodec → pulsesink

**Total: 10 test cases** (4 encode + 6 decode)

**Note:** OGG/MP3 playback tests require external test files (downloaded from URL or provided via `--clip-path`). If test files are not available, these tests will be skipped.

---

## PASS / FAIL / SKIP criteria

### PASS
- **Recording**: Output file is created and has size > 1000 bytes, and no GStreamer errors detected in log
  - Exit code is not directly checked - timeout/termination is acceptable if file is valid
- **Playback**: Pipeline completes successfully with exit code 0 and no GStreamer errors detected in log
- **Overall**: At least one test passes and no tests fail

### FAIL
- **Recording**: No output file created, file size too small (≤ 1000 bytes), or GStreamer errors detected in log
- **Playback**: Pipeline exits with non-zero code or GStreamer errors detected in log
- **Overall**: One or more tests fail

### SKIP
- Missing required tools (`gst-launch-1.0`, `gst-inspect-1.0`)
- Required GStreamer elements not available (audiotestsrc, pulsesrc, pulsesink, wavenc, flacenc)
- For playback tests: corresponding recorded file not found (record must run first)
- For pulsesrc tests: pulsesrc plugin not available

**Note:** The test always exits `0` even for FAIL/SKIP. The `.res` file is the source of truth.

---

## Logs and artifacts

By default, logs are written relative to the script working directory:

```
./Audio_Record_Playback.res
./logs/Audio_Record_Playback/
  gst.log                         # GStreamer debug output
  record_wav.log                  # Individual test logs
  record_flac.log
  record_pulsesrc_wav.log
  record_pulsesrc_flac.log
  playback_wav.log
  playback_flac.log
  playback_pulsesrc_wav.log
  playback_pulsesrc_flac.log
  dmesg/                          # dmesg scan outputs (if available)
    dmesg_errors.log
```

### Recorded Audio Artifacts

Recorded audio files are stored in a shared directory to enable artifact reuse across test runs:

**Local/Manual Runs** (fallback):
```
./logs/Audio_Record_Playback/recorded/
  record_wav.wav
  record_flac.flac
  record_pulsesrc_wav.wav
  record_pulsesrc_flac.flac
```

**CI/LAVA Runs** (shared path):
```
<repo_root>/shared/audio-record-playback/
  record_wav.wav
  record_flac.flac
  record_pulsesrc_wav.wav
  record_pulsesrc_flac.flac
```

The recorded artifact directory is determined by:
1. **Explicit override**: `AUDIO_SHARED_RECORDED_DIR` environment variable (if set)
2. **LAVA/tests detection**: Shared path derived from repository structure (if script path contains `/tests/`)
3. **Local fallback**: `./logs/Audio_Record_Playback/recorded/` (for manual runs)

This ensures that in CI/LAVA environments, recorded artifacts are placed in a shared location accessible across multiple test runs, while local/manual runs use a simple local directory.

---

## Dependencies

### Required
- `gst-launch-1.0`
- `gst-inspect-1.0`
- `audiotestsrc` GStreamer plugin
- `audioconvert` GStreamer plugin
- `pulsesink` GStreamer plugin

### Optional (for hardware capture tests)
- `pulsesrc` GStreamer plugin
- Working audio input device (microphone/line-in)

### Encoder Elements
- `wavenc` - WAV encoder
- `flacenc` - FLAC encoder

### Decoder Elements
- `wavparse` - WAV parser
- `flacparse` - FLAC parser
- `flacdec` - FLAC decoder

### Audio Backend
- PulseAudio server running

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

- `--mode <all|record|playback>`
  - Default: `all` (run both record and playback tests)
  - `record`: Run only recording tests (both audiotestsrc and pulsesrc)
  - `playback`: Run only playback tests (requires recorded files from previous record run)

- `--formats <wav,flac>`
  - Comma-separated list of formats to test
  - Default: `wav,flac` (both formats)
  - Examples: `wav`, `flac`, `wav,flac`

- `--duration <seconds>`
  - Duration for recording (in seconds)
  - Default: `10`
  - For audiotestsrc: Determines buffer count: `(44100 * duration) / 1024`
  - For pulsesrc: Uses timeout command to stop recording after this duration
  - Example: 10 seconds → 430 buffers (audiotestsrc) or 10 second timeout (pulsesrc)

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
  - Default: `Audio_Record_Playback`
  - Used by LAVA to match expected test case names
  - Example: `--lava-testcase-id "GStreamer_Audio_Record_wav"`
  - **Note:** This is typically set automatically by LAVA job definitions and should not be used for local testing

---

## Examples

### 1) Run all tests (default - 10 tests: 4 encode + 6 decode for WAV, FLAC, OGG, and MP3 with 10 second duration)

```bash
./run.sh
```

### 2) Run only recording tests (4 encode tests)

```bash
./run.sh --mode record
```

### 3) Run only playback tests (6 decode tests - requires recorded files from previous run, plus OGG/MP3 test files)

```bash
./run.sh --mode playback
```

### 4) Test only WAV format (6 tests total: 2 encode + 2 decode + 2 OGG/MP3 playback)

```bash
./run.sh --formats wav
```

### 5) Test only FLAC format (6 tests total: 2 encode + 2 decode + 2 OGG/MP3 playback)

```bash
./run.sh --formats flac
```

### 6) Test with longer duration (30 seconds)

```bash
./run.sh --duration 30
```

### 7) Quick test - WAV only with 3 second duration (6 tests total)

```bash
./run.sh --formats wav --duration 3
```

### 8) Increase GStreamer debug verbosity

```bash
./run.sh --gst-debug 5
```

---

## Pipeline Details

### Recording Pipeline - audiotestsrc (WAV)

```
audiotestsrc wave=sine freq=440 volume=1.0 num-buffers=<N>
  ! audioconvert
  ! wavenc
  ! filesink location=<output_file>
```

Where:
- `wave=sine` generates sine wave test tone
- `freq=440` sets frequency to 440Hz (A4 note)
- `volume=1.0` sets full volume
- `num-buffers` = (44100 * duration) / 1024
  - Example: 10 seconds → (44100 * 10) / 1024 = 430 buffers

### Recording Pipeline - audiotestsrc (FLAC)

```
audiotestsrc wave=sine freq=440 volume=1.0 num-buffers=<N>
  ! audioconvert
  ! flacenc
  ! filesink location=<output_file>
```

### Recording Pipeline - pulsesrc (WAV)

```
pulsesrc volume=10
  ! audioconvert
  ! wavenc
  ! filesink location=<output_file>
```

**Duration Control**: Uses `timeout` command to stop recording after specified duration (e.g., 10 seconds)

### Recording Pipeline - pulsesrc (FLAC)

```
pulsesrc volume=10
  ! audioconvert
  ! flacenc
  ! filesink location=<output_file>
```

**Duration Control**: Uses `timeout` command to stop recording after specified duration (e.g., 10 seconds)

### Playback Pipeline (WAV)

```
filesrc location=<input_file>
  ! wavparse
  ! audioconvert
  ! pulsesink volume=10
```

### Playback Pipeline (FLAC)

```
filesrc location=<input_file>
  ! flacparse
  ! flacdec
  ! pulsesink volume=10
```

---

## Audio Parameters

The test uses these audio parameters for buffer calculation (audiotestsrc only):

- **Sample Rate**: 44100 Hz (44.1 kHz - CD quality)
- **Samples per Buffer**: 1024 (standard buffer size)
- **Buffer Count Formula**: `(sample_rate * duration) / samples_per_buffer`

Example calculations:
- 3 seconds: (44100 * 3) / 1024 = 129 buffers
- 10 seconds: (44100 * 10) / 1024 = 430 buffers
- 30 seconds: (44100 * 30) / 1024 = 1291 buffers

**Note**: pulsesrc tests use timeout mechanism instead of buffer count for duration control.

---

## Troubleshooting

### A) "SKIP: Missing gstreamer runtime"
- Ensure `gst-launch-1.0` and `gst-inspect-1.0` are installed in the image.

### B) "audiotestsrc element not available"
- Check if audiotestsrc plugin is available:
  ```bash
  gst-inspect-1.0 audiotestsrc
  ```
- Install gst-plugins-base if missing

### C) "pulsesrc element not available"
- Check if pulsesrc plugin is available:
  ```bash
  gst-inspect-1.0 pulsesrc
  ```
- Install gst-plugins-good if missing
- Note: pulsesrc tests will be skipped if plugin is not available, but audiotestsrc tests will still run

### D) "pulsesink element not available"
- Check if pulsesink plugin is available:
  ```bash
  gst-inspect-1.0 pulsesink
  ```
- Ensure PulseAudio is installed and running:
  ```bash
  pulseaudio --check
  pactl info
  ```

### E) "wavenc plugin not available" or "flacenc plugin not available"
- Check if encoder plugins are available:
  ```bash
  gst-inspect-1.0 wavenc
  gst-inspect-1.0 flacenc
  ```
- Install gst-plugins-good if missing

### F) Playback tests skip with "recorded file not found"
- Run record tests first: `./run.sh --mode record`
- Or run all tests: `./run.sh --mode all`

### G) Recording fails or produces small files
- Check available disk space
- Check `logs/Audio_Record_Playback/record_*.log` for errors
- Try with shorter duration: `./run.sh --duration 3`
- Increase debug level: `./run.sh --gst-debug 5`

### H) "FAIL: file too small"
- Recording may have failed silently
- Check individual test logs in `logs/Audio_Record_Playback/`
- Verify GStreamer plugins are properly installed

### I) Playback fails with PulseAudio errors
- Check PulseAudio status:
  ```bash
  pulseaudio --check
  pactl info
  ```
- Restart PulseAudio if needed:
  ```bash
  pulseaudio --kill
  pulseaudio --start
  ```
- Check for audio sinks:
  ```bash
  pactl list sinks short
  ```

### J) pulsesrc recording fails or produces no audio
- Check if audio input device is available:
  ```bash
  pactl list sources short
  ```
- Test audio input manually:
  ```bash
  gst-launch-1.0 pulsesrc ! audioconvert ! wavenc ! filesink location=/tmp/test.wav
  # Let it run for a few seconds, then Ctrl+C
  aplay /tmp/test.wav
  ```
- Verify microphone is not muted:
  ```bash
  pactl list sources | grep -A 10 "Name:"
  ```
- Check microphone permissions and hardware connection

---

## Library Functions (Runner/utils/lib_gstreamer.sh)

This test uses reusable helper functions from `lib_gstreamer.sh` that other GStreamer tests can leverage:

### Audio Pipeline Builders

**`gstreamer_build_audio_record_pipeline <source_type> <format> <output_file> [num_buffers]`**
- Builds audio recording pipeline with specified source
- Parameters:
  - `source_type`: `audiotestsrc` or `pulsesrc`
  - `format`: `wav` or `flac`
  - `output_file`: Output file path
  - `num_buffers`: (optional) Number of buffers for audiotestsrc (ignored for pulsesrc)
- Returns: Complete pipeline string (or empty if format/source not supported)
- Example:
  ```sh
  # audiotestsrc recording
  NUM_BUFFERS=$(( (44100 * 10) / 1024 ))  # 10 seconds
  pipeline=$(gstreamer_build_audio_record_pipeline "audiotestsrc" "wav" "/tmp/test.wav" "$NUM_BUFFERS")
  gstreamer_run_gstlaunch_timeout 20 "$pipeline"
  
  # pulsesrc recording (uses timeout for duration control)
  pipeline=$(gstreamer_build_audio_record_pipeline "pulsesrc" "flac" "/tmp/hw_capture.flac")
  gstreamer_run_gstlaunch_timeout 10 "$pipeline"  # Records for 10 seconds
  ```

**`gstreamer_build_audio_playback_pipeline <format> <input_file>`**
- Builds audio playback pipeline using pulsesink
- Parameters:
  - `format`: `wav` or `flac`
  - `input_file`: Input file path
- Returns: Complete pipeline string (or empty if format not supported)
- Example:
  ```sh
  pipeline=$(gstreamer_build_audio_playback_pipeline "flac" "/tmp/test.flac")
  gstreamer_run_gstlaunch_timeout 20 "$pipeline"
  ```

### Usage in Other Tests

To use these functions in your GStreamer audio test:

```sh
#!/bin/sh
# Source init_env and lib_gstreamer.sh
. "$INIT_ENV"
. "$TOOLS/functestlib.sh"
. "$TOOLS/lib_gstreamer.sh"

# Calculate buffer count for 5 seconds (audiotestsrc)
SAMPLE_RATE=44100
SAMPLES_PER_BUFFER=1024
duration=5
NUM_BUFFERS=$(( (SAMPLE_RATE * duration) / SAMPLES_PER_BUFFER ))

# Build and run audiotestsrc record pipeline
pipeline=$(gstreamer_build_audio_record_pipeline "audiotestsrc" "wav" "/tmp/output.wav" "$NUM_BUFFERS")
if [ -n "$pipeline" ]; then
  gstreamer_run_gstlaunch_timeout 15 "$pipeline"
fi

# Build and run pulsesrc record pipeline (timeout controls duration)
pipeline=$(gstreamer_build_audio_record_pipeline "pulsesrc" "flac" "/tmp/hw_capture.flac")
if [ -n "$pipeline" ]; then
  gstreamer_run_gstlaunch_timeout 10 "$pipeline"  # 10 second recording
fi

# Build and run playback pipeline
pipeline=$(gstreamer_build_audio_playback_pipeline "wav" "/tmp/output.wav")
if [ -n "$pipeline" ]; then
  gstreamer_run_gstlaunch_timeout 15 "$pipeline"
fi
```

---

## Notes for CI / LAVA

- The test always exits `0`.
- Use the `.res` file for result:
  - `PASS` - All tests passed
  - `FAIL` - One or more tests failed
  - `SKIP` - No tests executed or all skipped
- Test summary is logged showing pass/fail/skip counts
- Individual test logs are available in `logs/Audio_Record_Playback/`
- Recorded files are preserved in the shared recorded directory for debugging:
  - CI/LAVA runs: `<repo_root>/shared/audio-record-playback/`
  - Local/manual runs: `logs/Audio_Record_Playback/recorded/` (fallback)

### LAVA Environment Variables

The test supports these environment variables (can be set in LAVA job definition):

- `AUDIO_TEST_MODE` - Test mode (all/record/playback) (default: all)
- `AUDIO_TEST_NAME` - Individual test name for single test execution (optional)
- `AUDIO_FORMATS` - Comma-separated format list (default: `wav,flac`)
- `AUDIO_DURATION` - Recording duration in seconds (default: 10)
- `RUNTIMESEC` - Alternative to AUDIO_DURATION (for backward compatibility)
- `AUDIO_GST_DEBUG` - GStreamer debug level (default: 2)
- `GST_DEBUG_LEVEL` - Alternative to AUDIO_GST_DEBUG
- `AUDIO_CLIP_URL` - URL to download test audio files (OGG/MP3) (default: GitHub release URL)
- `AUDIO_CLIP_PATH` - Local path to test audio files (overrides AUDIO_CLIP_URL if files exist)
- `AUDIO_SHARED_RECORDED_DIR` - Shared directory for recorded audio artifacts (optional)
- `REPO_PATH` - Repository root path (set by YAML, used for path resolution)
- `LAVA_TESTCASE_ID` - Override test case name for LAVA reporting (default: Audio_Record_Playback)

**Priority order for duration**: `AUDIO_DURATION` > `RUNTIMESEC` > default (10)

**Shared Artifact Directory**: The test uses `AUDIO_SHARED_RECORDED_DIR` to store recorded audio files in a shared location across multiple test runs. If not set, the test will automatically determine the appropriate directory based on the environment (LAVA vs local).

### LAVA Test Case Naming

The test supports flexible test case naming for LAVA integration:

- **Default behavior**: Reports results as `Audio_Record_Playback` in the `.res` file
- **LAVA override**: Set `LAVA_TESTCASE_ID` parameter in the YAML definition to match LAVA's expected test case name
- **Example YAML configuration**:
  ```yaml
  params:
    AUDIO_TEST_MODE: record
    AUDIO_FORMATS: wav
    LAVA_TESTCASE_ID: "GStreamer_Audio_Record_wav"  # Matches LAVA expected name
  ```
- This ensures LAVA correctly matches test results with expected test case names, avoiding "Unexpected test result" errors

### Test Counting

- **Total tests**: 10 (when running with default wav,flac formats in all mode)
  - 4 encode tests (2 audiotestsrc + 2 pulsesrc)
  - 6 decode tests (2 audiotestsrc playback + 2 pulsesrc playback + 2 OGG/MP3 playback)
- **Pass/Fail/Skip are mutually exclusive**: Each test increments exactly one counter
- **Plugin unavailability**: pulsesrc tests will skip if pulsesrc plugin is not available, but audiotestsrc tests will still run
- **Test file availability**: OGG/MP3 playback tests will skip if test files are not available

---

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear
