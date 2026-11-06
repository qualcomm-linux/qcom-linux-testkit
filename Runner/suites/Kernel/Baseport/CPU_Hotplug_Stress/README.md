# CPU_Hotplug_Stress

Repeated secondary-CPU hotplug, optional batch and concurrent phases, with online-mask restoration.

This is a separate suite. Existing runners, plans and shared helper interfaces retain their current behavior. It uses runtime capability discovery on Yocto, Debian, Ubuntu and CentOS, including shell-only images. Required utilities and optional payloads must be supplied by the image or job. It does not install packages, change boot selection or start services.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--exercise` | `0` |
| `--rounds` | `3` |
| `--batch` | `0` |
| `--concurrent` | `0` |
| `--load-seconds` | `0` |

Options are CLI-only. No new environment-variable overrides are introduced. For Yocto YAML, set `OPTIONS` to the same argument string.

Run from this suite directory:

```sh
./run.sh --exercise 1 --rounds 3
./run.sh --exercise 1 --batch 1 --concurrent 1 --load-seconds 600
```

Requires writable hotplug controls and `taskset`. Keeps the lowest runtime-online CPU permitted by the process affinity/cpuset available. Only initially online secondary CPUs in that permitted set are changed. Batch and concurrent stress are separate opt-in phases. `stress-ng` is required for a loaded run, choose `--load-seconds` long enough to cover every requested phase. Cleanup restores and verifies the initial online mask.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/CPU_Hotplug_Stress/run-*`, each invocation starts fresh. The shared result file is `./CPU_Hotplug_Stress.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
