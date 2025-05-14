Sure, here is a README for the IGT Core Auth Test:

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

- Required authentication libraries and dependencies
- Write access to the filesystem (for environment setup and logging)

## Directory Structure

```bash
results/
├── igt_core_auth/
│   ├── auth_test_<test>.txt
│   ├── dmesg_log.txt
│   └── syslog_log.txt
```

## Usage

1. Copy the script to your target system and make it executable:

```bash
chmod +x igt_core_auth_test.sh
```

2. Run the script:

```bash
./igt_core_auth_test.sh
```

3. Logs and test results will be available in the `results/igt_core_auth` directory.

## Output

- **Test Logs**: Stored in individual files for each test variant.
- **Kernel Logs**: Captured via `dmesg` and `syslog`.
- **Validation Result**: Printed to console and saved in a results file with PASS/FAIL status.

## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.

## Maintenance

- Ensure the authentication libraries remain compatible with your system.
- Update test cases as per new authentication requirements or updates in the IGT Core framework.

