# CPUFreq_Validation

## Overview

The `CPUFreq_Validation` test validates the CPU frequency scaling capabilities of a system using the Linux `cpufreq` subsystem. It verifies the ability to set and reflect CPU frequencies across shared policy domains (e.g., clusters of CPUs sharing frequency control).

This test is designed to be **SoC-agnostic**, supporting platforms with per-policy frequency management (e.g., Qualcomm SoCs with `policy0`, `policy4`, etc.).

## Test Goals

- Ensure all cpufreq policies are present and functional
- Iterate through all available frequencies and validate correct scaling
- Ensure that CPU governors can be set to `userspace`
- Provide robust reporting per policy (e.g., `CPU0-3 [via policy0] = PASS`)
- Avoid flaky failures in CI by using retries and proper checks

## Prerequisites

- Kernel must be built with `CONFIG_CPU_FREQ` and `CONFIG_CPU_FREQ_GOV_USERSPACE`
- `sysfs` access to `/sys/devices/system/cpu/cpufreq/*`
- Root privileges (to write to cpufreq entries)

## Script Location

```
Runner/suites/Kernel/FunctionalArea/baseport/CPUFreq_Validation/run.sh
```

## Files

- `run.sh` - Main test script
- `CPUFreq_Validation.res` - Summary result file with PASS/FAIL
- `CPUFreq_Validation.log` - Full execution log (generated if logging is enabled)

## How It Works

1. The script detects all cpufreq policies under `/sys/devices/system/cpu/cpufreq/`
2. For each policy:
   - Reads the list of related CPUs
   - Attempts to set each available frequency using the `userspace` governor
   - Verifies that the frequency was correctly applied
3. The result is logged per policy
4. The overall test passes only if all policies succeed

## Example Output

```
[INFO] CPU0-3 [via policy0] = PASS
[FAIL] CPU4-6 [via policy4] = FAIL
[INFO] CPU7 [via policy7] = PASS
```

## Return Code

- `0` — All policies passed
- `1` — One or more policies failed

## Integration in CI

- Can be run standalone or via LAVA
- Result file `CPUFreq_Validation.res` will be parsed by `result_parse.sh`

## Notes

- Some CPUs may share frequency domains, so per-core testing is not reliable
- The test includes retries to reduce false failures due to transient conditions

## License

SPDX-License-Identifier: BSD-3-Clause-Clear  
(c) Qualcomm Technologies, Inc. and/or its subsidiaries.

