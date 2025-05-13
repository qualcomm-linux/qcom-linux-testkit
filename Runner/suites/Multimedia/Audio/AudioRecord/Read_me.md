# Audio enccode Validation Script for RB3 Gen2 (Yocto)

## Overview

This script automates the validation of audio encode capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes pulseaudio test app to encode file.

## Features

- Encode PCM clip with --rate=48000 --format=s16le --channels=1 --file-format=wav /tmp/rec1.wav -d regular0
- Compatible with Yocto-based root filesystem

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `parec` binary(available at /usr/bin) 

## Directory Structure

```bash
Runner/
├utils/
├	├AudioPlayback
├──suites/
├	├── Multimedia/
│   ├	├── Audio/
│   ├	├	├── AudioRecord/
│   ├	├	├	├	└── run.sh
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
cd /var/Runner && ./run-test.sh AudioRecord
```

Sample Output:
sh-5.2# ./run-test.sh AudioRecord
[Executing test case: /var/Runner/suites/Multimedia/Audio/AudioRecord] 1980-01-10 00:50:32 -
--------------------------------------------------------------------------
-------------------Starting audio_record_test Testcase----------------------------
Checking if dependency binary is available
[PASS] 1980-01-10 00:50:32 - Test related dependencies are present.
/var/Runner/suites/Multimedia/Audio/AudioRecord/run.sh: line 41: PID: command not found
/var/Runner/suites/Multimedia/Audio/AudioRecord/run.sh: line 46: [-z: command not found
Test Binary parec is running successfully
=== Overall Audio Test Validation Result ===
Param 2808851
/var/Runner/suites/Multimedia/Audio/AudioRecord/run.sh: line 55: local: `=': not a valid identifier
/var/Runner/suites/Multimedia/Audio/AudioRecord/run.sh: line 55: local: `': not a valid identifier
 280905 pts/0    S+     0:00 parec --rate=48000 --format=s16le --channels=1 --file-format=wav /tmp/rec1.wav -d regular0
Successfully audio record completed
[PASS] 1980-01-10 00:50:42 - audio_record_test : Test Passed
Test Passed
Clean up the old PID by Killing the process
280903
/var/Runner/suites/Multimedia/Audio/AudioRecord/run.sh: line 84: 280903 Killed                  tail -f /var/log/syslog > results/audiotestresult/syslog_log.txt
280904
/var/Runner/suites/Multimedia/Audio/AudioRecord/run.sh: line 84: 280904 Killed                  dmesg -w > results/audiotestresult/dmesg_log.txt
280905
/var/Runner/suites/Multimedia/Audio/AudioRecord/run.sh: line 84: 280905 Killed                  parec --rate=48000 --format=s16le --channels=1 --file-format=wav /tmp/rec1.wav -d regular0
-------------------Completed audio_record_test Testcase----------------------------

3. Results will be available in the `Runner/suites/Multimedia/Audio/AudioRecord/audio_test.txt` directory.


## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.


