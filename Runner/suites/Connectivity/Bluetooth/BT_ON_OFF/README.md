Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

# Bluetooth Validation Test

## Overview

This test case validates the basic functionality of the Bluetooth controller on the device. It checks for:

- Presence of `bluetoothctl`
- Running status of `bluetoothd`
- Power state toggling of the Bluetooth controller

## Usage

Instructions:

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.
2. Verify Transfer: Ensure that the repo have been successfully copied to any directory on the target device.
3. Run Scripts: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run a Connectivity Bluetooth test using:
---
#### Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh Bluetooth
```

## Prerequisites
- bluez package must be installed (provides bluetoothctl)
- bluetoothd daemon must be running
- Root access may be required for complete validation

## Result Format

Test result will be saved in Bluetooth.res as:  
#### Pass Criteria  
- bluetoothctl is available
- bluetoothd is running
- Power on command returns success
- Bluetooth controller powered on successfully. – if all validations pass  
<!-- -->
#### Fail Criteria  
- bluetoothctl not found
- bluetoothd not running
- Power on command fails
- Failed to power on Bluetooth controller. – if any check fails


## Output
A .res file is generated in the same directory:

`PASS Bluetooth`  OR   `FAIL Bluetooth`


