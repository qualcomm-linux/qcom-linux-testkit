# Iris V4L2 Video Encode Validation Script for RB3 Gen2 (Yocto)

## Overview

This script automates the validation of video encoding capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes iri_v4l2_test test app to encode YUV into H264 bitstream output.

## Features

- V4L2 driver level test
- Encoding YUV to H264 compression format
- Compatible with Yocto-based root filesystem

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `iris_v4l2_test` (installed or in `$PATH` or in Runner/utils/) - this test app can be compiled from https://github.com/quic/v4l-video-test-app
- input json file H264Encoder.json
- input bitstream simple_AVC_720p_10fps_90frames.yuv
- Write access to root filesystem (for environment setup)

## Directory Structure

```bash
Runner/
├utils/
├	├iris_v4l2_test
├──suites/
├	├── Multimedia/
│   ├	├── Video/
│   ├	├	├── iris_v4l2_video_encode/
│   ├	├	├	├	├── H264Encoder.json
│   ├	├	├	├	└── run.sh
├	├	├	├	├	└── simple_nv12_720p_90frms.yuv
├	├	├	├	├	└── video_enc.txt
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
cd /var/Runner && ./run-test.sh iris_v4l2_video_encode
```
Sample output:
sh-5.2# cd /var/Runner && ./run-test.sh iris_v4l2_video_encode
[Executing test case: /var/Runner/suites/Multimedia/Video/iris_v4l2_video_encode] 1980-01-08 22:22:15 -
[INFO] 1980-01-08 22:22:15 - -----------------------------------------------------------------------------------------
[INFO] 1980-01-08 22:22:15 - -------------------Starting iris_v4l2_video_encode Testcase----------------------------
[INFO] 1980-01-08 22:22:15 - Checking if dependency binary is available
[PASS] 1980-01-08 22:22:15 - Test related dependencies are present.
[rawvideo @ 0x14a25390] Estimating duration from bitrate, this may be inaccurate
Input #0, rawvideo, from './suites/Multimedia/Video/iris_v4l2_video_encode/simple_nv12_720p_90frms.yuv':
  Duration: 00:00:01.28, start: 0.000000, bitrate: 276480 kb/s
  Stream #0:0: Video: rawvideo (NV12 / 0x3231564E), nv12, 1280x720, 276480 kb/s, 25 tbr, 25 tbn
Heap fd closed.
[PASS] 1980-01-08 22:22:17 - iris_v4l2_video_encode : Test Passed
[INFO] 1980-01-08 22:22:17 - -------------------Completed iris_v4l2_video_encode Testcase----------------------------


3. Results will be available in the `Runner/suites/Multimedia/Video/iris_v4l2_video_encode/video_enc.txt` directory.


## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.


