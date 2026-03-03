Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# Qualcomm Hardware Random Number Generator (QRNG) Script
# Overview

The qcom_hwrng test script validates Qualcomm Hardware Random Number Generator (HWRNG) basic functionality. This test ensures that the HWRNG kernel driver is correctly integrated and functional.

## Features

- Driver Validation: Confirms the presence and correct configuration of the qcom_hwrng kernel driver.
- Dependency Check: Verifies the availability of required tools like rngtest before execution.
- Automated Result Logging: Outputs test results to a .res file for automated result collection.
- Remote Execution Ready: Supports remote deployment and execution via scp and ssh.

## Prerequisites

Ensure the following components are present in the target:

- `rngtest` (Binary Available in /usr/bin) - this test app can be compiled from https://github.com/cernekee/rng-tools/

## Directory Structure
```
Runner/
├── suites/
│   ├── Kernel/
│   │   │   ├── Baseport/
│   │   │   │   ├── qcom_hwrng/
│   │   │   │   │   ├── run.sh
```
## Usage

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to the /var directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to the /var directory on the target device.

3. Run Scripts: Navigate to the /var directory on the target device and execute the scripts as needed.

---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:/<user-defined-location>
ssh user@target_device_ip 
cd /<user-defined-location>/Runner && ./run-test.sh qcom_hwrng

Sample output:
sh-5.2# ./run-test.sh qcom_hwrng
[Executing test case: qcom_hwrng] 2025-11-03 10:28:02 -
[INFO] 2025-11-03 10:28:02 - -----------------------------------------------------------------------------------------
[INFO] 2025-11-03 10:28:02 - -------------------Starting qcom_hwrng Testcase----------------------------
[INFO] 2025-11-03 10:28:02 - === Test Initialization ===
[INFO] 2025-11-03 10:28:02 - Checking if dependency binary is available
[INFO] 2025-11-03 10:28:02 - qcom_hwrng successfully set as the current RNG source.
[INFO] 2025-11-03 10:28:02 - Using FIPS 140-2 failure threshold: 10
[INFO] 2025-11-03 10:28:02 - Running rngtest with 20000032 bytes of entropy from /dev/hwrng...
[INFO] 2025-11-03 10:28:35 - rngtest: FIPS 140-2 failures = 1
[PASS] 2025-11-03 10:28:35 - qcom_hwrng : Test Passed (1 failures)
[INFO] 2025-11-03 10:28:35 - -------------------Completed qcom_hwrng Testcase----------------------------
[PASS] 2025-11-03 10:28:35 - qcom_hwrng passed

[INFO] 2025-11-03 10:28:35 - ========== Test Summary ==========
PASSED:
qcom_hwrng

FAILED:
 None

SKIPPED:
 None
[INFO] 2025-11-03 10:28:35 - ==================================
```
4. Results will be available in the `/<user-defined-location>/Runner/suites/Kernel/Baseport/qcom_hwrng/` directory.

## Notes

- The script sets qcom_hwrng as the primary hwrng.
- It validates Qualcomm Hardware Random Number Generator (HWRNG) basic functionality.
- If any critical tool is missing, the script exits with an error message.