# CyclicDeadline

## Overview

`CyclicDeadline` is the qcom-linux-testkit wrapper for the `rt-tests` `cyclicdeadline` binary.

It is similar to `cyclictest`, but instead of using `SCHED_FIFO` with `nanosleep()` to measure jitter, it uses `SCHED_DEADLINE` and treats the deadline as the wakeup interval.

This wrapper:

- runs `cyclicdeadline` in JSON mode
- parses KPI using `lib_rt.sh`
- supports repeated iterations
- prints per-iteration, aggregate, and per-thread aggregate results
- can keep partial results on user interrupt when supported by the common RT helpers
- writes final PASS/FAIL/SKIP summary to `CyclicDeadline.res`

The script is LAVA-friendly and always exits `0`. CI gating should use the `.res` file.

## Defaults

Defaults are aligned to the Linaro test-definition behavior unless explicitly overridden.

- `INTERVAL=1000`
- `STEP=500`
- `THREADS=1`
- `DURATION=5m`
- `BACKGROUND_CMD=""`
- `ITERATIONS=1`
- `USER_BASELINE=""`

## Files generated

By default, the test writes logs under:

`./logs_CyclicDeadline`

Typical outputs:

- `CyclicDeadline.res` - final PASS/FAIL/SKIP summary
- `logs_CyclicDeadline/result.txt` - parsed KPI output
- `logs_CyclicDeadline/iter_kpi.txt` - per-iteration KPI
- `logs_CyclicDeadline/agg_kpi.txt` - overall aggregate KPI
- `logs_CyclicDeadline/thread_agg_kpi.txt` - per-thread aggregate KPI
- `logs_CyclicDeadline/cyclicdeadline-<N>.json` - raw JSON per iteration
- `logs_CyclicDeadline/cyclicdeadline_stdout_iter<N>.log` - console/stdout capture per iteration
- `logs_CyclicDeadline/max_latencies.txt` - extracted max latency values when baseline comparison is used

## Usage

```sh
./run.sh [OPTIONS]
```

## Supported wrapper options

### Wrapper control

- `--out DIR`
  - Output directory
- `--result FILE`
  - Result text file path
- `--duration TIME`
  - Test duration passed as `-D TIME`
- `--iterations N`
  - Number of iterations to run
- `--background-cmd CMD`
  - Optional background workload to run during the test
- `--binary PATH`
  - Explicit path to the `cyclicdeadline` binary
- `--progress-every N`
  - Progress message cadence across iterations
- `--heartbeat-sec N`
  - Periodic "still running" heartbeat while a long iteration is executing
- `--verbose`
  - Enable additional wrapper logging

### cyclicdeadline options supported by the wrapper

- `--interval-us USEC`
  - Base interval in microseconds, maps to `-i`
- `--step-us USEC`
  - Step size in microseconds, maps to `-s`
- `--threads N`
  - Number of threads, maps to `-t`
  - If set to `0`, wrapper expands it to `nproc`
- `--user-baseline VALUE`
  - Baseline max latency to compare against when iteration count is high enough

## Baseline comparison behavior

When `ITERATIONS` is greater than `2`, the wrapper can evaluate max latency results against a baseline.

Behavior:

- extracts all `max-latency` values from per-iteration parsed output
- if `USER_BASELINE` is set, that value is used as the baseline
- otherwise, the minimum observed max latency becomes the baseline
- counts how many max latency values are above the baseline
- compares that count against `ITERATIONS / 2`

This provides a simple consistency check across repeated runs.

## Examples

Run one default iteration using auto-detected binary:

```sh
./run.sh
```

Run with explicit binary, 3 iterations, and 1 minute duration:

```sh
./run.sh --binary /tmp/cyclicdeadline --duration 1m --iterations 3
```

Run with one thread per CPU:

```sh
./run.sh --threads 0 --duration 1m
```

Run with custom interval and step:

```sh
./run.sh --interval-us 1000 --step-us 500 --threads 4 --duration 60s
```

Run with baseline comparison:

```sh
./run.sh --binary /tmp/cyclicdeadline --iterations 5 --user-baseline 120
```

Run with heartbeat messages every 10 seconds:

```sh
./run.sh --binary /tmp/cyclicdeadline --duration 60s --heartbeat-sec 10
```

## LAVA integration notes

Typical YAML wiring passes parameters into `run.sh` and reports using:

```sh
$REPO_PATH/Runner/utils/send-to-lava.sh CyclicDeadline.res
```

Recommended CI behavior:

- rely on `CyclicDeadline.res` for PASS/FAIL/SKIP
- keep `result.txt` and JSON files as artifacts for debugging
- use `--binary` when the binary is staged outside standard PATH

## Expected console behavior

The wrapper may print:

- environment and scheduler context
- selected binary and options
- per-iteration start messages
- optional heartbeat messages for long-running iterations
- per-iteration KPI
- aggregate KPI
- per-thread aggregate KPI
- final PASS/FAIL/SKIP summary

## Interrupt behavior

If the shared RT helper functions in `lib_rt.sh` are present and enabled, `Ctrl-C` can preserve partial output and mark the run as `SKIP` instead of `FAIL`.

This depends on the common RT helper implementation already being present in your tree.

## Dependencies

The wrapper expects:

- `cyclicdeadline` binary available either in `PATH` or via `--binary`
- `functestlib.sh`
- `lib_rt.sh`
- standard shell utilities such as `awk`, `sed`, `grep`, `tee`, `mkdir`, `cat`, `tr`, and `date`

## Notes

- Keep changes aligned with existing qcom-linux-testkit conventions.
- For CI, use the `.res` file as the authoritative result.
