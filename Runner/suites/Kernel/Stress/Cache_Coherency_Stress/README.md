# Cache coherency stress

Runs stressapptest shared cache-line counter verification with at least two
allowed online CPUs. Requires completed counter increments, native success and
no new kernel faults. Uses image-provided stressapptest with `--cc_test` and
`--no_affinity`, plus taskset and setsid, on Yocto, Debian, Ubuntu and CentOS.
Unsupported capabilities skip before execution.

```sh
./run.sh --duration 3600 --repeat 8
```

`--cpu-list` restricts scheduling. Native stressapptest chooses its coherency
thread count from configured CPUs. The initialization memory budget is bounded
by current availability, headroom and a configurable 32 MiB cap, it does not
claim a whole-memory integrity test. Set LAVA deadlines above requested load
time plus setup/cleanup allowances. Per-iteration logs remain under `logs/`.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
