# KVM_Guest_Lifecycle_Validation

Boot an isolated Linux KVM guest, execute a console command and verify clean shutdown.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/KVM_Guest_Lifecycle_Validation/run-*` and the result is `KVM_Guest_Lifecycle_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--binary` | `unset` | Installed lkvm executable, otherwise PATH discovery |
| `--kernel` | `/opt/kvm-guest/Image` | Image-provided guest kernel |
| `--initrd` | `/opt/kvm-guest/initramfs.cpio.gz` | Guest initramfs with the kvm-guest ready protocol |
| `--vcpus` | `unset` | Guest CPU count, otherwise up to two online host CPUs |
| `--memory` | `256` | Guest memory in MiB |
| `--timeout` | `120` | Overall guest boot, command and shutdown deadline in seconds |

Requires an Arm64 image with `lkvm`, Python 3, `setsid`, `/dev/kvm`,
and matching guest kernel/initramfs assets. The guest init must print
`kvm-guest: ready vcpus=N ...`, accept shell commands on the virtio console and
support `poweroff -f`. No network, host disk or host filesystem is attached.

Run on an isolated target with enough memory. The memory precheck reserves at
least half of currently available host memory. Missing assets skip. Guest boot,
CPU-count, command-response, shutdown and host kernel faults fail. A software
emulator is not substituted for KVM. Console and stage evidence are retained.


Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
