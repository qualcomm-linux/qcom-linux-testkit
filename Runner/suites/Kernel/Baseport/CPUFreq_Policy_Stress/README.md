# CPUFreq_Policy_Stress

Repeated policy frequency feedback, peer-policy coordination and pinned workload timing.

Uses runtime discovery on Yocto, Debian, Ubuntu and CentOS. Missing mapped tools can be installed on Ubuntu, Debian and CentOS through the shared package provider, with installed tools reused. Yocto and `TESTKIT_IMAGE_ONLY=1` use image-provided tools only. Recovery respects `CHECK_DEPS_RECOVER=0` and `Runner/config/pkg_provider.conf`. Native helpers and test assets still require provisioning.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--exercise` | `0` |
| `--samples` | `5` |
| `--tolerance-percent` | `5` |
| `--load-seconds` | `0` |

Direct runs use the CLI options below. Yocto YAML exposes each option as a named parameter. Optional parameters default to `null` and are omitted, preserving runtime discovery and runner defaults.

Run from this suite directory:

```sh
./run.sh --exercise 1 --samples 5
./run.sh --exercise 1 --load-seconds 15 --timeout 60
```

Requires cpufreq sysfs with discrete frequency tables, writable userspace controls and `taskset`. Every changed policy has its governor and min/max limits saved and restored, including readable userspace speed. Policies that were not changed are left alone. Other controllable policies are lowered to avoid shared-rail interference. Before measurement, a busy policy CPU must report two consecutive observations within the selected tolerance. Settling and all requested measured samples share one `--timeout` deadline. Settling observations are retained in `<policy>-<min|max>-settling.log`, measured values remain in `<policy>-<min|max>.log`. All measured samples must satisfy the original tolerance, sustained mismatches, malformed feedback and deadline expiry fail. Command and timeout diagnostics are retained in `<policy>-<min|max>.stderr.log`, separate from numeric samples. Hardware or scaling feedback is reported separately. Timing uses a pinned fixed workload with a 35% ratio tolerance. Optional load requires `stress-ng` and schedutil, it is not equivalent to a hardware throughput benchmark.

Cleanup stops owned load and hotplug workers before restoring state. If a worker cannot be stopped, restoration is deferred and the run fails. Unfinished cleanup is retained for one final exit attempt, an earlier failure remains FAIL even if that attempt succeeds.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/CPUFreq_Policy_Stress/run-*`, each invocation starts fresh. The shared result file is `./CPUFreq_Policy_Stress.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.


Yocto parameters:

The Yocto definition explicitly selects `EXERCISE=1`. Direct invocation retains the passive `--exercise 0` default.

| Parameter | Default | CLI option |
| --- | --- | --- |
| `TIMEOUT` | `60` | `--timeout` |
| `EXERCISE` | `1` | `--exercise` |
| `SAMPLES` | `5` | `--samples` |
| `TOLERANCE_PERCENT` | `5` | `--tolerance-percent` |
| `LOAD_SECONDS` | `null` | `--load-seconds` |

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
