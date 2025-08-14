# Audio Record Validation Script for Qualcomm Linux-based Platform (Yocto)

## Overview

This script automates the validation of audio recording capabilities on the Qualcomm Linux-based platform running a Yocto-based Linux system. It supports both PulseAudio and PipeWire backends for audio recording.

## Features

- Records PCM audio to '/tmp/rec1.wav' using either `parec` or `pw-record`
- Automatically detects and sets PipeWire source ID if PipeWire is used
- Uses `AUDIO_BACKEND` environment variable to select backend (default: pulseaudio)
- Captures kernel logs before and after recording
- Scans dmesg logs for audio-related errors
- Supports configurable timeout and loop count for recording
- Validates presence of required daemons and binaries												 
- Compatible with Yocto-based root filesystem

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `parec` binary (for PulseAudio)
- `pw-record`, `wpctl`, `grep`, `sed`, `timeout`, `pgrep` (for PipeWire)
- `pulseaudio` or `pipewire` daemon must be running depending on backend
								

## Directory Structure

```bash
Runner/
├──suites/
├   ├── Multimedia/
│   ├    ├── Audio/
│   ├    ├    ├── AudioRecord/
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
cd <Path in device>Runner
**Run with PulseAudio**
AUDIO_BACKEND=pulseaudio ./run-test.sh AudioRecord
**Run with PipeWire**
AUDIO_BACKEND=pipewire ./run-test.sh AudioRecord

Environment Variables:
You can customize recording behavior using the following environment variables:
AUDIO_BACKEND: Selects the audio backend (pulseaudio or pipewire). Default is pulseaudio.
RECORD_TIMEOUT: Timeout duration for recording (e.g., 12s). Default is 12s.
RECORD_LOOPS: Number of times to repeat recording. Default is 1.
```

Sample Output:
```
sh-5.2# AUDIO_BACKEND=pipewire ./run-test.sh AudioRecord
[Executing test case: AudioRecord] 2025-08-14 10:35:43 -
[INFO] 2025-08-14 10:35:43 - ------------------------------------------------------------
[INFO] 2025-08-14 10:35:43 - ------------------- Starting AudioRecord Testcase ------------
[INFO] 2025-08-14 10:35:43 - Using audio backend: pipewire
[INFO] 2025-08-14 10:35:43 - Checking if dependency binary is available
[INFO] 2025-08-14 10:35:43 - Detected PipeWire source ID: 50
[INFO] 2025-08-14 10:35:55 - Scanning dmesg for audio: errors & success patterns
[INFO] 2025-08-14 10:35:55 - No audio-related errors found (no OK pattern requested)
[PASS] 2025-08-14 10:35:55 - Recording completed or timed out (ret=124) as expected and output file exists.
[PASS] 2025-08-14 10:35:55 - AudioRecord : Test Passed
[PASS] 2025-08-14 10:35:55 - AudioRecord passed
```

3. Results will be available in the `Runner/suites/Multimedia/Audio/AudioRecord/AudioRecord.res` directory.


## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.

