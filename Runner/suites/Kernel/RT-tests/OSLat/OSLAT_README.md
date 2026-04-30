# OSLAT

## Overview

OSLAT is an OS latency detector from rt-tests. It runs busy loops on selected CPUs and measures operating system induced latency while optionally applying workloads such as `memmove`. In the qcom-linux-testkit wrapper, OSLAT is executed in JSON mode, parsed through `lib_rt.sh`, and summarized into machine-friendly and human-readable result files.

This wrapper follows the same structure used for the other RT tests in `Runner/suites/Kernel/RT-tests`, including:

- standard `run.sh` flow
- `PASS` / `FAIL` / `SKIP` summary in `OSLAT.res`
- detailed KPI in `logs_OSLAT/result.txt`
- aggregate KPI files under `logs_OSLAT/`
- LAVA-friendly behavior with exit code `0`
- heartbeat logging for long-running executions
- partial-result preservation on user interrupt

## Default behavior

The wrapper defaults are chosen to be safe and practical for embedded boards while still matching the oslat binary options.

Default wrapper values:

- `DURATION=1m`
- `ITERATIONS=1`
- `BACKGROUND_CMD=""`
- `QUIET=true`
- `WORKLOAD=no`
- `CPU_MAIN_THREAD=0`
- `PROGRESS_EVERY=1`
- `HEARTBEAT_SEC=10`

Unset binary options are passed only when explicitly requested.

## Files generated

Typical output directory:

`logs_OSLAT/`

Generated files include:

- `result.txt` - all parsed KPI lines and summary data
- `iter_kpi.txt` - per-iteration KPI lines
- `agg_kpi.txt` - aggregate KPI across iterations
- `thread_agg_kpi.txt` - per-thread aggregate KPI
- `oslat-<N>.json` - raw JSON output from each iteration
- `oslat_stdout_iter<N>.log` - captured console output for each iteration
- `tmp_result_one.txt` - temporary per-iteration parsed result file
- `OSLAT.res` - final summary result used by LAVA gating

## Supported wrapper options

### Wrapper options

- `--out DIR`
  Override output directory.

- `--result FILE`
  Override result file path.

- `--duration TIME`
  Test duration passed to oslat via `-D`.

- `--iterations N`
  Number of iterations to run.

- `--background-cmd CMD`
  Background workload command launched alongside the test.

- `--binary PATH`
  Explicit path to `oslat` binary.

- `--progress-every N`
  Iteration start progress cadence.

- `--heartbeat-sec N`
  Emit periodic "still running" messages while the binary is executing.

- `--verbose`
  Enable extra wrapper debug output.

## Supported oslat options in run.sh

The wrapper is expected to support the full set of useful oslat runtime options.

- `--bucket-size N`
  Pass `-b N`.

- `--bias BOOL`
  Pass `-B` when enabled.

- `--cpu-list LIST`
  Pass `-c LIST`, for example `1,3,5,7-15`.

- `--cpu-main-thread CPU`
  Pass `-C CPU`. Default is `0`.

- `--rtprio N`
  Pass `-f N`.

- `--workload-mem SIZE`
  Pass `-m SIZE`, for example `4K`, `1M`.

- `--quiet BOOL`
  Pass `-q` when enabled.

- `--single-preheat BOOL`
  Pass `-s` when enabled.

- `--trace-threshold USEC`
  Pass `-T USEC`.

- `--workload TYPE`
  Pass `-w TYPE`. Supported by oslat: `no`, `memmove`.

- `--bucket-width NS`
  Pass `-W NS`.

- `--zero-omit BOOL`
  Pass `-z` when enabled.

## Example commands

Run with defaults using an explicit binary:

```sh
./run.sh --binary /tmp/oslat
```

Run on selected CPUs for 1 minute with memmove workload:

```sh
./run.sh \
  --binary /tmp/oslat \
  --duration 1m \
  --cpu-list 0-3 \
  --cpu-main-thread 0 \
  --workload memmove \
  --workload-mem 1M
```

Run 3 iterations with heartbeat and FIFO priority:

```sh
./run.sh \
  --binary /tmp/oslat \
  --duration 60s \
  --iterations 3 \
  --rtprio 95 \
  --heartbeat-sec 10
```

Run with histogram tuning:

```sh
./run.sh \
  --binary /tmp/oslat \
  --bucket-size 128 \
  --bucket-width 1000 \
  --bias true \
  --zero-omit true
```

## Result interpretation

The parser extracts latency KPI from the JSON output and emits standard lines such as:

- per-thread minimum latency
- per-thread average latency
- per-thread maximum latency
- test return code and verdict

Aggregate summaries typically include:

- all-thread minimum latency min / mean / max
- all-thread average latency min / mean / max
- all-thread maximum latency min / mean / max
- worst thread maximum latency
- worst thread id
- per-thread aggregate summaries across iterations

These results are appended to `logs_OSLAT/result.txt` and also echoed to stdout in the standard qcom-linux-testkit format.

## Interrupt behavior

If the user presses `Ctrl-C` during execution:

- the wrapper asks the running binary to exit cleanly
- partial stdout and any flushed JSON are preserved
- parsed results collected so far are still printed
- final status is marked as `SKIP` instead of `FAIL`

This matches the improved handling used in the recent RT test wrappers.

## Expected repository layout

Typical placement inside qcom-linux-testkit:

`Runner/suites/Kernel/RT-tests/OSLAT/`

Expected files:

- `run.sh`
- `oslat.yaml`
- `README.md`

And supporting utilities:

- `Runner/utils/functestlib.sh`
- `Runner/utils/lib_rt.sh`

## LAVA integration notes

The wrapper is designed to integrate with the existing RT test YAML style used in your repository:

- repository-relative `cd` into the test directory
- invoke `./run.sh` with YAML params
- always call `send-to-lava.sh OSLAT.res`

The `.res` file is the gating artifact. The detailed KPI remains under `logs_OSLAT/`.

## Notes

- OSLAT should be run as root.
- CPU list and main-thread CPU should be chosen carefully on small embedded systems.
- `--single-preheat` should only be used when CPU frequency behavior is understood and controlled.
- `--trace-threshold` is useful only if ftrace is configured and available on the target.
- `--workload memmove` plus large `--workload-mem` can significantly increase system pressure.
