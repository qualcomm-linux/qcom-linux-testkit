# UFS validation

Discovers a block device beneath a bound UFS driver through sysfs, without
requiring udevadm or a board-specific device path. Raw access is read-only,
including when UFS hosts the root filesystem.

```sh
cd Runner/suites/Kernel/Baseport/Storage/UFS_Validation
./run.sh
```

Block reads have a 60-second limit. A 64 MiB file write/read check runs only if
CWD resolves to a filesystem directly backed by UFS. Each operation has a
60-second limit. On ramdisk, overlay or unverified stacked storage, the file
write subcheck is SKIP and the read-only check remains available. No raw writes
or formatting are performed. The temporary file is removed during cleanup.

`UFS_Validation.res` summarizes the checks, any failure takes precedence. A PASS
with the write subcheck skipped reports read-only coverage. Logs and the shared
kernel snapshot are retained under a unique `ufs-validation.*` directory in CWD.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

The file read requires exactly 64 complete 1 MiB records, independently of
the preceding write. Short successful reads remain FAIL with file-read.log.
