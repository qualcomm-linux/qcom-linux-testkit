# Rootfs_Build_Validation

Validate the rootfs BUILD_ID against the deployment contract.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/Rootfs_Build_Validation/run-*` and the result is `Rootfs_Build_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--expected-build-id` | `unset` | Exact expected BUILD_ID |
| `--release-file` | `unset` | Optional os-release path, defaults to /etc then /usr/lib/os-release |

An os-release VERSION_ID alone identifies a distribution release, not a unique image build. Images without BUILD_ID skip this test. Metadata is parsed as data and is never sourced.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
