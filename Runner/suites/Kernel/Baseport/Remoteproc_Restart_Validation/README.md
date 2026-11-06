# Remoteproc_Restart_Validation

Repeated explicit remoteproc stop/start, RPMsg disappearance and complete driver/channel restoration.

This is a separate suite. Existing runners, plans and shared helper interfaces retain their current behavior. It uses runtime capability discovery on Yocto, Debian, Ubuntu and CentOS, including shell-only images. Required utilities and optional payloads must be supplied by the image or job. It does not install packages, change boot selection or start services.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--exercise` | `0` |
| `--processors` | `auto` |
| `--rounds` | `3` |

Options are CLI-only. No new environment-variable overrides are introduced. For Yocto YAML, set `OPTIONS` to the same argument string.

Run from this suite directory:

```sh
./run.sh
./run.sh --exercise 1 --processors adsp,cdsp --rounds 3 --timeout 60
```

Requires both `--exercise 1` and explicit `--processors`. Choose only processors whose lifecycle the test is permitted to change, not a modem or subsystem owned by another active client. Names and stable owner IDs are discovered from sysfs, no SoC mapping is used. Only writable Linux-owned running processors are changed. Each round validates offline/running transitions, removal and restoration of RPMsg channel names/counts/drivers, plus new kernel errors. Empty baseline RPMsg inventory skips the channel assertion. Cleanup restores the initial running state and verifies the original channels and driver bindings. `--timeout` bounds each lifecycle command and channel-restoration wait. Missing explicit selections fail before any processor is changed.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/Remoteproc_Restart_Validation/run-*`, each invocation starts fresh. The shared result file is `./Remoteproc_Restart_Validation.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
