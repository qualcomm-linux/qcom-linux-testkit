# SigwaitTest

`SigwaitTest` is a qcom-linux-testkit wrapper around **rt-tests** `sigwaittest`, which measures the latency between sending a signal and returning from `sigwait()`.

This test:
- Runs `sigwaittest` in **JSON output** mode (one JSON per iteration)
- Parses KPIs using **`lib_rt.sh`** helpers (no python dependency required in the wrapper)
- Produces a human-readable KPI log (`result.txt`) and a one-line LAVA gating file (`SigwaitTest.res`)

> **LAVA note:** `run.sh` always exits `0` (LAVA-friendly). Gate on `SigwaitTest.res`.

---

## Location in repo

```
Runner/suites/Kernel/RT-tests/SigwaitTest/
  run.sh
  SigwaitTest.yaml
  README.md
```

---

## Default behavior (aligned to Linaro test-definitions)

Defaults are chosen to match Linaro’s `sigwaittest` test definition, with explicit thread defaulting for our wrapper/YAML alignment:

- Duration: `5m`
- Priority: `98`
- Threads: `2`
- Quiet mode: enabled (`-q`)
- Affinity: enabled (`-a`)
- Iterations: `1`
- Background command: empty

The wrapper supports additional `sigwaittest` options (see below) while keeping defaults conservative.

---

## Prerequisites

- Must run as **root** (RT scheduling + memory locking behavior can require elevated privileges).
- `sigwaittest` binary must be present and executable:
  - Either in `$PATH` (preferred), or
  - Provided explicitly via `--binary /path/to/sigwaittest`
- Testkit environment must be available:
  - `init_env` must exist in a parent directory
  - `functestlib.sh` and `lib_rt.sh` must load successfully via `init_env`

---

## Quick start

### Run with defaults
```sh
cd Runner/suites/Kernel/RT-tests/SigwaitTest
./run.sh
```

### Run for 1 minute, 3 iterations
```sh
./run.sh --duration 1m --iterations 3
```

### Use all CPUs (threads=0 => nproc)
```sh
./run.sh --threads 0
```

### Use an explicit binary path
```sh
./run.sh --binary /tmp/sigwaittest
```

### Run with background workload
```sh
./run.sh --background-cmd "stress-ng --cpu 4 --timeout 5m"
```

---

## `run.sh` usage

```text
./run.sh [OPTIONS]

Wrapper options:
  -h, --help               Show this help and exit
  --out DIR                Output directory
                           (default: ./logs_SigwaitTest under test folder)
  --result FILE            Result KPI file path
                           (default: <out>/result.txt)
  --duration TIME          sigwaittest duration (passes -D TIME)
                           Supports suffix: m/h/d (e.g., 30s, 1m, 2h)
                           (default: 5m)
  --iterations N           Number of iterations to run
                           (default: 1)
  --background-cmd CMD     Optional background workload command
                           (default: empty)
  --binary PATH            Explicit path to sigwaittest binary
  --progress-every N       Log progress every N iterations
                           (default: 1)
  --verbose                Extra wrapper logs

sigwaittest passthrough options:
  --prio N                 Priority (passes -p N) (default: 98)
  --threads N              Thread count (passes -t N)
                           If N=0, wrapper expands to nproc
                           (default: 2)
  --quiet BOOL             Enable/disable quiet mode (passes -q)
                           Values: true/false/1/0/yes/no
                           (default: true)
  --affinity BOOL          Enable/disable CPU affinity (passes -a)
                           Values: true/false/1/0/yes/no
                           (default: true)
  --affinity-cpu NUM       When affinity enabled, pass "-a NUM"
                           (optional)
  --breaktrace-us USEC     Breaktrace threshold in microseconds (passes -b USEC)
                           (optional)
  --loops N                Loop count (passes -l N) (optional)
  --distance USEC          Distance in microseconds (passes -d USEC) (optional)
  --interval USEC          Interval in microseconds (passes -i USEC) (optional)
  --fork BOOL              Enable/disable process mode (passes -f)
                           Values: true/false/1/0/yes/no
                           (default: false)
  --fork-opt OPT           Optional argument to -f (depends on rt-tests build)
                           (optional)
```

---

## How options map to `sigwaittest`

The wrapper builds the `sigwaittest` command using the options above and always forces JSON output:

- `--json=<file>` is always appended (one file per iteration)
- Quiet: `--quiet true` -> `-q`
- Threads: `--threads N` -> `-t N` (wrapper always supplies `-t`)
- Affinity: `--affinity true` -> `-a` (or `-a NUM` when `--affinity-cpu NUM`)
- Priority: `--prio N` -> `-p N`
- Duration: `--duration TIME` -> `-D TIME`
- Optional knobs: `-b`, `-l`, `-d`, `-i`, `-f` when set

---

## Outputs

By default, output goes to:

```
Runner/suites/Kernel/RT-tests/SigwaitTest/logs_SigwaitTest/
```

Typical files:

- `sigwaittest-<iter>.json`  
  JSON produced by `sigwaittest` for each iteration
- `sigwaittest_stdout_iter<iter>.log`  
  Captured stdout/stderr for that iteration
- `iter_kpi.txt`  
  Parsed KPI lines per iteration (prefixed with `iteration-<N>-`)
- `agg_kpi.txt`  
  Aggregate KPI across all iterations/threads (if supported by parser)
- `thread_agg_kpi.txt`  
  Per-thread aggregate KPIs (if supported by parser)
- `result.txt`  
  Combined KPI output (this file is sent to LAVA as test output)
- `SigwaitTest.res`  
  One-line summary used for gating:
  - `SigwaitTest PASS`
  - `SigwaitTest FAIL`
  - `SigwaitTest SKIP`

---

## LAVA YAML integration

A typical YAML invokes the wrapper like:

```yaml
- cd Runner/suites/Kernel/RT-tests/SigwaitTest
- ./run.sh
    --duration "${DURATION}"
    --iterations "${ITERATIONS}"
    --background-cmd "${BACKGROUND_CMD}"
    --prio "${PRIO}"
    --threads "${THREADS}"
    --quiet "${QUIET}"
    --affinity "${AFFINITY}"
    --affinity-cpu "${AFFINITY_CPU}"
    --breaktrace-us "${BREAKTRACE_US}"
    --loops "${LOOPS}"
    --distance "${DISTANCE}"
    --interval "${INTERVAL}"
    --fork "${FORK}"
    --fork-opt "${FORK_OPT}"
    --binary "${BINARY}"
    --out "${OUT_DIR}"
    $( [ "${VERBOSE}" = "1" ] && echo "--verbose" )
    --progress-every "${PROGRESS_EVERY}"
  || true
- $REPO_PATH/Runner/utils/send-to-lava.sh SigwaitTest.res
```

### YAML params (recommended)

- `DURATION`: `"5m"`
- `BACKGROUND_CMD`: `""`
- `ITERATIONS`: `"1"`
- `PRIO`: `"98"`
- `THREADS`: `"2"`
- `QUIET`: `"true"`
- `AFFINITY`: `"true"`
- Optional advanced params:
  - `AFFINITY_CPU`, `BREAKTRACE_US`, `LOOPS`, `DISTANCE`, `INTERVAL`, `FORK`, `FORK_OPT`
- Wrapper extras:
  - `BINARY`, `OUT_DIR`, `VERBOSE`, `PROGRESS_EVERY`

---

## Troubleshooting

- **SKIP: binary not found**
  - Ensure `sigwaittest` is installed and in `$PATH`, or pass `--binary`.
- **Non-RT kernel warning**
  - The wrapper may warn if the kernel does not look RT-enabled. Results are still captured, but latencies may be worse.
- **No KPIs / parse failure**
  - Ensure `lib_rt.sh` is present and exports:
    - `perf_parse_rt_tests_json`
    - `rt_aggregate_iter_latencies`
    - `rt_aggregate_iter_latencies_per_thread`
- **Background command issues**
  - Provide a single command string; wrapper starts/stops it using `perf_rt_bg_start/stop`.

---

## Upstream tool reference

`sigwaittest` comes from **rt-tests**. To see binary-level help on target:

```sh
sigwaittest --help
```
