# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# IGT MSM BO Test Script

## Overview

This script automates the validation of msm GEM buffer object ioctls (allocation and cache modes, offset/IOVA/flags queries, madvise and free, including invalid arguments) using the IGT `msm_bo` test. It captures detailed logs and provides a summary of the test results with subtest-level analysis.

## Features

- Runs the IGT `msm_bo` test with all subtests or a single selected subtest
- GPU ownership check, the test is skipped when KGSL owns the GPU
- Timeout protection for the IGT run
- Detailed logging of test progress and results
- Reports msm/adreno/drm kernel errors raised during the run
- Output stored in the current working directory
- Selects one msm device and passes it to IGT, so execution and diagnostics use the same GPU
- Help system with usage information

## Prerequisites

Ensure the following components are present in the target environment:

- IGT binary (`msm_bo`) - must be executable, default path `/usr/libexec/igt-gpu-tools/msm_bo`
- `setsid` (util-linux) - used to stop all IGT processes on timeout or interruption
- Write access to the filesystem (for logging)

## Directory Structure
```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Graphics/
│   │   │   ├── igt-gpu-tools/
│   │   │   │   ├── msm_bo/
│   │   │   │   │   ├── run.sh
│   │   │   │   │   ├── msm_bo.yaml
│   │   │   │   │   └── msm_bo_TestValidation_Readme.md
├── utils/
│   └── lib_igt.sh
```

## Usage

1. Copy the script to your target system and make it executable:

```bash
chmod +x run.sh
```

2. Run the script using one of the following methods:

**Method 1: Default binary path**
```bash
./run.sh
```

**Method 2: Custom binary path**
```bash
./run.sh --bin-path <msm_bo_bin_path>
```

**Method 3: Single subtest**
```bash
./run.sh --subtest <subtest_name>
```

**Method 4: Custom timeout**
```bash
./run.sh --timeout <seconds>
```

**Method 5: Get help**
```bash
./run.sh --help
./run.sh -h
```

Examples:
```bash
./run.sh --bin-path /usr/libexec/igt-gpu-tools/msm_bo
./run.sh --timeout 600
/usr/libexec/igt-gpu-tools/msm_bo --list-subtests
```

3. The result file is written to the current working directory (the suite directory when started through `run-test.sh` or LAVA). Logs of each run are kept in a separate `results/msm_bo/run-<timestamp>.<id>/` directory there:
   - `msm_bo.res` - Test result (PASS/FAIL/SKIP), in the working directory
   - `msm_bo_log.txt` - Detailed IGT output with subtest results
   - `dmesg/dmesg_errors.log` - msm/adreno/drm kernel errors raised during the run
   - `dmesg/dmesg_faults.log` - new GPU kernel fault blocks (Oops, BUG, panic) raised during the run

## Output

- **Console Output**: Real-time display of test configuration, execution and results with structured logging
- **Log File**: `msm_bo_log.txt` - Contains detailed output from the msm_bo binary including all subtests
- **Result File**: `msm_bo.res` - Contains final test status (PASS/FAIL/SKIP)
- **Kernel Log**: `dmesg/dmesg_errors.log` - Kernel errors raised during the run, reported as warnings only
- **Kernel Faults**: `dmesg/dmesg_faults.log` - New GPU kernel fault blocks raised during the run, reported as FAIL
- **Subtest Analysis**: Parsing and counting of individual subtest results, failed and skipped subtests are listed
- **Test Status Determination**:
  - **FAIL**: Timeout, IGT processes not stopped after cleanup, IGT opened a device other than the selected one, any subtest FAIL/CRASH/TIMEOUT, new GPU kernel fault block, return code other than 0 or 77, invalid argument, or binary name not matching the testcase
  - **SKIP**: Binary not found, KGSL owns the GPU, no msm DRM render node, `setsid` not available, return code 77, or all subtests skipped
  - **PASS**: Return code 0 AND no failures (success_count > 0 OR mixed results with no failures)

## Notes

- The default timeout is 300 seconds, it can also be set with the `IGT_TIMEOUT` environment variable.
- Exit code 77 indicates a SKIP condition (standard IGT behavior).
- Subtest coverage depends on the installed IGT build. List the available subtests with `msm_bo --list-subtests`.

  | IGT version | msm_bo subtests | Coverage |
  |---|---|---|
  | v2.6 and earlier | 16 | Allocation and info queries |
  | Upstream master from commit `a946c7a25` (2026-11-03), expected in IGT v2.7 | 51 | Adds `bo-alloc-cached-coherent`, `bo-madvise-*`, `bo-map-*` (mmap and CPU write/read consistency) and `bo-free-*` |

  The new subtests were added upstream by the series `8179dd770`..`a946c7a25` (tests/msm/msm_bo). Yocto images built with the IGT v2.6 recipe (SRCREV `916c79cf`) run the 16-subtest set.
- The msm device is `IGT_DEVICE` when it is a `drm:/dev/dri/<node>` filter, otherwise the first msm render node. It is passed to IGT with `--device`, which takes precedence over `.igtrc`. Other `IGT_DEVICE` filters report FAIL.
- When the kernel log or its comparison is unavailable, a warning is printed and the result is based on the IGT output only.
- Kernel errors are printed on the console capped at 20 lines, the complete list is kept in `dmesg/dmesg_errors.log`.
- Only new GPU kernel fault blocks (Oops, BUG, panic) make the test FAIL, expected `*ERROR*` lines stay warnings.
- On failure the last 200 lines of the IGT log are printed on the console.

## Maintenance

- Keep the IGT binary version compatible with the kernel msm driver.
- Update the test when IGT adds or removes msm subtests.

## Run test using:
```bash
git clone <this-repo>
cd <this-repo>
scp -r Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
```

- **Using Unified Runner**
```bash
cd <Path in device>/Runner
```

- **Run msm_bo testcase**
```bash
./run-test.sh msm_bo
./run-test.sh msm_bo --bin-path <msm_bo_bin_path>
```

Example:
```bash
./run-test.sh msm_bo --bin-path /usr/libexec/igt-gpu-tools/msm_bo
```

## EXAMPLE OUTPUT

```text
[Executing test case: msm_bo] 2026-11-19 05:35:31 -
[INFO] 2026-11-19 05:35:31 - --------------------------------------------------------------------------
[INFO] 2026-11-19 05:35:31 - ------------------- Starting msm_bo Testcase --------------------------
[INFO] 2026-11-19 05:35:31 - Detected OS, qcom-distro-catchall
[INFO] 2026-11-19 05:35:31 - Kernel, 7.3.0-g17bbb4b37bbc
[INFO] 2026-11-19 05:35:31 - GPU boot mode, msm
[INFO] 2026-11-19 05:35:31 - Config, BIN=/usr/libexec/igt-gpu-tools/msm_bo SUBTEST=all TIMEOUT=300s
[INFO] 2026-11-19 05:35:31 - Evidence, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_bo/results/msm_bo/run-<timestamp>.<id>
[INFO] 2026-11-19 05:35:31 - Using IGT binary, /usr/libexec/igt-gpu-tools/msm_bo
[INFO] 2026-11-19 05:35:31 - Launching /usr/libexec/igt-gpu-tools/msm_bo with timeout 300s
[INFO] 2026-11-19 05:35:32 - IGT version, 2.6-2.6 (aarch64) (Linux: 7.3.0-g17bbb4b37bbc aarch64)
[INFO] 2026-11-19 05:35:32 - IGT log, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_bo/results/msm_bo/run-<timestamp>.<id>/msm_bo_log.txt
[WARN] 2026-11-19 05:35:32 - Kernel errors raised during msm_bo, count=1 (capped at 20 lines), /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_bo/results/msm_bo/run-<timestamp>.<id>/dmesg/dmesg_errors.log
[WARN] 2026-11-19 05:35:32 - [dmesg] [ 2339.727321] [drm:msm_ioctl_gem_new [msm]] *ERROR* invalid flags: 02000000
[INFO] 2026-11-19 05:35:32 - Subtest results, SUCCESS=51 FAIL=0 SKIP=0 TOTAL=51 rc=0
[INFO] 2026-11-19 05:35:32 - ------------------- Completed msm_bo Testcase -------------------------
[PASS] 2026-11-19 05:35:32 - msm_bo PASS - 51 subtest(s) passed, 0 skipped
[PASS] 2026-11-19 05:35:32 - msm_bo passed

[INFO] 2026-11-19 05:35:32 - ========== Test Summary ==========
PASSED:
msm_bo

FAILED:
 None

SKIPPED:
 None
[INFO] 2026-11-19 05:35:32 - ==================================
```
