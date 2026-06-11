# Audio Hamoa Playback Validation Script

## Overview

This suite automates the validation of audio playback capabilities on Qualcomm Hamoa platforms using ALSA-based mixer configurations. It provides comprehensive testing for handset (speakers) and headset (headphones) audio output devices with robust mixer configuration validation and diagnostic logging.

## Features

- **ALSA-based audio playback** using direct mixer control
- **Dual device support**: Handset (4-way speakers) and Headset (stereo headphones)
- **Clip-based testing**: Uses pre-configured audio clips for validation
- **Mixer configuration validation**: Verifies all mixer settings before playback
- **CI/LAVA integration**: 
  - Unique result file suffixes prevent file collisions in parallel test runs
  - Unique testcase IDs prevent LAVA testcase ID collisions
  - Enables running multiple AudioPlayback_Hamoa configurations simultaneously in CI
- **Flexible device selection**: Test handset, headset, or both devices
- **Skip playback mode**: Test mixer configuration without actual audio playback
- Diagnostic logs: mixer dumps, playback logs per test case
- Generates `.res` result file for CI/LAVA integration

## Test Coverage

The test validates playback on two audio output devices:

### 1. Handset Playback (Speakers) - `plughw:0,1`
- **4-way speaker system** using WSA2 and WSA amplifiers
- **Audio path**: AIF1_PB → WSA2/WSA RX0/RX1 → WooferLeft/Right + TweeterLeft/Right
- **Mixer commands**: 44 controls configured
- **Features**:
  - Dual WSA codec support (WSA + WSA2)
  - Compressor and boost enabled
  - Maximum volume levels
  - Speaker protection (PBR) enabled

### 2. Headset Playback (Headphones) - `plughw:0,0`
- **Stereo headphone output** using RX codec
- **Class-H High Fidelity mode** for optimal audio quality
- **Audio path**: AIF1_PB → RX_MACRO RX0/RX1 → RX INT0/INT1 → HPHL/HPHR
- **Mixer commands**: 22 controls configured
- **Features**:
  - Class-H amplifier mode
  - Compressor enabled
  - Optimized volume levels
  - Low-distortion output

## Audio Clip Configurations

The test uses pre-configured audio clips for validation:

```  
| Config Name       | Sample Rate | Bit Depth | Channels | Duration |
|-------------------|-------------|-----------|----------|----------|
| playback_config1  | 8 KHz       | 8-bit     | 1ch      | 30s      |
| playback_config2  | 16 KHz      | 8-bit     | 6ch      | 30s      |
| playback_config3  | 16 KHz      | 16-bit    | 2ch      | 30s      |
| playback_config4  | 22.05 KHz   | 8-bit     | 1ch      | 30s      |
| playback_config5  | 24 KHz      | 24-bit    | 6ch      | 30s      |
| playback_config6  | 24 KHz      | 32-bit    | 1ch      | 30s      |
| playback_config7  | 32 KHz      | 8-bit     | 8ch      | 30s      |
| playback_config8  | 32 KHz      | 16-bit    | 2ch      | 30s      |
| playback_config9  | 44.1 KHz    | 16-bit    | 1ch      | 30s      |
| playback_config10 | 48 KHz      | 8-bit     | 2ch      | 30s      |
```   

## Prerequisites

Ensure the following components are present on the target platform:

- ALSA utilities: `aplay`, `amixer`
- Audio clips directory: `/home/AudioClips/` (or custom path)
- Hamoa audio drivers and codecs loaded
- Required mixer controls available

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
                └── AudioPlayback/
                    ├── run.sh
                    ├── README.md
                    ├── AudioPlayback_Hamoa_Handset.yaml
                    └── AudioPlayback_Hamoa_Headset.yaml
```

## Usage

Instructions:
1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device
2. Verify Transfer: Ensure that the repo has been successfully copied to the target device
3. Run Scripts: Navigate to the directory and execute the scripts as needed

### Basic Usage

```bash
cd Runner/suites/Multimedia/Audio/Audio_Hamoa/AudioPlayback

# Test both handset and headset (default)
./run.sh --device all --clip-name playback_config1 --audio-clips-path /home/AudioClips

# Test handset only
./run.sh --device handset --clip-name playback_config1 --audio-clips-path /home/AudioClips

# Test headset only
./run.sh --device headset --clip-name playback_config1 --audio-clips-path /home/AudioClips
```

### Mixer Configuration Only (No Playback)

```bash
# Test mixer configuration without actual playback
./run.sh --device handset --skip-actual-playback
```

### With Verbose Logging

```bash
./run.sh --device all --clip-name playback_config1 --audio-clips-path /home/AudioClips --verbose
```

### CI/LAVA Workflow with Unique Result Files

```bash
# Using --res-suffix prevents file collisions in parallel CI runs
./run.sh --device handset --clip-name playback_config1 --audio-clips-path /home/AudioClips --res-suffix "Handset" --lava-testcase-id "AudioPlayback_Hamoa_Handset"

# Result file: AudioPlayback_Hamoa_Handset.res
# Log directory: results/AudioPlayback_Hamoa_Handset/

./run.sh --device headset --clip-name playback_config1 --audio-clips-path /home/AudioClips --res-suffix "Headset" --lava-testcase-id "AudioPlayback_Hamoa_Headset"

# Result file: AudioPlayback_Hamoa_Headset.res
# Log directory: results/AudioPlayback_Hamoa_Headset/
```

## Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `--device <device>` | Device to test: handset, headset, or all | all |
| `--clip-name <name>` | Clip configuration name (playback_config1-10) | playback_config1 |
| `--audio-clips-path <path>` | Path to audio clips directory | /home/AudioClips |
| `--skip-actual-playback` | Skip actual playback, only test mixer configuration | Disabled |
| `--verbose` | Enable verbose logging | Disabled |
| `--res-suffix <suffix>` | Suffix for unique result file (e.g., "Handset") | Empty |
| `--lava-testcase-id <id>` | Unique testcase ID for LAVA (e.g., "AudioPlayback_Hamoa_Handset") | AudioPlayback_Hamoa |
| `--help`, `-h` | Show help message | - |

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| DEVICE | Device to test: handset, headset, or all | all |
| CLIP_NAMES | Clip configuration name | playback_config1 |
| AUDIO_CLIPS_BASE_DIR | Path to audio clips directory | /home/AudioClips |
| SKIP_ACTUAL_PLAYBACK | Skip actual playback (0=play, 1=skip) | 0 |
| VERBOSE | Enable verbose logging (0=disabled, 1=enabled) | 0 |
| RES_SUFFIX | Suffix for unique result file | Empty |
| LAVA_TESTCASE_ID | Unique testcase ID for LAVA | AudioPlayback_Hamoa |

## Test Execution Flow

### Handset Playback Test
1. Configure handset playback mixer (44 commands)
2. Validate mixer state
3. Play audio clip on plughw:0,1 (if not skipped)
4. Report results

### Headset Playback Test
1. Configure headset playback mixer (22 commands)
2. Validate mixer state
3. Play audio clip on plughw:0,0 (if not skipped)
4. Report results

## Sample Output

**Example 1: Testing handset playback**
```
[INFO] 2026-04-20 21:35:23 - Using unique result file: /tmp/Runner/suites/Multimedia/Audio/Audio_Hamoa/AudioPlayback/AudioPlayback_Hamoa_Handset.res
[INFO] 2026-04-20 21:35:23 - ------------------- Starting AudioPlayback_Hamoa Testcase --------------------------
[INFO] 2026-04-20 21:35:23 - Platform: machine='Qualcomm Technologies, Inc. Hamoa IoT EVK' target='unknown'
[INFO] 2026-04-20 21:35:23 - Configuration:
[INFO] 2026-04-20 21:35:23 -   Device: handset
[INFO] 2026-04-20 21:35:23 -   Clip Names: playback_config1
[INFO] 2026-04-20 21:35:23 -   Audio Clips Path: /home/AudioClips
[INFO] 2026-04-20 21:35:23 -   Discovered Clips: 1
[INFO] 2026-04-20 21:35:23 - ==========================================
[INFO] 2026-04-20 21:35:23 - TEST 1: Handset Playback (Speakers)
[INFO] 2026-04-20 21:35:23 - ==========================================
[INFO] 2026-04-20 21:35:23 - Configuring mixer for handset playback (speakers)...
[INFO] 2026-04-20 21:35:23 - Handset playback mixer configured successfully
[INFO] 2026-04-20 21:35:23 - Validating mixer state for: handset_playback
[INFO] 2026-04-20 21:35:23 - Mixer state validation passed
[INFO] 2026-04-20 21:35:23 - Playing clip: yesterday_16KHz_30s_16b_2ch.wav on device: plughw:0,1
Playing WAVE '/home/AudioClips/yesterday_16KHz_30s_16b_2ch.wav' : Signed 16 bit Little Endian, Rate 16000 Hz, Stereo
[PASS] 2026-04-20 21:35:53 - Handset playback test PASSED
[PASS] 2026-04-20 21:35:53 - AudioPlayback_Hamoa_Handset : PASS
```

**Example 2: Testing both devices**
```
[INFO] 2026-04-20 18:47:27 - Device: all
[INFO] 2026-04-20 18:47:27 - TEST 1: Handset Playback (Speakers)
[PASS] 2026-04-20 18:47:57 - Handset playback test PASSED
[INFO] 2026-04-20 18:47:57 - TEST 2: Headset Playback (Headphones)
[PASS] 2026-04-20 18:48:27 - Headset playback test PASSED
[PASS] 2026-04-20 18:48:27 - AudioPlayback_Hamoa : PASS
```

**Example 3: Mixer-only test (no playback)**
```
[INFO] 2026-04-20 18:48:59 - Skip Actual Playback: 1
[INFO] 2026-04-20 18:48:59 - Configuring mixer for handset playback (speakers)...
[INFO] 2026-04-20 18:48:59 - Handset playback mixer configured successfully
[INFO] 2026-04-20 18:48:59 - Validating mixer state for: handset_playback
[INFO] 2026-04-20 18:48:59 - Mixer state validation passed
[INFO] 2026-04-20 18:48:59 - Skipping actual playback (mixer configuration verified)
[PASS] 2026-04-20 18:48:59 - Handset playback test PASSED
```

## Expected Results

- **PASS**: All selected device tests succeed (mixer configuration and playback)
- **FAIL**: One or more device tests fail

## Results

- Results are stored in: `results/AudioPlayback_Hamoa/` (or `results/AudioPlayback_Hamoa_<suffix>/` when using --res-suffix)
- Summary result file: `AudioPlayback_Hamoa.res` (or `AudioPlayback_Hamoa_<suffix>.res` when using --res-suffix)
- Diagnostic logs: mixer dumps per test case
- **Note**: When using --res-suffix, both result files AND log directories are unique per invocation, preventing log collisions in CI/LAVA workflows

## Dependencies

- ALSA utilities (`aplay`, `amixer`)
- `Runner/utils/audio/alsa_common.sh` library
- `functestlib.sh` framework library
- Audio clips in `/home/AudioClips/` or custom path

## Notes

- Mixer configurations are based on verified Hamoa commands for the platform
- If no audio clips are found, the test will fail with an error message
- Mixer validation ensures all controls are set correctly before playback
- The test supports parallel execution with unique result files using --res-suffix
- Use --lava-testcase-id to prevent testcase ID collisions in LAVA
- Logs include complete mixer state dumps for debugging

## Known Limitations

- 8kHz mono recordings cannot be played back directly with `aplay` on this platform
- Use `sox` to convert for playback: `sox input.wav -r 48000 output.wav`
- Or play on a different device that supports 8kHz mono

## Related Tests

- **AudioRecord_Hamoa**: Tests audio capture functionality

## License

SPDX-License-Identifier: BSD-3-Clause
Copyright (C) Qualcomm Technologies, Inc. and/or its subsidiaries.