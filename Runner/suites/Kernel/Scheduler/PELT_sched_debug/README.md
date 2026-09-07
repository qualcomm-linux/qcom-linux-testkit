# PELT_sched_debug — Scheduler Debugfs Interface Validation

## Overview

Validates the **scheduler debugfs interface** (`/sys/kernel/debug/sched`)
which exposes PELT internal state, scheduler feature flags, scheduling domain
topology, and per-task load tracking detail.

## What Is Tested

| Check | Description |
|---|---|
| debugfs mount | Verifies `/sys/kernel/debug` is mounted; attempts mount if root |
| `sched/` directory | Must exist (requires CONFIG_SCHED_DEBUG) |
| `sched/features` | Scheduler feature flags logged; PELT-relevant flags checked |
| `sched/domains/` | Scheduling domain topology per CPU logged |
| Domain properties | `name`, `flags`, `min/max_interval`, `imbalance_pct` per domain |
| `/proc/self/sched` | Per-task PELT fields: `se.avg.util_avg`, `se.avg.load_avg`, etc. |

## PELT-Relevant Scheduler Features

| Feature | Description |
|---|---|
| `UTIL_EST` | Utilization estimation (smoothed PELT util for wakeup) |
| `NONTASK_CAPACITY` | Account non-task CPU capacity in PELT |
| `WAKEUP_PREEMPTION` | Preempt on wakeup using PELT vruntime |
| `GENTLE_FAIR_SLEEPERS` | Limit vruntime catch-up for sleepers |
| `TTWU_QUEUE` | Queue wake-up across CPUs |

## Pass / Fail / Skip Criteria

- **SKIP**: debugfs not mounted and not running as root
- **FAIL**: `/sys/kernel/debug/sched` missing (CONFIG_SCHED_DEBUG not enabled)
- **PASS**: Scheduler debugfs directory present and readable

## Usage

```sh
./run.sh
```

## Dependencies

- `CONFIG_SCHED_DEBUG` kernel config
- debugfs mounted at `/sys/kernel/debug`
- `grep`, `awk`, `cat`, `id`, `mount`, `basename`
