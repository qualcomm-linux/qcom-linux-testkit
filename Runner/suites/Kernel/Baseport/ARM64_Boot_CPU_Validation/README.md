# ARM64_Boot_CPU_Validation

Validate the physical boot CPU identity recorded by the Arm64 kernel.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/ARM64_Boot_CPU_Validation/run-*` and the result is `ARM64_Boot_CPU_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--expected-mpidr` | `unset` | Expected physical boot CPU MPIDR in hexadecimal |

Run early enough to retain the boot log. The expected MPIDR comes from the firmware/job contract, not a board-name lookup or the current CPU list.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
