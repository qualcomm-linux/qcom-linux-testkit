```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause-Clear
```

# USB Full Speed Validation

## Overview

This shell script executes on the DUT (Device-Under-Test) and verifies successful enumeration of connected USB Devices in Full Speed (FS - 12 Mb/s) .

---

## Setup

- Connect FS USB peripheral(s) to USB port(s) on DUT.
- Only applicable for USB ports that support Host Mode functionality. 
- USB peripherals examples: Mass Storage devices (pendrives, SSD, hard drives, etc.), HID devices (Mouse, Keyboard, USB headset, USB camera, etc.)

---

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
cd <path-on-device>/Runner && ./run-test.sh usb_fs
```
