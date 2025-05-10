# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Audio playback Validation Script for RB3 Gen2 (Yocto)

## Overview

This script automates the validation of audio playback capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes pulseaudio test app to decode wav file.

## Features

- Decoding PCM clip
- Compatible with Yocto-based root filesystem

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `paplay` binary(available at /usr/bin) 

## Directory Structure

```bash
Runner/
├utils/
├	├AudioPlayback
├──suites/
├	├── Multimedia/
│   ├	├── Audio/
│   ├	├	├── AudioPlayback/
│   ├	├	├	├	└── run.sh
├	├	├	├	├	└── yesterday_48KHz.wav
├	├	├	├	├	└── audio_test.txt
```

## Usage


Instructions

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to the /var directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to the /var directory on the target device.

3. Run Scripts: Navigate to the /var directory on the target device and execute the scripts as needed.

Run a specific test using:
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:/var
ssh user@target_device_ip 
cd /var/Runner && ./run-test.sh AudioPlayback
```

Sample Output:
sh-5.2# ./run-test.sh AudioRecord
[Test case directory not found: /var/Runner/suites/Multimedia/Audio/AudioRecord
/var/Runner/suites/Multimedia/AudioRecord] 1980-01-10 00:31:56 -
sh-5.2# ./run-test.sh AudioPlayback
[Executing test case: /var/Runner/suites/Multimedia/Audio/AudioPlayback] 1980-01-10 00:32:33 -
--------------------------------------------------------------------------
-------------------Starting audio_playback_test Testcase----------------------------
Checking if dependency binary is available
[PASS] 1980-01-10 00:32:33 - Test related dependencies are present.
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 41: PID: command not found
 
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 46: [-z: command not found
Test Binary paplay is running successfully
=== Overall Audio Test Validation Result ===
Param 2803321
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 55: local: `=': not a valid identifier
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 55: local: `': not a valid identifier
280352 pts/0    S+     0:00 paplay /tmp/yesterday_48KHz.wav -d low-latency0
Successfully audio playback completed
[PASS] 1980-01-10 00:32:43 - audio_playback_test : Test Passed
Test Passed
Clean up the old PID by Killing the process
280350
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 84: 280350 Killed                  tail -f /var/log/syslog > results/audiotestresult/syslog_log.txt
280351
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 84: 280351 Killed                  dmesg -w > results/audiotestresult/dmesg_log.txt
280352
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 84: 280352 Killed                  paplay /tmp/yesterday_48KHz.wav -d low-latency0
-------------------Completed audio_playback_test Testcase----------------------------
sh-5.2#


3. Results will be available in the `Runner/suites/Multimedia/Audio/AudioPlayback/audio_test.txt` directory.


## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.


