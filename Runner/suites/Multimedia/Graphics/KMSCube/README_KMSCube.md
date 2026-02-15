Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

SPDX-License-Identifier: BSD-3-Clause# KMSCube GraphicsTest Scripts for Qualcomm Linux based platform (Yocto)
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

Instructions

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to any directory on the target device.

3. Run Scripts: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run a Graphics KMSCube test using:
---
#### Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh KMSCube
```
#### Sample output:
```
sh-5.2# cd <Path in device>/Runner/ && ./run-test.sh KMSCube
[Executing test case: KMSCube] 2025-01-08 19:54:40 -
[INFO] 2025-01-08 19:54:40 - -------------------------------------------------------------------
[INFO] 2025-01-08 19:54:40 - ------------------- Starting kmscube Testcase -------------------
[INFO] 2025-01-08 19:54:40 - Stopping Weston...
[INFO] 2025-01-08 19:54:42 - Weston stopped.
[INFO] 2025-01-08 19:54:42 - Running kmscube test with --count=999...
[PASS] 2025-01-08 19:54:59 - kmscube : Test Passed
[INFO] 2025-01-08 19:55:02 - Weston started.
[INFO] 2025-01-08 19:55:02 - ------------------- Completed kmscube Testcase ------------------
[PASS] 2025-01-08 19:55:02 - KMSCube passed

[INFO] 2025-01-08 19:55:02 - ========== Test Summary ==========
PASSED:
KMSCube

FAILED:
 None
[INFO] 2025-01-08 19:55:02 - ==================================
sh-5.2#
```
## Notes

- It validates the graphics gles2 functionalities.
- If any critical tool is missing, the script exits with an error message.
