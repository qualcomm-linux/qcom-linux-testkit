# Shmbridge Validation Test

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

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

[INFO] 1970-01-01 00:09:09 - -----------------------------------------------------------------------------------------
[INFO] 1970-01-01 00:09:09 - -------------------Starting shmbridge Testcase----------------------------
[INFO] 1970-01-01 00:09:09 - === Test Initialization ===
[INFO] 1970-01-01 00:09:09 - Checking if required tools are available
[INFO] 1970-01-01 00:09:09 - Checking kernel config for QCOM_SCM support...
[INFO] 1970-01-01 00:09:09 - Checking dmesg logs for qcom_scm entries...
[INFO] 1970-01-01 00:09:09 - [    0.113484] qcom_scm: convention: smc arm 64
[INFO] 1970-01-01 00:09:09 - [    0.113727] qcom_scm firmware:scm: qseecom: found qseecom with version 0x1402000
[INFO] 1970-01-01 00:09:09 - [    0.113742] qcom_scm firmware:scm: qseecom: untested machine, skipping
[PASS] 1970-01-01 00:09:09 - shmbridge : Test Passed (QCOM_SCM present and no probe failures)
[INFO] 1970-01-01 00:09:09 - -------------------Completed shmbridge Testcase----------------------------
```