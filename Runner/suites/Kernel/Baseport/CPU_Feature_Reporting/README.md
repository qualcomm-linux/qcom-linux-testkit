# CPU_Feature_Reporting

Validate Arm64 kernel-reported CPU features on Yocto, Debian, Ubuntu and CentOS,
including shell-only ramdisks. The suite uses image-provided tools and never
installs packages, compiles a helper or changes CPU online state. If the image
already provides `idregs-arm64`, native feature validation runs after kernel
reporting. `--idregs` can select another installed executable or disable that
optional native path.

The default checks discover online CPUs, require a complete `Features` entry for
each CPU, and compare their system-wide userspace feature exposure. Arm64 reports
sanitized system capabilities here. Different physical CPU identities are allowed.

When available, the suite decodes the running shell interpreter's auxiliary
vector and compares selected public Arm64 HWCAP bits with `/proc/cpuinfo`.
Decoding uses the interpreter's ELF class and byte order, preserving masks as
hexadecimal strings to avoid 64-bit shell or awk precision loss. A 32-bit
compatibility interpreter retains its raw evidence and skips the Arm64 HWCAP
comparison. CPU identification register files are checked for valid values when
exported. Optional affinity checks run a trivial shell on online CPUs permitted
by the process cpuset, without treating excluded CPUs as broken.

Kernel reporting does not prove PAC or SVE/SME instruction execution, PAC key/fault
controls or KVM guest behavior. When the native helper is available, this suite
reuses the same validation functions as
[CPU_Feature_Exposure](../CPU_Feature_Exposure/README.md), shared through
`lib_kvm.sh`. Native checks and prerequisite skips are logged separately, with
their artifacts under `native/`. A missing optional native helper leaves kernel
reporting usable, without changing the standalone native suite's PASS/SKIP meaning.

| Option | Default | Meaning |
|---|---|---|
| `--timeout` | `60` | Bound each optional tool/affinity command, 1 through 600 seconds |
| `--expect` | unset | Comma-separated `present:flag` or `absent:flag` expectations using `/proc/cpuinfo` names |
| `--idregs` | `auto` | Use installed `idregs-arm64`, an explicit path/command, or `none` for kernel reporting only |
| `--feature-table` | auto-discovered | Optional native Arm feature table, same contract as CPU_Feature_Exposure |
| `--help` | | Show options without executing checks |

Direct runs use CLI options. Yocto YAML exposes named parameters, with `null` for optional overrides so runtime discovery and runner defaults remain active.
Expectations come from the user or CI job, not from a board or SoC table.

From this suite directory:

```sh
./run.sh
./run.sh --timeout 30
./run.sh --expect present:asimd
./run.sh --expect present:sve,absent:sme --timeout 30
./run.sh --idregs none
./run.sh --idregs /usr/bin/idregs-arm64
./run.sh --idregs /usr/bin/idregs-arm64 --feature-table /usr/share/cpu-features/features.txt --expect present:asimd
./run.sh --help
```

The expectation examples are assertions, not defaults. They FAIL if the running
system reports a different feature set. Repeating the same command starts fresh
evidence and revalidates the current runtime CPU population.

Required tools are `sh`, `awk`, `cat`, `tr`, `sort`, `grep` and the normal Runner
bootstrap utilities. `od`, `taskset` and `lscpu` are optional. The saved reference
ramdisk inventory includes these tools, actual availability is checked on the DUT.
No systemd, Git, native CPU helper or feature-table asset is required for kernel
reporting. The optional native helper must implement the existing idregs v1,
`pac` and `vec` contracts. Its matching feature table enables full feature decoding
and vector/register comparisons. Each native invocation uses `--timeout`, allow
the job budget to include the additional native commands when enabling this path.

PASS means the stated reporting assertions completed. Missing optional tools or
unexported register files SKIP only their checks. Unsupported architecture or
missing procfs SKIPs the suite. Malformed arguments, an incomplete online-CPU
feature inventory, failed explicit expectations, malformed present evidence,
HWCAP mismatches or a changed online CPU population produce FAIL. Explicitly
requested missing/non-executable native helpers, failed native execution,
malformed native output and failed native assertions also FAIL. Automatic native
discovery without a helper SKIPs only native coverage. Supplying a feature table
requests native decoding, a missing helper then FAILs, and `--idregs none` with a
feature table is rejected. `--expect` checks kernel flag names, the standalone
native suite retains its `FEAT_*` expectation interface. Missing
`lscpu` or failed optional `lscpu` diagnostics do not replace the actual procfs
and sysfs assertions.

Artifacts and temporary files stay under
`./results/CPU_Feature_Reporting/run-*`. The shared result is
`./CPU_Feature_Reporting.res`, published by the matching YAML. Files include
`cpuinfo.log`, `features.tsv`, available `auxv.tsv`, `hwcap-comparison.tsv`,
`identification.tsv` and bounded command logs. Native validation reuses the `CPU_Feature_Exposure/run.sh` entrypoint in
a dedicated `native/` working directory. Its `CPU_Feature_Exposure.res`, command
logs and decoded `features.tsv` are retained below that directory, reporting
data is preserved. Relative helper and feature-table overrides are resolved
before entering the native working directory.
Native instruction functionality is claimed only by completed native assertions.

Public ABI references:
[Arm64 HWCAP definitions](https://github.com/torvalds/linux/blob/master/arch/arm64/include/uapi/asm/hwcap.h)
and [Arm64 CPU reporting](https://github.com/torvalds/linux/blob/master/arch/arm64/kernel/cpuinfo.c).


Yocto parameters:

| Parameter | Default | CLI option |
| --- | --- | --- |
| `TIMEOUT` | `60` | `--timeout` |
| `IDREGS` | `null` | `--idregs` |
| `FEATURE_TABLE` | `null` | `--feature-table` |
| `EXPECT` | `null` | `--expect` |

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
