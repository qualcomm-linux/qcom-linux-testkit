Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

SPDX-License-Identifier: BSD-3-Clause

# KMSCube Graphics Test Scripts
# Overview

Graphics scripts automates the validation of Graphics OpenGL ES 2.0 capabilities on the Qualcomm RB3 Gen2 platform running a Yocto-based Linux system. It utilizes kmscube test app which is publicly available at https://gitlab.freedesktop.org/mesa/kmscube

## Features

- Primarily uses OpenGL ES 2.0, but recent versions include headers for OpenGL ES 3.0 for compatibility
- Uses Kernel Mode Setting (KMS) and Direct Rendering Manager (DRM) to render directly to the screen without a display server
- Designed to be lightweight and minimal, making it ideal for embedded systems and validation environments.
- Can be used to measure GPU performance or validate rendering pipelines in embedded Linux systems

## Prerequisites

Ensure the following components are present in the target image:

- kmscube (Binary Available in /usr/bin) - this test app can be compiled from https://gitlab.freedesktop.org/mesa/kmscube
- modetest from libdrm-tests, optional on CentOS
- Weston should be killed while running KMSCube Test
- Write access to root filesystem (for environment setup)

Yocto uses image-provided components. On Debian, Ubuntu, RHEL, and Fedora, a
missing `modetest` command is recovered through the shared package provider
before display detection. CentOS currently has no verified package providing
`modetest`, so its absence is reported as WARN and connector detection continues
through sysfs. If recovery fails on a distribution where `modetest` is
required, the test reports FAIL.

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

Direct runner usage:

```sh
./run.sh
./run.sh --base
./run.sh --overlay
./run.sh --auto
./run.sh --timeout 90
./run.sh --help
```

Ubuntu Desktop defaults to `--overlay`, so a plain `./run.sh` validates the
Qualcomm KGSL/Adreno stack without requiring an explicit mode argument. Ubuntu
Server is treated as headless and reports SKIP before graphics package or DRM
runtime preparation. Debian, CentOS, RHEL, and Fedora default to `--base`. Use
`--base`, `--overlay`, or `--auto` to override that policy explicitly on
applicable desktop systems. An explicit `--base` request on Ubuntu Desktop
reports SKIP because the supported Ubuntu graphics configuration is the
Qualcomm overlay.

KMSCube execution is bounded to 60 seconds by default. `--timeout SECONDS`
changes that limit. A timeout is reported as FAIL, and display-manager or Weston
state stopped by the suite is restored before exit. `-h` and `--help` print
usage and exit without changing package, GPU, display-manager, or Weston state.
Unknown arguments are reported as FAIL.

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
- A non-zero KMSCube exit status, insufficient rendered frames, or a
  case-insensitive `ERROR`, `FAIL`, `FAILED`, or `FAILURE` marker in the retained
  KMSCube output is classified as FAIL. Common zero-failure summaries such as
  `Failed: 0` and `0 failed` are ignored.
- Output markers are retained in `KMSCube_failure_markers.log` and the complete
  command output remains in `KMSCube_run.log`.

## CentOS Stream 10 overlay preparation

An explicit `./run.sh --overlay` request uses the shared package provider to
ensure EPEL and the Qualcomm CentOS 10 aarch64 and noarch repositories, refresh
DNF metadata, and install the documented Adreno overlay packages:

```text
kgsl-dkms gbm-msm-backend adreno-common adreno-gles1 adreno-gles2 adreno-egl1
```

The `gbm-msm-backend` dependency is tracked explicitly because this suite
validates the Qualcomm GBM backend before running KMSCube. Yocto execution
continues to use image-provided components.

`modetest` remains optional on CentOS because no verified `libdrm-tests`
package is available there. When `kmscube` is absent, the suite requests the
`kmscube` RPM from the configured CentOS repositories. If those repositories
do not publish the package, the suite reports an actionable SKIP asking for
the package to be published or provisioned in the image.

When the requested GPU stack has been installed but the running kernel still
uses the opposite `msm.skip_gpu` policy, the suite reports SKIP with a reboot
requirement. For example, overlay mode with `msm skip_gpu=N` requires a reboot
before KGSL and `/dev/kgsl-3d0` can be validated.
