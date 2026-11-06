# CPUFreq_Policy_Stress

Repeated policy frequency feedback, peer-policy coordination and pinned workload timing.

This is a separate suite. Existing runners, plans and shared helper interfaces retain their current behavior. It uses runtime capability discovery on Yocto, Debian, Ubuntu and CentOS, including shell-only images. Required utilities and optional payloads must be supplied by the image or job. It does not install packages, change boot selection or start services.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--exercise` | `0` |
| `--samples` | `5` |
| `--tolerance-percent` | `5` |
| `--load-seconds` | `0` |

Options are CLI-only. No new environment-variable overrides are introduced. For Yocto YAML, set `OPTIONS` to the same argument string.

Run from this suite directory:

```sh
./run.sh --exercise 1 --samples 5
./run.sh --exercise 1 --load-seconds 15 --timeout 60
```

Requires cpufreq sysfs with discrete frequency tables, writable userspace controls and `taskset`. Every changed policy has its governor and min/max limits saved and restored, including readable userspace speed. Policies that were not changed are left alone. Other controllable policies are lowered to avoid shared-rail interference. Frequency sampling requires all requested samples, tolerates the selected percentage and reports hardware or scaling feedback separately. Timing uses a pinned fixed workload with a 35% ratio tolerance. Optional load requires `stress-ng` and schedutil, it is not equivalent to a hardware throughput benchmark.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/CPUFreq_Policy_Stress/run-*`, each invocation starts fresh. The shared result file is `./CPUFreq_Policy_Stress.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
