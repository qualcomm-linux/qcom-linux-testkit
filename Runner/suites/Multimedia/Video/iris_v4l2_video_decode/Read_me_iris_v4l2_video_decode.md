# Iris V4L2 Video Decode Validation Script for RB3 Gen2 (Yocto)

## Overview

This script automates the validation of video decoding capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes iri_v4l2_test test app to decode H264 bitstream into yuv output.

## Features

- V4L2 driver level test
- Decoding H264 compression format to YUV
- Compatible with Yocto-based root filesystem

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `iris_v4l2_test` (installed or in `$PATH` or in Runner/utils/) - this test app can be compiled from https://github.com/quic/v4l-video-test-app
- input json file H264Decoder.json
- input bitstream simple_AVC_720p_10fps_90frames.264
- Write access to root filesystem (for environment setup)

## Directory Structure

```bash
Runner/
├utils/
├	├iris_v4l2_test
├──suites/
├	├── Multimedia/
│   ├	├── Video/
│   ├	├	├── iris_v4l2_video_decode/
│   ├	├	├	├	├── H264Decoder.json
│   ├	├	├	├	└── run.sh
├	├	├	├	├	└── simple_AVC_720p_10fps_90frames.264
├	├	├	├	├	└── video_dec.txt
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
cd /var/Runner && ./run-test.sh iris_v4l2_video_decode
```

Sample Output:
sh-5.2# cd /var/Runner && ./run-test.sh iris_v4l2_video_decode
[Executing test case: /var/Runner/suites/Multimedia/Video/iris_v4l2_video_decode] 1980-01-08 22:22:05 -
[INFO] 1980-01-08 22:22:05 - -----------------------------------------------------------------------------------------
[INFO] 1980-01-08 22:22:05 - -------------------Starting iris_v4l2_video_decode Testcase----------------------------
[INFO] 1980-01-08 22:22:05 - Checking if dependency binary is available
[PASS] 1980-01-08 22:22:05 - Test related dependencies are present.
Input #0, h264, from './suites/Multimedia/Video/iris_v4l2_video_decode/simple_AVC_720p_10fps_90frames.264':
  Duration: N/A, bitrate: N/A
  Stream #0:0: Video: h264 (High), none(progressive), 1280x720, 25 fps, 20 tbr, 1200k tbn
[Decoder Testcase]: Error: Read frame failed
[Decoder Testcase]: Error: Read frame failed
Heap fd closed.
[PASS] 1980-01-08 22:22:07 - iris_v4l2_video_decode : Test Passed
[INFO] 1980-01-08 22:22:07 - -------------------Completed iris_v4l2_video_decode Testcase----------------------------


3. Results will be available in the `Runner/suites/Multimedia/Video/iris_v4l2_video_decode/video_dec.txt` directory.


## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.


