# KVM runtime readiness

Run `./run.sh` from this directory with image-provided cat, grep, awk, sed, tr,
mkdir, uname and readlink. No Python, QEMU or package installation is required.
Checks required KVM configuration, accessible /dev/kvm and captured EL2/HYP
initialization errors. Missing expected device/configuration or initialization
errors FAIL. Missing inventory tools SKIP. Artifacts remain under CWD
`results/KVM_Runtime_Validation/run-*`.

This focused readiness result does not replace KVM_Driver ioctl or KVM_Infra
QEMU execution. Those tests still SKIP when their optional clients are absent.
Works on Yocto, Debian, Ubuntu and CentOS, independent of the init manager.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
