# Freq_Scaling

Validate image-provided CPUFreq policies on Yocto, Debian, Ubuntu, CentOS and
ramdisk systems. No packages are installed and no SoC or CPU index is assumed.

```sh
cd Runner/suites/Kernel/DCVS/Freq_Scaling
./run.sh
```

The test selects online members of each runtime policy. Offline policies are
skipped. When userspace frequency control is available, it exercises all distinct
advertised frequencies within the original policy limits. It checks
each write and polls observed frequency for up to five seconds, allowing 5%
measurement variation. A rejected write, invalid evidence, missing selected
policy attribute or failure to observe the requested frequency is FAIL. Thermal
or driver limits can therefore cause a real functional failure and are not
silently ignored.

Without discrete userspace control, it exercises advertised alternative governors
and reports governor-control coverage only. It does not claim a frequency
transition from an inventory check. No exercisable policies or controls is SKIP,
never an all-skipped PASS. Root or equivalent sysfs write access is required.

Each selected control is exercised with a two-second workload pinned to a schedulable online member. Image-provided taskset is required for this load coverage. Missing taskset or no schedulable member is SKIP.

Before mutation, it saves the governor and min/max limits, plus the current
userspace request when applicable. It restores them on success, failure and
catchable signals, checks restoration, and fails if restoration is incomplete.
Limits are written in an order that avoids min exceeding max. SIGKILL or device
power loss cannot run shell cleanup.

Evidence is retained in a unique directory under CWD/results/Freq_Scaling and printed
to stdout. The LAVA result remains next to run.sh as Freq_Scaling.res. Both launch
from Runner and direct suite-directory execution are supported. Base utilities
sh, cat, grep, awk, date, mkdir and mktemp must come from the image.

SPDX-License-Identifier: BSD-3-Clause(C) Qualcomm Technologies, Inc. and/or its subsidiaries.
