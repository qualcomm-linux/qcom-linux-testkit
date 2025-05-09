# Iris V4L2 Video Test Scripts for RB3 Gen2 (Yocto)

## Overview

Video scripts automates the validation of video encoding and decoding capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes iri_v4l2_test test app which is publicly available @https://github.com/quic/v4l-video-test-app

## Features

- V4L2 driver level test
- Encoding YUV to H264 bitstream
- Decoding H264 bitstream to YUV
- Compatible with Yocto-based root filesystem

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `iris_v4l2_test` (installed or in `$PATH` or in Runner/utils/) - this test app can be compiled from https://github.com/quic/v4l-video-test-app
- input json file for iris_v4l2_test app
- input bitstream for decode script
- input YUV for encode script
- Write access to root filesystem (for environment setup)

## Directory Structure

```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Video/
│   │   │   ├── iris_v4l2_video_encode/
│   │   │   │   ├── H264Encoder.json
│   │   │   │   ├── run.sh
│   │   │   ├── iris_v4l2_video_decode/    
│   │   │   │   ├── H264Decoder.json
│   │   │   │   ├── run.sh      
```

## Usage

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
...
[PASS] 1980-01-08 22:22:17 - iris_v4l2_video_encode : Test Passed
[INFO] 1980-01-08 22:22:17 - -------------------Completed iris_v4l2_video_encode Testcase----------------------------

3. Results will be available in the `Runner/suites/Multimedia/Video/` directory under each usecase folder.

## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.