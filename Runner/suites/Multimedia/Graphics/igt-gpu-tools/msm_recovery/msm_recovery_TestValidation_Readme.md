# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# IGT MSM Recovery Test Script

## Overview

This script automates the validation of GPU hang detection and recovery using the IGT `msm_recovery` test. It captures detailed logs and provides a summary of the test results with subtest-level analysis.

## Features

- Runs the IGT `msm_recovery` test with all subtests or a single selected subtest
- GPU ownership check, the test is skipped when KGSL owns the GPU
- Timeout protection for the IGT run
- Detailed logging of test progress and results
- Reports msm/adreno/drm kernel errors raised during the run
- Output stored in the current working directory
- Selects one msm device and passes it to IGT, so execution and diagnostics use the same GPU
- Help system with usage information

## Prerequisites

Ensure the following components are present in the target environment:

- IGT binary (`msm_recovery`) - must be executable, default path `/usr/libexec/igt-gpu-tools/msm_recovery`
- `setsid` (util-linux) - used to stop all IGT processes on timeout or interruption
- Write access to the filesystem (for logging)

## Directory Structure
```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Graphics/
│   │   │   ├── igt-gpu-tools/
│   │   │   │   ├── msm_recovery/
│   │   │   │   │   ├── run.sh
│   │   │   │   │   ├── msm_recovery.yaml
│   │   │   │   │   └── msm_recovery_TestValidation_Readme.md
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
./run.sh --bin-path <msm_recovery_bin_path>
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
./run.sh --bin-path /usr/libexec/igt-gpu-tools/msm_recovery
./run.sh --timeout 900
/usr/libexec/igt-gpu-tools/msm_recovery --list-subtests
```

3. The result file is written to the current working directory (the suite directory when started through `run-test.sh` or LAVA). Logs of each run are kept in a separate `results/msm_recovery/run-<timestamp>.<id>/` directory there:
   - `msm_recovery.res` - Test result (PASS/FAIL/SKIP), in the working directory
   - `msm_recovery_log.txt` - Detailed IGT output with subtest results
   - `dmesg/dmesg_errors.log` - msm/adreno/drm kernel errors raised during the run
   - `dmesg/dmesg_faults.log` - new GPU kernel fault blocks (Oops, BUG, panic) raised during the run

## Output

- **Console Output**: Real-time display of test configuration, execution and results with structured logging
- **Log File**: `msm_recovery_log.txt` - Contains detailed output from the msm_recovery binary including all subtests
- **Result File**: `msm_recovery.res` - Contains final test status (PASS/FAIL/SKIP)
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
- The test deliberately hangs the GPU. `hangcheck` and `gpu fault` kernel messages naming `msm_recovery` are expected.
- Only the `hangcheck` subtest changes the GPU `disable_err_irq` debugfs value. When the selected subtests can run it (all subtests, `hangcheck` or a wildcard), the value of the selected device is saved before the run and restored and verified afterwards, including on timeout and interruption. If the control does not exist, IGT skips `hangcheck` and the other subtests still run. If IGT processes survive cleanup, the saved state is kept for the next run and the result is FAIL.

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

- **Run msm_recovery testcase**
```bash
./run-test.sh msm_recovery
./run-test.sh msm_recovery --bin-path <msm_recovery_bin_path>
```

Example:
```bash
./run-test.sh msm_recovery --bin-path /usr/libexec/igt-gpu-tools/msm_recovery
```

## EXAMPLE OUTPUT

```text
[Executing test case: msm_recovery] 2026-11-24 16:50:50 -
[INFO] 2026-11-24 16:50:50 - --------------------------------------------------------------------------
[INFO] 2026-11-24 16:50:50 - ------------------- Starting msm_recovery Testcase --------------------------
[INFO] 2026-11-24 16:50:50 - Detected OS, qcom-distro
[INFO] 2026-11-24 16:50:50 - Kernel, 7.3.0-rc2-ge428097a36d2
[INFO] 2026-11-24 16:50:50 - GPU boot mode, msm
[INFO] 2026-11-24 16:50:50 - Config, BIN=/usr/libexec/igt-gpu-tools/msm_recovery SUBTEST=all TIMEOUT=600s
[INFO] 2026-11-24 16:50:50 - Evidence, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_recovery/results/msm_recovery/run-<timestamp>.<id>
[INFO] 2026-11-24 16:50:50 - GPU error-interrupt state saved, /sys/kernel/debug/dri/0/disable_err_irq=N
[INFO] 2026-11-24 16:50:50 - Using IGT binary, /usr/libexec/igt-gpu-tools/msm_recovery
[INFO] 2026-11-24 16:50:50 - Launching /usr/libexec/igt-gpu-tools/msm_recovery with timeout 600s
[INFO] 2026-11-24 16:51:12 - IGT version, 2.6-2.6 (aarch64) (Linux: 7.3.0-rc2-ge428097a36d2 aarch64)
[INFO] 2026-11-24 16:51:12 - IGT log, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_recovery/results/msm_recovery/run-<timestamp>.<id>/msm_recovery_log.txt
[WARN] 2026-11-24 16:51:13 - Kernel errors raised during msm_recovery, count=128 (capped at 20 lines), /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_recovery/results/msm_recovery/run-<timestamp>.<id>/dmesg/dmesg_errors.log
[WARN] 2026-11-24 16:51:13 - [dmesg] [  701.815186] msm_dpu ae01000.display-controller: [drm:hangcheck_handler [msm]] *ERROR* 06020300: hangcheck detected gpu lockup rb 0!
[WARN] 2026-11-24 16:51:14 - [dmesg] [  701.827653] msm_dpu ae01000.display-controller: [drm:recover_worker [msm]] *ERROR* 06020300: hangcheck recover!
...
[INFO] 2026-11-24 16:51:14 - Subtest results, SUCCESS=5 FAIL=0 SKIP=0 TOTAL=5 rc=0
[INFO] 2026-11-24 16:51:14 - ------------------- Completed msm_recovery Testcase -------------------------
[INFO] 2026-11-24 16:51:14 - GPU error-interrupt state restored, /sys/kernel/debug/dri/0/disable_err_irq=N
[PASS] 2026-11-24 16:51:14 - msm_recovery PASS - 5 subtest(s) passed, 0 skipped
[PASS] 2026-11-24 16:51:15 - msm_recovery passed

[INFO] 2026-11-24 16:51:15 - ========== Test Summary ==========
PASSED:
msm_recovery

FAILED:
 None

SKIPPED:
 None
[INFO] 2026-11-24 16:51:15 - ==================================
```
