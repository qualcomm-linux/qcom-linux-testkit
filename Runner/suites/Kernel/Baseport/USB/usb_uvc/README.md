```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
```

# USB Video Class Validation

## Overview

This shell script executes on the DUT (Device-Under-Test) and validates USB Video Class (UVC) devices.
The test validation scope includes:
- Successful enumeration of UVC devices and display following details for each device:
  - DEVICE (USB device address), VID:PID, and PRODUCT string.
- Validation of video device nodes creation:
  - For each UVC interface of each detected device, verify /dev/video* nodes exist.
- Print a table of enumerated devices:

```
DEVICE    VID:PID   DRIVER            PRODUCT
-------------------------------------------------------------------------------
<dev>     <vid:pid> <uvcvideo> <product>
```
The test PASS requires all detected UVC devices to have associated /dev/video* nodes.

Running this test on a DUT without a connected USB Video peripheral is expected to FAIL with the message: No 'USB Video Device' found.

---

## Setup

- Connect USB Video peripheral(s) to USB port(s) on DUT.
- Only applicable for USB ports that support Host Mode functionality. 
- USB Video peripherals examples: USB webcam, video capture cards, etc. 

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
./run-test.sh usb_uvc
```
