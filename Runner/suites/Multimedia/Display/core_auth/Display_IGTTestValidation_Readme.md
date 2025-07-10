# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

2. Run the script:

```bash
./run.sh
```

3. Logs and test results will be available in the `results/igt_core_auth` directory.

## Output

- **Validation Result**: Printed to console and saved in a results file with PASS/FAIL status.

## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.

## Maintenance

- Ensure the authentication libraries remain compatible with your system.
- Update test cases as per new authentication requirements or updates in the IGT Core framework.

