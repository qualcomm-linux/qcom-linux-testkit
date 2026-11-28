Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
SPDX-License-Identifier: BSD-3-Clause

# SoC_Infra_CPU_Current_Freq_Validation

Readability smoke test for the current frequency that each online CPU reports
through cpufreq. For every online CPU, it checks that
`/sys/devices/system/cpu/cpu<N>/cpufreq/scaling_cur_freq` can be read and holds
one positive integer (kHz) within the policy's `cpuinfo_min_freq`..`cpuinfo_max_freq`.

## Coverage

This is readability and format smoke coverage. It catches:

- a `scaling_cur_freq` file that cannot be read;
- a value that is not a single positive integer;
- a value outside the hardware limits of the policy.

It takes one snapshot per CPU. The `cpufreq` directory of a CPU is a link to its
policy, so CPUs of the same policy read the same policy value, and the values can
differ slightly when the frequency changes between two reads. No particular value
is expected and equality within a policy is not checked. The value is not required
to match an entry of `scaling_available_frequencies`, because a driver can report
a rounded or measured frequency that is not in the table. The test does not verify
that the frequency is correct, that it follows the load or the governor, or that a
transition succeeds. Use `CPUFreq_Validation` for policy control and frequency
transitions.

## Prerequisites

- A cpufreq driver bound to the CPUs. cpufreq is optional, so the test skips when
  it is not available.
- No root access is needed. The test only reads sysfs and writes nothing.
- Base utilities: `cat`, `tr`, `grep`, `readlink`. The test never installs
  packages. It skips when a utility is missing.

The test changes no module, service, mount or setting, so there is nothing to
clean up on the device.

## Applicability

Only online CPUs are checked, as listed in `/sys/devices/system/cpu/online`. An
offline CPU is ignored. This also keeps the test away from a policy whose CPUs are
all offline: such a policy can stay in sysfs, but every attribute of it then fails
to read. The cpufreq link of an online CPU always leads to an active policy.

An online CPU that has no `cpufreq` directory is reported in the log and not
checked. It does not fail the test, because cpufreq coverage is a platform choice.

A CPU that goes offline while the test runs can still make its read fail, so do
not run the test together with CPU hotplug tests.

## Usage

The suite has no command-line options and no environment overrides.

```sh
cd Runner
./run-test.sh SoC_Infra_CPU_Current_Freq_Validation
```

It can also be run directly:

```sh
cd Runner/suites/Kernel/Baseport/SoC_Infra_CPU_Current_Freq_Validation
./run.sh
```

## Results and logs

All files are written to the directory the test is started from. That is the suite
directory when the test runs through `run-test.sh`, the LAVA definition, or
`./run.sh` inside the suite directory:

| File | Content |
|---|---|
| `SoC_Infra_CPU_Current_Freq_Validation.res` | Final verdict: `PASS`, `FAIL` or `SKIP` |
| `cpu_current_freqs.log` | One `cpu<N> <policy> <freq>` line per checked CPU, with the frequency in kHz; a bad value shows as `READ_ERROR`, `INVALID_VALUE(<value>)` or `OUT_OF_RANGE(<value> not in <min>..<max>)` in place of the frequency |
| `SoC_Infra_CPU_Current_Freq_Validation_stdout_<time>.log` | Captured console output of the run |

The lines of `cpu_current_freqs.log` are also replayed in the console output with
the `[CPU-CURRENT-FREQ-KHZ]` label, so a LAVA job log shows every CPU, its policy
and its current frequency in kHz.

These files are runtime output and must not be committed.

## PASS, FAIL and SKIP

| Verdict | Condition |
|---|---|
| PASS | At least one online CPU exposes `scaling_cur_freq`, and every online CPU that does reports one positive integer within its `cpuinfo_min_freq`..`cpuinfo_max_freq`. |
| FAIL | An online CPU exposes the file but it cannot be read, is not a single positive integer, or is outside the policy's hardware limits. |
| FAIL | The report file cannot be created in the current directory. |
| SKIP | No online CPU has a cpufreq directory that exposes `scaling_cur_freq`. |
| SKIP | A required base utility is missing. |

The value is validated with `is_unsigned_number` exactly as read. Only the trailing
newline is dropped, so embedded or surrounding whitespace makes the value invalid.
The hardware limits are used only when both can be read as integers.

## LAVA publication

The LAVA definition publishes the result with
`send-to-lava.sh SoC_Infra_CPU_Current_Freq_Validation.res --strict --expected-testcase-id SoC_Infra_CPU_Current_Freq_Validation`.
If `run.sh` exits early and leaves no valid result, the publish step fails instead
of reporting nothing. The step is the last one in the definition, so its failure
status is kept.
