```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
```

# USB MSD Validation

## Overview

This shell script executes on the DUT (Device-Under-Test) and verifies enumeration of connected USB Mass Storage Devices (MSD).

---

## Setup

- Connect USB MSD peripheral(s) to USB port(s) on DUT.
- Only applicable for USB ports that support Host Mode functionality. 
- USB MSD peripherals examples: USB flash drive, external HDD/SSD, etc. 

---

## Usage
### Instructions:
1. **Copy the test suite to the target device** using `scp` or any preferred method.
2. **Navigate to the test directory** on the target device.
3. **Run the test script** using the test runner or directly.

---

### Quick Example
```
cd Runner
./run-test.sh usb_msd
```
