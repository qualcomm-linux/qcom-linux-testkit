# Hackbench (qcom-linux-testkit)

Hackbench is both a benchmark and a stress test for the Linux kernel scheduler. It creates groups of communicating tasks (threads or processes) via sockets or pipes and measures how long they take to exchange data.

This test wrapper runs `hackbench` for **N iterations**, captures all output, parses `Time:` samples, and emits KPI lines (mean/min/max and worst-sample), plus a LAVA-friendly `.res` verdict.

---

## Location

- Test: `Runner/suites/Kernel/RT-tests/Hackbench/run.sh`
- Shared helpers: `Runner/utils/lib_rt.sh`
- Logging/helpers: `Runner/utils/functestlib.sh`

---

## What this test produces

### Console (examples)

You will see high-signal context and KPI lines, for example:

- `Hackbench: uname -a: ...`
- `Hackbench: sched_rt_runtime_us=...`
- `Hackbench: hackbench opts: -s 100 -l 100 -g 10 -f 20 -T`
- `hackbench-mean pass 0.220660 s`
- `hackbench-min pass 0.185000 s`
- `hackbench-max pass 0.272000 s`
- `hackbench-worst pass 0.272000 s` *(worst-sample = max for the run)*

> Note: On some hackbench versions, the output lines are `Time: <seconds>`.

### Files

By default, output is written under:

- `logs_Hackbench/` (or `OUT_DIR` if overridden)
  - `hackbench-output-host.txt` – raw log with all `Time:` samples
  - `parsed_hackbench.txt` – parsed KPI lines
  - `result.txt` – same KPI lines used for LAVA result submission
- `Hackbench.res` – single-line verdict (`Hackbench PASS|FAIL|SKIP`)

---

## Requirements

### Mandatory
- `hackbench` binary (either in `PATH` or provided via `--binary`)
- Standard tools: `uname`, `awk`, `sed`, `grep`, `tr`, `head`, `tail`, `mkdir`, `cat`, `sh`, `tee`, `sleep`, `kill`, `date`

The script uses your testkit’s `check_dependencies` to validate the above.

### Optional (nice-to-have)
- `ensure_reasonable_clock()` from `functestlib.sh`  
  If available, it will be used to avoid epoch timestamps (e.g., 1970) in logs.
- Background workload command (`--background-cmd`) to apply system load while measuring.

---

## Usage

Run from the test folder:

```sh
cd Runner/suites/Kernel/RT-tests/Hackbench
./run.sh
```

### Common examples

Run 200 iterations with threaded mode:

```sh
./run.sh --iteration 200 --threads true
```

Run with pipes (instead of sockets):

```sh
./run.sh --iteration 200 --pipe true
```

Explicit hackbench binary path:

```sh
./run.sh --binary /tmp/hackbench --iteration 200
```

Increase message size / loops / groups:

```sh
./run.sh --datasize 1024 --loops 200 --grps 20 --fds 20 --iteration 100
```

Add background workload:

```sh
./run.sh --background-cmd "sh -c 'while :; do :; done'" --iteration 200
```

Control progress logging (default: every 50 iterations):

```sh
./run.sh --iteration 500 --progress-every 25
```

Verbose mode:

```sh
./run.sh --verbose
```

---

## Parameters

The wrapper accepts both **CLI arguments** and **environment variables**.  
If both are set, the CLI argument wins.

### Output control
- `--out DIR` / `OUT_DIR`  
  Output directory (default: `./logs_Hackbench` under the test path).
- `--result FILE` / `RESULT_TXT`  
  KPI output file (default: `${OUT_DIR}/result.txt`).
- `--log FILE` / `TEST_LOG`  
  Raw hackbench log (default: `${OUT_DIR}/hackbench-output-host.txt`).

### Hackbench workload knobs (Linaro-style)
- `--iteration N` / `ITERATION` (default: `1000`)  
- `--target host|kvm` / `TARGET` *(informational label only)*  
- `--datasize BYTES` / `DATASIZE` → `-s`
- `--loops N` / `LOOPS` → `-l`
- `--grps N` / `GRPS` → `-g`
- `--fds N` / `FDS` → `-f`
- `--pipe true|false` / `PIPE`  
  Adds `-p` when true.
- `--threads true|false` / `THREADS`  
  Adds `-T` when true. (Default is process mode.)

### Testkit extras
- `--background-cmd CMD` / `BACKGROUND_CMD`  
  Runs a background workload during the benchmark (best-effort stop on exit).
- `--binary PATH` / `BINARY`  
  Explicit `hackbench` path.
- `--progress-every N` / `PROGRESS_EVERY`  
  Progress log cadence (default: `50`).
- `--verbose` / `VERBOSE=1`

---

## Result parsing and KPIs

The parsing is done by `rt_hackbench_parse_times` from `Runner/utils/lib_rt.sh`.

It extracts all lines like:

```
Time: 0.210
```

…and computes:

- `hackbench-mean pass <seconds> s`
- `hackbench-min pass <seconds> s`
- `hackbench-max pass <seconds> s`
- `hackbench-worst pass <seconds> s` *(worst-sample = max)*

These are written to:
- `${OUT_DIR}/parsed_hackbench.txt`
- `${OUT_DIR}/result.txt`

---

## LAVA integration

A typical test definition YAML can run this via CLI args:

```yaml
run:
  steps:
    - cd Runner/suites/Kernel/RT-tests/Hackbench
    - >-
      ./run.sh
      --out "${OUT_DIR}"
      --iteration "${ITERATION}"
      --datasize "${DATASIZE}"
      --loops "${LOOPS}"
      --grps "${GRPS}"
      --fds "${FDS}"
      --pipe "${PIPE}"
      --threads "${THREADS}"
      --background-cmd "${BACKGROUND_CMD}"
      --binary "${BINARY}"
      --progress-every "${PROGRESS_EVERY}"
      $( [ "${VERBOSE}" = "1" ] && echo "--verbose" )
      || true
    - ../../../../utils/send-to-lava.sh Hackbench.res
```

> LAVA exports `params:` variables automatically into the test shell environment.  
> Using CLI args makes the command line explicit and reproducible, matching the Linaro style.

---

## Troubleshooting

### 1) Timestamps show 1970-01-01
- Your board clock is likely not set.
- If `ensure_reasonable_clock()` exists in `functestlib.sh`, the script can call it before running.
- Otherwise, set time via NTP / RTC / manual `date`.

### 2) No KPI lines (mean/min/max)
- Check that `${OUT_DIR}/hackbench-output-host.txt` contains `Time:` lines.
- If the hackbench output format differs (some variants use `Time:` with different formatting), update the parser in `lib_rt.sh` accordingly.

### 3) Hackbench not found
- Provide `--binary /path/to/hackbench`, or ensure `hackbench` is in `PATH`.

### 4) High variance / outliers
- Run with a background workload to characterize worst-case scheduling.
- Increase iterations to stabilize mean.
- Pin CPU frequency governor if needed (platform policy dependent).

---

## Notes

- The `.res` file is always created for LAVA.
- The script is intended to be POSIX `sh` compatible and CI-friendly.
