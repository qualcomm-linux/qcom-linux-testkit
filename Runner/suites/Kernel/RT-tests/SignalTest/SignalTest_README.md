# SignalTest (RT signal roundtrip latency)

This test wraps **`signaltest`** from the *rt-tests* suite and integrates it into the **qcom-linux-testkit** runner style:

- Runs `signaltest` for a configurable duration and number of iterations
- Captures per-iteration JSON output
- Parses KPIs via `lib_rt.sh` (no Python required)
- Produces:
  - `SignalTest.res` (PASS/FAIL/SKIP summary for LAVA gating)
  - `logs_SignalTest/result.txt` (detailed KPI lines for LAVA upload / human review)
  - additional debug logs and aggregate KPI files

> **LAVA behavior:** `run.sh` always exits `0` (LAVA-friendly). Use `SignalTest.res` as the gating signal.

---

## Location

Typical path in repo:

```
Runner/suites/Kernel/RT-tests/SignalTest/
  run.sh
  README.md
```

---

## What this test measures

`signaltest` measures **signal roundtrip latency** between real-time threads. It reports per-thread statistics such as:
- min latency (µs)
- average latency (µs)
- max latency (µs)

The wrapper records these per iteration and also computes aggregates across:
- **all iterations + all threads**
- **per-thread across iterations**

---

## Requirements

### Runtime dependencies
- `signaltest` binary (from rt-tests)
- Common userland tools used by the wrapper:
  - `uname awk sed grep tr head tail mkdir cat sh tee sleep kill date`
- The test is typically run as **root** (RT scheduling + mlockall, etc.)

### qcom-linux-testkit dependencies
`run.sh` expects the standard testkit environment:

- `init_env` available somewhere above this directory (auto-discovered)
- `${TOOLS}/functestlib.sh` available (loaded via init_env)
- `${TOOLS}/lib_rt.sh` available (loaded via init_env)
  - Must provide JSON parsing helpers such as `perf_parse_rt_tests_json`
  - Must provide aggregation helpers such as `rt_aggregate_iter_latencies`
  - Optional: `rt_print_kpi_block` for pretty KPI blocks

If any of the required components are missing, the test will **SKIP** and write `SignalTest SKIP` to `SignalTest.res`.

---

## Default behavior (matches Linaro test-definitions defaults)

Defaults follow the *linaro test-definitions* signaltest baseline:

| Parameter | Default | Meaning |
|---|---:|---|
| Duration | `1m` | `signaltest -D` runtime |
| Priority | `98` | `signaltest -p` |
| Threads | `2` | `signaltest -t` |
| Iterations | `1` | wrapper-level iterations |
| Background cmd | empty | optional stress/workload |
| Quiet | enabled | `-q` summary only |
| Mlockall | enabled | `-m` lock memory |
| Affinity | enabled | `-a` try to pin threads (best-effort) |

> Note: Threads can be higher than `nproc`. `signaltest` will still run, but results may reflect oversubscription effects.

---

## Usage

### Run locally (recommended)

From the test directory:

```sh
./run.sh
```

### Typical override example

```sh
./run.sh --binary /tmp/signaltest --duration 1m --iterations 3 --prio 98 --threads 24
```

### Show help

```sh
./run.sh --help
```

---

## `run.sh` options

The wrapper accepts long options (testkit style). Common options:

| Option | Example | Description |
|---|---|---|
| `--duration` | `--duration 5m` | `signaltest -D` runtime (`s/m/h/d` supported) |
| `--iterations` | `--iterations 3` | Number of iterations (wrapper loops) |
| `--background-cmd` | `--background-cmd "stress-ng --cpu 4"` | Optional background workload |
| `--binary` | `--binary /tmp/signaltest` | Explicit `signaltest` path |
| `--out` | `--out ./logs_SignalTest` | Output directory |
| `--result` | `--result ./logs_SignalTest/result.txt` | Result file path |
| `--progress-every` | `--progress-every 5` | Progress log frequency |
| `--verbose` | `--verbose` | Additional debug logs |
| `--prio` | `--prio 98` | `signaltest -p` priority |
| `--threads` | `--threads 2` | `signaltest -t` threads |
| `--quiet` | `--quiet true` | Enable `-q` |
| `--mlockall` | `--mlockall true` | Enable `-m` |
| `--affinity` | `--affinity true` | Enable `-a` |
| `--loops` | `--loops 1000` | `signaltest -l` loops |
| `--breaktrace-us` | `--breaktrace-us 50` | `signaltest -b USEC` |
| `--json` | *(internal)* | Wrapper always uses `--json=FILE` per iteration |

> The wrapper uses `--json=FILENAME` (equals form), matching `signaltest` expectations.

---

## Outputs

After running, you should see:

```
SignalTest.res
logs_SignalTest/
  result.txt
  iter_kpi.txt
  agg_kpi.txt
  thread_agg_kpi.txt
  signaltest-1.json
  signaltest-2.json
  ...
  signaltest_stdout_iter1.log
  signaltest_stdout_iter2.log
  ...
```

### Meaning of key files
- **`SignalTest.res`**: Single-line PASS/FAIL/SKIP (for CI/LAVA gating)
- **`logs_SignalTest/result.txt`**: Detailed KPI lines (per-iteration + aggregates)
- **`iter_kpi.txt`**: Parsed KPIs per iteration, prefixed with `iteration-N-...`
- **`agg_kpi.txt`**: Aggregates across all iterations + all threads
- **`thread_agg_kpi.txt`**: Aggregates per thread (t0..tN) across iterations
- **`signaltest_stdout_iterN.log`**: Raw stdout/stderr for debugging
- **`signaltest-N.json`**: Raw JSON output from `signaltest`

---

## Interpreting results

Example KPI lines (from `result.txt`):

- Per-iteration:
  - `iteration-1-t0-min-latency pass 187 us`
  - `iteration-1-t0-avg-latency pass 4801.31 us`
  - `iteration-1-t0-max-latency pass 7747 us`
- Aggregate (all threads/iterations):
  - `signaltest-all-max-latency-max pass 18796 us`
  - `signaltest-worst-thread-id pass 20 id`

If any iteration run fails, JSON is missing, or parsing fails, the wrapper marks the test as **FAIL**.

---

## LAVA integration

A typical qcom-linux-testkit LAVA test definition will:
1. `cd` into the test directory
2. execute `./run.sh ... || true`
3. upload/send result file via `send-to-lava.sh SignalTest.res`

Example `run` steps:

```yaml
run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Kernel/RT-tests/SignalTest
    - ./run.sh --duration "${DURATION}" --iterations "${ITERATIONS}" --background-cmd "${BACKGROUND_CMD}" --prio "${PRIO}" --threads "${THREADS}" --binary "${BINARY}" --out "${OUT_DIR}" || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh SignalTest.res
```

---

## Notes / best practices

- Run on an RT-enabled kernel for meaningful RT latency characterization.
- Consider setting CPU governor to `performance` for tighter jitter bounds, if allowed by your lab policy.
- Oversubscribing threads (threads >> cores) can inflate average/max latency and jitter.
- Use `BACKGROUND_CMD` to reproduce realistic system load conditions.

---

## Troubleshooting

### Test is SKIP
Common causes:
- `signaltest` binary not found or not executable
- `lib_rt.sh` not loaded or missing parser/aggregator helpers
- missing basic tools

### Test is FAIL
Common causes:
- `signaltest` non-zero exit code
- JSON output not created
- Parser failed (malformed JSON or unexpected schema)

Check:
- `logs_SignalTest/signaltest_stdout_iterN.log`
- `logs_SignalTest/signaltest-N.json`
- `logs_SignalTest/result.txt`

---

## Maintainers

Qualcomm Linux Testkit team (internal). Update this README alongside any interface changes to `run.sh`.
