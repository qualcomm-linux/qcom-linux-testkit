# OpenCV Test/Perf Suite Runner — README
*(Updated 2025-10-15 10:33:13Z)*

This README documents the **OpenCV-only** test/performance suite runner (`run.sh`) that auto-discovers
OpenCV gtest binaries (`opencv_test_*`) and perf binaries (`opencv_perf_*`), runs them with a unified
interface, and produces a single summary with correct exit codes. Camera tests are **not** included here.

---

## What’s new / enhancements

- **Auto-discovery** of `opencv_test_*` and `opencv_perf_*` from `--build-dir`, its `bin/`, and `$PATH`.
- **Per-binary skip** when a test/perf binary isn’t installed—suite continues and overall result only fails when any test fails.
- **Filter precedence**: `--filter` > `GTEST_FILTER` > `GTEST_FILTER_STRING` > `*` (default).
- **OPENCV_TEST_DATA_PATH**: auto-exported if not set (tries common locations), or override via `--testdata`.
- **Detailed logging**: start/end banners per test, exact binary path, **full arguments**, and log file path.
- **Performance defaults** for `opencv_perf_*`:
  `--perf_impl=plain --perf_min_samples=1 --perf_force_samples=1 --perf_verify_sanity --skip_unstable=1`  
  (override with `--perf-args "..."`).
- **List mode** (`--list`): shows gtest test names for each binary without executing them.
- **Robust summary**: per-binary PASS/FAIL/SKIP table, **Totals**, and overall result written to `opencv_suite.res`.
- **Zero-tests treated as SKIP**: when a binary returns success but runs zero tests.
- **Timeout** support per run (`--timeout <sec>`, requires `timeout` tool).

---

## Usage

```bash
# Common env (optional)
export OPENCV_TEST_DATA_PATH=/usr/share/opencv4/testdata
export GTEST_FILTER_STRING='-tracking_GOTURN.GOTURN/*'   # Global default filter

# Basic help
./run.sh --help
```

### Run a single binary
```bash
# Let the script locate it on $PATH/build-dir
./run.sh --bin opencv_test_sfm

# With an explicit filter (overrides env)
./run.sh --bin opencv_test_sfm --filter 'PoseEstimation*'

# With extra args passed through
./run.sh --bin opencv_test_sfm --args '--gtest_also_run_disabled_tests'
```

### Run full suites (auto-discovery)
```bash
# Accuracy only (opencv_test_*)
./run.sh --suite accuracy

# Performance only (opencv_perf_*) with default perf args
./run.sh --suite performance

# Everything
./run.sh --suite all
```

### Performance args
```bash
# Override the defaults (example: more samples)
./run.sh --suite performance --perf-args '--perf_impl=plain --perf_min_samples=10 --perf_force_samples=10'
```

### Test data path
```bash
# Explicit test data root (exported to children)
./run.sh --testdata /usr/share/opencv4/testdata
```

### Repeat / shuffle / seed
```bash
./run.sh --bin opencv_test_core --repeat 5 --shuffle --seed 123
```

### List tests in a binary
```bash
./run.sh --bin opencv_test_imgproc --list
```

### Timeout
```bash
./run.sh --suite accuracy --timeout 600
```

### Working directory for execution
```bash
./run.sh --cwd /tmp
```

---

## Environment variables honored

- `OPENCV_TEST_DATA_PATH` — path provided to OpenCV tests. Auto-discovered if not set; can be overridden by `--testdata`.
- `GTEST_FILTER` — gtest filter (overridden by `--filter`).
- `GTEST_FILTER_STRING` — alternate filter env (used if `--filter` and `GTEST_FILTER` are not set).

**Filter resolution order:** `--filter` > `GTEST_FILTER` > `GTEST_FILTER_STRING` > `*`.

Example:
```bash
export GTEST_FILTER_STRING='-tracking_GOTURN.GOTURN/*'
./run.sh --suite accuracy
```

---

## Logs, artifacts, and exit codes

- **Per-run logs**: logs are written under a logs directory (default: `./logs`) as `<binary>_<timestamp>.log`
- **Summary table**: printed to stdout and written to `opencv_suite.summary`
- **Result list**: per-binary results in `opencv_suite.reslist`
- **Overall result**: `opencv_suite.res` contains `PASS`, `FAIL`, or `SKIP`

**Exit codes:**
- `0` — At least one test ran and **all** executed tests passed
- `1` — At least one test failed
- `2` — No tests executed (all missing/empty) → suite considered **SKIP**

**Zero tests** (e.g., filtered out) are treated as **SKIP** for that binary.

---

## Example session

```text
[INFO] 1970-01-01 02:36:14 - ========= Starting OpenCV Suite at 1970-01-01 02:36:14 =========
[INFO] 1970-01-01 02:36:14 - ----- START opencv_test_sfm @ 1970-01-01 02:36:14 -----
[INFO] 1970-01-01 02:36:14 - Running opencv_test_sfm
[INFO] 1970-01-01 02:36:14 - Binary : /usr/bin/opencv_test_sfm
[INFO] 1970-01-01 02:36:14 - OPENCV_TEST_DATA_PATH=/usr/share/opencv4/testdata
[INFO] 1970-01-01 02:36:14 - GTEST_FILTER_STRING=-tracking_GOTURN.GOTURN/*
[INFO] 1970-01-01 02:36:14 - Args : --gtest_color=yes --gtest_filter=-tracking_GOTURN.GOTURN/*
[INFO] 1970-01-01 02:36:14 - Log : /var/Runner/suites/Multimedia/OpenCV/opencv_suite/logs/opencv_test_sfm_19700101-023614.log
[PASS] 1970-01-01 02:36:14 - opencv_test_sfm : PASS
[INFO] 1970-01-01 02:36:14 - ----- END opencv_test_sfm (rc=0, PASS) @ 1970-01-01 02:36:14 -----

========= OpenCV Suite Summary =========
TEST                             RES  LOG
opencv_test_sfm                  PASS /var/Runner/suites/Multimedia/OpenCV/opencv_suite/logs/opencv_test_sfm_19700101-023614.log
----------------------------------------
Totals: PASS=1 FAIL=0 SKIP=0
```

---

## Troubleshooting

- **Binary not found** → reported as `SKIP`; check that the package containing that `opencv_test_*`/`opencv_perf_*` is installed, or point `--build-dir` to your build root.
- **No tests run** → verify `--filter`/`GTEST_FILTER(_STRING)` patterns; tests filtered out lead to `SKIP` for that binary.
- **Test data missing** → set `--testdata` or `OPENCV_TEST_DATA_PATH` to your `opencv_extra/testdata` (or distro path like `/usr/share/opencv4/testdata`).
- **Long perf runs** → adjust `--perf-args` (e.g., reduce `--perf_min_samples`) or use `--timeout`.

---

## Original README (verbatim, user-supplied)

> The content below is pasted verbatim from your uploaded README for reference.

---

# OpenCV Test/Perf Suite Runner (`run.sh`)

A single script that auto-discovers and runs all installed **OpenCV accuracy tests** (`opencv_test_*`) and **performance tests** (`opencv_perf_*`) on the target.  
It handles per-binary **PASS/FAIL/SKIP**, prints a **suite summary**, writes artifacts, and returns CI-friendly **exit codes**:

- **0 = PASS**, **1 = FAIL**, **2 = SKIP** (overall PASS unless any binary fails)

The script also exports helpful environment variables (e.g., `OPENCV_TEST_DATA_PATH`, `GTEST_FILTER_STRING`) and applies sane defaults for perf runs.

---

## Download

Pick one option and replace placeholders with your real path:

**Option A — from your GitHub repo (raw link):**
```bash
curl -fsSL https://raw.githubusercontent.com/<ORG>/<REPO>/<BRANCH>/path/to/run.sh -o run.sh
chmod +x run.sh
```

**Option B — from a hosted file URL:**
```bash
curl -fsSL https://<your-host>/artifacts/opencv/run.sh -o run.sh
chmod +x run.sh
```

> If your project uses this script in-tree, you can obviously skip the download step.

---

## Requirements

- POSIX shell (`/bin/sh`) and coreutils (`find`, `sort`, etc.)
- Optional: `timeout` (GNU coreutils) for `--timeout` support
- The script sources your existing environment helpers:
  - `init_env` (auto-located, walking up from the script directory)
  - `functestlib.sh` (via `$TOOLS/functestlib.sh`)
- OpenCV gtest/perf binaries on the **PATH** or under your **build directory**:
  - Examples (from your target list):  
    `opencv_test_core`, `opencv_test_imgproc`, `opencv_perf_imgproc`, …  
    (auto-discovered; no static list required)

---

## Quick Start

Run **all** discovered accuracy + performance suites:
```bash
./run.sh
```

Only **accuracy** tests:
```bash
./run.sh --suite accuracy
```

Only **performance** tests:
```bash
./run.sh --suite performance
```

Run a **single** binary:
```bash
./run.sh --bin opencv_test_sfm
```

---

## Environment

- `OPENCV_TEST_DATA_PATH`  
  Path to OpenCV test data (auto-detected if not provided: `/var/testdata`, `/usr/share/opencv4/testdata`, etc.).

- `GTEST_FILTER` or `GTEST_FILTER_STRING`  
  Global GoogleTest filter applied to every run.  
  Example (exclude GOTURN):
  ```bash
  export GTEST_FILTER_STRING='-tracking_GOTURN.GOTURN/*'
  ./run.sh
  ```

> Precedence: `--filter` (CLI) → `GTEST_FILTER` → `GTEST_FILTER_STRING` → `*`

---

## Common Options

```text
--suite <accuracy|performance|all>   Defaults to all
--bin <path|name>                    Run only one binary (e.g., opencv_test_core)
--build-dir <path>                   Where to search for binaries (default . and ./bin)
--cwd <path>                         Working directory for each run (default .)
--testdata <path>                    Export OPENCV_TEST_DATA_PATH to this dir
--filter <pattern>                   GoogleTest filter (e.g., "*", "-tracking_GOTURN.GOTURN/*")
--repeat <N>                         GoogleTest repeat count
--shuffle                            Enable GoogleTest shuffle
--seed <N>                           GoogleTest random seed
--args "<args>"                      Extra args passed to ALL binaries
--perf-args "<args>"                 Extra args for perf binaries (defaults provided)
--timeout <sec>                      Kill a run after N seconds (requires `timeout`)
--list                               List tests (per-binary) and exit (treated as PASS)
```

**Default perf args** (if not provided):  
`--perf_impl=plain --perf_min_samples=1 --perf_force_samples=1 --perf_verify_sanity --skip_unstable=1`

---

## Behavior & Exit Codes

- Each discovered binary is executed independently:
  - **Not found** → **SKIP**
  - **Runs but zero tests** (e.g., filter excludes everything) → **SKIP**
  - **Exit code 0** → **PASS**
  - **Non-zero / timeout** → **FAIL**
- **Overall result**:
  - Any **FAIL** → overall **FAIL** (exit **1**)
  - Else if at least one **PASS** → overall **PASS** (exit **0**)
  - Else (only SKIPs) → overall **SKIP** (exit **2**)

---

## Artifacts

- Logs directory: `${LOG_DIR:-./logs}`  
  Each binary writes `logs/<binary>_<timestamp>.log`
- Suite summary: `./opencv_suite.summary` (table of results + log paths)
- Result file: `./opencv_suite.res` with `PASS`/`FAIL`/`SKIP`

Example summary line:
```
opencv_test_sfm                 PASS  logs/opencv_test_sfm_20250101-120000.log
```

---

## Examples

Exclude GOTURN for all runs + custom testdata:
```bash
export OPENCV_TEST_DATA_PATH=/var/testdata
export GTEST_FILTER_STRING='-tracking_GOTURN.GOTURN/*'
./run.sh --suite all
```

Run only performance with explicit args and timeout:
```bash
./run.sh --suite performance   --perf-args "--perf_impl=plain --skip_unstable=1"   --timeout 600
```

Run one binary with extra args:
```bash
./run.sh --bin opencv_test_core --args "--gapi_backend=cpu"
```

---

## Troubleshooting

- **No binaries discovered** → check `PATH` and `--build-dir`.
- **Zero tests executed** → your `--filter` (or env filter) may exclude all tests.
- **Missing testdata** → export `OPENCV_TEST_DATA_PATH` explicitly.
- **Timeout fails** → ensure `timeout` is installed or drop `--timeout`.

---

## License

BSD-3-Clause (same as the script).

