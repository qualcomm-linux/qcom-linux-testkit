# Bluetooth firmware, driver and service validation

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

Run with image-provided Bluetooth tools:

```sh
cd Runner/suites/Connectivity/Bluetooth/BT_FW_KMD_Service
./run.sh
cat BT_FW_KMD_Service.res
```

The suite discovers a usable HCI adapter and validates its driver, service and
nonzero address. Firmware completion markers supplement current runtime
readiness. Inventory and readiness do not establish radio communication,
use `BT_ON_OFF` and `BT_SCAN` for those operations.

The bound QCA UART driver supports original ROM firmware/config when its
patch lookup returns ENOENT or EAGAIN. Such messages remain visible in
`results/BT_FW_KMD_Service/kernel/firmware_unavailable.log` and stdout.
Missing patch completion markers alone do not fail an otherwise usable
runtime, and a PASS does not certify patched firmware. An unusable runtime,
transport timeout, other fatal firmware error or captured crash still fails.
An explicit `BTFW_FATAL_RE` override retains the caller's stricter policy.

Kernel snapshots, original errors and fatal blocks stay under the invocation
CWD. No firmware is copied and no packages are installed by these checks.
