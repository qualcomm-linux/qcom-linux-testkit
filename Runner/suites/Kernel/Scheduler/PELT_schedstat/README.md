# PELT_schedstat — PELT /proc/schedstat Interface Validation

## Overview

Validates `/proc/schedstat`, the kernel interface that exposes
**per-CPU PELT runtime accounting** data. This includes CPU run time,
run-queue wait delay, and scheduling event counts per CPU.

## What Is Tested

| Check | Description |
|---|---|
| `/proc/schedstat` presence | File must exist (requires CONFIG_SCHEDSTATS) |
| Version field | Schedstat format version is logged |
| Per-CPU line format | Each `cpuN` line must have ≥ 10 fields |
| `rq_cpu_time` non-zero | Total CPU run time must be > 0 (PELT accounting active) |
| Scheduling domain lines | `domain*` lines logged (informational) |
| `/proc/self/schedstat` | Per-task exec time, wait time, timeslice count |
| `/proc/loadavg` | PELT-derived 1/5/15-min load averages |

## /proc/schedstat Field Reference (v15)

```
cpuN  yld_count  yld_act_count  sched_count  sched_goidle
      ttwu_count  ttwu_local  rq_cpu_time  run_delay  pcount
```

| Field | Description |
|---|---|
| `rq_cpu_time` (field 8) | Total ns tasks spent running on this CPU |
| `run_delay` (field 9) | Total ns tasks spent waiting in runqueue |
| `pcount` (field 10) | Number of tasks that have run on this CPU |

## Pass / Fail Criteria

- **FAIL**: `/proc/schedstat` missing, no `cpu*` lines, or `rq_cpu_time` is zero
- **PASS**: All CPU lines valid and `rq_cpu_time` > 0

## Usage

```sh
./run.sh
```

## Dependencies

- `grep`, `awk`, `cat`
