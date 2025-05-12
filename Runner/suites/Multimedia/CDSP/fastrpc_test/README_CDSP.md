# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# FastRPC Test Scripts for RB3 Gen2 (Yocto)

## Overview

CDSP scripts demonstrates the usage of FastRPC (Fast Remote Procedure Call) to offload computations to different DSP (Digital Signal Processor) domains. The test application supports multiple examples, including a simple calculator service, a HAP example, and a multithreading example. This test app is publicly available @https://github.com/quic/fastrpc

## Features

- Simple Calculator Service
- HAP example
- Multithreading Example

## Prerequisites

Ensure the following components are present in the target Yocto build (at usr/share/bin/):

- this test app can be compiled from https://github.com/quic/fastrpc
- `fastrpc_test` : The compiled test application.
- `android Directory` : Contains shared libraries for the Android platform.
- `linux Directory` : Contains shared libraries for the Linux platform.
- `v68 Directory` : Contains skeletons for the v68 architecture version.
- Write access to root filesystem (for environment setup)

## Directory Structure

```bash
Runner/
├── suites/
│   ├── Multimedia/
│   │   ├── CDSP/
│   │   │   ├── fastrpc_test/
│   │   │   │   ├── run.sh
      
```

## Usage

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to the /var directory on the target device.

2. Verify Transfer: Ensure that the repo have been successfully copied to the /var directory on the target device.

3. Run Scripts: Navigate to the /var directory on the target device and execute the scripts as needed.

Run a specific test using:
---
Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:/var
ssh user@target_device_ip 
cd /var/Runner && ./run-test.sh 
```
Sample output:
sh-5.2# cd /var/Runner && ./run-test.sh fastrpc_test
[Executing test case: /var/Runner/suites/Multimedia/CDSP/fastrpc_test] 1980-01-06 01:33:25 -
[INFO] 1980-01-06 01:33:25 - -----------------------------------------------------------------------------------------
[INFO] 1980-01-06 01:33:25 - -------------------Starting fastrpc_test Testcase----------------------------
[INFO] 1980-01-06 01:33:25 - Checking if dependency binary is available
[PASS] 1980-01-06 01:33:25 - Test related dependencies are present.
...
[PASS] 1980-01-06 01:33:27 - fastrpc_test : Test Passed
[INFO] 1980-01-06 01:33:27 - -------------------Completed fastrpc_test Testcase----------------------------

4. Results will be available in the `Runner/suites/Multimedia/CDSP/` directory.

## Notes

- The script does not take any arguments.
- It validates the presence of required libraries before executing tests.
- If any critical tool is missing, the script exits with an error message.