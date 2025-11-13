# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

# IGT Core Auth Test Script

## Overview

This script automates the validation of authentication mechanisms within the IGT Core framework. It performs a series of tests to ensure that the authentication processes are functioning correctly and securely. The script captures detailed logs and provides a comprehensive summary of the test results with subtest-level analysis.

## Features

- Comprehensive IGT authentication tests
- Environment setup for required dependencies
- Detailed logging of test processes and results
- Color-coded pass/fail summaries
- Output stored in structured results directory
- Auto-check for required libraries and dependencies
- Compatible with various Linux distributions
- Help system with usage information

## Prerequisites

Ensure the following components are present in the target environment:

- Core authentication binary (core_auth) - must be executable
- Required authentication libraries and dependencies
- Write access to the filesystem (for environment setup and logging)

## Directory Structure
```bash
Runner/
├──suites/
├   ├── Multimedia/
│   ├    ├── Display/
│   ├    ├    ├── igt_gpu_tools/
│   ├    ├    ├    ├── core_auth/
│   ├    ├    ├    ├    ├── run.sh
├   ├    ├    ├    ├    └── Display_IGT_Core_Auth_TestValidation_Readme.md
```

## Usage

1. Copy the script to your target system and make it executable:

```bash
chmod +x run.sh
```

2. Run the script using one of the following methods:

**Method 1: Positional argument**
```bash
./run.sh <core_auth_bin_path>
```

**Method 2: Named argument**
```bash
./run.sh --core-auth-path <core_auth_bin_path>
```

**Method 3: Get help**
```bash
./run.sh --help
./run.sh -h
```

Examples:
```bash
./run.sh /usr/libexec/igt-gpu-tools/core_auth
./run.sh --core-auth-path /usr/libexec/igt-gpu-tools/core_auth
```

3. Logs and test results will be available in the test directory:
   - `core_auth_log.txt` - Detailed test execution log with subtest results
   - `core_auth.res` - Test result (PASS/FAIL/SKIP)

## Output

- **Console Output**: Real-time display of test execution and results with structured logging
- **Log File**: `core_auth_log.txt` - Contains detailed output from the core_auth binary including all subtests
- **Result File**: `core_auth.res` - Contains final test status (PASS/FAIL/SKIP)
- **Subtest Analysis**: Detailed parsing and counting of individual subtest results
- **Test Status Determination**:
  - **FAIL**: Return code ≠ 0 OR any subtest failed (fail_count > 0)
  - **SKIP**: Return code = 0 AND all subtests skipped (skip_count > 0, success_count = 0)
  - **PASS**: Return code = 0 AND no failures (success_count > 0 OR mixed results with no failures)

## Notes

- The script requires the path to the core_auth binary (via positional or named argument).
- Enhanced argument validation includes checking for missing values in named parameters.
- Comprehensive validation ensures the core_auth binary exists and is executable.
- Automatic Weston compositor management using the `weston_stop` function from functestlib.sh.
- Built-in help system provides usage information with improved syntax display.
- Robust error handling with appropriate exit codes and result file generation.
- Test results are determined by both return codes and log content analysis.

## Maintenance

- Ensure the authentication libraries remain compatible with your system.
- Update test cases as per new authentication requirements or updates in the IGT Core framework.

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

- **Run Core_auth testcase**
```bash
./run-test.sh core_auth <core_auth_bin_path>
```

Example:
```bash
./run-test.sh core_auth /usr/libexec/igt-gpu-tools/core_auth
```

## EXAMPLE OUTPUT

[Executing test case: core_auth] 2025-05-31 17:39:52 -
[INFO] 2025-05-31 17:39:52 - -------------------Starting core_auth Testcase-----------------------------
[INFO] 2025-05-31 17:39:52 - Using core_auth binary at: /usr/libexec/igt-gpu-tools/core_auth
[INFO] 2025-05-31 17:39:52 - Weston is not running.
[INFO] 2025-05-31 17:39:52 - Logs written to: /var/qcom-linux-testkit/Runner/suites/Multimedia/Display/core_auth/core_auth_log.txt
[INFO] 2025-05-31 17:39:52 - Subtest Results: SUCCESS=4, FAIL=0, SKIP=0, TOTAL=4
[INFO] 2025-05-31 17:39:52 - results will be written to "./core_auth.res"
[INFO] 2025-05-31 17:39:52 - -------------------Completed core_auth Testcase----------------------------
[PASS] 2025-05-31 17:39:52 - core_auth : Test Passed - All 4 subtest(s) succeeded
[PASS] 2025-05-31 17:39:52 - core_auth passed

[INFO] 2025-05-31 17:39:52 - ========== Test Summary ==========
PASSED:
core_auth

FAILED:
 None

SKIPPED:
 None
[INFO] 2025-05-31 17:39:52 - =================================
