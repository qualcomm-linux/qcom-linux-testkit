# Kernel_Build_Validation

Validate the running kernel release against the deployment contract.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/Kernel_Build_Validation/run-*` and the result is `Kernel_Build_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--expected-release` | `unset` | Exact expected uname -r value |

Use the complete release, including any source-revision and applied-patch suffix. This checks kernel identity, not rootfs or bootloader identity.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
