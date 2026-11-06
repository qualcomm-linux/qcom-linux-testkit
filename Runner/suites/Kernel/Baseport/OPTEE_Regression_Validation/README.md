# OPTEE_Regression_Validation

Opt-in reviewed OP-TEE mutex, crypto, multi-session and basic OS regressions beyond native smoke.

This is a separate suite. Existing runners, plans and shared helper interfaces retain their current behavior. It uses runtime capability discovery on Yocto, Debian, Ubuntu and CentOS, including shell-only images. Required utilities and optional payloads must be supplied by the image or job. It does not install packages, change boot selection or start services.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--exercise` | `0` |
| `--cases` | `1003,1004,1005,1006` |
| `--xtest` | `xtest` |
| `--ta-dir` | `` |

Options are CLI-only. No new environment-variable overrides are introduced. For Yocto YAML, set `OPTIONS` to the same argument string.

Run from this suite directory:

```sh
./run.sh --exercise 1 --cases 1003,1004
./run.sh --exercise 1 --cases 1005,1006 --ta-dir /opt/optee_armtz --timeout 300
```

Requires native OP-TEE, image-provided `xtest` and its matching TA payloads. The separate reviewed tier allows 1003 (optional core mutex PTA), 1004 (crypto TA), 1005 (concurrent sessions TA) and 1006 (basic OS TA). Other IDs are rejected before execution. No RPMB provisioning, storage reset or full-catalogue invocation is allowed. TA files are searched in `/lib/optee_armtz`, `/usr/lib/optee_armtz` and `--ta-dir`. Non-filesystem embedded TAs are outside this tier's discovery contract. The native smoke allowlist remains unchanged.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/OPTEE_Regression_Validation/run-*`, each invocation starts fresh. The shared result file is `./OPTEE_Regression_Validation.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
