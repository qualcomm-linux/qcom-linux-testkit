# KVM_Unit_Test_Validation

Validate image-provided KVM unit tests with hardware acceleration.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/KVM_Unit_Test_Validation/run-*` and the result is `KVM_Unit_Test_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--test-dir` | `unset` | Installed kvm-unit-tests directory, otherwise standard image paths |
| `--tests` | `unset` | Optional space-separated names from the installed test inventory |
| `--timeout` | `900` | Overall execution deadline in seconds |

Provide a trusted, configured and compiled `kvm-unit-tests` bundle, its
configured QEMU or kvmtool runtime, and readable/writable `/dev/kvm`. The suite
does not download or compile test binaries. A minimal ramdisk without these
components skips.

Use bundle and working-directory paths without whitespace. The upstream runner
does not quote its log-rotation paths, so unsupported paths skip before execution.

Default execution retains upstream manual-only and errata exclusions. It does
not enable `--all`. QEMU-only tests remain skipped in a kvmtool bundle. To cover
them, run this suite separately with `--test-dir` pointing to a QEMU-configured
bundle. Every invocation forces `ACCEL=kvm` and retains its own logs.


Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
