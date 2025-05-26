# Scheduler CPU Affinity validation Test

This test validates the Scheduler support and runtime status on Qualcomm platforms with Yocto builds.

## Overview

The test script performs these functional checks:

1. **Kernel Configuration**:
   - Validates presence of `CONFIG_SCHED_DEBUG`, `CONFIG_CGROUP_SCHED` and `CONFIG_SMP*` entries in `/proc/config.gz`.

2. **Runtime Verification**:
   - Checks cpu affinity by creating a CPU-bound background task

## How to Run

```sh
source init_env
cd suites/Kernel/FunctionalArea/Scheduler/CPU_affinity
./run.sh
```

## Prerequisites

- `taskset`, `grep`, `zgrep`, `top`, `chrt` must be available
- Root access may be required for complete validation

## Result Format

Test result will be saved in `CPU_affinity.res` as:
- `Default scheduling policy detected. Test passed` – if all validations pass
- `Unexpected scheduling policy. Test Failed` – if any check fails

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(C) Qualcomm Technologies, Inc. and/or its subsidiaries.
