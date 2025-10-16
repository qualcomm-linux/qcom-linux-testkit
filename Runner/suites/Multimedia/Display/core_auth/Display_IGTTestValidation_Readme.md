# License
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

# IGT Core Auth Test Script

## Overview

This script automates the validation of authentication mechanisms within the IGT Core framework. It performs a series of tests to ensure that the authentication processes are functioning correctly and securely. The script captures detailed logs and provides a summary of the test results.

## Features

- Comprehensive authentication tests
- Environment setup for required dependencies
- Detailed logging of test processes and results
- Color-coded pass/fail summaries
- Output stored in a structured results directory
- Auto-check for required libraries and dependencies
- Compatible with various Linux distributions

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
│   ├    ├    ├── core_auth/
│   ├    ├    ├    ├    └── run.sh
├   ├    ├    ├    ├    └── Display_IGTTestValidation_Readme.md
```

## Usage

1. Copy the script to your target system and make it executable:

```bash
chmod +x run.sh
```

2. Run the script with the path to the core_auth binary:

```bash
./run.sh <core_auth_bin_path>
```

Example:
```bash
./run.sh /usr/libexec/igt-gpu-tools/core_auth
```

3. Logs and test results will be available in the current directory:
   - `core_auth_log.txt` - Detailed test execution log
   - `core_auth.res` - Test result (PASS/FAIL/SKIP)

## Output

- **Console Output**: Real-time display of test execution and results
- **Log File**: `core_auth_log.txt` - Contains detailed output from the core_auth binary
- **Result File**: `core_auth.res` - Contains final test status (PASS/FAIL/SKIP)
- **Test Status Determination**:
  - PASS: Return code 0 or log contains "SUCCESS"
  - SKIP: Log contains "SKIP"
  - FAIL: Any other condition

## Notes

- The script requires one argument: the path to the core_auth binary.
- It validates that the core_auth binary exists and is executable before running tests.
- Weston compositor will be automatically stopped if running, with a 10-second timeout.
- If the core_auth binary is missing or not executable, the script exits with an error.
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
