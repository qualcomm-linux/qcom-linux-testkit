```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause```

# USB Host Mode Validation

## Overview

This shell script executes on the DUT and validates USB host runtime state. It
reports root hubs, connected devices, negotiated speeds, interface classes,
bound drivers, runtime-power state, `lsusb` inventory when available, and a
focused USB kernel-health snapshot.

A healthy host controller with no external peripheral is a valid controller
result and reports the fixture-dependent device check as `SKIP`. An inactive
device role is also reported as `SKIP`, rather than as a host-controller
failure.

---

## Setup

- Connect USB peripheral(s) to USB port(s) on DUT.
- Only applicable for USB ports that support Host Mode functionality. 
- USB peripherals examples: Mass Storage devices (pendrives, SSD, hard drives, etc.), HID devices (Mouse, Keyboard, USB headset, USB camera, etc.) 

## Run

```sh
cd Runner/suites/Kernel/Baseport/USBHost
./run.sh
```

Artifacts are retained under `results/USBHost/`.

Kernel-log findings are advisory by default. Enable strict gating after the
platform's expected boot-time messages are understood:

```sh
USB_DMESG_STRICT=1 ./run.sh
```

---

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause```
