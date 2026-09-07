# PELT_tunables — CFS/PELT Scheduler Tunables Validation

## Overview

Validates the **CFS and PELT scheduler tunables** exposed via
`/proc/sys/kernel/sched_*`. These tunables control scheduling latency,
task migration cost, and utilization clamping (uclamp) which directly
influence PELT behaviour.

## What Is Tested

| Tunable | Path | Check |
|---|---|---|
| `sched_latency_ns` | `/proc/sys/kernel/` | Present and > 0 |
| `sched_min_granularity_ns` | `/proc/sys/kernel/` | Present and > 0 |
| `sched_wakeup_granularity_ns` | `/proc/sys/kernel/` | Present and > 0 |
| CFS invariant | — | `latency_ns >= min_granularity_ns` |
| `sched_migration_cost_ns` | `/proc/sys/kernel/` | Present (informational) |
| `sched_util_clamp_min` | `/proc/sys/kernel/` | Present if CONFIG_UCLAMP_TASK |
| `sched_util_clamp_max` | `/proc/sys/kernel/` | Present if CONFIG_UCLAMP_TASK |
| uclamp invariant | — | `clamp_min <= clamp_max` |
| Per-domain tunables | `/proc/sys/kernel/sched_domain/` | Logged (informational) |

## CFS Timing Invariant

The kernel enforces:

```
sched_latency_ns >= sched_min_granularity_ns
```

If violated, the CFS scheduler may behave incorrectly. This test
explicitly validates this invariant.

## uclamp (Utilization Clamp)

Available on kernels ≥ 5.3 with `CONFIG_UCLAMP_TASK`. Controls the
min/max PELT utilization signal used by the Energy-Aware Scheduler (EAS)
and cpufreq governors.

## Pass / Fail Criteria

- **FAIL**: Core CFS timing tunables missing or zero, or CFS/uclamp invariant violated
- **PASS**: All required tunables present, non-zero, and invariants hold

## Usage

```sh
./run.sh
```

## Dependencies

- `/proc/sys/kernel/sched_*`
- `CONFIG_UCLAMP_TASK` (optional, for uclamp checks)
- `grep`, `awk`, `cat`
