# PELT_decay — PELT Exponential Decay Validation

## Overview

Validates that **PELT (Per-Entity Load Tracking) exponential decay** is
functioning correctly in the kernel. PELT uses a geometric series with a
~32 ms half-life to track CPU utilization. After a task stops running,
its `util_avg` must decay toward zero — this is the mechanism that allows
the scheduler and cpufreq governors to reduce CPU frequency after load drops.

This is the **only** testcase in the PELT suite that explicitly validates
decay. The other tests (`PELT_load_tracking`, `PELT_schedutil`) only validate
accumulation (load going up), not the decay direction.

## PELT Decay Theory

```
util_avg(t) = util_avg(t0) × 0.5^( Δt / 32ms )

Half-life  = 32 ms  (one PELT period = 1024 µs)
After 100ms idle:  util_avg → 11.5% of peak
After 200ms idle:  util_avg →  1.3% of peak
After 1000ms idle: util_avg → ~0%   of peak  (< 0.001%)
```

## Two Validation Methods

### Method 1: `/proc/self/sched` `se.avg.util_avg` (Primary)

**Requires:** `CONFIG_SCHED_DEBUG`

The test script itself performs a CPU-bound busy loop for ~3 seconds,
saturating its own PELT `util_avg`. It then reads `util_avg` immediately
after the loop (should be high), sleeps 1 second, and reads again (should
be near zero).

```
1. Read baseline util_avg  (shell is idle → low)
2. Run arithmetic busy loop for ~3s  (saturates util_avg → near 1024)
3. Read peak util_avg  (should be > 100/1024)
4. Sleep 1 second  (~31 PELT half-lives → >99.9% theoretical decay)
5. Read decayed util_avg  (should be < peak/2)
6. Assert: decayed_util < peak_util / 2
```

**Pass threshold:** `decayed_util < peak_util / 2` (50% decay after 1s).
This is extremely conservative — theoretical decay after 1s is >99.9%.

### Method 2: schedutil Frequency Proxy (Secondary)

**Requires:** `schedutil` cpufreq governor active

`schedutil` translates PELT `util_avg` into CPU frequency requests. When
`util_avg` decays after load stops, `schedutil` should lower the frequency.

```
1. Record idle frequency
2. Spawn background busy loop for 3s → record peak frequency
3. Kill load, wait 2 seconds
4. Record post-decay frequency
5. Assert: post_decay_freq < load_freq
```

This method is **informational** — a warning is issued if frequency does
not drop, but it does not cause a FAIL (thermal floors, rate_limit_us, or
platform-specific governor behaviour can prevent immediate frequency drop).

## Pass / Fail / Skip Criteria

| Condition | Result |
|---|---|
| Neither method available | SKIP |
| Method 1 available, decay ≥ 50% after 1s | PASS |
| Method 1 available, decay < 50% after 1s | FAIL |
| Method 2 only, frequency dropped after load | PASS (informational) |
| Method 2 only, frequency did not drop | WARN (not FAIL) |

## Why Existing Tests Don't Cover Decay

| Test | What it measures | Decay? |
|---|---|---|
| `PELT_schedstat` | `rq_cpu_time` (monotonic counter, never decays) | ✗ |
| `PELT_load_tracking` | `rq_cpu_time` increases under load | ✗ |
| `PELT_schedutil` | Frequency rises under load | ✗ (rise only) |
| **`PELT_decay`** | `util_avg` decreases after load stops | **✓** |

## Usage

```sh
./run.sh
```

## Dependencies

- `/proc/self/sched` — `CONFIG_SCHED_DEBUG` (Method 1)
- `schedutil` governor — `CONFIG_CPU_FREQ_GOV_SCHEDUTIL` (Method 2)
- `grep`, `awk`, `cat`, `date`
