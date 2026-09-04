Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
# USB HID Validation

## Overview

This shell script executes on the DUT and validates connected USB Human
Interface Device interfaces. It reports the device identity and verifies that
every HID class interface has a bound kernel driver. A missing external HID
fixture is reported as `SKIP`.

---

## Setup

- Connect USB HID peripheral(s) to USB port(s) on DUT.
- Only applicable for USB ports that support Host Mode functionality. 
- USB HID peripherals examples: Mouse, Keyboard, USB headset, etc. 

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
./run-test.sh usb_hid
```

Run directly:

```sh
cd Runner/suites/Kernel/Baseport/usb_hid
./run.sh
```

Runtime evidence is retained under `results/usb_hid/`.
