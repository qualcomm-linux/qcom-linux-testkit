# CPU_Boot_Online_Validation

Validate first online transitions for CPUs excluded by maxcpus at boot.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/CPU_Boot_Online_Validation/run-*` and the result is `CPU_Boot_Online_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--exercise` | `0` | Set 1 only on an isolated fresh boot with maxcpus=N |

Run this test before any CPU hotplug or stress suite on an isolated Arm64 boot with maxcpus=N, where N is below the present CPU count. Set EXERCISE=1 in its YAML only for that boot variant. The test restores initially offline CPUs, so a rerun can no longer prove first startup and skips. Kernel capability conflicts remain failures with evidence, they are not retried into PASS. nr_cpus is a different hard limit and does not replace maxcpus.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
