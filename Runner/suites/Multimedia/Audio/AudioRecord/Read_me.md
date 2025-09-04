# Audio Record Validation Script for Qualcomm Linux-based Platform (Yocto)

## Overview

This script automates the validation of audio recording capabilities on the Qualcomm Linux-based platform running a Yocto-based Linux system. It supports both PulseAudio and PipeWire backends for audio recording.

## Features

- Records PCM audio to '/tmp/rec.wav' using either `parec` or `pw-record`
- Automatically detects and sets PipeWire source ID if PipeWire is used
- Uses `AUDIO_BACKEND` environment variable to select backend (default: PipeWire)
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
├── run-test.sh
├── utils/
│   ├── functestlib.sh
│   └── libaudio.sh
└── suites/
    └── Multimedia/
        └── Audio/
            ├── AudioRecord/
                ├── run.sh         
                └── Read_me.md      
```

## Usage

Instructions:
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
AUDIO_BACKEND=pulseaudio RECORD_TIMEOUT=12s RECORD_LOOPS=2 RECORD_FILE=/tmp/record_pa.wav ./run-test.sh AudioRecord
cd Runner/suites/Multimedia/Audio/AudioRecord && ./run.sh --backend pulseaudio --loops 2 --timeout 12s --rec-file /tmp/record_pa.wav

**Run with PipeWire**
AUDIO_BACKEND=pipewire ./run-test.sh AudioRecord
AUDIO_BACKEND=pipewire RECORD_TIMEOUT=10s RECORD_LOOPS=3 RECORD_FILE=/tmp/record_pw.wav ./run-test.sh AudioRecord
cd Runner/suites/Multimedia/Audio/AudioRecord && ./run.sh --backend pipewire --loops 3 --timeout 10s --rec-file /tmp/record_pw.wav


Environment Variables:
You can customize recording behavior using the following environment variables:
AUDIO_BACKEND: Selects the audio backend (pulseaudio or pipewire). Default is pulseaudio.
RECORD_TIMEOUT: Timeout duration for recording (e.g., 12s). Default is 12s.
RECORD_LOOPS: Number of times to repeat recording. Default is 1.

CLI Options:
Option		Description
--backend	Select audio backend: pulseaudio or pipewire
--loops		Number of recording loops
--timeout	Recording timeout duration (e.g., 12s)
--rec-file	Path to output WAV file
--help		Show usage instructions
```

Sample Output:
```
sh-5.2# AUDIO_BACKEND=pipewire ./run-test.sh AudioRecord
[Executing test case: AudioRecord] 2025-09-04 09:14:09 -
[INFO] 2025-09-04 09:14:09 - ---------------- Starting AudioRecord Testcase ----------------
[INFO] 2025-09-04 09:14:09 - Using audio backend: pipewire
[INFO] 2025-09-04 09:14:09 - Detected PipeWire source ID: 48
[INFO] 2025-09-04 09:14:09 - Recording loop 1 of 1
[WARN] 2025-09-04 09:14:24 - Recording loop 1: Timed out (ret=124) and recorded clip exists
[INFO] 2025-09-04 09:14:24 - Scanning dmesg for audio: errors & success patterns
[INFO] 2025-09-04 09:14:24 - No audio-related errors found (no OK pattern requested)
[PASS] 2025-09-04 09:14:24 - Audio record test completed successfully
[PASS] 2025-09-04 09:14:24 - AudioRecord passed
```

Results:
Results are stored in: results/AudioRecord/
Summary result file: AudioRecord.res


## Notes

- The script validates the presence of required libraries before executing tests.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.

