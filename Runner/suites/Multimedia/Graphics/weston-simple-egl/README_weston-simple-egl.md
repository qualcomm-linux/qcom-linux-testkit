Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

SPDX-License-Identifier: BSD-3-Clause

# weston-simple-egl Graphics Test

# Overview

This suite validates OpenGL ES 2.0 through the `weston-simple-egl` Wayland client on Qualcomm Linux platforms. It supports image-provided Weston on Yocto and active desktop Wayland sessions on Debian-family distributions.

## Features

- Wayland Client Integration , Uses wl_compositor, wl_shell, wl_seat, and wl_shm interfaces
- OpenGL ES 2.0 Rendering
- EGL Context Initialization

## Prerequisites

Yocto images must provide the required client and Weston runtime. Debian and Ubuntu recover Weston from `weston`. CentOS recovers the compositor from `weston`, the example clients from `weston-demo`, the DRM seat provider from `seatd`, and `/usr/bin/eglinfo` from `egl-utils`. Overlay mode first accepts a complete image-provided Qualcomm EGL, GBM, and KGSL runtime. When graphics recovery is needed, it uses the distro-specific package family and repository policy.

- `weston-simple-egl` (Binary Available in /usr/bin) be default
- Write access to root filesystem (for environment setup)

## Desktop distribution modes

- Ubuntu Desktop defaults to `--overlay`, so a plain `./run.sh` validates the
  Qualcomm KGSL/Adreno stack without requiring an explicit mode argument.
- Ubuntu Server is treated as headless and reports SKIP before graphics package
  or display-runtime preparation. Run the suite on Ubuntu Desktop to validate
  graphics.
- An explicit `--base` request on Ubuntu Desktop reports SKIP because the
  supported Ubuntu graphics configuration is the Qualcomm overlay.
- Debian, CentOS, RHEL, and Fedora default to `--base` for compatibility with
  their selectable base and overlay package flows.
- `./run.sh --base` selects the upstream MSM/freedreno stack and ensures the OS-specific Mesa package set.
- `./run.sh --overlay` selects the Qualcomm KGSL/Adreno stack. A ready runtime is reused without package changes. Otherwise, the focused EGL/GLES package set is recovered and DKMS changes can require a reboot before validation continues.
- Debian uses the `adreno-*` packages from `qli-staging`. Ubuntu uses the `qcom-adreno-*` packages and existing image APT sources, never Debian `qli` or `qli-staging`. CentOS uses the `adreno-*` RPMs from the configured Qualcomm RPM repositories.
- The MSM GBM package is resolved from the distro package map: `libgbm-msm1` on Debian, `libgbm-msm` on Ubuntu, and `gbm-msm-backend` on CentOS. Set `GPU_OVERLAY_GBM_PACKAGE` only when an explicit override is required.
- Desktop automatic mode runs `weston-simple-egl -b` when the client advertises that option. This is an unsynchronized EGL throughput benchmark with a minimum functional FPS gate, not a display-refresh measurement.
- Yocto, other image-based runs, and `--strict-refresh-fps` keep the compositor-synchronized client mode. FPS evidence remains required by default. Use `--no-require-fps` only when connectivity and EGL execution are the intended coverage.
- On Ubuntu, the test reuses an active GNOME Wayland session when Weston is not running. A root-launched test executes the client as the Wayland socket owner without stopping or restarting GDM.
- On desktop distributions without a packaged `weston.service`, `--allow-relaunch` starts Weston directly on the dynamically selected DRM device and validates the resulting Wayland socket before launching the client. On CentOS, the shared runtime preparation starts the packaged `seatd.service` when needed. It does not enable the service persistently.
- GDM can throttle an unfocused greeter client. That path validates compositor connectivity and EGL startup while recording, but not performance-gating, any FPS samples.

Examples:

```sh
./run.sh --base
./run.sh --overlay
./run.sh --auto
```

On CentOS, `./run.sh --base --allow-relaunch` verifies the Mesa RPM set
`mesa-libEGL mesa-dri-drivers mesa-libgbm libglvnd-egl libglvnd-gles` through
the shared package provider, with full-set recovery when needed. The mapping
is checked before overlay package removal or KGSL boot cleanup. A missing
mapping or failed recovery reports FAIL. Changes to overlay packages or boot
artifacts report SKIP requiring a reboot before rerunning. Once ready, the
existing Weston and EGL client validation proceeds. Ubuntu mode restrictions
and Yocto image-provided execution are unchanged.

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
