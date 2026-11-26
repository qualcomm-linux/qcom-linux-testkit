# ARM64_Boot_Mode_Validation

Validate consistent Arm64 CPU entry exception levels.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/ARM64_Boot_Mode_Validation/run-*` and the result is `ARM64_Boot_Mode_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--expected-mode` | `unset` | Optional EL1 or EL2 contract, otherwise require consistent entry |

EL1 and EL2 are both valid unless the job supplies a specific expectation. This checks kernel entry mode, not successful KVM guest execution.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
