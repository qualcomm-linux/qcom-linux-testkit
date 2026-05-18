# PELT_config — PELT Kernel Configuration Validation

## Overview

Validates that the kernel is built with the configurations required for
**PELT (Per-Entity Load Tracking)**, the Linux CFS scheduler mechanism that
tracks CPU utilization per scheduling entity (tasks and task groups).

## What Is Tested

| Config | Required | Purpose |
|---|---|---|
| `CONFIG_SMP` | Yes | Multi-CPU support — PELT load balancing is SMP-only |
| `CONFIG_FAIR_GROUP_SCHED` | Yes | Per-entity load tracking across scheduling groups |
| `CONFIG_SCHED_DEBUG` | Optional | Enables `/sys/kernel/debug/sched` and `/proc/<pid>/sched` |
| `CONFIG_CFS_BANDWIDTH` | Optional | CFS bandwidth control (uses PELT util signals) |
| `CONFIG_NO_HZ_COMMON` | Optional | Tickless kernel — affects PELT decay accuracy |
| `CONFIG_SCHED_AUTOGROUP` | Optional | Automatic task group creation |
| `CONFIG_CGROUP_SCHED` | Optional | cgroup-based scheduling (PELT tracks per cgroup) |
| `CONFIG_CPU_FREQ_GOV_SCHEDUTIL` | Optional | schedutil governor — consumes PELT util_avg |

## Pass / Fail / Skip Criteria

- **SKIP**: `/proc/config.gz` not present (CONFIG_IKCONFIG not enabled)
- **FAIL**: `CONFIG_SMP` or `CONFIG_FAIR_GROUP_SCHED` not enabled
- **PASS**: All required configs enabled (optional configs logged as warnings only)

## Usage

```sh
./run.sh
```

## Dependencies

- `/proc/config.gz` (CONFIG_IKCONFIG + CONFIG_IKCONFIG_PROC)
- `grep`, `zgrep` or `gzip` (provided by functestlib)
