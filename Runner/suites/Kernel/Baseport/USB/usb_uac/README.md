```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
```

# USB Audio Class Validation

## Overview

This shell script executes on the DUT (Device-Under-Test) and validates USB Audio Class (UAC) devices.
The test validation scope includes:
- Successful enumeration of UAC devices and display following details for each device:
  - DEVICE (USB device address), VID:PID, and PRODUCT string.
- Validation of ALSA integration:
  - Confirm /proc/asound/cards exists.
  - Identify ALSA cards corresponding to the UAC device.
  - At least one PCM playback or capture node exists for each such card.

---

## Setup

- Connect USB Audio peripheral(s) to USB port(s) on DUT.
- Only applicable for USB ports that support Host Mode functionality. 
- USB Audio peripherals examples: USB headset, microphone, sound card, etc. 

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
./run-test.sh usb_uac
```
