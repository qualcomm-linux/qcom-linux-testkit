# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Iris V4L2 Video Test Scripts for Qualcomm Linux based platform (Yocto)

## Overview

Video scripts automates the validation of video encoding and decoding capabilities on the Qualcomm Linux based platform running a Yocto-based Linux system. It utilizes iri_v4l2_test test app which is publicly available @https://github.com/quic/v4l-video-test-app

## Features

- V4L2 driver level test
- Encoding YUV to H264/H265 bitstream
- Decoding H264/H265/VP9 bitstream to YUV
- Compatible with Yocto-based root filesystem
- Supports both encode and decode test modes.
- Parses and runs multiple JSON config files.
- Automatically fetches missing input clips from a predefined URL.
- Supports timeout, repeat, dry-run, and JUnit XML output.
- Performs dmesg scanning for kernel errors.
- Generates summary reports.

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `iris_v4l2_test` (available in /usr/bin/) - this test app can be compiled from https://github.com/quic/v4l-video-test-app
- input json config files for encode/decode tests
- input bitstream for decode script
- input YUV for encode script
- Write access to root filesystem (for environment setup)
- POSIX shell utilities: grep, sed, awk, find, sort
- Optional: run_with_timeout function from functestlib.sh
- Internet access (for fetching missing clips)

## Directory Structure

```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Video/
│   │   │   ├── Video_V4L2_Runner/
│   │   │   │   ├── h264Decoder.json
│   │   │   │   ├── h265Decoder.json
│   │   │   │   ├── vp9Decoder.json
│   │   │   │   ├── h264Encoder.json
│   │   │   │   ├── h265Encoder.json
│   │   │   │   ├── run.sh
│   │   │   ├── README_Video.md
├── utils/
│   ├── lib_video.sh
```

## Usage

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to any directory on the target device.

3. Run Scripts: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run a specific test using:
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip 
cd <Path in device>/Runner && ./run-test.sh Video_V4L2_Runner
```
Sample output:
```
sh-5.2# ./run-test.sh Video_V4L2_Runner
[Executing test case: Video_V4L2_Runner] 2025-09-02 05:08:36 -
[INFO] 2025-09-02 05:08:36 - ----------------------------------------------------------------------
[INFO] 2025-09-02 05:08:36 - ------------------ Starting Video_V4L2_Runner (generic runner) ----------------
[INFO] 2025-09-02 05:08:36 - === Initialization ===
[INFO] 2025-09-02 05:08:36 - TIMEOUT=60s STRICT=0 DMESG_SCAN=1 SUCCESS_RE=SUCCESS
[INFO] 2025-09-02 05:08:36 - LOGLEVEL=15
[INFO] 2025-09-02 05:08:36 - REPEAT=1 REPEAT_DELAY=0s REPEAT_POLICY=all
[INFO] 2025-09-02 05:08:36 - No config argument passed, searching for JSON files in ./Runner/suites/Multimedia/Video/
[INFO] 2025-09-02 05:08:36 - Configs to run:
- ./Runner/suites/Multimedia/Video/Video_V4L2_Runner/h264Decoder.json
- ./Runner/suites/Multimedia/Video/Video_V4L2_Runner/h264Encoder.json
- ./Runner/suites/Multimedia/Video/Video_V4L2_Runner/h265Decoder.json
- ./Runner/suites/Multimedia/Video/Video_V4L2_Runner/h265Encoder.json
- ./Runner/suites/Multimedia/Video/Video_V4L2_Runner/vp9Decoder.json
[INFO] 2025-09-02 05:08:37 - No relevant, non-benign errors for modules [oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error] in recent dmesg.
[PASS] 2025-09-02 05:08:37 - [Decode1] PASS (1/1 ok)
[INFO] 2025-09-02 05:08:39 - No relevant, non-benign errors for modules [oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error] in recent dmesg.
[PASS] 2025-09-02 05:08:39 - [Encode1] PASS (1/1 ok)
[INFO] 2025-09-02 05:08:55 - No relevant, non-benign errors for modules [oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error] in recent dmesg.
[PASS] 2025-09-02 05:08:55 - [Decode2] PASS (1/1 ok)
[INFO] 2025-09-02 05:08:57 - No relevant, non-benign errors for modules [oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error] in recent dmesg.
[PASS] 2025-09-02 05:08:57 - [Encode2] PASS (1/1 ok)
[INFO] 2025-09-02 05:09:01 - No relevant, non-benign errors for modules [oom|memory|BUG|hung task|soft lockup|hard lockup|rcu|page allocation failure|I/O error] in recent dmesg.
[PASS] 2025-09-02 05:09:01 - [Decode3] PASS (1/1 ok)
[INFO] 2025-09-02 05:09:01 - Summary: total=5 pass=5 fail=0 skip=0
[PASS] 2025-09-02 05:09:01 - Video_V4L2_Runner: PASS
[PASS] 2025-09-02 05:09:01 - Video_V4L2_Runner passed
 
[INFO] 2025-09-02 05:09:01 - ========== Test Summary ==========
PASSED:
Video_V4L2_Runner
 
FAILED:
None
 
SKIPPED:
None
[INFO] 2025-09-02 05:09:01 - ==================================
```

4. Results will be available in the `Runner/suites/Multimedia/Video/Video_V4L2_Runner` directory.

## Common Options

| Option | Description |
|--------|-------------|

| `--extract-input-clips true|false` | Auto-fetch missing clips (default: true) |
| `--stack auto|upstream|downstream|base|overlay|up|down` | Select video stack |
| `--platform lemans|monaco|kodiak` | Specify platform for validation |
| `--downstream-fw PATH` | Path to downstream firmware (Kodiak-specific) |
| `--force` | Force stack switch or firmware override |
| `--verbose` | Enable verbose logging |
| `--config path.json` | Run a specific config file | 
| `--dir DIR` | Directory to search for configs | 
| `--pattern GLOB` | Filter configs by glob pattern | 
| `--timeout S` | Timeout per test (default: 60s) | 
| `--strict`              | Fail on critical dmesg errors                   |
| `--no-dmesg`            | Disable dmesg scanning                          |
| `--max N`               | Run at most N tests                             |
| `--stop-on-fail`        | Stop on first failure                           |
| `--loglevel N`          | Set log level for `iris_v4l2_test`             |
| `--repeat N`            | Repeat each test N times                        |
| `--repeat-delay S`      | Delay between repeats                           |
| `--repeat-policy        | all or any |
| `--junit FILE`          | Output JUnit XML to file                        |
| `--dry-run`             | Show commands without executing                 |


## Notes

- The script auto-detects encode/decode mode based on config filename.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.
- Missing input clips are fetched from:
https://github.com/qualcomm-linux/qcom-linux-testkit/releases/download/IRIS-Video-Files-v1.0/video_clips_iris.tar.gz

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.