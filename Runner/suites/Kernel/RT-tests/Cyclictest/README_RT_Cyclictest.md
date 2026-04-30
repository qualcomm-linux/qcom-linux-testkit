# Cyclictest (rt-tests / cyclictest)

This test is part of **qcom-linux-testkit** and wraps `rt-tests` **cyclictest** to measure timer wakeup latency and report KPIs (min/avg/max) in a LAVA-friendly way.

It is designed to work on minimal images **without Python modules** by parsing cyclictest JSON output using POSIX shell helpers in `Runner/utils/lib_rt.sh`.

---

## What this test does

For each iteration, the wrapper:

1. Validates required tools and privileges (must run as **root**).
2. Optionally starts a background load command (`BACKGROUND_CMD`) to stress the system.
3. Runs `cyclictest` with `--json=<file>` and captures console output into a per-iteration `.out`.
4. Parses the JSON and emits KPI lines like:
   - `t0-min-latency pass <us> us`
   - `t0-avg-latency pass <us> us`
   - `t0-max-latency pass <us> us`
   - … (for additional threads, `t1-…`, `t2-…`, etc., if present in JSON)
5. Aggregates **t0** latency KPIs across iterations and reports averages.
6. Emits `<TESTNAME>.res` as PASS/FAIL/SKIP for CI/LAVA gating.

> Note: The test is **warn-only** if the kernel is not RT-enabled. It will still run and report latencies.

---

## Location

- Test: `Runner/suites/Kernel/RT-tests/Cyclictest/run.sh`
- Helpers: `Runner/utils/lib_rt.sh` (JSON parsing, progress logging, background load helpers)

---

## Prerequisites

### Permissions
- Must run as **root** (`id -u == 0`), since cyclictest typically uses RT scheduling and `mlockall()`.

### Tools required
The wrapper expects the following tools to exist (or it will SKIP):
- `uname`, `awk`, `sed`, `grep`, `tr`, `head`, `tail`, `mkdir`, `cat`, `sh`, `tee`, `sleep`, `kill`, `date`
- `cyclictest` executable (either in `$PATH` or provided via `--binary` / `BINARY`)

### Kernel considerations (recommended)
- RT kernel (PREEMPT_RT) is recommended for meaningful RT KPIs.
- The script prints a warning if `uname -r` / `uname -v` doesn’t look RT-enabled.

Useful runtime knobs (optional):
- `/proc/sys/kernel/sched_rt_runtime_us` (RT bandwidth)
- system frequency governor / CPU online state can affect results.

---

## Basic usage

From the test directory:

```sh
cd Runner/suites/Kernel/RT-tests/Cyclictest
sudo ./run.sh
```

If cyclictest is not in PATH:

```sh
sudo ./run.sh --binary /tmp/cyclictest
```

Run multiple iterations (example: 5 runs):

```sh
sudo ./run.sh --binary /tmp/cyclictest --iterations 5
```

Use more threads (example: 8):

```sh
sudo ./run.sh --binary /tmp/cyclictest --threads 8
```

Change duration (example: 30 seconds):

```sh
sudo ./run.sh --binary /tmp/cyclictest --duration 30s
```

> Note: `THREADS=0` means “auto”: uses `nproc` and sets `AFFINITY=all`.

---

## Parameters (Environment / LAVA params)

All options can be provided as environment variables (LAVA `params:`) or as CLI options.

### Output / logging
- `OUT_DIR` (default: `./logs_Cyclictest`)
- `RESULT_TXT` (default: `$OUT_DIR/result.txt`)
- `VERBOSE` (default: `0`)

### cyclictest control
- `PRIORITY` (default: `98`) → cyclictest `-p`
- `INTERVAL` (default: `1000`) microseconds → cyclictest `-i`
- `THREADS` (default: `1`) → cyclictest `-t`
- `AFFINITY` (default: `0`) CPU id or `all` → cyclictest `-a`
- `DURATION` (default: `1m`) → cyclictest `-D`
- `HISTOGRAM_MAX` (default: empty) → cyclictest `-h` (optional)

### Iteration / progress
- `ITERATIONS` (default: `1`) number of iterations
- `PROGRESS_STEP` (default: `5`) seconds between “still running…” progress logs

### Background load
- `BACKGROUND_CMD` (default: empty) command to run during test (stopped afterward)

### Binary override
- `BINARY` (default: empty) explicit path to cyclictest executable

---

## CLI options

`run.sh` supports:

- `--out DIR`
- `--result FILE`
- `--priority N`
- `--interval USEC`
- `--threads N`
- `--affinity CPU|all`
- `--duration DUR`
- `--histogram-max USEC`
- `--iterations N`
- `--progress-step S`
- `--background-cmd CMD`
- `--binary PATH`
- `--verbose`
- `-h, --help`

---

## Output files

Within `OUT_DIR` (default: `logs_Cyclictest`):

- `cyclictest_iterN.json` : cyclictest JSON output per iteration
- `cyclictest_iterN.out`  : cyclictest stdout/stderr per iteration
- `parsed_iterN.txt`      : parsed KPI lines per iteration (from JSON)
- `metrics_all.txt`       : KPI lines used for averaging (t0 only by default)
- `average_summary.txt`   : computed averages across iterations (t0 min/avg/max)
- `result.txt`            : concatenated per-iteration KPI lines + averages + final verdict

At the test root:
- `Cyclictest.res` : single-line PASS/FAIL/SKIP result for LAVA

---

## Console output (what to expect)

You’ll see:

- Start banner
- Tool checks
- RT kernel status (INFO or WARN)
- System context (uname, nproc, cpu online, governor, etc.)
- Progress logs every `PROGRESS_STEP` seconds while cyclictest runs
- cyclictest’s own output (the `T:` lines)
- Parsed KPI lines per iteration:
  - `t0-min-latency pass ... us`
  - `t0-avg-latency pass ... us`
  - `t0-max-latency pass ... us`
- Final averages across iterations (t0)
- PASS/FAIL

---

## LAVA integration

### Do we need to pass variables in the `run:` step?

Usually **no**. LAVA exports `params:` as environment variables before executing `run.steps`.
So this is typically enough:

```yaml
run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Kernel/RT-tests/Cyclictest
    - ./run.sh || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh Cyclictest.res
```

If you want to override a param only for one step, you can still prefix env vars inline.

---

## Troubleshooting

### 1) “must run as root” / SKIP
Run via `sudo` or ensure the test is executed as root in LAVA.

### 2) “cyclictest binary not found”
- Install `rt-tests`, or
- Provide explicit path: `--binary /path/to/cyclictest` or `BINARY=/path/to/cyclictest`.

### 3) Latency lines not printed
Ensure JSON parsing is working:
- Check `OUT_DIR/parsed_iterN.txt` exists and contains `t*-min/avg/max-latency` lines.
- If the JSON format changed, update the parser in `Runner/utils/lib_rt.sh`.

### 4) Very large max latency spikes (e.g., tens of ms)
Common causes:
- Non-RT kernel or RT throttling (`sched_rt_runtime_us`)
- CPU frequency scaling / idle states
- Interrupt storms / background load
- Thermal throttling
Try:
- Use RT kernel
- Pin affinity (`AFFINITY=0` or isolated CPU)
- Reduce system activity / background load
- Increase priority cautiously

---

## Notes / Design choices

- This wrapper is POSIX shell and ShellCheck-friendly (avoid python dependency).
- It produces `.res` and always exits `0` (LAVA-friendly), while still gating via `.res`.
- KPI lines are intended to be easy to post-process and trend.

---

## Maintainers / Contribution

If you update `lib_rt.sh`, please keep:
- POSIX compatibility
- ShellCheck cleanliness (avoid `A && B || C` for control flow, avoid unused vars)
- Robustness on minimal images
