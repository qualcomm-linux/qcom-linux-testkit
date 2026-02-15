# UFS Hibern8 Validation
## Overview

This shell script executes on the DUT (Device-Under-Test) and verifies the UFS Hibern8/Active state transitions on load and no-load conditions.

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of `CONFIG_SCSI_UFS_QCOM`, `CONFIG_SCSI_UFSHCD` and entries in `/proc/config.gz`.

2. **UFS Link State Verification**:
   - Checks the UFS link state in `/sys/bus/platform/devices/*ufs*/power_info/link_state`
   - Verifies the link state is "ACTIVE" during I/O load
   - Verifies the link state transitions to "HIBERN8" after an idle period

3. **Runtime Verification**:
   - Generates I/O load using `dd` command and monitors link state
   - Creates an idle time to allow Hibern8 entry
   - Validates proper state transitions between active and hibernation states

## How to Run

```sh
source init_env
cd suites/Kernel/Baseport/Storage/ufs_hibern8
./run.sh
```

## Prerequisites

- `dd`, `grep`, `dmesg`, `cut`, `head`, `tail`, `udevadm`, `sleep` must be available
- Root access may be required for complete validation

## Result Format

Test result will be saved in `ufs_hibern8.res` as:
- `ufs_hibern8 PASS` – if link state is ACTIVE on application of load & HIBERN8 when idle
- `ufs_hibern8 FAIL` – if any check fails

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
```