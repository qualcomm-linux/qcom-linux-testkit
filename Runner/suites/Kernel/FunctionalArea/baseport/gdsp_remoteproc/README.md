# gdsp_remoteproc Test

© Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear

## Overview

This test case validates the functionality of the **GPDSP (General Purpose DSP)** firmware loading and control on the **Lemans** platform. It specifically targets:

- `gpdsp0`
- `gpdsp1`

The script ensures that each GPDSP remote processor:
- Is currently running
- Can be stopped successfully
- Can be restarted and returns to the running state

This is essential for verifying the stability and control of DSP subsystems on Qualcomm-based platforms.

## Usage

### Instructions

1. **Transfer the Script**: Use `scp` or any file transfer method to copy the script to the Lemans target device.
2. **Navigate to the Script Directory**: SSH into the device and go to the directory where the script is located.
3. **Run the Script**:
   ```sh
   ./run.sh
   ```
   ---
   #### Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh gdsp_remoteproc
```
---
## Prerequisites
1. The device must expose `/sys/class/remoteproc/remoteproc*/firmware and /state` interfaces.
2. Root access may be required to write to remoteproc state files.
3. The firmware names must include gpdsp0 and gpdsp1.
 ---
 ## Result Format
Test result will be saved in `gdsp_remoteproc.res` as:  
## Output
A .res file is generated in the same directory:

`gdsp_remoteproc PASS`  OR   `gdsp_remoteproc FAIL`

## Sample Log
```
Output

[INFO] 1970-01-01 03:56:11 - ------------------------------------------------------------------------------
[INFO] 1970-01-01 03:56:11 - -------------------Starting gdsp_remoteproc Testcase----------------------------
[INFO] 1970-01-01 03:56:11 - === Test Initialization ===
[INFO] 1970-01-01 03:56:11 - Found gpdsp0 at /sys/class/remoteproc/remoteproc3
[PASS] 1970-01-01 03:56:11 - gpdsp0 stop successful
[INFO] 1970-01-01 03:56:11 - Restarting gpdsp0
[PASS] 1970-01-01 03:56:12 - gpdsp0 PASS
[INFO] 1970-01-01 03:56:12 - Found gpdsp1 at /sys/class/remoteproc/remoteproc4
[PASS] 1970-01-01 03:56:12 - gpdsp1 stop successful
[INFO] 1970-01-01 03:56:12 - Restarting gpdsp1
[PASS] 1970-01-01 03:56:12 - gpdsp1 PASS
[INFO] 1970-01-01 03:56:12 - -------------------Completed gdsp_remoteproc Testcase----------------------------
```