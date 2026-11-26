# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# IGT MSM Perfcntrs Test Script

## Overview

This script automates the validation of msm GPU performance counter configuration and allocation (group discovery, reservation and conflict handling; counter samples are not read) using the IGT `msm_perfcntrs` test. It captures detailed logs and provides a summary of the test results with subtest-level analysis.

## Features

- Runs the IGT `msm_perfcntrs` test with all subtests or a single selected subtest
- GPU ownership check, the test is skipped when KGSL owns the GPU
- Timeout protection for the IGT run
- Detailed logging of test progress and results
- Reports msm/adreno/drm kernel errors raised during the run
- Output stored in the current working directory
- Selects one msm device and passes it to IGT, so execution and diagnostics use the same GPU
- Help system with usage information

## Prerequisites

Ensure the following components are present in the target environment:

- IGT binary (`msm_perfcntrs`) - must be executable, default path `/usr/libexec/igt-gpu-tools/msm_perfcntrs`
- `setsid` (util-linux) - used to stop all IGT processes on timeout or interruption
- Write access to the filesystem (for logging)

## Directory Structure
```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Graphics/
│   │   │   ├── igt-gpu-tools/
│   │   │   │   ├── msm_perfcntrs/
│   │   │   │   │   ├── run.sh
│   │   │   │   │   ├── msm_perfcntrs.yaml
│   │   │   │   │   └── msm_perfcntrs_TestValidation_Readme.md
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
./run.sh --bin-path <msm_perfcntrs_bin_path>
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
./run.sh --bin-path /usr/libexec/igt-gpu-tools/msm_perfcntrs
./run.sh --timeout 600
/usr/libexec/igt-gpu-tools/msm_perfcntrs --list-subtests
```

3. The result file is written to the current working directory (the suite directory when started through `run-test.sh` or LAVA). Logs of each run are kept in a separate `results/msm_perfcntrs/run-<timestamp>.<id>/` directory there:
   - `msm_perfcntrs.res` - Test result (PASS/FAIL/SKIP), in the working directory
   - `msm_perfcntrs_log.txt` - Detailed IGT output with subtest results
   - `dmesg/dmesg_errors.log` - msm/adreno/drm kernel errors raised during the run
   - `dmesg/dmesg_faults.log` - new GPU kernel fault blocks (Oops, BUG, panic) raised during the run

## Output

- **Console Output**: Real-time display of test configuration, execution and results with structured logging
- **Log File**: `msm_perfcntrs_log.txt` - Contains detailed output from the msm_perfcntrs binary including all subtests
- **Result File**: `msm_perfcntrs.res` - Contains final test status (PASS/FAIL/SKIP)
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

- **Run msm_perfcntrs testcase**
```bash
./run-test.sh msm_perfcntrs
./run-test.sh msm_perfcntrs --bin-path <msm_perfcntrs_bin_path>
```

Example:
```bash
./run-test.sh msm_perfcntrs --bin-path /usr/libexec/igt-gpu-tools/msm_perfcntrs
```

## EXAMPLE OUTPUT

```text
[Executing test case: msm_perfcntrs] 2026-11-19 05:36:15 -
[INFO] 2026-11-19 05:36:15 - --------------------------------------------------------------------------
[INFO] 2026-11-19 05:36:15 - ------------------- Starting msm_perfcntrs Testcase --------------------------
[INFO] 2026-11-19 05:36:15 - Detected OS, qcom-distro-catchall
[INFO] 2026-11-19 05:36:15 - Kernel, 7.3.0-g17bbb4b37bbc
[INFO] 2026-11-19 05:36:15 - GPU boot mode, msm
[INFO] 2026-11-19 05:36:15 - Config, BIN=/usr/libexec/igt-gpu-tools/msm_perfcntrs SUBTEST=all TIMEOUT=300s
[INFO] 2026-11-19 05:36:15 - Evidence, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_perfcntrs/results/msm_perfcntrs/run-<timestamp>.<id>
[INFO] 2026-11-19 05:36:15 - Using IGT binary, /usr/libexec/igt-gpu-tools/msm_perfcntrs
[INFO] 2026-11-19 05:36:15 - Launching /usr/libexec/igt-gpu-tools/msm_perfcntrs with timeout 300s
[INFO] 2026-11-19 05:36:16 - IGT version, 2.6-2.6 (aarch64) (Linux: 7.3.0-g17bbb4b37bbc aarch64)
[INFO] 2026-11-19 05:36:16 - IGT log, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_perfcntrs/results/msm_perfcntrs/run-<timestamp>.<id>/msm_perfcntrs_log.txt
[INFO] 2026-11-19 05:36:16 - No new msm/adreno/drm kernel errors
[INFO] 2026-11-19 05:36:16 - Subtest results, SUCCESS=6 FAIL=0 SKIP=0 TOTAL=6 rc=0
[INFO] 2026-11-19 05:36:17 - ------------------- Completed msm_perfcntrs Testcase -------------------------
[PASS] 2026-11-19 05:36:17 - msm_perfcntrs PASS - 6 subtest(s) passed, 0 skipped
[PASS] 2026-11-19 05:36:17 - msm_perfcntrs passed

[INFO] 2026-11-19 05:36:17 - ========== Test Summary ==========
PASSED:
msm_perfcntrs

FAILED:
 None

SKIPPED:
 None
[INFO] 2026-11-19 05:36:17 - ==================================
```
