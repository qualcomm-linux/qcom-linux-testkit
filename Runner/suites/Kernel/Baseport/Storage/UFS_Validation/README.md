# UFS validation

Run from the suite directory on a Yocto, Debian, Ubuntu or CentOS image with
the required tools already installed:

```sh
cd Runner/suites/Kernel/Baseport/Storage/UFS_Validation
./run.sh
```

The suite takes no command-line options. It uses the shared running-kernel
configuration discovery, checks UFS platform devices and discovers a UFS block
device at runtime. It does not install packages or select a board by SoC name.
The runner checks for `dd`, `grep`, `cut`, `head`, `tail` and `udevadm`, and also
uses shell utilities including `awk`, `readlink`, `find` and `sed`. `findmnt`
and `stat` have existing fallback paths.

`CONFIG_SCSI_UFSHCD` and `CONFIG_SCSI_UFS_QCOM` remain mandatory. Missing
mandatory configuration, UFS platform devices or a UFS block device produces
SKIP. A detected block device matching the root filesystem also produces SKIP.
Optional UFS configurations are queried with the shared `kernel_config_value`
helper. Enabled values (`y` or `m`), explicitly disabled values and unreported
options are logged as INFO. An absent optional controller configuration does
not produce a FAIL message or prevent functional validation.

The existing checks read 32 MiB from the selected block device, then write and
read a 64 MiB scratch file in the suite directory and remove it. Scratch-file
I/O exercises the filesystem containing that directory, which need not be UFS.
A failed I/O check remains FAIL. The runner retains its existing kernel-log
capture through `scan_dmesg_errors`.

The verdict is written to `UFS_Validation.res` in the suite directory. The
existing stdout capture and `dmesg_snapshot.log`/`dmesg_errors.log` provide
diagnostics there. To publish the result in a LAVA test shell:

```sh
TMPDIR="$PWD" ../../../../../utils/send-to-lava.sh UFS_Validation.res --strict
```

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

SPDX-License-Identifier: BSD-3-Clause
