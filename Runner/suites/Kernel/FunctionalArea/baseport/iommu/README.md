# IOMMU Validation Test

This test validates the IOMMU (Input-Output Memory Management Unit) support and runtime status on Qualcomm platforms with Yocto builds.

## Overview

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of `CONFIG_IOMMU_SUPPORT` and `CONFIG_ARM_SMMU*` entries in `/proc/config.gz`.

2. **Driver Loading**:
   - Confirms SMMU/IOMMU-related drivers are loaded via `/proc/modules`.

3. **Device Tree Nodes**:
   - Verifies IOMMU/SMMU-related nodes in `/proc/device-tree`.

4. **Runtime Verification**:
   - Checks `dmesg` for any runtime IOMMU initialization or fault logs.

## How to Run

```sh
source init_env
cd suites/Kernel/FunctionalArea/IOMMU_Validation
./run.sh
```

## Prerequisites

- `dmesg`, `grep`, `zgrep`, `lsmod` must be available
- Root access may be required for complete validation

## Result Format

Test result will be saved in `IOMMU.res` as:
- `IOMMU PASS` – if all validations pass
- `IOMMU FAIL` – if any check fails

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.
