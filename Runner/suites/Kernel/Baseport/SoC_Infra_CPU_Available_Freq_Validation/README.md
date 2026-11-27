Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# SoC_Infra_CPU_Available_Freq_Validation

Readability smoke test for the frequency list that each cpufreq policy advertises.
For every `/sys/devices/system/cpu/cpufreq/policy*` that exposes
`scaling_available_frequencies`, it checks that the list can be read, is not
empty, and holds only positive integers (kHz) within the policy's
`cpuinfo_min_freq`..`cpuinfo_max_freq`.

## Coverage

This is readability and format smoke coverage. It catches:

- a `scaling_available_frequencies` file that cannot be read or is empty;
- a list entry that is not a positive integer;
- a list entry outside the hardware limits of the policy.

It does not verify that the CPU can run at any listed frequency, that a frequency
transition succeeds, that the list is complete or ordered, or the current
frequency. Use `CPUFreq_Validation` for policy control and frequency transitions.

## Prerequisites

- A cpufreq driver bound to the CPUs. cpufreq is optional, so the test skips when
  it is not available.
- No root access is needed. The test only reads sysfs and writes nothing.
- Base utilities: `cat`, `tr`, `grep`, `readlink`. The test never installs
  packages. It skips when a utility is missing.

The test changes no module, service, mount or setting, so there is nothing to
clean up on the device.

## Applicability

Each policy covers every CPU that shares it (`related_cpus`). The test checks each
policy once, whatever the number of CPUs it covers.

A policy whose CPUs are all offline can stay in sysfs, but every attribute of it
then fails to read. The test therefore checks only policies that have at least one
online CPU, found through the `cpufreq` link of each online CPU, and reports the
others as offline. A CPU that goes offline while the test runs can still make its
policy unreadable, so do not run it together with CPU hotplug tests.

Some drivers do not provide a frequency table and then do not expose
`scaling_available_frequencies`. Such a policy is not checked.

## Usage

The suite has no command-line options and no environment overrides.

```sh
cd Runner
./run-test.sh SoC_Infra_CPU_Available_Freq_Validation
```

It can also be run directly:

```sh
cd Runner/suites/Kernel/Baseport/SoC_Infra_CPU_Available_Freq_Validation
./run.sh
```

## Results and logs

All files are written to the directory the test is started from. That is the suite
directory when the test runs through `run-test.sh`, the LAVA definition, or
`./run.sh` inside the suite directory:

| File | Content |
|---|---|
| `SoC_Infra_CPU_Available_Freq_Validation.res` | Final verdict: `PASS`, `FAIL` or `SKIP` |
| `cpu_available_freqs.log` | One `<policy> <freq> <freq> ...` line per checked policy, with frequencies in kHz; a bad list shows as `READ_ERROR`, `EMPTY`, `INVALID_VALUE(<token>)` or `OUT_OF_RANGE(<token> not in <min>..<max>)` |
| `SoC_Infra_CPU_Available_Freq_Validation_stdout_<time>.log` | Captured console output of the run |

The lines of `cpu_available_freqs.log` are also replayed in the console output with
the `[CPU-AVAILABLE-FREQ-KHZ]` label, so a LAVA job log shows every policy and its
advertised frequencies in kHz.

These files are runtime output and must not be committed.

## PASS, FAIL and SKIP

| Verdict | Condition |
|---|---|
| PASS | At least one online policy exposes `scaling_available_frequencies`, and every online policy that does advertises a non-empty list of positive integers within its `cpuinfo_min_freq`..`cpuinfo_max_freq`. |
| FAIL | A policy exposes the file but it cannot be read, is empty, holds an entry that is not a positive integer, or holds an entry outside the policy's hardware limits. |
| FAIL | The report file cannot be created in the current directory. |
| SKIP | There is no cpufreq policy under `/sys/devices/system/cpu/cpufreq`. |
| SKIP | No online policy exposes `scaling_available_frequencies`. |
| SKIP | A required base utility is missing. |

Each entry is validated with `is_unsigned_number` exactly as read. The order of
the list and duplicate entries are not checked, because the table order is up to
the driver. The hardware limits are used only when both can be read as integers.

## LAVA publication

The LAVA definition publishes the result with
`send-to-lava.sh SoC_Infra_CPU_Available_Freq_Validation.res --strict --expected-testcase-id SoC_Infra_CPU_Available_Freq_Validation`.
If `run.sh` exits early and leaves no valid result, the publish step fails instead
of reporting nothing. The step is the last one in the definition, so its failure
status is kept.
