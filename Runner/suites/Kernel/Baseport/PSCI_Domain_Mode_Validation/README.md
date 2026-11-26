# PSCI_Domain_Mode_Validation

Validate the PSCI CPU power-domain coordination mode reported by the kernel.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/PSCI_Domain_Mode_Validation/run-*` and the result is `PSCI_Domain_Mode_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--expected-mode` | `unset` | Optional OSI or PC coordination contract |

A cpuidle directory alone does not prove the PSCI coordination mode. This checks domain initialization, while residency and suspend recovery need separate functional tests.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
