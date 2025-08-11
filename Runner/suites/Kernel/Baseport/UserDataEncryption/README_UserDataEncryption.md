Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

# Qualcomm UserDataEncryption Functionality Test Script
## Overview

The `UserDataEncryption` test script verifies basic filesystem encryption functionality. It generates a 64-byte key, adds it to the system, applies an encryption policy to a mount directory, and confirms the setup by creating and reading a test file. This ensures that key management and encryption policies work as expected.

## Features

- **Dependency Check**: Verifies the presence of the `fscryptctl` binary.
- **Key Management**: Generates a 64-byte key and adds it to the filesystem.
- **Encryption Policy**: Applies and verifies encryption policy on a mount directory.
- **Functional Validation**: Creates and reads a test file to confirm encryption functionality.
- **Automated Result Logging**: Outputs test results to a `.res` file for automated result collection.

## Prerequisites

Ensure the following components are present on the target device:

- `fscryptctl` binary available in `/data/`
- Sufficient permissions to create and mount directories

## Directory Structure
```
Runner/
├── suites/
│   ├── Kernel/
│   │   │   ├── baseport/
│   │   │   │   ├── UserDataEncryption/
│   │   │   │   │   ├── run.sh
```
## Usage

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to the ```/<user-defined-location>``` directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to the ```/<user-defined-location>``` directory on the target device.

3. Run Scripts: Navigate to the ```/<user-defined-location>``` directory on the target device and execute the scripts as needed.

---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:/<user-defined-location>
ssh user@target_device_ip 
cd /<user-defined-location>/Runner && ./run-test.sh UserDataEncryption

Sample output:
sh-5.2# ./run-test.sh UserDataEncryption
[Executing test case: UserDataEncryption] 2025-11-18 15:03:05 -
[INFO] Running as root. Continuing...
[INFO] 2025-11-18 15:03:05 - -----------------------------------------------------------------------------------------
[INFO] 2025-11-18 15:03:05 - -------------------Starting UserDataEncryption Testcase----------------------------
[INFO] 2025-11-18 15:03:05 - === Test Initialization ===
[INFO] 2025-11-18 15:03:05 - Checking if dependency binary is available
[INFO] 2025-11-18 15:03:05 - Temporary key file created: /tmp/tmp.yV9Fgr7z7T
[INFO] 2025-11-18 15:03:05 - Generating 64-byte encryption key
[INFO] 2025-11-18 15:03:05 - Creating unique mount folder under /mnt
[INFO] 2025-11-18 15:03:05 - Created unique mount directory: /mnt/testing.pb1KIn
[INFO] 2025-11-18 15:03:05 - Derived filesystem mount point: /var
[INFO] 2025-11-18 15:03:05 - Adding encryption key to the filesystem
[INFO] 2025-11-18 15:03:05 - No relevant, non-benign errors for modules [fscrypt] in recent dmesg.
[INFO] 2025-11-18 15:03:05 - Key ID: 80ae0d678e52fb126ea6eda7d32861eb
[INFO] 2025-11-18 15:03:05 - Checking key status
[INFO] 2025-11-18 15:03:05 - Key Status: Present (user_count=1, added_by_self)
[INFO] 2025-11-18 15:03:05 - Setting encryption policy on /mnt/testing.pb1KIn
[INFO] 2025-11-18 15:03:06 - No relevant, non-benign errors for modules [fscrypt] in recent dmesg.
[INFO] 2025-11-18 15:03:06 - Verifying encryption policy
[INFO] 2025-11-18 15:03:06 - No relevant, non-benign errors for modules [fscrypt] in recent dmesg.
[INFO] 2025-11-18 15:03:06 - Policy verification successful: Master key identifier matches key_id
[INFO] 2025-11-18 15:03:06 - Creating test file in encrypted directory
[INFO] 2025-11-18 15:03:06 - Reading test file
[PASS] 2025-11-18 15:03:06 - UserDataEncryption : Test Passed
[INFO] 2025-11-18 15:03:06 - -------------------Completed UserDataEncryption Testcase----------------------------
[INFO] 2025-11-18 15:03:06 - Cleaning up mount directory: /mnt/testing.pb1KIn
[INFO] 2025-11-18 15:03:06 - Deleted test file: /mnt/testing.pb1KIn/file.txt
[INFO] 2025-11-18 15:03:06 - Removed mount directory: /mnt/testing.pb1KIn
[PASS] 2025-11-18 15:03:06 - UserDataEncryption passed

[INFO] 2025-11-18 15:03:06 - ========== Test Summary ==========
PASSED:
UserDataEncryption

FAILED:
 None

SKIPPED:
 None
[INFO] 2025-11-18 15:03:06 - ==================================
```
4. Results will be available in the `/<user-defined-location>/Runner/suites/Kernel/baseport/UserDataEncryption/` directory.

## Notes

- The script uses /data/UserDataEncryption for all operations.
- Temporary files such as the encryption key are cleaned up after the test.
- If any test fails, the script logs the error and exits with a failure code.
