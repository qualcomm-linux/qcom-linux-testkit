Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# Qualcomm Crypto (qcom_crypto) Functionality Test Script
# Overview

The qcom_crypto test script validates the basic functionality of cryptographic operations using the kcapi tool. It ensures that encryption, decryption, and HMAC-SHA256 operations are correctly executed and verified against expected outputs.

## Features

- Environment Initialization: Robustly locates and sources the init_env file from the directory hierarchy.
- Dependency Check: Verifies the presence of required tools like kcapi.
- Crypto Validation: Performs AES-CBC encryption/decryption and HMAC-SHA256 operations.
- Automated Result Logging: Outputs test results to a .res file for automated result collection.
- Modular Integration: Designed to work within a larger test framework using functestlib.sh.

## Prerequisites

Ensure the following components are present on the target device:

- `kcapi` (Kernel Crypto tool) Available in /usr/bin
- `libkcapi.so.1` (Kernel Crypto library) Available in /usr/lib

## Directory Structure
```
Runner/
├── suites/
│   ├── Kernel/
│   │   ├── Baseport/
│   │   │   ├── qcom_crypto/
│   │   │   │   ├── run.sh

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
cd /<user-defined-location>/Runner && ./run-test.sh qcom_crypto

Sample output:
sh-5.2# ./run-test.sh qcom_crypto
[Executing test case: qcom_crypto] 1970-01-01 05:44:18 -
[INFO] 1970-01-01 05:44:18 - -----------------------------------------------------------------------------------------
[INFO] 1970-01-01 05:44:18 - -------------------Starting qcom_crypto Testcase----------------------------
[INFO] 1970-01-01 05:44:18 - === Test Initialization ===
[INFO] 1970-01-01 05:44:18 - Checking if dependency binary is available
[INFO] 1970-01-01 05:44:18 - Running encryption test
[INFO] 1970-01-01 05:44:18 - Encryption test passed
[INFO] 1970-01-01 05:44:18 - Running decryption test
[INFO] 1970-01-01 05:44:18 - Decryption test passed
[INFO] 1970-01-01 05:44:18 - Running HMAC-SHA256 test
[INFO] 1970-01-01 05:44:18 - HMAC-SHA256 test passed
[PASS] 1970-01-01 05:44:18 - qcom_crypto : All tests passed
[PASS] 1970-01-01 05:44:18 - qcom_crypto passed

[INFO] 1970-01-01 05:44:18 - ========== Test Summary ==========
PASSED:
qcom_crypto

FAILED:
 None

SKIPPED:
 None
[INFO] 1970-01-01 05:44:18 - ==================================
```
4. Results will be available in the `/<user-defined-location>/Runner/suites/Kernel/FunctionalArea/baseport/qcom_crypto/` directory.

## Notes

- It uses kcapi to validate AES-CBC encryption/decryption and HMAC-SHA256 hashing.
- If any test fails, the script logs the expected vs actual output and exits with a failure code.