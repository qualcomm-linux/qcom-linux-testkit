# CPU_Feature_Exposure

Per-CPU EL0/KVM feature exposure, PAC key and guest controls, and vector consistency.

This is a separate suite. Existing runners, plans and shared helper interfaces retain their current behavior. It uses runtime capability discovery on Yocto, Debian, Ubuntu and CentOS, including shell-only images. Required utilities and optional payloads must be supplied by the image or job. It does not install packages, change boot selection or start services.

| Option | Default |
|---|---|
| `--timeout` | `60` |
| `--idregs` | `idregs-arm64` |
| `--feature-table` | `` |
| `--expect` | `` |

Direct runs use the CLI options below. Yocto YAML exposes each option as a named parameter. Optional parameters default to `null` and are omitted, preserving runtime discovery and runner defaults.

Run from this suite directory:

```sh
./run.sh
./run.sh --idregs /usr/bin/idregs-arm64 --feature-table /usr/share/cpu-features/features.txt
./run.sh --expect present:FEAT_SVE,absent:FEAT_SME --feature-table /usr/share/cpu-features/features.txt
```

Requires Arm64 and an image-provided `idregs-arm64` executable with the Open Boot Stack idregs v1 output contract, including `pac` and `vec` modes. No target-side compilation is performed. The suite-local `cpu_feature_decode.awk` decodes the supplied table. The optional nine-column `features.txt` table must match that helper. Expectations come from the build/job, not a SoC table. KVM masking can differ legitimately from EL0. The suite validates each view and exercises guest PAC positive/negative controls, it does not require all guest fields to equal host fields. Mixed address/generic PAC capabilities skip the all-key helper check. Existing arm64 selftest coverage remains in `Kernel_Selftests`.

For fixed-tool ramdisks without this native helper, use the separate
[CPU_Feature_Reporting](../CPU_Feature_Reporting/README.md) suite. It checks
kernel-reported flags and available HWCAP, register and affinity evidence using
existing shell tools. When `idregs-arm64` is installed or supplied with `--idregs`,
it also reuses this suite's native validation functions through `lib_kvm.sh`.
Reporting PASS alone does not replace native PAC, vector-instruction or KVM guest
coverage. The standalone suite retains its existing CLI and missing-helper SKIP
behavior.

PASS requires executed functional evidence. Missing optional utilities, hardware or assets produce an actionable SKIP. Malformed options, failed applicable operations, missing completion evidence, mismatched results or failed state restoration produce FAIL. Logs and temporary files are under `./results/CPU_Feature_Exposure/run-*`, each invocation starts fresh. The shared result file is `./CPU_Feature_Exposure.res`. Kernel snapshots and errors are retained when available.

Reference: [Open Boot Stack scripts](https://github.com/EmbeddedAndroid/test-definitions/tree/ddad80e29f576d8ae95bbea6b209c3c3449bbd87/automated/linux). Source analysis is not DUT validation. State-changing tests require isolated hardware with no competing lifecycle/policy manager.


Yocto parameters:

| Parameter | Default | CLI option |
| --- | --- | --- |
| `TIMEOUT` | `60` | `--timeout` |
| `IDREGS` | `null` | `--idregs` |
| `FEATURE_TABLE` | `null` | `--feature-table` |
| `EXPECT` | `null` | `--expect` |

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
