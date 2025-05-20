# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# KMSCube GraphicsTest Scripts for RB3 Gen2 (Yocto)
# Overview

Graphics scripts automates the validation of Graphics OpenGL ES 2.0 capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes kmscube test app which is publicly available at https://gitlab.freedesktop.org/mesa/kmscube

## Features

- Primarily uses OpenGL ES 2.0, but recent versions include headers for OpenGL ES 3.0 for compatibility
- Uses Kernel Mode Setting (KMS) and Direct Rendering Manager (DRM) to render directly to the screen without a display server
- Designed to be lightweight and minimal, making it ideal for embedded systems and validation environments.
- Can be used to measure GPU performance or validate rendering pipelines in embedded Linux systems

## Prerequisites

Ensure the following components are present in the target Yocto build:

- kmscube (Binary Available in /usr/bin) - this test app can be compiled from https://gitlab.freedesktop.org/mesa/kmscube
- Weston should be killed while running KMSCube Test
- Write access to root filesystem (for environment setup)

## Directory Structure

```
bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Graphics/
│   │   │   ├── KMSCube/
│   │   │   │   ├── run.sh
```

## Usage

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to the /var directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to the /var directory on the target device.

3. Run Scripts: Navigate to the /var directory on the target device and execute the scripts as needed.

Run a Graphics KMSCube test using:
---
#### Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:/var
ssh user@target_device_ip 
cd /var/Runner && ./run-test.sh KMSCube
```
#### Sample output:
```
sh-5.2# cd /var/Runner && ./run-test.sh KMSCube
[Executing test case: /var/Runner/suites/Multimedia/Graphics/KMSCube] 2024-12-03 02:24:28 -
[INFO] 2024-12-03 02:24:28 - -----------------------------------------------------------------------------------------
[INFO] 2024-12-03 02:24:28 - ------------------- Starting KMSCube Testcase ----------------------------
[INFO] Weston is not running.
[INFO] Running kmscube test with --count=999...
Using display 0xaaaae2bc1570 with EGL version 1.5
===================================
.
.
.
.
===================================
Rendered 120 frames in 2.002644 sec (59.920778 fps)
Rendered 240 frames in 4.004462 sec (59.933152 fps)
Rendered 360 frames in 6.007069 sec (59.929391 fps)
Rendered 480 frames in 8.009654 sec (59.927682 fps)
Rendered 600 frames in 10.011171 sec (59.933051 fps)
Rendered 720 frames in 12.014519 sec (59.927493 fps)
Rendered 840 frames in 14.015205 sec (59.934905 fps)
Rendered 960 frames in 16.017444 sec (59.934656 fps)
Rendered 998 frames in 16.651489 sec (59.934580 fps)

[PASS] kmscube rendered 998 frames successfully.

KMSCube PASS
[INFO] 2024-12-03 02:24:45 -
[INFO] 2024-12-03 02:24:45 - ------------------- Completed KMSCube Testcase ----------------------------
```
## Notes

- It validates the graphics gles2 functionalities.
- If any critical tool is missing, the script exits with an error message.
- kmscube_validation__$(date +%Y%m%d_%H%M%S).log are useful to debug driver related issue