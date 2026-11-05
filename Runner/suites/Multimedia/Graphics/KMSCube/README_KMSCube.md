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

The following components are required or used by the test:

- kmscube (Binary Available in /usr/bin) - this test app can be compiled from https://gitlab.freedesktop.org/mesa/kmscube
- modetest from libdrm-tests, optional on CentOS
- Weston should be killed while running KMSCube Test
- Write access to root filesystem (for environment setup)

After argument and platform-applicability checks, the runner checks `kmscube`
before graphics package preparation, GPU boot-policy changes or stopping the
display runtime. An executable already in `PATH` is reused. On Debian and
Ubuntu Desktop, a missing command is recovered through `check_dependencies()`
and the existing package provider's `kmscube` mapping. This restores the
installation path removed by commit `414648b` for these distros. Recovery is
the same for base, overlay and auto modes that pass the platform checks.

Package-provider installation and recovery opt-outs remain authoritative.
`CHECK_DEPS_RECOVER=0` disables this application recovery explicitly. If recovery
is disabled or cannot provide the executable, the result is SKIP and graphics
preparation and rendering are not attempted. Retain the package-provider output
to distinguish disabled installation, an unavailable package and installation
failure.

Yocto and other distros retain the image-provided `kmscube`
requirement. Provision the binary in those images, or add an existing
installation directory to `PATH`, then rerun:

```sh
command -v kmscube
./run.sh --overlay --timeout 60
```

For an existing installation outside `PATH` (replace the example directory):

```sh
PATH="/opt/graphics/bin:$PATH" ./run.sh --overlay --timeout 60
```

Use `--base` for an intentionally selected Mesa stack or `--auto` to preserve
the active stack. Ubuntu Desktop retains its overlay-only graphics policy,
and Ubuntu Server skips before application recovery because it is headless.
The finite-frame and continuous-run validation remains unchanged when the
application is present. The graphics-stack and `modetest` preparation policies
below are separate from this application prerequisite.

For Debian/Ubuntu ramdisk validation or any run requiring image-provided tools,
disable recovery explicitly:

```sh
CHECK_DEPS_RECOVER=0 ./run.sh --overlay --timeout 60
```

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
./run.sh --auto --timeout 60 --no-stdbuf
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

The suite detects the capabilities of the installed `kmscube` instead of
assuming one package implementation. A build advertising `--count` runs in the
same process group with `--count=999` and a bounded deadline. The count is
in frames, not seconds, and the default remains unchanged for Yocto. Its exit status and rendered-frame summary are both
validated. Standard builds without `--count`, including the common Debian
package, run continuously under the managed timeout. For those builds, reaching
the timeout is the expected controlled completion, and retained EGL plus OpenGL
initialization output is required for PASS.

`eglinfo` is an optional renderer preflight. When it is absent, the runner
reports WARN and continues with the actual KMSCube rendering validation.
When it is available, the existing CPU/software-renderer gate still applies.

`--timeout SECONDS` sets the execution deadline for **both** builds, defaulting
to 60 seconds. A finite build must finish and report at least `FRAME_COUNT - 1`
frames before that deadline. A finite timeout is FAIL, even when initialization
succeeded. For slower targets, increase the deadline without reducing coverage:

```sh
./run.sh --auto --timeout 120
```

Before terminating an expired run, the runner captures the process status,
kernel wait channel, syscall, kernel stack, memory mappings and file-descriptor
information in `KMSCube_process_state.log`. Kernel and OS metadata are included.
The reader has a two-second deadline and bounded cancellation, which can add up
to six seconds before KMSCube termination begins. Missing procfs entries or
restricted access are recorded without changing the rendering verdict.

A finite timeout remains FAIL even if the reported frame count reached the
minimum. The failure reason includes both the reported count and the threshold,
so completed rendering can be distinguished from a process that did not exit.
On failure, the retained process snapshot is also printed to stdout. Continuous
runs retain the same snapshot at their expected controlled timeout.

After capture, the runner allows two seconds for TERM and two for KILL. If the
child still cannot stop, the test reports FAIL and withholds display restoration
to avoid competing DRM ownership. Inspect the reported PID and retained
`.KMSCube-display-manager.*.state` file before recovering the display runtime.
Otherwise, display-manager or Weston state stopped by the suite is restored
before the final result. Weston restoration first checks socket/service startup
for three seconds, then uses the existing startup fallback and the full
15-second final readiness wait. An intermediate miss is informational. The
fallback outcome and final readiness are reported. Rendering and restoration
failures are both retained in the final FAIL reason, and the EXIT handler does
not silently repeat a restoration already attempted during normal completion.
A failed display-manager restoration retains its state file for diagnosis.
Interrupting the runner also stops its child before
restoration and records FAIL. Help probes have a five-second deadline, and an
expired probe is FAIL rather than being classified as a continuous build.
The existing timeout helper used by other suites is unchanged.

Logs and display-state files are written under the invocation working directory.
Run from the suite directory for the usual artifact paths. If `stdbuf` is
available, output is line-buffered in both modes. Without it, a forcibly stopped
application may leave an incomplete log. `--no-stdbuf` explicitly bypasses that
wrapper for diagnosis, without changing the frame threshold, deadline or result
checks. It has no environment-variable equivalent. A continuous build with
buffered output may fail the initialization-evidence check after termination.
The complete available run log is
printed on failure. `-h` and `--help` print usage and exit without changing
package, GPU, display-manager, or Weston state. Unknown arguments are reported
as FAIL.

### Ubuntu hang diagnosis

Compare buffering on the same prepared graphics stack and connected display.
Run from this suite directory after any requested overlay reboot:

```sh
runner="$(pwd -P)/run.sh"
mkdir -p kmscube-ubuntu-diagnostics/default kmscube-ubuntu-diagnostics/native
git rev-parse HEAD >kmscube-ubuntu-diagnostics/testkit-head.txt
uname -a >kmscube-ubuntu-diagnostics/kernel.txt
command -v kmscube stdbuf >kmscube-ubuntu-diagnostics/commands.txt
(
    cd kmscube-ubuntu-diagnostics/default || exit 1
    "$runner" --overlay --timeout 60 >stdout.log 2>&1
    printf '%s\n' "$?" >exit.status
    cp "$(dirname "$runner")/KMSCube.res" .
)
(
    cd kmscube-ubuntu-diagnostics/native || exit 1
    "$runner" --overlay --timeout 60 --no-stdbuf >stdout.log 2>&1
    printf '%s\n' "$?" >exit.status
    cp "$(dirname "$runner")/KMSCube.res" .
)
```

Retain both directories, including stdout, run logs, process snapshots,
capability output and display-restoration logs. Repeat the pair if the outcomes
differ. A finite run that renders the requested frames but stays alive is still
FAIL. A futex wait identifies a blocked userspace operation, its lock owner
requires a userspace backtrace.

If `gdb` is already available, use a second terminal while the stalled child is
still alive and before its deadline. Identify the PID belonging to this run:

```sh
pgrep -x kmscube
ps -o pid,ppid,stat,wchan,args -C kmscube
```

Then replace `PID` with that PID and save the backtrace in the matching run
directory. Attaching a debugger temporarily pauses the application, so use this
as a separate diagnostic run:

```sh
gdb -q -batch -p PID \
    -ex 'set pagination off' \
    -ex 'thread apply all bt' \
    -ex 'detach' \
    -ex 'quit' >userspace-backtrace.log 2>&1
```

Do not install a debugger just to run the test. The buffering comparison and
automatic process snapshots remain usable when it is unavailable.

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
- A non-zero finite-run exit status, insufficient rendered frames, a missing
  finite-run frame summary, an unexpected continuous-run exit, missing EGL or
  OpenGL initialization evidence, or a case-insensitive `ERROR`, `FAIL`,
  `FAILED`, or `FAILURE` marker in the retained KMSCube output is classified as
  FAIL. Common zero-failure summaries such as `Failed: 0` and `0 failed` are
  ignored.
- Output markers are retained in `KMSCube_failure_markers.log` and the complete
  command output remains in `KMSCube_run.log`.
- Capability-probe output is retained in `KMSCube_capabilities.log`.
- `KMSCube_display_runtime.log` retains Weston process arguments, the discovered
  socket before DRM release and after restoration, startup fallback output and
  the final readiness result. It is also printed to stdout. Restoration uses
  the existing services and generic startup fallback, an arbitrary manually
  launched Weston command is not saved and replayed.
- A direct Weston fallback writes `KMSCube_weston_restore.log` and
  `KMSCube_weston_restore.log.launch` in CWD instead of using a shared `/tmp` log.
- Timeout process evidence is retained in `KMSCube_process_state.log` under the
  invocation directory and printed to stdout for failed runs. A normal finite
  completion leaves this file empty.
- Temporary display-manager state is kept in the invocation working directory
  and removed after restoration, not stored under `/tmp`.

## CentOS Stream 10 base preparation

`./run.sh --base` (also the CentOS default) uses the shared `graphics-base`
mapping: `mesa-libEGL mesa-dri-drivers mesa-libgbm libglvnd-egl libglvnd-gles`.
The mapping is checked before overlay package removal or KGSL boot cleanup.
An unavailable mapping reports FAIL without performing those operations.
The existing package provider verifies the complete set and recovers missing
packages from the configured repositories. Recovery failure reports FAIL.
If overlay removal or boot cleanup changes the system, reboot and rerun after
the reported SKIP. Rendering is validated only when the base runtime is ready.
Yocto continues to use image-provided components.

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
package is available there. Missing `kmscube` is reported by the early
image-prerequisite check, without querying or installing an unverified RPM.
An installed Adreno/GBM stack or passing Weston EGL test does not supply the
`kmscube` application and does not establish KMSCube rendering success.

When the requested GPU stack has been installed but the running kernel still
uses the opposite `msm.skip_gpu` policy, the suite reports SKIP with a reboot
requirement. For example, overlay mode with `msm skip_gpu=N` requires a reboot
before KGSL and `/dev/kgsl-3d0` can be validated.
