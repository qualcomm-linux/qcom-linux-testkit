# Reboot_health_check 

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview
This test case validates the system's ability to reboot and recover correctly by:
- Automatically creating a systemd service to run the test after reboot
- Performing post-reboot health checks such as:  
  - Root shell access  
  - Filesystem availability  
  - Kernel version  
  - Network stack  
- Retrying the test up to 3 times if any check fails
- Logging results and cleaning up after success or failure

## Usage
Instructions:
1. **Copy repo to Target Device**: Use `scp` to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.
2. **Verify Transfer**: Ensure that the repo has been successfully copied to the target device.
3. **Run Scripts**: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run the Reboot_health_check test using:
---
#### Quick Example
```sh
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh Reboot_health_check
```
---

## Prerequisites
1. Root access is required
2. systemctl, ifconfig or ip, and uname must be available
3. The system must support systemd and reboot functionality
---
 ## Result Format
Test result will be saved in `Reboot_health_check.res ` as:  

## Pass Criteria
 All health checks pass successfully  
System reboots and recovers correctly  
Reboot_health_check PASS

## Fail Criteria
Any health check fails after 3 retries  
Reboot_health_check FAIL
## Output 
A .res file is generated in the same directory:
`Reboot_health_check PASS`  OR   `Reboot_health_check  FAIL` 

## Sample Log
```
[INFO] 1980-01-06 00:23:09 - ------------------- Starting Reboot_health_check Test ----------------------------
[INFO] 1980-01-06 00:23:09 - === Test Initialization ===
[INFO] 1980-01-06 00:23:09 - Creating systemd service and Rebooting...
[INFO] 1980-01-06 00:23:12 - System will reboot in 2 seconds...
sh-5.2#

[INFO] 1980-01-06 00:00:00 - ------------------- Starting Reboot_health_check Test ----------------------------
[INFO] 1980-01-06 00:00:00 - === Test Initialization ===
[INFO] 1980-01-06 00:00:00 - Post-reboot validation
[INFO] 1980-01-06 00:00:00 - Retry Count: 0
[PASS] 1980-01-06 00:00:00 - Reboot_health_check PASS
[INFO] 1980-01-06 00:00:00 - ------------------- Completed Reboot_health_check Test ----------------------------
sh-5.2#

```