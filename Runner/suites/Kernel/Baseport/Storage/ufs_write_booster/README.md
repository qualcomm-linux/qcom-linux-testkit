# UFS Write Booster Validation
## Overview

This shell script executes on the DUT (Device-Under-Test) and verifies the UFS Write Booster feature activation on application of write load to UFS driver.

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of `CONFIG_SCSI_UFS_QCOM`, `CONFIG_SCSI_UFSHCD` and entries in `/proc/config.gz`.

2. **Read UFS Specification Version**:
   - Reads the UFS specification version from `/sys/devices/platform/soc@0/*ufs*/device_descriptor/specification_version`
   - Verifies the UFS specification version is 3.1 (0x0310) or higher, which supports Write Booster feature

3. **Runtime Verification**:
   - Checks `/sys/devices/platform/soc@0/*ufs*/devfreq/*ufs*/device/wb_on` on application of load
   - Verifies Write Booster is enabled (value = 1) during write operations

## How to Run

```sh
source init_env
cd suites/Kernel/Baseport/Storage/ufs_write_booster
./run.sh
```

## Prerequisites

- `dd`, `grep`, `cut`, `head`, `tail`, `udevadm`, `sleep` must be available
- Root access may be required for complete validation

## Result Format

Test result will be saved in `ufs_write_booster.res` as:
- `ufs_write_booster PASS` – if Write Booster is enabled during write operations
- `ufs_write_booster FAIL` – if any check fails

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
```