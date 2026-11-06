# CPU CoreSight trace validation

Discover a runtime CPU trace source (ETM or ETE), follow its output connections
through links, and select a connected character-device sink. Sources, sinks and
CPU numbers are discovered from sysfs, with symlinks resolved and cycles guarded.
No board list, etm0, tmc_etr0 or kernel-config-file requirement is used.

```sh
cd Runner/suites/Kernel/Baseport/etm_trace
./run.sh
```

The image must provide taskset and base shell utilities, CPU CoreSight sysfs
controls, a connected sink device and permission to access them. No components
are installed at runtime. Missing optional capability or no schedulable route
is SKIP. Existing active tracing is left untouched and produces SKIP.

For an idle route, the test enables the sink and source, generates finite pinned
CPU activity, stops the source, reads the sink and requires fresh nonempty trace
data. Workload and read commands each have a ten-second watchdog. It verifies
control writes and restores only its own source/sink changes, including after
failure or catchable signals. A selected path failing activation, capture or
restoration is FAIL. SIGKILL and power loss cannot execute shell cleanup.

The test records raw trace presence, not decoded instruction correctness.
route.txt, capture.log and trace.bin are retained under a unique directory below
CWD/results/etm_trace. Capture diagnostics also appear in stdout. The result
remains in the suite directory as etm_trace.res. This uses image-provided
interfaces across Yocto, Debian, Ubuntu, CentOS and ramdisk systems.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
