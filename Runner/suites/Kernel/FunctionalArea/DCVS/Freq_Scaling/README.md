# DCVS Frequency Scaling Validation Test

This test validates the DCVS support and runtime status on Qualcomm platforms with Yocto builds.

## Overview

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of `CONFIG_CPU_FREQ`, `CONFIG_CPU_FREQ_GOV_PERFORMANCE` and `CONFIG_CPU_FREQ_GOV_SCHEDUTIL*` entries in `/proc/config.gz`.

2. **Runtime Verification**:
   - Checks `/sys/devices/system/cpu/cpu0/cpufreq` before and after a load is applied.

## How to Run

```sh
source init_env
cd suites/Kernel/FunctionalArea/DCVS/Freq_Scaling
./run.sh
```

## Prerequisites

- `dmesg`, `grep`, `zgrep`, `lsmod` must be available
- Root access may be required for complete validation

## Result Format

Test result will be saved in `Freq_Scaling.res` as:
- `DCVS scaling appears functional. Test Passed` – if all validations pass
- `DCVS did not scale as expected. Test Failed` – if any check fails

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.
