# KVM_Check - Validation test
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview
This test case validates the presence of the **dev/kvm** device node on the target system. The /dev/kvm interface is essential for enabling hardware-assisted virtualization using KVM (Kernel-based Virtual Machine). This test ensures that the KVM module is properly loaded and available.

## Test Performs :
1. Verifies required dependencies
2. Checks for the presence of **/dev/kvm**
3. Logs the result and writes it to a .res file

## Usage
Instructions:
1. **Copy repo to Target Device**: Use `scp` to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.
2. **Verify Transfer**: Ensure that the repo has been successfully copied to the target device.
3. **Run Scripts**: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run the kvm_check test using:
---
#### Quick Example
```sh
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh kvm_check
```
---

## Prerequisites
1. Root access is required to check device nodes.
---

 ## Result Format
Test result will be saved in `kvm_check.res` as:  

## Output
A .res file is generated in the same directory:
`kvm_check  PASS`  OR   `kvm_check FAIL` 

## Sample Log
```
[INFO] 1970-01-01 00:15:40 - -----------------------------------------------------------------------------------------
[INFO] 1970-01-01 00:15:40 - ------------------- Starting kvm_check Testcase ----------------------------
[INFO] 1970-01-01 00:15:40 - === Test Initialization ===
[INFO] 1970-01-01 00:15:40 - Checking for /dev/kvm presence...
[PASS] 1970-01-01 00:15:40 - /dev/kvm is present

```