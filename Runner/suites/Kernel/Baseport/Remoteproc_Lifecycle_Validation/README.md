# Remoteproc_Lifecycle_Validation

Runtime lifecycle expectations and retained evidence of recovered remoteproc crashes.

Uses runtime discovery on Yocto, Debian, Ubuntu and CentOS. Missing mapped tools can be installed on Ubuntu, Debian and CentOS through the shared package provider, with installed tools reused. Yocto and `TESTKIT_IMAGE_ONLY=1` use image-provided tools only. Recovery respects `CHECK_DEPS_RECOVER=0` and `Runner/config/pkg_provider.conf`. Native helpers and test assets still require provisioning.

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
