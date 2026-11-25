# CPU_Idle_Residency_Validation

Measure actual idle residency across online CPUs without changing idle policy.

Uses image-provided tools on Yocto, Debian, Ubuntu and CentOS, including ramdisks.
No packages are installed. Missing optional evidence produces SKIP, an observed
mismatch or malformed evidence produces FAIL. Logs are retained under
`results/CPU_Idle_Residency_Validation/run-*` and the result is `CPU_Idle_Residency_Validation.res` in the working directory.

Run `./run.sh --help` for options. Supply expected values from the build or job,
never derive them from the running target being checked.

| Option | Default | Purpose |
| --- | --- | --- |
| `--seconds` | `10` | Read-only observation interval in seconds |
| `--min-percent` | `unset` | Optional required aggregate idle-residency percentage per CPU |

Measures completed idle-state time and records entry/rejection deltas for
every discovered state. A CPU passes only with observed residency in an enabled
state. Unused states and rejected entries alone do not prove a software fault.
No observed residency skips unless `--min-percent` supplies an explicit target
requirement, then missing that requirement fails.

Run on a quiet target. The suite does not disable states, change governors or
offline CPUs. Counter regression and kernel faults fail. Concurrent topology or
idle-policy changes skip as an invalid observation. This extends coverage beyond
the existing idle-attribute/monotonic-counter validation and does not claim that
every state or the deepest state was exercised.


Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause
