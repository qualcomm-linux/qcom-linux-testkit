# CPU_Power_Domain_Residency_Validation

Measure idle residency of runtime-discovered CPU power domains and their parents.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/CPU_Power_Domain_Residency_Validation/run-*` and the result is `CPU_Power_Domain_Residency_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--seconds` | `10` | Read-only observation interval in seconds |
| `--domain-root` | `unset` | Optional pm_genpd directory, otherwise the mounted debugfs |
| `--min-percent` | `unset` | Optional required aggregate idle-residency percentage per domain |

Uses the CPU device links and parent-domain topology in existing `pm_genpd`
debugfs. No debugfs mount, governor change or power-domain write is performed.
`total_idle_time` proves time spent powered down, state entries and rejections
are retained as diagnostics. Missing interfaces skip, counter regression or
kernel faults fail.

Use a quiet target. No observed residency skips by default, or fails an explicit
`--min-percent` requirement. A domain can remain off across the interval without
a new entry, which is valid residency. This measures generic-domain accounting,
it is not a measurement of physical rail power or firmware acceptance.


Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
