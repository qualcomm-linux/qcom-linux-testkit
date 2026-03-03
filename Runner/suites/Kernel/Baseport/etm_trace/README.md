# ETM_Trace  Validation test
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause
## Overview
This test case validates the CoreSight Embedded Trace Macrocell (ETM) trace capture functionality on the target device. It ensures that the ETM source and TMC sink are properly enabled and that trace data can be successfully captured and validated.

## Test Performs :
1. Verifies the presence of required kernel configuration (CONFIG_CORESIGHT_SOURCE_ETM4X)
2. Enables the CoreSight sink (tmc_etr0)
3. Enables the CoreSight source (etm0)
4. Captures trace data from /dev/tmc_etr0 into a binary file
5. Validates that the trace file is non-empty

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
cd <Path in device>/Runner && ./run-test.sh etm_trace
```
---

## Prerequisites
1. The kernel must be built with CONFIG_CORESIGHT_SOURCE_ETM4X enabled.
2. CoreSight devices (etm0, tmc_etr0) must be exposed in /sys/bus/coresight/devices/.
3. Root access may be required to access /dev/tmc_etr0 and write to system paths.
---

 ## Result Format
Test result will be saved in `etm_trace.res` as:  

## Output
A .res file is generated in the same directory:
`etm_trace PASS`  OR   `etm_trace FAIL`   OR `etm_trace SKIP`

## Skip Criteria
1. If the required kernel configuration is missing, the result will be:
2. `etm_trace SKIP`

## Sample Log
```
[INFO] 1980-01-06 00:04:29 - -----------------------------------------------------------------------------------------
[INFO] 1980-01-06 00:04:29 - -------------------Starting etm_trace Testcase----------------------------
[INFO] 1980-01-06 00:04:29 - === Test Initialization ===
[INFO] 1980-01-06 00:04:29 - Enabling CoreSight sink (tmc_etr0)...
[INFO] 1980-01-06 00:04:29 - Sink enabled successfully.
[INFO] 1980-01-06 00:04:29 - Enabling CoreSight source (etm0)...
[INFO] 1980-01-06 00:04:29 - Source enabled successfully.
[INFO] 1980-01-06 00:04:29 - Capturing trace data to /tmp/qdss.bin...
[INFO] 1980-01-06 00:04:29 - Trace data captured successfully.
[PASS] 1980-01-06 00:04:29 - etm_trace : Test Passed
sh-5.2# ls
etm_trace.res  run.sh
sh-5.2# cat etm_trace.res
etm_trace PASS
```