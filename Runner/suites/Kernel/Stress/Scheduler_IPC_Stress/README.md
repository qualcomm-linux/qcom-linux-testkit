# Scheduler and IPC stress

Runs stress-ng context-switch, futex and pipe workloads together. Requires
positive completed operations from all three, native success and no new kernel
faults. Requires stress-ng, taskset and setsid. Missing stress-ng is recovered
through configured packages on Debian, Ubuntu and CentOS/RHEL as root when
recovery is enabled. Yocto and `TESTKIT_IMAGE_ONLY=1` remain image-managed,
using PATH and skipping if stress-ng is absent.
Use `--binary /path/to/stress-ng` to select a supplied file, including in
image-only mode. Missing owner execute permission is added when permitted.
Other missing tools and unsupported stressors skip before execution.

```sh
./run.sh --duration 3600 --repeat 8
```

`--workers` controls instances per stressor, defaulting to the allowed online
CPU count. Workers can spawn children. `--cpu-list` restricts the CPU set.
Set LAVA deadlines above the total duration plus setup/cleanup allowances.
Logs remain under `logs/`, and failure or cancellation prevents PASS.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
