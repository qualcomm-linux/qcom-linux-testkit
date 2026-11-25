# Early_Memory_Test_Validation

Validate completed kernel early memory testing and retained pattern coverage.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/Early_Memory_Test_Validation/run-*` and the result is `Early_Memory_Test_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--expected-passes` | `unset` | Optional positive expected pattern-pass count |

Boot the isolated test image with CONFIG_MEMTEST=y and memtest=N before running this suite. The suite never changes boot arguments or runs a userspace memory stress tool. A bare memtest uses the current kernel pattern count. Only early free-memory ranges are tested, this does not claim coverage of all installed RAM.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
