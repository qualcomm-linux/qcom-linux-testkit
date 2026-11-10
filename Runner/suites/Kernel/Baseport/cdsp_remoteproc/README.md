# cdsp_remoteproc

Validates every runtime CDSP remoteproc discovered by the existing DT and
firmware helpers. Requires image-provided tools, works without systemd and does
not install packages. Existing applicability and optional RPMsg checks are retained.

```sh
cd Runner/suites/Kernel/Baseport/cdsp_remoteproc
./run.sh
./run.sh --boot-to 30 --poll-i 1
./run.sh --boot-to 0
```

`--boot-to` sets a passive deadline per discovered instance, default 10 seconds.
Zero requests an immediate state check. `--poll-i` defaults to 1 second and must
be positive. `--boot-to` uses whole decimal seconds without leading zeros, at most
86400. Fractional polling intervals supported by the image's `sleep` are retained. Sleep is capped at the remaining deadline.
Discovery state is refreshed
from sysfs, and a crash observed during discovery or polling remains a failure.

An initially running processor passes immediately when no correlated crash
evidence is found. Offline-to-running without crash evidence is logged as
`startup-delay`. `crash-recovered` remains FAIL, as do a deadline expiry, unreadable
state or confirmed fatal kernel messages. Kernel messages are matched using the
runtime remoteproc ID and controller derived from sysfs. Unrelated sibling errors
do not fail this instance. Missing kernel-log access is warned explicitly, a
state-based PASS does not certify that inaccessible boot history was crash-free.

Diagnostics are retained under the invocation CWD in
`results/cdsp_remoteproc/run-*/<remoteproc-id>/boot/`: `readiness.log`,
`fatal_errors.log`, kernel snapshots/access logs and optional `trace.log`.
Initial state, transitions, elapsed seconds, final state and classification are
printed to the console. The suite result remains `cdsp_remoteproc.res` in this directory.

The passive check never writes start/stop. Existing restart checks remain
explicitly selected by `--ssr`, with `--stop-to` and `--start-to` retaining their
10-second defaults and existing environment overrides. These restart timeouts do
not set the boot deadline. SSR can disturb dependent workloads and should run
only on a suitable validation setup.

```sh
./run.sh --boot-to 30 --ssr --stop-to 10 --start-to 20
```

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

The optional RPMsg subcheck requires an image-provided echo client and a known
service. Set `RPMSG_ECHO_CLIENT` and `RPMSG_ECHO_SERVICE` only for the protocol
implemented by that client. It receives one argument, the discovered endpoint
device owned by the selected DSP, and must return failure when echo validation
fails. Missing optional assets skip that subcheck, no arbitrary data is sent to
unknown channels. For example:

```sh
RPMSG_ECHO_CLIENT=/opt/tests/rpmsg-echo RPMSG_ECHO_SERVICE=echo ./run.sh
```

Explicit SSR writes use bounded stop/start operations and restore only the
instance stopped by the test. Restoration failure affects the final verdict.
Captured fatal blocks remain failures after recovery. Explicit sibling instance
faults are excluded, unassigned remoteproc driver faults remain visible.
