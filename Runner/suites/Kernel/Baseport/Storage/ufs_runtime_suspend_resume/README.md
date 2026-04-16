# UFS Runtime Suspend/Resume Validation
## Overview

This shell script executes on the DUT (Device-Under-Test) and verifies the UFS Runtime Suspend/Resume functionality on load and no-load conditions.

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of `CONFIG_SCSI_UFS_QCOM`, `CONFIG_SCSI_UFSHCD` and entries in `/proc/config.gz`.

2. **UFS Runtime Status Verification**:
   - Checks the UFS runtime status in `/sys/devices/platform/soc@0/*ufs*/power/runtime_status`
   - Verifies the runtime status is "active" during I/O load
   - Verifies the runtime status transitions to "suspended" after an idle period

3. **Runtime Verification**:
   - Generates I/O load using `dd` command and monitors runtime status
   - Creates an idle time to allow runtime suspend
   - Validates proper state transitions between active and suspended states

## How to Run

```sh
source init_env
cd suites/Kernel/Baseport/Storage/ufs_runtime_suspend_resume
./run.sh
```

## Prerequisites

- `dd`, `grep`, `cut`, `head`, `tail`, `udevadm`, `sleep` must be available
- Root access may be required for complete validation

## Result Format

Test result will be saved in `ufs_runtime_suspend_resume.res` as:
- `ufs_runtime_suspend_resume PASS` – if runtime status is active on application of load & suspended when idle
- `ufs_runtime_suspend_resume FAIL` – if any check fails

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
```