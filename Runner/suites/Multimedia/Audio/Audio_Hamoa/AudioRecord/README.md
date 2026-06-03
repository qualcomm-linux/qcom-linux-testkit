# Audio Hamoa Record Validation Script

## Overview

This suite automates the validation of audio recording (capture) capabilities on Qualcomm Hamoa platforms using ALSA-based mixer configurations. It provides comprehensive testing for handset (built-in microphone) and headset (headset microphone) audio input devices with robust mixer configuration validation and diagnostic logging.

## Features

- **ALSA-based audio recording** using direct mixer control
- **Dual device support**: Handset (built-in DMIC) and Headset (SoundWire mic)
- **Config-based testing**: Uses pre-configured audio parameters for validation
- **Mixer configuration validation**: Verifies all mixer settings before recording
- **CI/LAVA integration**: 
  - Unique result file suffixes prevent file collisions in parallel test runs
  - Unique testcase IDs prevent LAVA testcase ID collisions
  - Enables running multiple AudioRecord_Hamoa configurations simultaneously in CI
- **Flexible device selection**: Test handset, headset, or both devices
- **Skip recording mode**: Test mixer configuration without actual audio recording
- **Recording validation**: Verifies file size and format
- Diagnostic logs: mixer dumps, recording logs per test case
- Generates `.res` result file for CI/LAVA integration

## Test Coverage

The test validates recording on two audio input devices:

### 1. Handset Capture (Built-in Microphone) - `plughw:0,3`
- **VA_DMIC** (Voice Activation DMIC - built-in digital microphone)
- **Audio path**: DMIC0/DMIC1 → VA DMIC MUX0/MUX1 → VA DEC0/DEC1 → VA_AIF1_CAP
- **Mixer commands**: 8 controls configured
- **Features**:
  - Dual DMIC support (DMIC0 + DMIC1)
  - Voice activation codec
  - Optimized for built-in microphones
  - Volume control per channel

### 2. Headset Capture (Headset Microphone) - `plughw:0,2`
- **SWR_MIC** (SoundWire microphone - headset mic)
- **Audio path**: SWR_MIC → ADC2 → TX SMIC MUX0 (SWR_MIC0) → TX DEC0 → TX_AIF1_CAP
- **Mixer commands**: 10 controls configured
- **Features**:
  - SoundWire interface
  - ADC2 with volume control
  - TX codec path
  - Optimized for external microphones
- **Critical Fix**: TX SMIC MUX0 set to 'SWR_MIC0' (not 'ADC1')

## Audio Record Configurations

The test uses pre-configured audio parameters for validation:

```  
| Config Name      | Sample Rate | Channels | Format  |
|------------------|-------------|----------|---------|
| record_config1   | 8 KHz       | 1ch      | S16_LE  |
| record_config2   | 16 KHz      | 1ch      | S16_LE  |
| record_config3   | 16 KHz      | 2ch      | S16_LE  |
| record_config4   | 24 KHz      | 1ch      | S16_LE  |
| record_config5   | 32 KHz      | 2ch      | S16_LE  |
| record_config6   | 44.1 KHz    | 2ch      | S16_LE  |
| record_config7   | 48 KHz      | 2ch      | S16_LE  |
| record_config8   | 48 KHz      | 6ch      | S16_LE  |
| record_config9   | 96 KHz      | 2ch      | S16_LE  |
| record_config10  | 96 KHz      | 6ch      | S16_LE  |
```   

## Prerequisites

Ensure the following components are present on the target platform:

- ALSA utilities: `arecord`, `amixer`
- Hamoa audio drivers and codecs loaded
- Required mixer controls available
- Sufficient disk space for recordings

## Directory Structure

```bash
Runner/
├── run-test.sh
├── utils/
│   ├── functestlib.sh
│   └── audio/
│       └── alsa_common.sh
└── suites/
    └── Multimedia/
        └── Audio/
            └── Audio_Hamoa/
                └── AudioRecord/
                    ├── run.sh
                    ├── README.md
                    ├── AudioRecord_Hamoa_Handset.yaml
                    └── AudioRecord_Hamoa_Headset.yaml
```

## Usage

Instructions:
1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device
2. Verify Transfer: Ensure that the repo has been successfully copied to the target device
3. Run Scripts: Navigate to the directory and execute the scripts as needed

### Basic Usage (5 second recording)

```bash
cd Runner/suites/Multimedia/Audio/Audio_Hamoa/AudioRecord

# Test both handset and headset (default)
./run.sh --device all --config-name record_config1 --duration 5

# Test handset only
./run.sh --device handset --config-name record_config1 --duration 5

# Test headset only
./run.sh --device headset --config-name record_config1 --duration 5
```

### Custom Duration

```bash
# Record for 10 seconds
./run.sh --device handset --config-name record_config1 --duration 10
```

### Mixer Configuration Only (No Recording)

```bash
# Test mixer configuration without actual recording
./run.sh --device handset --skip-actual-recording
```

### With Verbose Logging

```bash
./run.sh --device all --config-name record_config1 --duration 5 --verbose
```

### CI/LAVA Workflow with Unique Result Files

```bash
# Using --res-suffix prevents file collisions in parallel CI runs
./run.sh --device handset --config-name record_config1 --duration 5 --res-suffix "Handset" --lava-testcase-id "AudioRecord_Hamoa_Handset"

# Result file: AudioRecord_Hamoa_Handset.res
# Log directory: results/AudioRecord_Hamoa_Handset/

./run.sh --device headset --config-name record_config1 --duration 5 --res-suffix "Headset" --lava-testcase-id "AudioRecord_Hamoa_Headset"

# Result file: AudioRecord_Hamoa_Headset.res
# Log directory: results/AudioRecord_Hamoa_Headset/
```

## Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `--device <device>` | Device to test: handset, headset, or all | all |
| `--config-name <name>` | Config name (record_config1-10) | record_config1 |
| `--duration <secs>` | Recording duration in seconds | 5 |
| `--skip-actual-recording` | Skip actual recording, only test mixer configuration | Disabled |
| `--verbose` | Enable verbose logging | Disabled |
| `--res-suffix <suffix>` | Suffix for unique result file (e.g., "Handset") | Empty |
| `--lava-testcase-id <id>` | Unique testcase ID for LAVA (e.g., "AudioRecord_Hamoa_Handset") | AudioRecord_Hamoa |
| `--help`, `-h` | Show help message | - |

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| DEVICE | Device to test: handset, headset, or all | all |
| CONFIG_NAME | Config name (record_config1-10) | record_config1 |
| DURATION | Recording duration in seconds | 5 |
| SKIP_ACTUAL_RECORDING | Skip actual recording (0=record, 1=skip) | 0 |
| VERBOSE | Enable verbose logging (0=disabled, 1=enabled) | 0 |
| RES_SUFFIX | Suffix for unique result file | Empty |
| LAVA_TESTCASE_ID | Unique testcase ID for LAVA | AudioRecord_Hamoa |

## Test Execution Flow

### Handset Capture Test
1. Configure handset capture mixer (8 commands)
2. Validate mixer state
3. Record audio on plughw:0,3 for specified duration (if not skipped)
4. Validate recording file size
5. Report results

### Headset Capture Test
1. Configure headset capture mixer (10 commands)
2. Validate mixer state
3. Record audio on plughw:0,2 for specified duration (if not skipped)
4. Validate recording file size
5. Report results

## Sample Output

**Example 1: Testing handset recording**
```
[INFO] 2026-04-20 21:42:47 - Using unique result file: /tmp/Runner/suites/Multimedia/Audio/Audio_Hamoa/AudioRecord/AudioRecord_Hamoa_Handset.res
[INFO] 2026-04-20 21:42:47 - ------------------- Starting AudioRecord_Hamoa Testcase --------------------------
[INFO] 2026-04-20 21:42:47 - Platform: machine='Qualcomm Technologies, Inc. Hamoa IoT EVK' target='unknown'
[INFO] 2026-04-20 21:42:47 -   Config Name: record_config1
[INFO] 2026-04-20 21:42:47 -   Config applied: Rate=8000 Hz, Channels=1
[INFO] 2026-04-20 21:42:47 - Configuration:
[INFO] 2026-04-20 21:42:47 -   Duration: 5s
[INFO] 2026-04-20 21:42:48 -   Format: S16_LE
[INFO] 2026-04-20 21:42:48 -   Rate: 8000 Hz
[INFO] 2026-04-20 21:42:48 -   Channels: 1
[INFO] 2026-04-20 21:42:48 - ==========================================
[INFO] 2026-04-20 21:42:48 - TEST 1: Handset Capture (Built-in Mic)
[INFO] 2026-04-20 21:42:48 - ==========================================
[INFO] 2026-04-20 21:42:48 - Configuring mixer for handset capture (built-in mic)...
[INFO] 2026-04-20 21:42:48 - Handset capture mixer configured successfully
[INFO] 2026-04-20 21:42:48 - Validating mixer state for: handset_capture
[INFO] 2026-04-20 21:42:48 - Mixer state validation passed
[INFO] 2026-04-20 21:42:48 - Recording from device: plughw:0,3
[INFO] 2026-04-20 21:42:48 - Output file: /tmp/Runner/suites/Multimedia/Audio/Audio_Hamoa/AudioRecord/results/AudioRecord_Hamoa_Handset/handset_recording.wav
Recording WAVE '/tmp/Runner/suites/Multimedia/Audio/Audio_Hamoa/AudioRecord/results/AudioRecord_Hamoa_Handset/handset_recording.wav' : Signed 16 bit Little Endian, Rate 8000 Hz, Mono
[INFO] 2026-04-20 21:42:53 - Audio file validated: /tmp/Runner/suites/Multimedia/Audio/Audio_Hamoa/AudioRecord/results/AudioRecord_Hamoa_Handset/handset_recording.wav (80044 bytes)
[INFO] 2026-04-20 21:42:53 - Recording validated: /tmp/Runner/suites/Multimedia/Audio/Audio_Hamoa/AudioRecord/results/AudioRecord_Hamoa_Handset/handset_recording.wav (80044 bytes)
[PASS] 2026-04-20 21:42:53 - Handset capture test PASSED
[PASS] 2026-04-20 21:42:53 - AudioRecord_Hamoa_Handset : PASS
```

**Example 2: Testing both devices**
```
[INFO] 2026-04-20 18:34:24 - Device: all
[INFO] 2026-04-20 18:34:24 - TEST 1: Handset Capture (Built-in Mic)
[PASS] 2026-04-20 18:34:29 - Handset capture test PASSED
[INFO] 2026-04-20 18:34:29 - TEST 2: Headset Capture (Headset Mic)
[PASS] 2026-04-20 18:34:34 - Headset capture test PASSED
[PASS] 2026-04-20 18:34:34 - AudioRecord_Hamoa : PASS
```

**Example 3: Mixer-only test (no recording)**
```
[INFO] 2026-04-20 19:06:12 - Skip Actual Recording: 1
[INFO] 2026-04-20 19:06:12 - Configuring mixer for handset capture (built-in mic)...
[INFO] 2026-04-20 19:06:12 - Handset capture mixer configured successfully
[INFO] 2026-04-20 19:06:12 - Validating mixer state for: handset_capture
[INFO] 2026-04-20 19:06:12 - Mixer state validation passed
[INFO] 2026-04-20 19:06:12 - Skipping actual recording (mixer configuration verified)
[PASS] 2026-04-20 19:06:12 - Handset capture test PASSED
```

## Expected Results

- **PASS**: All selected device tests succeed (mixer configuration and recording)
- **FAIL**: One or more device tests fail

## Output Files

Recorded audio files are saved to:
- `results/AudioRecord_Hamoa/handset_recording.wav` (or `results/AudioRecord_Hamoa_<suffix>/handset_recording.wav`)
- `results/AudioRecord_Hamoa/headset_recording.wav` (or `results/AudioRecord_Hamoa_<suffix>/headset_recording.wav`)

## Results

- Results are stored in: `results/AudioRecord_Hamoa/` (or `results/AudioRecord_Hamoa_<suffix>/` when using --res-suffix)
- Summary result file: `AudioRecord_Hamoa.res` (or `AudioRecord_Hamoa_<suffix>.res` when using --res-suffix)
- Diagnostic logs: mixer dumps, recording files per test case
- **Note**: When using --res-suffix, both result files AND log directories are unique per invocation, preventing log collisions in CI/LAVA workflows

## Dependencies

- ALSA utilities (`arecord`, `amixer`)
- `Runner/utils/audio/alsa_common.sh` library
- `functestlib.sh` framework library

## Notes

- Mixer configurations are based on verified Hamoa commands for the platform
- Recording validation checks for minimum file size to ensure audio was captured
- Mixer validation ensures all controls are set correctly before recording
- The test supports parallel execution with unique result files using --res-suffix
- Use --lava-testcase-id to prevent testcase ID collisions in LAVA
- Logs include complete mixer state dumps for debugging
- Recording files can be played back on compatible devices

## Important Fix

The headset capture mixer includes a critical fix:
- **TX SMIC MUX0** must be set to **'SWR_MIC0'** (not 'ADC1')
- This ensures proper routing for SoundWire microphone input
- Without this fix, headset recording will not work correctly

## Known Limitations

- 8kHz mono recordings cannot be played back directly with `aplay` on this platform
- Use `sox` to convert for playback: `sox input.wav -r 48000 output.wav`
- Or play on a different device that supports 8kHz mono
- Recording validation is based on file size; actual audio quality should be verified manually

## Related Tests

- **AudioPlayback_Hamoa**: Tests audio playback functionality

## License

SPDX-License-Identifier: BSD-3-Clause
Copyright (C) Qualcomm Technologies, Inc. and/or its subsidiaries.