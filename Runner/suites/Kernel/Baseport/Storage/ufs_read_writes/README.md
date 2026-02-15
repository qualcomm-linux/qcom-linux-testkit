# UFS Read/Writes
## Overview

This shell script executes on the DUT (Device-Under-Test) and verifies whether basic UFS file read writes are functional.

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of `CONFIG_SCSI_UFS_QCOM`, `CONFIG_SCSI_UFSHCD` and entries in `/proc/config.gz`.

2. **UFS Block Device Detection**:
   - Detects UFS block devices using `detect_ufs_partition_block()`
   - Verifies the detected block is not the root filesystem

3. **Runtime Verification**:
   - Performs basic read test on the UFS block device using `dd`
   - Runs I/O stress test with 64MB read and write operations on a temporary file

## How to Run

```sh
source init_env
cd suites/Kernel/Baseport/Storage/ufs_read_writes
./run.sh
```

## Prerequisites

- `dd`, `grep`, `cut`, `head`, `tail`, `udevadm` must be available
- Root access may be required for complete validation

## Result Format

Test result will be saved in `ufs_read_writes.res` as:
- `ufs_read_writes PASS` – if read/writes are successful
- `ufs_read_writes FAIL` – if any check fails

## License

```
Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause-Clear
```