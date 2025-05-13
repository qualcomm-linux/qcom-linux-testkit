# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Audio playback Validation Script for Qualcomm Linux based platform (Yocto)

## Overview

This script automates the validation of audio playback capabilities on the Qualcomm Linux based platform running a Yocto-based Linux system. It utilizes pulseaudio test app to decode wav file.

## Features

- Decoding PCM clip
- Compatible with Yocto-based root filesystem

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `paplay` binary(available at /usr/bin) 

## Directory Structure

```bash
Runner/
├──suites/
├   ├── Multimedia/
│   ├    ├── Audio/
│   ├    ├    ├── AudioPlayback/
│   ├    ├    ├    ├    └── run.sh
├   ├    ├    ├    ├    └── yesterday_48KHz.wav
├   ├    ├    ├    ├    └── audio_test.txt
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
```
sh-5.2# cd /var/Runner && ./run-test.sh AudioPlayback
[Executing test case: /var/Runner/suites/Multimedia/Audio/AudioPlayback] 1980-01-08 18:11:49 -
[INFO] 1980-01-08 18:11:49 - --------------------------------------------------------------------------
[INFO] 1980-01-08 18:11:49 - -------------------Starting audio_playback_test Testcase----------------------------
[INFO] 1980-01-08 18:11:49 - Checking if dependency binary is available
[PASS] 1980-01-08 18:11:49 - Test related dependencies are present.
[INFO] Checking network connectivity...
[FAIL] No active network interface found.
[INFO] Downloading https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/Pulse-Audio-Files-v1.0/AudioClips.tar.gz...
[INFO] 1980-01-08 18:11:49 - Playback clip downloaded
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 50: [-z: command not found
[INFO] 1980-01-08 18:11:59 - Test Binary paplay is running successfully
[INFO] 1980-01-08 18:11:59 - === Overall Audio Test Validation Result ===
[INFO] 1980-01-08 18:11:59 - Param 26916561
2691687 pts/0    S+     0:00 paplay ./suites/Multimedia/Audio/AudioPlayback/yesterday_48KHz.wav -d low-latency0
[INFO] 1980-01-08 18:11:59 - Successfully audio playback completed
[PASS] 1980-01-08 18:11:59 - audio_playback_test : Test Passed
[INFO] 1980-01-08 18:11:59 - Clean up the old PID by Killing the process
[INFO] 1980-01-08 18:11:59 - 2691685
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 86: 2691685 Killed                  tail -f /var/log/syslog > results/audiotestresult/syslog_log.txt
[INFO] 1980-01-08 18:12:00 - 2691686
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 86: 2691686 Killed                  dmesg -w > results/audiotestresult/dmesg_log.txt
[INFO] 1980-01-08 18:12:01 - 2691687
/var/Runner/suites/Multimedia/Audio/AudioPlayback/run.sh: line 86: 2691687 Killed                  paplay ./suites/Multimedia/Audio/AudioPlayback/yesterday_48KHz.wav -d low-latency0
[INFO] 1980-01-08 18:12:02 - -------------------Completed audio_playback_test Testcase----------------------------
sh-5.2#
```
3. Results will be available in the `Runner/suites/Multimedia/Audio/AudioPlayback/audio_test.txt` directory.


## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.


