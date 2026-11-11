# Remoteproc_Lifecycle_Validation

Runtime lifecycle expectations and retained evidence of recovered remoteproc crashes.

This is a separate suite. Existing runners, plans and shared helper interfaces retain their current behavior. It uses runtime capability discovery on Yocto, Debian, Ubuntu and CentOS, including shell-only images. Required utilities and optional payloads must be supplied by the image or job. It does not install packages, change boot selection or start services.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--processors` | `auto` |

Direct runs use the CLI options below. Yocto YAML exposes each option as a named parameter. Optional parameters default to `null` and are omitted, preserving runtime discovery and runner defaults.

Run from this suite directory:

```sh
./run.sh
./run.sh --processors adsp,cdsp
```

Auto-discovery records running/attached instances and skips offline instances with unconfirmed lifecycle ownership. `--processors` requires every selected runtime name or stable owner ID to be registered and running/attached. Duplicate names select all matching instances, stable owner IDs select an individual instance. A recovered crash in retained boot logs fails even when the current state is running. A readable current ring buffer cannot prove history that has already been overwritten.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/Remoteproc_Lifecycle_Validation/run-*`, each invocation starts fresh. The shared result file is `./Remoteproc_Lifecycle_Validation.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.


Yocto parameters:

| Parameter | Default | CLI option |
| --- | --- | --- |
| `TIMEOUT` | `60` | `--timeout` |
| `PROCESSORS` | `null` | `--processors` |

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
