# virtio_infra_test Test
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview
This test case validates the virtio infrastructure by launching a QEMU-based virtual machine using KVM acceleration. It ensures that the virtual machine boots successfully and that the login prompt is detected, confirming that the virtio and KVM setup is functional

## Test Performs :
1. Dynamically locates required directories:  
     init_env for environment setup  
     `myqemu` for QEMU binaries and libraries  
     volatile for kernel image and root filesystem  
2. Creates a temporary input file to simulate Enter key press  
3. Launches `QEMU` with `KVM` using the discovered binaries and images
4. Monitors the serial log for:  
     Login prompt  
     `KVM` usage confirmation  
5. Writes test result to a .res file

## Usage
Instructions:
1. **Prepare Directories:**  
   Place QEMU binaries and libraries under a directory named myqemu  
   Place the kernel image (`Image`) and root filesystem (`*.ext4`) anywhere on the target device. These files will be discovered dynamically by the script.  
   Ensure both directories are accessible from the script's location (they will be discovered dynamically)  
2. **Copy repo to Target Device**: Use `scp` to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.
3. **Verify Transfer**: Ensure that the repo has been successfully copied to the target device.
4. **Run Scripts**: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run the etm_trace  test using:
---

#### Quick Example
```sh
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh virtio_infra_test
```
---

## Prerequisites
1. Required directories must exist:  
  myqemu containing `QEMU b`inaries and libraries  
  volatile containing Image and .ext4 root filesystem
2. The target device must boot with **KVM as the hypervisor** enabled
3. Root access is required to run` QEMU` with` KVM`
---

 ## Result Format
Test result will be saved in `virtio_infra_test.res` as:  

## Output
A .res file is generated in the same directory:
`virtio_infra_test PASS`  OR   `virtio_infra_test FAIL` 

## Sample Log
```
[INFO] 1970-01-01 01:34:09 - -----------------------------------------------------------------------------------------
[INFO] 1970-01-01 01:34:09 - -------------------Starting virtio_infra_test Testcase----------------------------
[INFO] 1970-01-01 01:34:09 - === Test Initialization ===
[INFO] 1970-01-01 01:34:09 - Creating temporary input file for QEMU...
[INFO] 1970-01-01 01:34:09 - Launching QEMU with KVM...
[INFO] 1970-01-01 01:34:09 - Waiting for VM to boot (checking logs)...
[PASS] 1970-01-01 01:34:17 - Login prompt detected
[PASS] 1970-01-01 01:34:17 - KVM usage confirmed in boot logs
[INFO] 1970-01-01 01:34:17 - -------------------Completed virtio_infra_test Testcase----------------------------
--
```