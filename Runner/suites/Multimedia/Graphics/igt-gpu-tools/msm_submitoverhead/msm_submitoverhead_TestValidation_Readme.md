# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# IGT MSM Submit Overhead Test Script

## Overview

This script automates the validation of msm submit ioctl overhead using the IGT `msm_submitoverhead` test. It captures detailed logs and provides a summary of the test results with subtest-level analysis.

## Features

- Runs the IGT `msm_submitoverhead` test with all subtests or a single selected subtest
- GPU ownership check, the test is skipped when KGSL owns the GPU
- Timeout protection for the IGT run
- Detailed logging of test progress and results
- Reports msm/adreno/drm kernel errors raised during the run
- Output stored in the current working directory
- Selects one msm device and passes it to IGT, so execution and diagnostics use the same GPU
- Help system with usage information

## Prerequisites

Ensure the following components are present in the target environment:

- IGT binary (`msm_submitoverhead`) - must be executable, default path `/usr/libexec/igt-gpu-tools/msm_submitoverhead`
- `setsid` (util-linux) - used to stop all IGT processes on timeout or interruption
- Write access to the filesystem (for logging)

## Directory Structure
```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Graphics/
│   │   │   ├── igt-gpu-tools/
│   │   │   │   ├── msm_submitoverhead/
│   │   │   │   │   ├── run.sh
│   │   │   │   │   ├── msm_submitoverhead.yaml
│   │   │   │   │   └── msm_submitoverhead_TestValidation_Readme.md
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
./run.sh --bin-path <msm_submitoverhead_bin_path>
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
./run.sh --bin-path /usr/libexec/igt-gpu-tools/msm_submitoverhead
./run.sh --timeout 900
/usr/libexec/igt-gpu-tools/msm_submitoverhead --list-subtests
```

3. The result file is written to the current working directory (the suite directory when started through `run-test.sh` or LAVA). Logs of each run are kept in a separate `results/msm_submitoverhead/run-<timestamp>.<id>/` directory there:
   - `msm_submitoverhead.res` - Test result (PASS/FAIL/SKIP), in the working directory
   - `msm_submitoverhead_log.txt` - Detailed IGT output with subtest results
   - `dmesg/dmesg_errors.log` - msm/adreno/drm kernel errors raised during the run
   - `dmesg/dmesg_faults.log` - new GPU kernel fault blocks (Oops, BUG, panic) raised during the run

## Output

- **Console Output**: Real-time display of test configuration, execution and results with structured logging
- **Log File**: `msm_submitoverhead_log.txt` - Contains detailed output from the msm_submitoverhead binary including all subtests
- **Result File**: `msm_submitoverhead.res` - Contains final test status (PASS/FAIL/SKIP)
- **Kernel Log**: `dmesg/dmesg_errors.log` - Kernel errors raised during the run, reported as warnings only
- **Kernel Faults**: `dmesg/dmesg_faults.log` - New GPU kernel fault blocks raised during the run, reported as FAIL
- **Subtest Analysis**: Parsing and counting of individual subtest results, failed and skipped subtests are listed
- **Test Status Determination**:
  - **FAIL**: Timeout, IGT processes not stopped after cleanup, IGT opened a device other than the selected one, any subtest FAIL/CRASH/TIMEOUT, new GPU kernel fault block, return code other than 0 or 77, invalid argument, or binary name not matching the testcase
  - **SKIP**: Binary not found, KGSL owns the GPU, no msm DRM render node, `setsid` not available, return code 77, or all subtests skipped
  - **PASS**: Return code 0 AND no failures (success_count > 0 OR mixed results with no failures)

## Notes

- The default timeout is 600 seconds, it can also be set with the `IGT_TIMEOUT` environment variable.
- Exit code 77 indicates a SKIP condition (standard IGT behavior).
- The msm device is `IGT_DEVICE` when it is a `drm:/dev/dri/<node>` filter, otherwise the first msm render node. It is passed to IGT with `--device`, which takes precedence over `.igtrc`. Other `IGT_DEVICE` filters report FAIL.
- When the kernel log or its comparison is unavailable, a warning is printed and the result is based on the IGT output only.
- Kernel errors are printed on the console capped at 20 lines, the complete list is kept in `dmesg/dmesg_errors.log`.
- Only new GPU kernel fault blocks (Oops, BUG, panic) make the test FAIL, expected `*ERROR*` lines stay warnings.
- On failure the last 200 lines of the IGT log are printed on the console.
- This is a performance measurement. The result reflects whether the subtests ran, not a performance threshold.

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

- **Run msm_submitoverhead testcase**
```bash
./run-test.sh msm_submitoverhead
./run-test.sh msm_submitoverhead --bin-path <msm_submitoverhead_bin_path>
```

Example:
```bash
./run-test.sh msm_submitoverhead --bin-path /usr/libexec/igt-gpu-tools/msm_submitoverhead
```

## EXAMPLE OUTPUT

```text
[Executing test case: msm_submitoverhead] 1970-01-01 04:37:56 -
[INFO] 1970-01-01 04:37:57 - --------------------------------------------------------------------------
[INFO] 1970-01-01 04:37:57 - ------------------- Starting msm_submitoverhead Testcase --------------------------
[INFO] 1970-01-01 04:37:57 - Detected OS, qcom-distro
[INFO] 1970-01-01 04:37:57 - Kernel, 7.3.0-rc2-ge428097a36d2
[INFO] 1970-01-01 04:37:57 - GPU boot mode, msm
[INFO] 1970-01-01 04:37:57 - Config, BIN=/usr/libexec/igt-gpu-tools/msm_submitoverhead SUBTEST=all TIMEOUT=600s
[INFO] 1970-01-01 04:37:57 - Evidence, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_submitoverhead/results/msm_submitoverhead/run-<timestamp>.<id>
[INFO] 1970-01-01 04:37:57 - Using IGT binary, /usr/libexec/igt-gpu-tools/msm_submitoverhead
[INFO] 1970-01-01 04:37:57 - Launching /usr/libexec/igt-gpu-tools/msm_submitoverhead with timeout 600s
[INFO] 1970-01-01 04:38:20 - IGT version, 2.6-2.6 (aarch64) (Linux: 7.3.0-rc2-ge428097a36d2 aarch64)
[INFO] 1970-01-01 04:38:20 - IGT log, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_submitoverhead/results/msm_submitoverhead/run-<timestamp>.<id>/msm_submitoverhead_log.txt
[INFO] 1970-01-01 04:38:21 - No new msm/adreno/drm kernel errors
[INFO] 1970-01-01 04:38:21 - Subtest results, SUCCESS=10 FAIL=0 SKIP=0 TOTAL=10 rc=0
[INFO] 1970-01-01 04:38:21 - ------------------- Completed msm_submitoverhead Testcase -------------------------
[PASS] 1970-01-01 04:38:21 - msm_submitoverhead PASS - 10 subtest(s) passed, 0 skipped
[PASS] 1970-01-01 04:38:21 - msm_submitoverhead passed

[INFO] 1970-01-01 04:38:21 - ========== Test Summary ==========
PASSED:
msm_submitoverhead

FAILED:
 None

SKIPPED:
 None
[INFO] 1970-01-01 04:38:21 - ==================================
```
