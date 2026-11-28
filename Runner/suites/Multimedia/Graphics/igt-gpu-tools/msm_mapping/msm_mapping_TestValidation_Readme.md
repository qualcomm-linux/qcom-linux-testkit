# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# IGT MSM Mapping Test Script

## Overview

This script automates the validation of GPU address-space mappings and IOMMU fault handling using the IGT `msm_mapping` test. It captures detailed logs and provides a summary of the test results with subtest-level analysis.

## Features

- Runs the IGT `msm_mapping` test with all subtests or a single selected subtest
- GPU ownership check, the test is skipped when KGSL owns the GPU
- Timeout protection for the IGT run
- Detailed logging of test progress and results
- Reports msm/adreno/drm kernel errors raised during the run
- Output stored in the current working directory
- Selects one msm device and passes it to IGT, so execution and diagnostics use the same GPU
- Help system with usage information

## Prerequisites

Ensure the following components are present in the target environment:

- IGT binary (`msm_mapping`) - must be executable, default path `/usr/libexec/igt-gpu-tools/msm_mapping`
- `setsid` (util-linux) - used to stop all IGT processes on timeout or interruption
- Write access to the filesystem (for logging)

## Directory Structure
```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── Graphics/
│   │   │   ├── igt-gpu-tools/
│   │   │   │   ├── msm_mapping/
│   │   │   │   │   ├── run.sh
│   │   │   │   │   ├── msm_mapping.yaml
│   │   │   │   │   └── msm_mapping_TestValidation_Readme.md
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
./run.sh --bin-path <msm_mapping_bin_path>
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
./run.sh --bin-path /usr/libexec/igt-gpu-tools/msm_mapping
./run.sh --timeout 600
/usr/libexec/igt-gpu-tools/msm_mapping --list-subtests
```

3. The result file is written to the current working directory (the suite directory when started through `run-test.sh` or LAVA). Logs of each run are kept in a separate `results/msm_mapping/run-<timestamp>.<id>/` directory there:
   - `msm_mapping.res` - Test result (PASS/FAIL/SKIP), in the working directory
   - `msm_mapping_log.txt` - Detailed IGT output with subtest results
   - `dmesg/dmesg_errors.log` - msm/adreno/drm kernel errors raised during the run
   - `dmesg/dmesg_faults.log` - new GPU kernel fault blocks (Oops, BUG, panic) raised during the run

## Output

- **Console Output**: Real-time display of test configuration, execution and results with structured logging
- **Log File**: `msm_mapping_log.txt` - Contains detailed output from the msm_mapping binary including all subtests
- **Result File**: `msm_mapping.res` - Contains final test status (PASS/FAIL/SKIP)
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
- The test deliberately triggers GPU faults. `gpu fault` and `hangcheck recover!` kernel messages naming `msm_mapping` are expected.

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

- **Run msm_mapping testcase**
```bash
./run-test.sh msm_mapping
./run-test.sh msm_mapping --bin-path <msm_mapping_bin_path>
```

Example:
```bash
./run-test.sh msm_mapping --bin-path /usr/libexec/igt-gpu-tools/msm_mapping
```

## EXAMPLE OUTPUT

```text
[Executing test case: msm_mapping] 2026-11-19 05:35:55 -
[INFO] 2026-11-19 05:35:55 - --------------------------------------------------------------------------
[INFO] 2026-11-19 05:35:55 - ------------------- Starting msm_mapping Testcase --------------------------
[INFO] 2026-11-19 05:35:55 - Detected OS, qcom-distro-catchall
[INFO] 2026-11-19 05:35:55 - Kernel, 7.3.0-g17bbb4b37bbc
[INFO] 2026-11-19 05:35:55 - GPU boot mode, msm
[INFO] 2026-11-19 05:35:55 - Config, BIN=/usr/libexec/igt-gpu-tools/msm_mapping SUBTEST=all TIMEOUT=300s
[INFO] 2026-11-19 05:35:55 - Evidence, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_mapping/results/msm_mapping/run-<timestamp>.<id>
[INFO] 2026-11-19 05:35:55 - Using IGT binary, /usr/libexec/igt-gpu-tools/msm_mapping
[INFO] 2026-11-19 05:35:55 - Launching /usr/libexec/igt-gpu-tools/msm_mapping with timeout 300s
[INFO] 2026-11-19 05:36:01 - IGT version, 2.6-2.6 (aarch64) (Linux: 7.3.0-g17bbb4b37bbc aarch64)
[INFO] 2026-11-19 05:36:01 - IGT log, /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_mapping/results/msm_mapping/run-<timestamp>.<id>/msm_mapping_log.txt
[WARN] 2026-11-19 05:36:01 - Kernel errors raised during msm_mapping, count=24 (capped at 20 lines), /var/qcom-linux-testkit/Runner/suites/Multimedia/Graphics/igt-gpu-tools/msm_mapping/results/msm_mapping/run-<timestamp>.<id>/dmesg/dmesg_errors.log
[WARN] 2026-11-19 05:36:01 - [dmesg] [ 2363.822876] adreno 5900000.gpu: [drm:a6xx_irq [msm]] *ERROR* gpu fault ring 0 fence 300d9f status 00800005 rb 0035/0044 ib1 0000000100000000/0000 ib2 0000000000000000/0000
[WARN] 2026-11-19 05:36:01 - [dmesg] [ 2363.823471] msm_dpu 5e01000.display-controller: [drm:recover_worker [msm]] *ERROR* 07000400: hangcheck recover!
...
[INFO] 2026-11-19 05:36:01 - Subtest results, SUCCESS=5 FAIL=0 SKIP=2 TOTAL=7 rc=0
[SKIP] 2026-11-19 05:36:02 - Subtest preempt_record_ring0: SKIP (0.103s)
[SKIP] 2026-11-19 05:36:02 - Subtest preempt_smmu_info_ring0: SKIP (0.102s)
[INFO] 2026-11-19 05:36:02 - ------------------- Completed msm_mapping Testcase -------------------------
[PASS] 2026-11-19 05:36:02 - msm_mapping PASS - 5 subtest(s) passed, 2 skipped
[PASS] 2026-11-19 05:36:02 - msm_mapping passed

[INFO] 2026-11-19 05:36:02 - ========== Test Summary ==========
PASSED:
msm_mapping

FAILED:
 None

SKIPPED:
 None
[INFO] 2026-11-19 05:36:02 - ==================================
```
