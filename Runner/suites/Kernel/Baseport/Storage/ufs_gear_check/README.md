# UFS Gear Validation
## Overview

This shell script executes on the DUT (Device-Under-Test) and verifies the UFS Gear based on the UFS spec supported by the device on application of load to UFS driver.

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of `CONFIG_SCSI_UFS_QCOM`, `CONFIG_SCSI_UFSHCD` and entries in `/proc/config.gz`.

2. **Read UFS Specification Version**:
    - Reads the UFS specification version from `/sys/devices/platform/soc@0/1d84000.ufs/device_descriptor/specification_version`
    - Based on the UFS specification version decides the max operating gear.

2. **Runtime Verification**:
   - Checks `/sys/devices/platform/soc@0/1d84000.ufs/power_info/gear` on application of load whether the operating gear is same as max supported gear.

## How to Run

```sh
source init_env
cd suites/Kernel/Baseport/Storage/ufs_gear_lane
./run.sh
```

## Prerequisites

- `dd`, `grep`, `sleep`, `findmnt`, `awk` must be available
- Root access may be required for complete validation

## Result Format

Test result will be saved in `ufs_gear_check.res` as:
- `UFS Gear Validation Successful. Test Passed` – if all validations pass
- `UFS Gear did not reach max gear on load. Test Failed` – if any check fails

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
```