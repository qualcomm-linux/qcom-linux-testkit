Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

SPDX-License-Identifier: BSD-3-Clause-Clear
# weston-simple-egl GraphicsTest Scripts for Qualcomm Linux based platform (Yocto)
# Overview

Graphics scripts automates the validation of Graphics OpenGL ES 2.0 capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes Weston-Simple-EGL test app which is publicly available at https://github.com/krh/weston

## Features

- Wayland Client Integration , Uses wl_compositor, wl_shell, wl_seat, and wl_shm interfaces
- OpenGL ES 2.0 Rendering
- EGL Context Initialization

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `weston-simple-egl` (Binary Available in /usr/bin) be default
- Write access to root filesystem (for environment setup)

## Directory Structure

```
bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Graphics/
│   │   │   ├── weston-simple-egl/
│   │   │   │   ├── run.sh
```

## Usage

Instructions

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to any directory on the target device.

3. Run Scripts: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run Graphics weston-simple-egl using:
---
#### Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh weston-simple-egl
```

#### Sample output:
```
sh-5.2# cd <Path in device>/Runner/ && ./run-test.sh weston-simple-egl
[Executing test case: weston-simple-egl] 2025-01-08 19:57:17 -
[INFO] 2025-01-08 19:57:17 - --------------------------------------------------------------------------
[INFO] 2025-01-08 19:57:17 - ------------------- Starting weston-simple-egl Testcase --------------------------
[INFO] 2025-01-08 19:57:17 - Weston already running.
[INFO] 2025-01-08 19:57:17 - Running weston-simple-egl for 30 seconds...
QUALCOMM build                   : 05b958b3c9, Ia7470d0c4c
Build Date                       : 03/27/25
OpenGL ES Shader Compiler Version:
Local Branch                     :
Remote Branch                    :
Remote Branch                    :
Reconstruct Branch               :

Build Config                     : G ESX_C_COMPILER_OPT 3.3.0 AArch64
Driver Path                      : /usr/lib/libGLESv2_adreno.so.2
Driver Version                   : 0808.0.6
Process Name                     : weston-simple-egl
PFP: 0x016dc112, ME: 0x00000000
Pre-rotation disabled !!!

EGL updater thread started

MSM_GEM_NEW returned handle[1] for drm_fd=5 buffer flag=65536 buffer size=266240
Get fd[7] from GEM HANDLE[1]
MSM_GEM_NEW returned handle[2] for drm_fd=5 buffer flag=65536 buffer size=266240
Get fd[7] from GEM HANDLE[2]
MSM_GEM_NEW returned handle[3] for drm_fd=5 buffer flag=65536 buffer size=266240
Get fd[7] from GEM HANDLE[3]
MSM_GEM_NEW returned handle[4] for drm_fd=5 buffer flag=65536 buffer size=266240
Get fd[7] from GEM HANDLE[4]
303 frames in 5 seconds: 60.599998 fps
300 frames in 5 seconds: 60.000000 fps
298 frames in 5 seconds: 59.599998 fps
300 frames in 5 seconds: 60.000000 fps
299 frames in 5 seconds: 59.799999 fps
[PASS] 2025-01-08 19:57:49 - weston-simple-egl : Test Passed
[INFO] 2025-01-08 19:57:49 - ------------------- Completed weston-simple-egl Testcase ------------------------
[PASS] 2025-01-08 19:57:49 - weston-simple-egl passed

[INFO] 2025-01-08 19:57:49 - ========== Test Summary ==========
PASSED:
weston-simple-egl

FAILED:
 None
[INFO] 2025-01-08 19:57:49 - ==================================
sh-5.2#
```
## Notes

- It validates the graphics gles2 functionalities.
- If any critical tool is missing, the script exits with an error message.
