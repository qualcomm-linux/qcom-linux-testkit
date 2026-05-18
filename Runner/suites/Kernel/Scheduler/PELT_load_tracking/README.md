# PELT_load_tracking — PELT Functional Load Tracking Validation

## Overview

Functional test that verifies **PELT (Per-Entity Load Tracking) is actively
accounting CPU utilization** by spawning a CPU-bound task and measuring the
change in `/proc/schedstat` counters before and after the load.

## What Is Tested

| Check | Description |
|---|---|
| Baseline snapshot | Captures `rq_cpu_time`, `run_delay`, `pcount` from `/proc/schedstat` |
| CPU-bound load | Spawns a POSIX busy-loop task for 3 seconds |
| `rq_cpu_time` increase | Total CPU run time must increase — confirms PELT accounting |
| `pcount` increase | Scheduling event count must increase |
| Per-CPU breakdown | Logs per-CPU `rq_cpu_time` after load for triage |
| Load average | Logs `/proc/loadavg` before and after (informational) |

## Test Methodology

```
1. Read baseline /proc/schedstat (sum rq_cpu_time across all CPUs)
2. Fork a POSIX busy-loop: ( i=0; while true; do i=$((i+1)); done ) &
3. Sleep 3 seconds  (PELT half-life ~32 ms — 3s is ample to accumulate)
4. Read post-load /proc/schedstat
5. Kill load task
6. Assert: post_rq_cpu_time > baseline_rq_cpu_time
```

## Pass / Fail Criteria

- **FAIL**: `/proc/schedstat` missing, or `rq_cpu_time` did not increase after load
- **PASS**: `rq_cpu_time` increased — PELT is tracking CPU utilization

## Usage

```sh
./run.sh
```

## Dependencies

- `/proc/schedstat` (CONFIG_SCHEDSTATS)
- `/proc/loadavg`
- `grep`, `awk`, `cat`
