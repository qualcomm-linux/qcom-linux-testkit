# SVSematest

## Overview

`SVSematest` is the qcom-linux-testkit wrapper for the `rt-tests` `svsematest` binary. It runs the SYSV semaphore latency test in JSON mode, parses results using `lib_rt.sh`, prints KPIs to the console, writes detailed results to log files, and emits a summary result file for LAVA.

This test follows the same style as the earlier RT tests in the suite, such as `PTSEMATest`, `PMQTest`, `RTMigrateTest`, `SignalTest`, and `SigwaitTest`.

## What the test validates

`svsematest` measures the latency between releasing a SYSV semaphore on one side and acquiring it on the other side. It is useful for validating RT scheduling behavior and semaphore wakeup latency under PREEMPT/RT-capable kernels or RT-focused workloads.

## Default behavior

The wrapper defaults are aligned with the Linaro test-definitions flow:

- `DURATION=5m`
- `BACKGROUND_CMD=""`
- `ITERATIONS=1`
- `PRIO=98`
- `QUIET=true`
- `THREADS=true`
- `AFFINITY=true`
- `SMP=false`
- `FORK_MODE=false`

By default, the effective command shape is equivalent to:

- `svsematest -q -t -a -p 98 -D 5m --json=<file>`

## Files produced

The test creates a log directory like:

- `logs_SVSematest/`

Typical generated files:

- `result.txt` - detailed KPI output used for review
- `iter_kpi.txt` - per-iteration KPI lines
- `agg_kpi.txt` - aggregate KPI across all iterations/threads
- `thread_agg_kpi.txt` - per-thread aggregate KPI summary
- `svsematest-<N>.json` - raw JSON output from `svsematest`
- `svsematest_stdout_iter<N>.log` - stdout/stderr captured from the binary
- `tmp_result_one.txt` - temporary parsed KPI file
- `SVSematest.res` - final PASS/FAIL/SKIP summary for LAVA gating

## Console behavior

The wrapper is designed to be operator-friendly:

- prints environment and runtime context before execution
- streams `svsematest` stdout to the console
- supports heartbeat progress messages while the binary is running
- prints per-iteration KPI summary at the end
- prints aggregate KPI summary at the end
- prints per-thread aggregate summary at the end

For long runs, a heartbeat message is shown by default so the user knows the test is still active.

Example heartbeat lines:

- `SVSematest: still running... 10s elapsed`
- `SVSematest: still running... 20s elapsed`

## Interrupt behavior

If the user presses `Ctrl-C` during execution:

- the wrapper requests the running `svsematest` process to exit cleanly
- any partial stdout/JSON data already produced is preserved
- collected KPI is still parsed if possible
- final result is marked as `SKIP`

This is intentional so partially collected data is not lost.

## Prerequisites

- root access
- `svsematest` binary available either in `PATH` or provided explicitly with `--binary`
- qcom-linux-testkit environment initialized through `init_env`
- `functestlib.sh`
- `lib_rt.sh`
- basic user-space tools such as:
  - `uname`
  - `awk`
  - `sed`
  - `grep`
  - `tr`
  - `head`
  - `tail`
  - `mkdir`
  - `cat`
  - `sh`
  - `tee`
  - `sleep`
  - `kill`
  - `date`
  - `mkfifo`
  - `rm`

## Command-line usage

```sh
./run.sh [OPTIONS]
```

### Wrapper options

- `--out DIR`  
  Output directory. Default: `./logs_SVSematest`

- `--result FILE`  
  Result file path. Default: `<OUT_DIR>/result.txt`

- `--duration TIME`  
  Passes `-D TIME` to `svsematest`. Default: `5m`

- `--iterations N`  
  Number of iterations to run. Default: `1`

- `--background-cmd CMD`  
  Optional background workload command

- `--binary PATH`  
  Explicit path to `svsematest`

- `--progress-every N`  
  Iteration progress print interval. Default: `1`

- `--verbose`  
  Enable extra wrapper-side debug logging

### Supported svsematest options

The wrapper supports the full practical set used by the binary.

- `--affinity BOOL`  
  Enable or disable `-a`

- `--affinity-cpu NUM`  
  Use `-a NUM`

- `--breaktrace-us USEC`  
  Use `-b USEC`

- `--distance-us USEC`  
  Use `-d DIST`

- `--fork BOOL`  
  Enable or disable `-f`

- `--fork-opt OPT`  
  Use `-f OPT`

- `--interval-us USEC`  
  Use `-i INTV`

- `--loops N`  
  Use `-l LOOPS`

- `--prio N`  
  Use `-p PRIO`. Default: `98`

- `--quiet BOOL`  
  Enable or disable `-q`

- `--smp BOOL`  
  Enable or disable `-S`

- `--threads BOOL`  
  Enable or disable `-t`

- `--threads-num NUM`  
  Use `-t NUM`

## Binary help reference

The wrapper is designed around the `svsematest` usage below:

```text
svsematest V 2.20
Usage:
svsematest <options>

Function: test SYSV semaphore latency

Available options:
-a [NUM] --affinity        run thread #N on processor #N, if possible
                           with NUM pin all threads to the processor NUM
-b USEC  --breaktrace=USEC send break trace command when latency > USEC
-d DIST  --distance=DIST   distance of thread intervals in us default=500
-D       --duration=TIME   specify a length for the test run
-f [OPT] --fork[=OPT]      fork new processes instead of creating threads
-i INTV  --interval=INTV   base interval of thread in us default=1000
         --json=FILENAME   write final results into FILENAME, JSON formatted
-l LOOPS --loops=LOOPS     number of loops: default=0 (endless)
-p PRIO  --prio=PRIO       priority
-S       --smp             SMP testing: options -a -t and same priority
                           of all threads
-t       --threads         one thread per available processor
-t [NUM] --threads[=NUM]   number of threads
                           without NUM, threads = max_cpus
                           without -t default = 1
```

## Example commands

Run with defaults aligned to Linaro behavior:

```sh
./run.sh
```

Run with an explicit binary path:

```sh
./run.sh --binary /tmp/svsematest
```

Run with one thread per CPU and explicit affinity CPU selection:

```sh
./run.sh --binary /tmp/svsematest --threads true --threads-num 8 --affinity true --affinity-cpu 0
```

Run for 60 seconds with explicit interval:

```sh
./run.sh --binary /tmp/svsematest --threads true --threads-num 8 --affinity true --affinity-cpu 0 --interval-us 1000 --duration 60s
```

Run in fork mode:

```sh
./run.sh --binary /tmp/svsematest --fork true --fork-opt 2 --distance-us 500 --interval-us 1000
```

Run multiple iterations:

```sh
./run.sh --binary /tmp/svsematest --iterations 3
```

## Result interpretation

The wrapper emits parsed KPI in a normalized format such as:

- `t0-min-latency pass 5 us`
- `t0-avg-latency pass 9.25 us`
- `t0-max-latency pass 66 us`
- `svsematest pass`

It also generates aggregate KPIs such as:

- `svsematest-all-min-latency-min`
- `svsematest-all-avg-latency-mean`
- `svsematest-all-max-latency-max`
- `svsematest-worst-thread-max-latency`
- `svsematest-worst-thread-id`

And per-thread aggregate KPIs such as:

- `svsematest-t0-min-latency-mean`
- `svsematest-t0-avg-latency-mean`
- `svsematest-t0-max-latency-max`

## LAVA integration

The YAML for this test should invoke `run.sh` and then publish:

- `SVSematest.res` through `send-to-lava.sh`

The wrapper always exits `0` for LAVA friendliness. Gating should be based on:

- `SVSematest.res`

Possible final states:

- `SVSematest PASS`
- `SVSematest FAIL`
- `SVSematest SKIP`

## Notes

- `--duration` controls runtime, not `--interval-us`
- `--interval-us` is the base thread interval in microseconds
- `--threads-num` is only meaningful when `--threads true`
- `--affinity-cpu` is only meaningful when `--affinity true`
- if the user deletes the log directory and reruns the test, the wrapper recreates it automatically
- heartbeat logging is expected during long-running test execution

## Maintainer intent

This wrapper is intentionally consistent with the Qualcomm RT test wrappers already present in the suite. Future changes should preserve:

- naming consistency
- POSIX shell compatibility
- ShellCheck cleanliness
- LAVA-friendly behavior
- reuse of shared helpers from `functestlib.sh` and `lib_rt.sh`
