# PELT_schedutil — Schedutil Governor PELT Integration Validation

## Overview

Validates the **schedutil cpufreq governor** integration with PELT utilization
signals. Schedutil is the primary governor that translates PELT's per-CPU
`util_avg` into CPU frequency requests, making it the key interface between
the scheduler and the power management subsystem.

## What Is Tested

| Check | Description |
|---|---|
| Governor detection | Identifies all CPU policies using `schedutil` |
| Frequency range | `scaling_min_freq` ≤ `scaling_max_freq` per policy |
| `rate_limit_us` | Schedutil-specific update rate limit (informational) |
| Available frequencies | Logged per policy |
| Frequency response | CPU frequency increases under CPU-bound load |
| Per-CPU util | `/sys/devices/system/cpu/cpuN/cpufreq/util` (if present) |

## Test Methodology

```
1. Scan /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
2. For each schedutil policy: validate freq range, log rate_limit_us
3. Pick first schedutil policy
4. Record idle frequency
5. Spawn POSIX busy-loop for 3 seconds
6. Record under-load frequency
7. Assert: load_freq >= idle_freq  (schedutil raised freq in response to PELT util)
```

## Pass / Fail / Skip Criteria

- **SKIP**: No CPU policies using schedutil governor found
- **FAIL**: Frequency range invalid (`max < min`)
- **PASS**: All schedutil policies valid; frequency responded to load (or already at max)

## Note on Frequency Response

If the CPU is already at maximum frequency at idle (e.g., performance mode
or thermal headroom), the frequency-under-load check will show no change.
This is logged as a **warning**, not a failure.

## Usage

```sh
./run.sh
```

## Dependencies

- `/sys/devices/system/cpu/cpufreq/` (CONFIG_CPU_FREQ)
- `schedutil` governor (CONFIG_CPU_FREQ_GOV_SCHEDUTIL)
- `grep`, `awk`, `cat`
