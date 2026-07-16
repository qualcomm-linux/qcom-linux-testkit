# kernel module signing & Out-of-tree module validation Test

This test validates the kernel module signing and out-of-tree modules on Qualcomm platforms with Yocto builds.

## Overview

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of `CONFIG_MODULE_SIG` and `CONFIG_MODULE_SIG_FORCE` entries in `/proc/config.gz`.

2. **Runtime Verification**:
   - Checks kernel modules are signed or not. Also checks if there is Out-of-tree module taints the kernel and if that Out-of-tree module is signed or not.

## How to Run

```sh
source init_env
cd suites/Kernel/kmodule_sign_OOT
./run.sh
```

## Prerequisites

- `zcat`, `grep`, `modinfo`, `dmesg`, `find` must be available
- Root access may be required for complete validation

## Result Format

Test result will be saved in `Kernel_Module_Sign_OOT_check.res` as:
- `Kernel_Module_Sign_Check_OOT_check PASSED` – if all validations pass
- `Kernel_Module_Sign_OOT_check FAIL` – if any check fails

## License

SPDX-License-Identifier: BSD-3-Clause(C) Qualcomm Technologies, Inc. and/or its subsidiaries.
