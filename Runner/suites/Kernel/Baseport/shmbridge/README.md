# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

# shmbridge Validation Test

## Overview

This test validates the presence, registration, and correct runtime state of the
Qualcomm Secure Channel Manager (`qcom_scm`) driver on the target device. The
`qcom_scm` driver is the kernel-side interface to TrustZone / Secure World and is
a hard dependency for shared-memory bridge (shmbridge), SMMU, Crypto, and many
other Qualcomm subsystem drivers.

---

## Checks Performed

| # | Check | Path / Interface | Mandatory |
|---|-------|-----------------|-----------|
| 1 | **sysfs module presence** | `/sys/module/qcom_scm` | Yes |
| 2 | **Device Tree firmware/scm node** | `/sys/firmware/devicetree/base/firmware/scm` | Yes |
| 3 | **Platform driver registration** | `/sys/bus/platform/drivers/qcom_scm` | Yes |
| 4 | **Driver-to-device binding** | Symlinks under `/sys/bus/platform/drivers/qcom_scm/` | Yes |
| 5 | **sysfs attribute readability** | `/sys/module/qcom_scm/parameters/*` | Yes |
| 6 | **Device uevent / modalias** | `<bound_device>/uevent` | Informational |
| 7 | **TEE / TrustZone device node** | `/dev/tee0`, `/dev/teepriv0` | Informational |

> **Informational checks** may log warnings, but they do not cause the test to
> FAIL when the path is absent. This handles platforms where CONFIG_TEE or
> related runtime exposure is optional.

### Check details

1. **sysfs module presence** — Confirms the `qcom_scm` driver was compiled into
   the kernel (or loaded as a module) and is visible under `/sys/module`.

2. **Device Tree firmware/scm node** — The `qcom_scm` driver requires a
   `firmware/scm` node in the Device Tree to probe successfully. Uses the
   `check_dt_nodes()` helper from `functestlib.sh`.

3. **Platform driver registration** — Confirms the driver called
   `platform_driver_register()` successfully and is listed on the platform bus.

4. **Driver-to-device binding** — Confirms `probe()` completed without error by
   checking that at least one symlink (bound device) exists under the driver
   directory.

5. **sysfs attribute readability** — Iterates all files under
   `/sys/module/qcom_scm/parameters/` and verifies each can be read without an
   I/O error. Logs the name and current value of each parameter (e.g.
   `download_mode`).

6. **Device uevent / modalias** — Reads the `uevent` file of the bound device and
   validates that a `MODALIAS` entry is present, confirming correct udev/hotplug
   registration.

7. **TEE / TrustZone device node — Checks for the character devices /dev/tee0
	and /dev/teepriv0. These are created by the TEE subsystem when CONFIG_TEE
	is enabled. Absence is logged as a warning only and does not fail the test.

---

## Prerequisites

| Requirement | Notes |
|-------------|-------|
| `CONFIG_QCOM_SCM=y` or `CONFIG_QCOM_SCM=m` | Test is **failed** if this config is absent |
| `grep`, `find` | Test is **skipped** if these utilities are missing |
| `/proc/config.gz` readable | Required by `check_kernel_config()` |
| Root access | Required to read some sysfs power and uevent paths |

---

## Usage

### Quick start

```sh
git clone <this-repo>
cd <this-repo>
scp -r Runner user@<target_ip>:<path_on_device>
ssh user@<target_ip>
cd <path_on_device>/Runner && ./run-test.sh shmbridge
```

### Run directly on the device

```sh
cd Runner
./run-test.sh shmbridge
```

---


## Sample Log

### PASS output
```
[INFO] 2026-05-08 05:07:27 - -----------------------------------------------------------------------------------------
[INFO] 2026-05-08 05:07:27 - -------------------Starting shmbridge Testcase----------------------------
[INFO] 2026-05-08 05:07:27 - ==== Test Initialization ====
[INFO] 2026-05-08 05:07:27 - Checking if required tools are available...
[INFO] 2026-05-08 05:07:27 - Checking kernel config for CONFIG_QCOM_SCM support...
[PASS] 2026-05-08 05:07:27 - Kernel config CONFIG_QCOM_SCM is enabled
[INFO] 2026-05-08 05:07:27 - --- qcom_scm sysfs module presence ---
[PASS] 2026-05-08 05:07:27 - qcom_scm module directory exists under /sys/module.
[INFO] 2026-05-08 05:07:27 - --- Device Tree firmware/scm node ---
[INFO] 2026-05-08 05:07:27 - /sys/firmware/devicetree/base/firmware/scm
[INFO] 2026-05-08 05:07:27 - /sys/firmware/devicetree/base/firmware/scm
[PASS] 2026-05-08 05:07:27 - Device tree node exists: /sys/firmware/devicetree/base/firmware/scm
[PASS] 2026-05-08 05:07:27 - Device Tree firmware/scm node is present.
[INFO] 2026-05-08 05:07:27 - --- qcom_scm platform driver registration ---
[PASS] 2026-05-08 05:07:27 - qcom_scm platform driver is registered on the platform bus.
[INFO] 2026-05-08 05:07:27 - --- qcom_scm driver-to-device binding ---
[PASS] 2026-05-08 05:07:27 - qcom_scm driver is bound to device: firmware:scm
[INFO] 2026-05-08 05:07:28 - --- qcom_scm sysfs attribute readability ---
[PASS] 2026-05-08 05:07:28 - qcom_scm sysfs attribute readable: download_mode = full
[INFO] 2026-05-08 05:07:28 - --- qcom_scm device uevent/modalias ---
[PASS] 2026-05-08 05:07:28 - qcom_scm device uevent is valid: MODALIAS=of:NscmT(null)Cqcom,scm-sa8775pCqcom,scm
[INFO] 2026-05-08 05:07:28 - --- TEE/TrustZone device node presence ---
[PASS] 2026-05-08 05:07:28 - TEE device node is present: /dev/tee0
[INFO] 2026-05-08 05:07:28 - -----------------------------------------------------------------------------------------
[PASS] 2026-05-08 05:07:28 - shmbridge : PASS - qcom_scm driver validated successfully across all checks.
[INFO] 2026-05-08 05:07:28 - -------------------Completed shmbridge Testcase----------------------------
[PASS] 2026-05-08 05:07:28 - shmbridge passed

[INFO] 2026-05-08 05:07:28 - ========== Test Summary ==========
PASSED:
shmbridge

FAILED:
 None

SKIPPED:
 None
[INFO] 2026-05-08 05:07:28 - ==================================
```

## License

SPDX-License-Identifier: BSD-3-Clause  
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.