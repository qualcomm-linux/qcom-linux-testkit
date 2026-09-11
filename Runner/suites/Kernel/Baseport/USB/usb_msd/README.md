```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
```

# USB MSD Validation

## Overview

This shell script executes on the DUT and validates USB mass-storage devices.
The test validation scope includes:
- Successful enumeration of MSD devices
- For each device:
  - Determine and report the bound transport driver
  - Discover associated block devices via sysfs
  - Wait a bounded time for asynchronous block-device creation
  - Read 512 bytes from each block device by default without modifying media

The test passes only when every detected MSD interface is driver-bound, exposes
its block device, and completes the enabled read validation. A missing external
MSD fixture is reported as `SKIP`.
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

Run directly with defaults:

```sh
cd Runner/suites/Kernel/Baseport/USB/usb_msd
./run.sh
```

Disable the read-only media check or adjust enumeration wait time:

```sh
./run.sh --read-verify 0 --wait-seconds 20
```

Equivalent environment variables are `USB_MSD_READ_VERIFY` and
`USB_MSD_WAIT_SECONDS`. Runtime evidence is retained under
`results/usb_msd/`.
