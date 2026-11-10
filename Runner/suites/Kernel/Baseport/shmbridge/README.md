Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# SCM and shared-memory bridge validation

This test checks `CONFIG_QCOM_SCM`, runtime SCM evidence and the captured
current-boot kernel log. It uses the shared `scan_dmesg_errors` helper once,
retaining errors for SCM, the shared-memory bridge and its TZ memory allocator.
Timestamp/thread prefixes and driver-instance names are supported. Kernel BUG,
warning, oops and panic blocks fail when their header or stack identifies the
selected driver. A module appearing only in the loaded-module list or a later
unrelated log message does not attribute that fault to SCM.

The test reads runtime state. It does not format partitions, provision storage,
restart drivers or perform a secure-memory allocation workload. The existing
YAML invocation and testcase ID remain `shmbridge`.

## Run

Use image-provided tools on Yocto, Debian, Ubuntu, CentOS or shell-only ramdisk.
The script has no command-line parameters and does not install packages.
Kernel configuration discovery uses the existing shared helper, including
`/proc/config.gz` and readable image-provided config fallbacks. The scanner uses
preinstalled shell, grep, cat, sed, mkdir, mktemp, date, wc, tr, id and cp.
Restricted kernel-log access requires the appropriate privileges. The existing
`KERNEL_LOG_JOURNAL_FALLBACK=1` opt-in permits an installed journalctl fallback.

```sh
# Run from the suite directory.
cd Runner/suites/Kernel/Baseport/shmbridge
./run.sh

# Alternatively, from Runner, keep diagnostics under Runner/results/shmbridge.
./suites/Kernel/Baseport/shmbridge/run.sh

# Allow the existing journal fallback when direct kernel-log access is restricted.
KERNEL_LOG_JOURNAL_FALLBACK=1 ./run.sh
```

`shmbridge.res` stays beside `run.sh`. PASS means SCM runtime evidence exists
and the captured log contains no selected error. A selected kernel fault or
missing SCM evidence with an accessible log produces FAIL. Missing tools,
unavailable kernel configuration or disabled SCM produces SKIP. Once SCM
validation is selected, unavailable kernel-log access produces FAIL, whether
or not SCM runtime evidence was found. A required health check cannot complete
from an empty error file. Inspect `dmesg_access.log` for the capture failure
and the privileges or image tools needed to obtain the log.

Each invocation stores `dmesg_snapshot.log`, `dmesg_errors.log`, access
information and timestamped error history under
`$PWD/results/shmbridge/run-*/`. Failure evidence is printed to stdout. A new
run uses fresh artifacts, so a previous PASS or FAIL cannot supply its verdict.
