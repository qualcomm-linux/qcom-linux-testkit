# PTSEMATest (rt-tests) — qcom-linux-testkit

PTSEMATest is a wrapper around **rt-tests `ptsematest`** to measure POSIX threads synchronization latency (threads synchronized using POSIX primitives, reported per-thread min/avg/max latencies).

This test case is integrated into **qcom-linux-testkit** with a consistent flow used across other RT-tests:

- Runs `ptsematest` in **JSON** mode (`--json=<file>`)
- Parses KPI using `Runner/utils/lib_rt.sh` (**no python required**)
- Writes detailed KPI lines to `result.txt`
- Writes a **PASS/FAIL/SKIP** summary to `PTSEMATest.res`
- Always exits `0` (LAVA-friendly). Use `PTSEMATest.res` for gating.

---

## Location

```
Runner/suites/Kernel/RT-tests/PTSEMATest/
```

---

## Prerequisites

- Must run as **root**
- `ptsematest` binary must be present and executable:
  - Either available in `PATH` (e.g. provided by rt-tests package), or
  - Provided explicitly via `--binary <path>`
- `init_env` must exist somewhere above the test directory so the runner can load:
  - `Runner/utils/functestlib.sh`
  - `Runner/utils/lib_rt.sh`

The script performs dependency checks for basic tools (e.g. `uname`, `awk`, `grep`, `tr`, `tee`, etc.). If required pieces are missing, the test will **SKIP**.

---

## What gets measured

For each iteration, the test produces per-thread latency KPIs emitted by `perf_parse_rt_tests_json` (from `lib_rt.sh`):

- `t<tid>-min-latency pass <N> us`
- `t<tid>-avg-latency pass <N> us`
- `t<tid>-max-latency pass <N> us`
- `ptsematest-ok pass 1 ok` (or `0 ok` on failure)
- `ptsematest-rc pass <rc> rc`
- `ptsematest pass|fail`

The wrapper prefixes iteration KPI lines like:

- `iteration-1-t0-max-latency pass 268 us`
- `iteration-2-t7-avg-latency pass 2.47 us`
- ...

Aggregate KPIs are computed from **ALL threads across ALL iterations** using `rt_aggregate_iter_latencies` (from `lib_rt.sh`), for example:

- `ptsematest-all-max-latency-min pass ... us`
- `ptsematest-all-max-latency-mean pass ... us`
- `ptsematest-all-max-latency-max pass ... us`
- `ptsematest-worst-thread-max-latency pass ... us`
- `ptsematest-worst-thread-id pass ... id`

---

## Running locally

### Examples

Run `ptsematest` for 1 minute, 2 iterations, with explicit binary:

```sh
cd Runner/suites/Kernel/RT-tests/PTSEMATest
./run.sh --binary /tmp/ptsematest --duration 1m --iterations 2
```

Add an optional background workload (example only):

```sh
./run.sh --duration 2m --iterations 3 --background-cmd "stress-ng --cpu 4 --timeout 2m"
```

### CLI options

`run.sh` supports the same parameter flow as other RT-tests wrappers:

- `--duration <STR>` : Duration passed to `ptsematest -D` (default: `5m`)
- `--iterations <N>` : Number of iterations (default: `1`)
- `--background-cmd <CMD>` : Optional background workload during measurement
- `--binary <PATH>` : Explicit `ptsematest` binary path
- `--out <DIR>` : Output directory (default: `./logs_PTSEMATest` under the test directory)
- `--result <FILE>` : Output KPI file (default: `<OUT_DIR>/result.txt`)
- `--prio <N>` : RT priority (default: `98`)
- `--mode-s <true|false>` : Include `-S` (default: `true`)
- `--quiet <true|false>` : Include `-q` (default: `true`)
- `--verbose` : Additional logs
- `-h|--help` : Help

> Note: The wrapper is designed to be POSIX/ShellCheck-friendly and consistent with other RT-tests in this repo.

---

## Output files

By default outputs are written under:

```
Runner/suites/Kernel/RT-tests/PTSEMATest/logs_PTSEMATest/
```

Typical outputs:

- `PTSEMATest.res`  
  Summary line for gating:
  - `PTSEMATest PASS`
  - `PTSEMATest FAIL`
  - `PTSEMATest SKIP`

- `logs_PTSEMATest/result.txt`  
  KPI lines for LAVA artifact capture / debugging.

- `logs_PTSEMATest/ptsematest-<iter>.json`  
  Raw JSON from `ptsematest` for each iteration.

- `logs_PTSEMATest/ptsematest_stdout_iter<iter>.log`  
  Console/stdout log captured per iteration.

---

## LAVA YAML (test definition)

Use the standardized RT-tests YAML flow used across this repo:

```yaml
metadata:
  name: ptsematest
  format: "Lava-Test Test Definition 1.0"
  description: "Run rt-tests ptsematest in JSON mode and parse results without requiring python3."
  os:
    - linux
  scope:
    - performance
    - preempt-rt

params:
  DURATION: "5m"
  BACKGROUND_CMD: ""
  ITERATIONS: "1"

  PRIO: "98"
  MODE_S: "true"
  QUIET: "true"

  BINARY: ""
  OUT_DIR: "./logs_PTSEMATest"

run:
  steps:
    - REPO_PATH=$PWD
    - cd Runner/suites/Kernel/RT-tests/PTSEMATest
    - ./run.sh --duration "${DURATION}" --iterations "${ITERATIONS}" --background-cmd "${BACKGROUND_CMD}" --prio "${PRIO}" --mode-s "${MODE_S}" --quiet "${QUIET}" --binary "${BINARY}" --out "${OUT_DIR}" || true
    - $REPO_PATH/Runner/utils/send-to-lava.sh PTSEMATest.res
```

---

## Troubleshooting

### Clock looks invalid (1970)

RT latency numbers can be misleading if the system time starts at epoch. The runner uses `ensure_reasonable_clock` (if available) and may seed time from kernel build time when no network is available.

If your environment has NTP or RTC issues, fix them before relying on performance baselines.

### Binary not found

- Ensure `ptsematest` is installed and in `PATH`, or
- Provide an explicit path: `--binary /tmp/ptsematest`

### Result says SKIP

Common causes:
- Missing dependencies (basic shell tools)
- `lib_rt.sh` not loaded via `init_env`
- Binary not executable

Check console logs for the SKIP reason and confirm `init_env` + `Runner/utils` are present.

---

## Notes for CI

- The runner always exits `0`. CI/LAVA should gate on:
  - `Runner/suites/Kernel/RT-tests/PTSEMATest/PTSEMATest.res`
- For deeper analysis, archive:
  - `logs_PTSEMATest/result.txt`
  - `logs_PTSEMATest/*.json`
  - `logs_PTSEMATest/*stdout*`
