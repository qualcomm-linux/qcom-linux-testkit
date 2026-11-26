# Firmware_Build_Validation

Validate the firmware-published BIOS version against the deployment contract.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/Firmware_Build_Validation/run-*` and the result is `Firmware_Build_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--expected-version` | `unset` | Exact expected SMBIOS BIOS version |

This checks the SMBIOS BIOS version only. It does not establish the identity of every secure firmware or boot stage. Firmware with console-only identity needs a LAVA boot-console assertion.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
