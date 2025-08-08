# Audio Playback Validation Script for Qualcomm Linux-based Platform (Yocto)

## Overview

This script automates the validation of audio playback capabilities on the Qualcomm Linux-based platform running a Yocto-based Linux system. It supports both PulseAudio and PipeWire backends for audio playback.

## Features

- Plays a test audio clip using either `paplay` or `pw-play`
- Supports configurable playback volume, timeout, and loop count
- Automatically downloads and extracts audio clip if not present
- Captures kernel logs before and after playback
- Scans dmesg logs for audio-related errors
- Validates presence of required daemons and binaries

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `paplay` binary (for PulseAudio)
- `pw-play`, `pgrep`, `timeout`, `grep` (for PipeWire)
- `pulseaudio` or `pipewire` daemon must be running depending on backend

## Directory Structure

```bash
Runner/
├──suites/
├   ├── Multimedia/
│   ├    ├── Audio/
│   ├    ├    ├── AudioPlayback/
│   ├    ├    ├    ├    └── run.sh
├   ├    ├    ├    ├    └── Read_me.md
```

## Usage


Instructions

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.

2. Verify Transfer: Ensure that the repo has been successfully copied to any directory on the target device.

3. Run Scripts: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run a specific test using:
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip 
cd <Path in device>/Runner
**Run with PulseAudio**
AUDIO_BACKEND=pulseaudio ./run-test.sh AudioPlayback
**Run with PipeWire**
AUDIO_BACKEND=pipewire ./run-test.sh AudioPlayback

Environment Variables:
You can customize playback behavior using the following environment variables:
AUDIO_BACKEND: Selects the audio backend (pulseaudio or pipewire). Default is pulseaudio.
PLAYBACK_TIMEOUT: Timeout duration for playback (e.g., 15s). Default is 15s.
PLAYBACK_LOOPS: Number of times to repeat playback. Default is 1.
PLAYBACK_VOLUME: Playback volume.
For paplay: Range is 0–65536 (default: 65536)
For pw-play: Range is 0.0–1.0 (default: 1.0)
```
Sample Output:
```
sh-5.2# AUDIO_BACKEND=pipewire ./run-test.sh AudioPlayback
[Executing test case: AudioPlayback] 2025-08-14 10:17:35 -
[INFO] 2025-08-14 10:17:35 - ------------------------------------------------------------
[INFO] 2025-08-14 10:17:35 - ------------------- Starting AudioPlayback Testcase ------------
[INFO] 2025-08-14 10:17:35 - Using audio backend: pipewire
[INFO] 2025-08-14 10:17:35 - Checking if dependency binary is available
[INFO] 2025-08-14 10:17:35 - Playback clip present: AudioClips/yesterday_48KHz.wav
[INFO] 2025-08-14 10:17:51 - Scanning dmesg for audio: errors & success patterns
[INFO] 2025-08-14 10:17:51 - No audio-related errors found (no OK pattern requested)
[PASS] 2025-08-14 10:17:51 - Playback completed or timed out (ret=124) as expected.
[PASS] 2025-08-14 10:17:51 - AudioPlayback : Test Passed
[PASS] 2025-08-14 10:17:51 - AudioPlayback passed
[INFO] 2025-08-14 10:17:51 - ========== Test Summary ==========
```
3. Results will be available in the `Runner/suites/Multimedia/Audio/AudioPlayback/AudioPlayback.res` directory.


## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.

