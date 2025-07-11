# PCIe Validation Test
© Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
## Overview
This test case validates the PCIe interface on the target device by checking for the presence of key PCIe attributes using the `lspci -vvv` command. It ensures that the PCIe subsystem is correctly enumerated and functional
### The test checks for:
- Presence of **Device Tree Node**
- Availability of **PCIe Capabilities**
- Binding of a **Kernel Driver**

These checks help confirm that the PCIe root port is properly initialized and ready for use 
## Usage
### Instructions:
1. **Copy the test suite to the target device** using `scp` or any preferred method.
2. **Navigate to the test directory** on the target device.
3. **Run the test script** using the test runner or directly.
---
### Quick Example
```bash
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<path-on-device>
ssh user@target_device_ip
cd <path-on-device>/Runner && ./run-test.sh PCIe
```
---
### Prerequisites
1. `lspci` must be available on the target device 
2. PCIe interface must be exposed and initialized
3. Root access may be required depending on system configuration
---
## Result Format
Test result will be saved in `PCIe.res` as:  
## Output
A .res file is generated in the same directory:
`PCIe PASS`  OR   `PCIe FAIL`
## Sample Log
```
Output
[INFO] 1980-01-06 01:51:08 - --------------------------------------------------------
[INFO] 1980-01-06 01:51:08 - -------------------Starting PCIe Testcase----------------------------
[INFO] 1980-01-06 01:51:08 - === Test Initialization ===
[INFO] 1980-01-06 01:51:08 - Running PCIe Test
[INFO] 1980-01-06 01:51:08 - Yes, 'Device tree node:' is found
[INFO] 1980-01-06 01:51:08 - Yes, 'Capabilities:' is found
[INFO] 1980-01-06 01:51:09 - Yes, 'Kernel driver in use:' is found
[PASS] 1980-01-06 01:51:09 - pcie : Test Passed
```