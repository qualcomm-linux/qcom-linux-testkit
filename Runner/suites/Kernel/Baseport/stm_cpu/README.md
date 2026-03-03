# STM CPU Trace  Validation test
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause
## Overview
This test case validates the System Trace Macrocell (STM) functionality on the target device by configuring the STM source, enabling tracing, and capturing trace data. It ensures that the STM infrastructure is correctly initialized and capable of generating trace output.

## Test Performs :
1. Verifies presence of required kernel configurations
2. Mounts **configfs** and **debugfs**
3. Loads STM-related kernel modules
4. configures STM policy directories
5. Enables ETF sink and STM source
6. Captures and validates trace output

## Usage
Instructions:
1. **Copy repo to Target Device**: Use `scp` to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.
2. **Verify Transfer**: Ensure that the repo has been successfully copied to the target device.
3. **Run Scripts**: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run the etm_trace  test using:
---

#### Quick Example
```sh
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh stm_cpu
```
---

## Prerequisites
1. Required kernel configs must be enabled:    
   CONFIG_STM_PROTO_BASIC   
   CONFIG_STM_PROTO_SYS_T    
   CONFIG_STM_DUMMY    
   CONFIG_STM_SOURCE_CONSOLE    
   CONFIG_STM_SOURCE_HEARTBEAT
2. Root access is required to mount filesystems and load kernel modules.
3. init_env and functestlib.sh must be present and correctly configured.
---

 ## Result Format
Test result will be saved in `stm_cpu.res` as:  

## Output
A .res file is generated in the same directory:
`stm_cpu PASS`  OR   `stm_cpu FAIL`   OR `stm_cpu SKIP`

## Skip Criteria
1. If the required kernel configuration is missing, the result will be:
2. `stm_cpu SKIP`

## Sample Log
```
[INFO] 1970-01-01 00:44:35 - -----------------------------------------------------------------------------------------
[INFO] 1970-01-01 00:44:35 - -------------------Starting stm_cpu Testcase----------------------------
[INFO] 1970-01-01 00:44:35 - === Test Initialization ===
[FAIL] 1970-01-01 00:44:35 - Kernel config CONFIG_STM_PROTO_BASIC is missing or not enabled
[SKIP] 1970-01-01 00:44:35 - stm_cpu : Required kernel configs missing
```