# SSDD

## Overview

**SSDD** is an rt-tests utility that stresses `ptrace` single-step behavior by creating multiple tracer/tracee pairs and repeatedly issuing `PTRACE_SINGLESTEP` operations. It is useful for checking scheduler behavior and interference when many tracer/tracee pairs are running concurrently.

In the qcom-linux-testkit flow, the **SSDD** wrapper follows the same style as the other RT tests:
- structured logging using `functestlib.sh`
- JSON based result capture
- parsed KPI output without requiring Python at runtime
- `.res` summary file for LAVA gating
- `result.txt` with detailed per-iteration and aggregate KPI
- heartbeat/progress logs for long runs

## What the test does

The test:
- launches a configurable number of tracer/tracee pairs
- performs a configurable number of `PTRACE_SINGLESTEP` iterations per pair
- verifies `waitpid(2)` return behavior during stepping
- records final test results in JSON format
- emits pass/fail style KPI lines consumable by the testkit

## Defaults

The wrapper should keep defaults aligned with the tool defaults unless you intentionally override them:

- **forks**: `10`
- **iters**: `10000`
- **iterations** (wrapper level): `1`
- **background workload**: empty
- **quiet**: enabled when supported by wrapper design

## Binary usage reference

`ssdd` supports the following options:

- `-f`, `--forks=NUM`  
  Number of tracer/tracee pairs to fork. Default is `10`.

- `-h`, `--help`  
  Display usage.

- `-i`, `--iters=NUM`  
  Number of `PTRACE_SINGLESTEP` iterations per tracer/tracee pair. Default is `10000`. Must be at least `1`.

- `--json=FILENAME`  
  Write final results into `FILENAME` in JSON format.

## Expected wrapper behavior

The qcom-linux-testkit `run.sh` for **SSDD** should follow the same conventions used in the earlier RT test wrappers:

- detect and source `init_env`
- load `functestlib.sh` and `lib_rt.sh`
- resolve `TESTNAME="SSDD"`
- write summary result to `SSDD.res`
- write detailed logs under `logs_SSDD/`
- support explicit `--binary PATH`
- support wrapper iteration count separate from `ssdd --iters`
- preserve partial results on interrupt when practical
- always exit `0` for LAVA friendliness, with gating based on `SSDD.res`

## Suggested wrapper options

The wrapper can expose these arguments in the same style as the other RT tests:

### Wrapper level options

- `--out DIR`  
  Output directory.

- `--result FILE`  
  Result text file path.

- `--iterations N`  
  Number of wrapper iterations.

- `--background-cmd CMD`  
  Optional background workload.

- `--binary PATH`  
  Explicit path to the `ssdd` binary.

- `--progress-every N`  
  Print iteration progress every N iterations.

- `--heartbeat SEC`  
  Periodic liveness logging while the test is running.

- `--verbose`  
  Enable extra wrapper logs.

### SSDD specific options

- `--forks NUM`  
  Maps to `-f` / `--forks=NUM`.

- `--iters NUM`  
  Maps to `-i` / `--iters=NUM`.

## Example commands

Run with defaults from PATH:

```sh
./run.sh
```

Run a specific binary with more tracer/tracee pairs:

```sh
./run.sh --binary /tmp/ssdd --forks 16 --iters 20000
```

Run multiple wrapper iterations:

```sh
./run.sh --binary /tmp/ssdd --forks 8 --iters 5000 --iterations 3
```

Run with a background workload:

```sh
./run.sh --binary /tmp/ssdd --forks 12 --iters 10000 --background-cmd "stress-ng --cpu 4 --timeout 60"
```

## Output files

A typical wrapper layout should look like this:

```text
SSDD/
|-- SSDD.res
|-- run.sh
|-- ssdd.yaml
|-- README.md
`-- logs_SSDD/
    |-- result.txt
    |-- iter_kpi.txt
    |-- agg_kpi.txt
    |-- ssdd-1.json
    |-- ssdd_stdout_iter1.log
    `-- tmp_result_one.txt
```

### Important files

- **SSDD.res**  
  Final summary for LAVA. Example:
  - `SSDD PASS`
  - `SSDD FAIL`
  - `SSDD SKIP`

- **logs_SSDD/result.txt**  
  Detailed parsed KPI for all iterations.

- **logs_SSDD/iter_kpi.txt**  
  Per-iteration KPI lines.

- **logs_SSDD/agg_kpi.txt**  
  Aggregate KPI lines across iterations.

- **logs_SSDD/ssdd-<n>.json**  
  Raw JSON result emitted by the binary.

- **logs_SSDD/ssdd_stdout_iter<n>.log**  
  Captured stdout/stderr for each iteration.

## Pass, fail, and skip model

Typical wrapper result handling should be:

- **PASS** when all iterations run successfully, JSON is generated, and parsed verdicts indicate success
- **FAIL** when the binary exits unexpectedly, JSON is missing, or parsing indicates failure
- **SKIP** when required tools are missing, the binary is unavailable, or the run is intentionally interrupted and the wrapper is designed to preserve partial results

## Notes for integration

- Keep the script POSIX compliant and ShellCheck clean.
- Avoid `A && B || C` style patterns.
- Reuse existing helpers from `functestlib.sh` and `lib_rt.sh` instead of inventing new wrapper-local helper names unless necessary.
- Preserve naming consistency with earlier RT tests.
- Use the same logging style and result file conventions as `PMQTest`, `PTSEMATest`, `SignalTest`, `SVSematest`, and `CyclicDeadline`.

## Suggested YAML parameters

A matching YAML would typically expose:

- `FORKS`
- `ITERS`
- `ITERATIONS`
- `BACKGROUND_CMD`
- `BINARY`
- `OUT_DIR`
- `VERBOSE`
- `PROGRESS_EVERY`
- optional heartbeat parameter if your wrapper supports it

## Summary

**SSDD** is a useful RT stress test for validating `ptrace` single-step behavior under concurrent tracer/tracee activity. In qcom-linux-testkit it should be wrapped exactly like the other RT tests: structured logs, JSON parsing, deterministic result files, and LAVA-friendly summary handling.
