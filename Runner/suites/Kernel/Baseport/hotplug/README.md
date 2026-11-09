# CPU hotplug

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

The suite discovers online CPUs, verifies schedulability, exercises eligible
offline/online controls and restores only CPUs offlined by this invocation.
It requires root and image-provided utilities, no systemd or debugfs mount.
Persistent failures, kernel faults and incomplete restoration remain FAIL.

`HOTPLUG_SUITE_TIMEOUT_SECONDS` defaults to 300 seconds. Offline writes and retry
waits respect the remaining deadline. Online restoration still runs after expiry.
Numeric overrides use whole decimal values without leading zeros. Existing
EBUSY retries, deferred passes and optional `HOTPLUG_CPU_LIST` selection remain.
Logs and process-state diagnostics are retained under the invocation CWD.

```sh
cd Runner/suites/Kernel/Baseport/hotplug
HOTPLUG_SUITE_TIMEOUT_SECONDS=300 ./run.sh
cat hotplug.res
```
