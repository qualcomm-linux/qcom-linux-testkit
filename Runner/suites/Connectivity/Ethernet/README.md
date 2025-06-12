Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear

# Ethernet Validation Test

## Overview

This test case validates the basic functionality of the Ethernet interface (`eth0`) on the device. It checks for:

- Interface presence
- Interface status (UP/DOWN)
- Basic connectivity via ping to `8.8.8.8`

## Usage

Instructions:

1. Copy repo to Target Device: Use scp to transfer the scripts from the host to the target device. The scripts should be copied to any directory on the target device.
2. Verify Transfer: Ensure that the repo have been successfully copied to any directory on the target device.
3. Run Scripts: Navigate to the directory where these files are copied on the target device and execute the scripts as needed.

Run a Connectivity Ethernet test using:
---
#### Quick Example
```
git clone <this-repo>
cd <this-repo>
scp -r common Runner user@target_device_ip:<Path in device>
ssh user@target_device_ip
cd <Path in device>/Runner && ./run-test.sh Ethernet
# Optional: specify preferred interface (e.g., eth1)
./run.sh [preferred-interface]
```

## Prerequisites

- `ip` and `ping` must be available
- Root access may be required for complete validation

## Result Format
Test result will be saved in `Ethernet.res` as:  
#### Pass Criteria  
- Ethernet interface eth0 is detected
- Interface is successfully brought up (if down)
- Ping to 8.8.8.8 succeeds
- `Ethernet connectivity verified` – if all validations pass  
<!-- -->
#### Fail Criteria  
- Interface eth0 is not found
- Interface cannot be brought up
- Ping test fails
- `Ethernet ping failed` – if any check fails


## Output
A .res file is generated in the same directory:

`Ethernet PASS`  OR   `Ethernet FAIL`

## Sample Log
```
Output

[INFO] 2025-06-11 10:12:23 - Detected Ethernet interface: enP1p4s0u1u1
[PASS] 2025-06-11 10:12:30 - enP1p4s0u1u1 is UP
[INFO] 2025-06-11 10:12:31 - Assigned IP: 10.0.0.55
[PASS] 2025-06-11 10:12:35 - Ping successful on enP1p4s0u1u1
```
