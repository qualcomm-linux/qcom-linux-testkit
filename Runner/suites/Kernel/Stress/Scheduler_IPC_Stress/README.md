# Scheduler and IPC stress

Runs stress-ng context-switch, futex and pipe workloads together. Requires
positive completed operations from all three, native success and no new kernel
faults. Image-provided stress-ng, taskset and setsid are required on Yocto,
Debian, Ubuntu and CentOS. Unsupported stressors skip before execution.

```sh
./run.sh --duration 3600 --repeat 8
```

`--workers` controls instances per stressor, defaulting to the allowed online
CPU count. Workers can spawn children. `--cpu-list` restricts the CPU set.
Set LAVA deadlines above the total duration plus setup/cleanup allowances.
Logs remain under `logs/`, and failure or cancellation prevents PASS.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
