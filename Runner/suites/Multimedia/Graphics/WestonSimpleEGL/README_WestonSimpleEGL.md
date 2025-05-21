# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
# WestonSimpleEGL GraphicsTest Scripts for RB3 Gen2 (Yocto)
# Overview

Graphics scripts automates the validation of Graphics OpenGL ES 2.0 capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes Weston-Simple-EGL test app which is publicly available at https://github.com/krh/weston

## Features

- Wayland Client Integration , Uses wl_compositor, wl_shell, wl_seat, and wl_shm interfaces
- OpenGL ES 2.0 Rendering
- EGL Context Initialization

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `WestonSimpleEGL` (Binary Available in /usr/bin) be default
- Write access to root filesystem (for environment setup)

## Directory Structure

```
bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Graphics/
│   │   │   ├── WestonSimpleEGL/
│   │   │   │   ├── run.sh
```

## Usage

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to the /var directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to the /var directory on the target device.

3. Run Scripts: Navigate to the /var directory on the target device and execute the scripts as needed.

Run Graphics WestonSimpleEGL using:
---
#### Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:/var
ssh user@target_device_ip 
cd /var/Runner && ./run-test.sh WestonSimpleEGL
```

#### Sample output:
```
sh-5.2# cd /var/Runner && ./run-test.sh WestonSimpleEGL
[Executing test case: /var/Runner/suites/Multimedia/Graphics/WestonSimpleEGL] 2024-12-03 05:04:26 -
[INFO] 2024-12-03 05:04:26 - -----------------------------------------------------------------------------------------
[INFO] 2024-12-03 05:04:26 - ------------------- Starting WestonSimpleEGL Testcase ----------------------------
[INFO] Running weston-simple-egl for 30 seconds...
has EGL_EXT_buffer_age and EGL_EXT_swap_buffers_with_damage
302 frames in 5 seconds: 60.400002 fps
300 frames in 5 seconds: 60.000000 fps
300 frames in 5 seconds: 60.000000 fps
300 frames in 5 seconds: 60.000000 fps
300 frames in 5 seconds: 60.000000 fps
[INFO] weston-simple-egl successfully executed for 30 seconds.
WestonSimpleEGL PASS
[INFO] 2024-12-03 05:05:02 - ------------------- Completed WestonSimpleEGL Testcase ----------------------------
```

## Notes

- It validates the graphics gles2 functionalities.
- If any critical tool is missing, the script exits with an error message.
- WestonSimpleEGL_$(date +%Y%m%d_%H%M%S).log are useful to debug driver related issue