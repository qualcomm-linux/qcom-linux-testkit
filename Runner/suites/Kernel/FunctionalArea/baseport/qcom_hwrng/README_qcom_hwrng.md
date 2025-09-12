Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

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
│   │   ├── FunctionalArea/
│   │   │   ├── baseport/
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
[Executing test case: qcom_hwrng] 1970-01-01 00:17:53 -
[INFO] 1970-01-01 00:17:53 - -----------------------------------------------------------------------------------------
[INFO] 1970-01-01 00:17:53 - -------------------Starting qcom_hwrng Testcase----------------------------
[INFO] 1970-01-01 00:17:53 - === Test Initialization ===
[INFO] 1970-01-01 00:17:53 - Checking if dependency binary is available
[INFO] 1970-01-01 00:17:53 - qcom_hwrng successfully set as the current RNG source.
[INFO] 1970-01-01 00:17:53 - Running rngtest with 20000032 bytes of entropy from /dev/random...
rngtest 6.15
Copyright (c) 2004 by Henrique de Moraes Holschuh
This is free software; see the source for copying conditions.  There is NO warranty; not even for MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

rngtest: starting FIPS tests...
rngtest: bits received from input: 20000032
rngtest: FIPS 140-2 successes: 999
rngtest: FIPS 140-2 failures: 1
rngtest: FIPS 140-2(2001-10-10) Monobit: 0
rngtest: FIPS 140-2(2001-10-10) Poker: 0
rngtest: FIPS 140-2(2001-10-10) Runs: 0
rngtest: FIPS 140-2(2001-10-10) Long run: 1
rngtest: FIPS 140-2(2001-10-10) Continuous run: 0
rngtest: input channel speed: (min=3.682; avg=5.473; max=7.173)Mibits/s
rngtest: FIPS tests speed: (min=84.771; avg=138.269; max=155.069)Mibits/s
rngtest: Program run time: 3623356 microseconds
[INFO] 1970-01-01 00:17:56 - rngtest: FIPS 140-2 failures = 1
[PASS] 1970-01-01 00:17:56 - qcom_hwrng : Test Passed (1 failures)
[PASS] 1970-01-01 00:17:56 - qcom_hwrng passed

[INFO] 1970-01-01 00:17:57 - ========== Test Summary ==========
PASSED:
qcom_hwrng

FAILED:
 None
[INFO] 1970-01-01 00:17:57 - ==================================
```
4. Results will be available in the `/<user-defined-location>/Runner/suites/Kernel/FunctionalArea/baseport/qcom_hwrng/` directory.

## Notes

- The script sets qcom_hwrng as the primary hwrng.
- It validates Qualcomm Hardware Random Number Generator (HWRNG) basic functionality.
- If any critical tool is missing, the script exits with an error message.