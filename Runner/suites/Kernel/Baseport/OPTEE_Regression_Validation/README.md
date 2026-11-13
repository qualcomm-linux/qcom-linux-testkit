# OPTEE_Regression_Validation

Opt-in reviewed OP-TEE mutex, crypto, multi-session and basic OS regressions beyond native smoke.

Uses runtime discovery on Yocto, Debian, Ubuntu and CentOS. Missing mapped tools can be installed on Ubuntu, Debian and CentOS through the shared package provider, with installed tools reused. Yocto and `TESTKIT_IMAGE_ONLY=1` use image-provided tools only. Recovery respects `CHECK_DEPS_RECOVER=0` and `Runner/config/pkg_provider.conf`. Native helpers and test assets still require provisioning.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--exercise` | `0` |
| `--cases` | `1003,1004,1005,1006` |
| `--xtest` | `xtest` |
| `--ta-dir` | `` |

Direct runs use the CLI options below. Yocto YAML exposes each option as a named parameter. Optional parameters default to `null` and are omitted, preserving runtime discovery and runner defaults.

Run from this suite directory:

```sh
./run.sh --exercise 1 --cases 1003,1004
./run.sh --exercise 1 --cases 1005,1006 --ta-dir /opt/optee_armtz --timeout 300
```

Requires native OP-TEE, image-provided `xtest` and its matching TA payloads. The separate reviewed tier allows 1003 (optional core mutex PTA), 1004 (crypto TA), 1005 (concurrent sessions TA) and 1006 (basic OS TA). Other IDs are rejected before execution. No RPMB provisioning, storage reset or full-catalogue invocation is allowed. TA files are searched in `/lib/optee_armtz`, `/usr/lib/optee_armtz` and `--ta-dir`. Non-filesystem embedded TAs are outside this tier's discovery contract. The native smoke allowlist remains unchanged.

Kernel health uses an exact retained baseline, including a timestamped suffix
after ring rotation. `kernel-after/kernel_delta.log`, `kernel_delta_status.log`
and `kernel_errors.log` retain comparison details and appended records. Lost
continuity SKIPs kernel health, captured newer faults still FAIL. Selected OP-TEE
case results remain independently assessed.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/OPTEE_Regression_Validation/run-*`, each invocation starts fresh. The shared result file is `./OPTEE_Regression_Validation.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.


Yocto parameters:

The Yocto definition explicitly selects `EXERCISE=1`. Direct invocation retains the passive `--exercise 0` default.

| Parameter | Default | CLI option |
| --- | --- | --- |
| `TIMEOUT` | `60` | `--timeout` |
| `EXERCISE` | `1` | `--exercise` |
| `CASES` | `1003,1004,1005,1006` | `--cases` |
| `XTEST` | `null` | `--xtest` |
| `TA_DIR` | `null` | `--ta-dir` |

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
