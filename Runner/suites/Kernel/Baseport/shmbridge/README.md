Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

# shmbridge Validation test

## Overview

This test case validates the presence and initialization of the Qualcomm Secure Channel Manager (QCOM_SCM) interface on the device. It ensures that:

- The kernel is configured with QCOM_SCM support
- The dmesg logs contain expected `qcom_scm` entries
- There are no "probe failure" messages in the logs

## Usage

Instructions:

1. **Copy repo to Target Device**: Use `scp` to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.
2. **Verify Transfer**: Ensure that the repo has been successfully copied to the target device.
3. **Run Scripts**: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run the SHM Bridge test using:
---
#### Quick Example
```sh
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh shmbridge
```
---
## Prerequisites
1. zcat, grep, and dmesg must be available.
2. Root access may be required to write to read kernel logs.
 ---
 ## Result Format
Test result will be saved in `shmbridge.res` as:  
## Output
A .res file is generated in the same directory:

`shmbridge PASS`  OR   `shmbridge FAIL`

## Sample Log
```
Output

[INFO] 2025-03-06 11:02:51 - -----------------------------------------------------------------------------------------
[INFO] 2025-03-06 11:02:51 - -------------------Starting shmbridge Testcase----------------------------
[INFO] 2025-03-06 11:02:51 - ==== Test Initialization ====
[INFO] 2025-03-06 11:02:51 - Checking if required tools are available
[INFO] 2025-03-06 11:02:51 - Checking kernel config for QCOM_SCM support...
[PASS] 2025-03-06 11:02:51 - Kernel config CONFIG_QCOM_SCM is enabled
[INFO] 2025-03-06 11:02:51 - Scanning dmesg logs for qcom_scm-related errors...
[INFO] 2025-03-06 11:02:51 - Scanning dmesg for recent qcom_scm-related I/O errors...
[INFO] 2025-03-06 11:02:51 - No qcom_scm-related errors found in recent dmesg logs.
[PASS] 2025-03-06 11:02:51 - shmbridge : Test Passed (qcom_scm present and no probe failures)
[INFO] 2025-03-06 11:02:51 - -------------------Completed shmbridge Testcase----------------------------
```
