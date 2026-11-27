# Cache coherency stress

Runs stressapptest shared cache-line counter verification with at least two
allowed online CPUs. Requires completed counter increments, native success and
no new kernel faults. Requires stressapptest with `--cc_test` and
`--no_affinity`, plus taskset and setsid. Missing stressapptest is recovered
through configured packages on Debian, Ubuntu and CentOS/RHEL as root when
recovery is enabled. Yocto and `TESTKIT_IMAGE_ONLY=1` remain image-managed,
using PATH and skipping if stressapptest is absent.
Use `--binary /path/to/stressapptest` to select a supplied file, including in
image-only mode. Missing owner execute permission is added when permitted.
Other missing tools and unsupported capabilities skip before execution.

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
