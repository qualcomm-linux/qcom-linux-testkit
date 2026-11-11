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

Direct runs use the CLI options below. Yocto YAML exposes each option as a named parameter. Optional parameters default to `null` and are omitted, preserving runtime discovery and runner defaults.

Run from this suite directory:

```sh
./run.sh --exercise 1 --rounds 3
./run.sh --exercise 1 --batch 1 --concurrent 1 --load-seconds 600
```

Requires writable hotplug controls and `taskset`. Keeps the lowest runtime-online CPU permitted by the process affinity/cpuset available. Only initially online secondary CPUs in that permitted set are changed. Batch and concurrent stress are separate opt-in phases. `stress-ng` is required for a loaded run, choose `--load-seconds` long enough to cover every requested phase. Cleanup restores and verifies the initial online mask.

Cleanup stops owned load and hotplug workers before restoring state. If a worker cannot be stopped, restoration is deferred and the run fails. Unfinished cleanup is retained for one final exit attempt, an earlier failure remains FAIL even if that attempt succeeds.

Kernel health compares complete snapshots and accepts ring rotation only when
an exact timestamped baseline suffix remains. `kernel-after/kernel_delta.log`,
`kernel_delta_status.log` and `kernel_errors.log` retain appended evidence and
comparison details. Lost continuity SKIPs kernel health, captured newer faults
still FAIL. Functional hotplug results remain separately assessed.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/CPU_Hotplug_Stress/run-*`, each invocation starts fresh. The shared result file is `./CPU_Hotplug_Stress.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.


Yocto parameters:

The Yocto definition explicitly selects `EXERCISE=1`. Direct invocation retains the passive `--exercise 0` default.

| Parameter | Default | CLI option |
| --- | --- | --- |
| `TIMEOUT` | `60` | `--timeout` |
| `EXERCISE` | `1` | `--exercise` |
| `ROUNDS` | `3` | `--rounds` |
| `BATCH` | `null` | `--batch` |
| `CONCURRENT` | `null` | `--concurrent` |
| `LOAD_SECONDS` | `null` | `--load-seconds` |

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
