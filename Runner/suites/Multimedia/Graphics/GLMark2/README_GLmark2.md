# GLmark2-es2-wayland GraphicsTest Scripts for RB3 Gen2 (Yocto)

## Overview

Graphics scripts automates the validation of Graphics gles2 capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes GLmark2-es2-wayland test app which is publicly available @https://github.com/glmark2/glmark2

## Features

- OpenGL ES 2.0 API level test
- Various standard features , such as vertex arrays, vertex buffer objects (VBOs), texturing, and shaders 
- Provides detailed performance metrics, including frame rates and scores
- Supports offscreen rendering, allowing you to benchmark without displaying the output on the screen
- Specifically designed to run as a Wayland client, making it suitable for modern Linux desktop environments
- Compatible with Yocto-based root filesystem

## Prerequisites

Ensure the following components are present in the target Yocto build:

- `glmark2-es2-wayland` (Binary Available in /usr/bin) - this test app can be compiled from https://github.com/glmark2/glmark2
- `glmark2` (resouces Available  in /usr/bin) - this data path can be taken from https://github.com/glmark2/glmark2
- Write access to root filesystem (for environment setup)

## Directory Structure

```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Graphics/
│   │   │   ├── GLmark2/
│   │   │   │   ├── run.sh


## Usage

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to the /var directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to the /var directory on the target device.

3. Run Scripts: Navigate to the /var directory on the target device and execute the scripts as needed.

Run a Graphics GLMark2 test using:
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:/var
ssh user@target_device_ip 
cd /var/Runner && ./run-test.sh GLMark2
```
Sample output:
sh-5.2# sh-5.2# cd /var/Runner && ./run-test.sh GLMark2 
[Executing test case: /var/Runner/suites/Multimedia/Graphics/GLMark2] 2025-01-10 01:12:55 -
[INFO] 2025-01-10 01:12:55 - -----------------------------------------------------------------------------------------
[INFO] 2025-01-10 01:12:55 - -------------------Starting GLMark2_Validation Testcase----------------------------
Running onscreen_default...
...
=======================================================
                                  glmark2 Score: 378
=======================================================

EGL updater thread exited

GEM Handle for BO=1 closed
GEM Handle for BO=2 closed
GEM Handle for BO=3 closed
GEM Handle for BO=4 closed
GEM Handle for BO=5 closed
[PASS] onscreen_default score detected.
Running offscreen_default...
.....
=======================================================
                                  glmark2 Score: 381
=======================================================

EGL updater thread exited

[PASS] offscreen_default score detected.
[INFO] 2025-01-10 01:23:21 -
[INFO] 2025-01-10 01:23:21 - === Overall GLMark2 Validation Result ===
[OVERALL PASS] GLMark2 rendering validated.
[PASS] 2025-01-10 01:23:21 - GLMark2_Validation : Test Passed


4. Results will be available in the `/var/Runner/suites/Multimedia/Graphics/GLmark2/results` directory for both onscreen and offscreen tests.

## Notes

- The script takes input like offscreen & onscreen.
- It validates the graphics gles2 functionalities.
- If any critical tool is missing, the script exits with an error message.
- Syslog_log.txt & dmesg_log.txt are useful to debug driver related issue