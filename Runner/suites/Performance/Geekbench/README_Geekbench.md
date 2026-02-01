# Geekbench Performance (Geekbench)

This suite runs **Geekbench 6** on embedded Linux targets (Yocto / LE / Ubuntu variants) and produces:
- **Live console progress** (workload-by-workload + heartbeat)
- **Per-iteration logs**
- **CSV outputs** (readable summary + workloads, and optional “all metrics” long format)
- **LAVA-friendly result** file (`Geekbench.res`) with PASS/FAIL/SKIP

It is designed to work inside the **qcom-linux-testkit** Runner layout and to be overridden from **LAVA YAML params** as well as **script CLI args**.

---

## Contents

- [What this suite does](#what-this-suite-does)
- [Prerequisites](#prerequisites)
- [Where to place Geekbench](#where-to-place-geekbench)
- [License and unlocking](#license-and-unlocking)
- [Outputs](#outputs)
- [Running locally](#running-locally)
- [LAVA integration](#lava-integration)
- [All supported Geekbench options](#all-supported-geekbench-options)
- [Runner options and environment variables](#runner-options--environment-variables)
- [Examples](#examples)
- [Baseline / gating (.conf)](#baseline--gating-conf)
- [Troubleshooting](#troubleshooting)

---

## What this suite does

By default, Geekbench runs the **CPU benchmark**. This runner:
1. Detects `init_env` and loads `functestlib.sh` + `lib_performance.sh`.
2. Optionally forces CPU governors to `performance` (best-effort).
3. Runs Geekbench **N times** (`RUNS` / `--runs`) with **live progress**:
   - raw Geekbench output is streamed to console
   - progress lines are emitted as `log_info`:
     - `Progress, <label>, entered Single-Core`
     - `Progress, <label>, Single-Core, <idx>, <workload>`
     - heartbeat `still running` messages every `HEARTBEAT_SECS`
4. Parses Geekbench text output and dumps results to CSV:
   - `geekbench_summary.csv`: totals + sub-scores
   - `geekbench_workloads.csv`: per-workload score + throughput string
   - (optional) `geekbench_all_metrics.csv`: long-format “everything” metrics
5. Writes `Geekbench.res` with `PASS/FAIL/SKIP` (and always exits `0` for LAVA friendliness).

---

## Prerequisites

### Required tools on target
- `geekbench_aarch64` (or `geekbench`) in `PATH`
- Basic POSIX tools:
  - `awk`, `sed`, `grep`, `date`, `mkfifo`, `tee`, `sleep`
- Optional:
  - `stdbuf` (improves streaming output)
  - `taskset` (only required if you use `--core-list` / `GEEKBENCH_CORE_LIST`)

### Required Runner environment
- `Runner/init_env` must exist (unless you implement a standalone mode)
- `Runner/utils/functestlib.sh`
- `Runner/utils/lib_performance.sh`

---

## Where to place Geekbench

Geekbench is typically distributed as a standalone binary or a small directory. Common patterns:

- Put the binary in a standard location and add it to PATH:
  ```sh
  install -m 0755 geekbench_aarch64 /usr/local/bin/
  ```

- Or keep it alongside the suite and reference it:
  ```sh
  ./run.sh --bin ./geekbench_aarch64
  ```

**Binary selection precedence**
1. `--bin <PATH>` (CLI)
2. `GEEKBENCH_BIN` (env)
3. `geekbench_aarch64` (in `PATH`)
4. `geekbench` (in `PATH`)

---

> **Note (runner convenience):** `run.sh` accepts `--bin` as **either** a direct executable (e.g. `/var/Geekbench-6.1.0-LinuxARM/geekbench_aarch64`) **or** the **bundle directory** (e.g. `/var/Geekbench-6.1.0-LinuxARM`).  
> If the Geekbench files are not executable (common when copied over), the runner will try to fix permissions (`chmod +x`) before running.

## License and unlocking

Geekbench supports unlocking with:

```
--unlock EMAIL KEY
```

This runner supports unlocking via:
- CLI:
  ```sh
  ./run.sh --unlock "user@example.com" "YOUR-KEY"
  ```
- or LAVA/YAML env vars:
  - `GEEKBENCH_UNLOCK_EMAIL`
  - `GEEKBENCH_UNLOCK_KEY`

**Notes**
- Unlock is executed once before the benchmark loop (best-effort).
- If unlock fails, the runner logs a warning and continues the benchmark.


> **Pro-only options:** switches like `--export-license`, `--section`, `--workload-list`, `--single-core`, `--multi-core`, `--cpu-workers`, `--iterations`, and `--workload-gap` are accepted **only after a successful unlock**.  
> If you run the runner with Pro-only switches before unlocking, Geekbench exits non-zero (often `255`) and the runner will likely report **FAIL** for that run.

### Exporting a standalone license (Pro)
Geekbench supports:

```
--export-license DIR
```

Pass it via:
- CLI: `./run.sh --export-license /tmp/gb-license`
- env: `GEEKBENCH_EXPORT_LICENSE_DIR=/tmp/gb-license`

**Important:** `--export-license` takes a **directory path**, not your email/key.  
Unlock first, then export. One convenient way (fast, no benchmark upload) is:

```sh
./run.sh --bin /var/Geekbench-6.1.0-LinuxARM \
  --unlock "geekbench@your.com" "GHJEO-...-IGN8J" \
  --export-license "/var/tmp/geekbench_license" \
  --sysinfo --no-upload
```



---

## Outputs

By default, outputs go under:
- `./geekbench_out/` (or `--outdir` / `GEEKBENCH_OUTDIR`)

Typical files:
- `geekbench_iter1.log`, `geekbench_iter2.log`, ...
- `geekbench_summary.csv`
- `geekbench_workloads.csv`
- `geekbench_final_summary.txt`
- `Geekbench.res` (in the suite directory, unless overridden)

### CSV formats

**1) Summary CSV**
Header:
```
timestamp,test,iteration,single_total,single_integer,single_fp,multi_total,multi_integer,multi_fp
```

**2) Workloads CSV**
Header:
```
timestamp,test,iteration,core_mode,workload,score,throughput
```

Throughput column keeps Geekbench's printed throughput string (e.g., `156.6 MB/sec`).

**3) Optional: All metrics (long format)**
If your runner enables it, header:
```
timestamp,test,metric,iteration,value,extra
```

Where `metric` includes summary keys and workload keys, and `extra` holds `unit=... kind=...`.

---

## Running locally

From the suite directory:
```sh
cd Runner/suites/Performance/Geekbench/ || exit 1
./run.sh --runs 1 --no-upload
cat Geekbench.res
```

To pin CPUs:
```
**Important:** `--export-license` takes a **directory path**, not your email/key.  
Unlock first, then export. One convenient way (fast, no benchmark upload) is:

```sh
./run.sh --bin /var/Geekbench-6.1.0-LinuxARM \
  --unlock "geekbench@qualcomm.com" "ONGAL-...-7Y6QI" \
  --export-license "/var/tmp/geekbench_license" \
  --sysinfo --no-upload
```

sh
./run.sh --core-list "0-3" --runs 3 --no-upload
```

To run sysinfo only:
```sh
./run.sh --sysinfo
```

---

## LAVA integration

This runner is **LAVA-friendly**:
- Always exits `0`
- Writes `Geekbench.res` with `PASS/FAIL/SKIP`
- Put output dir into artifacts collection if desired

Typical LAVA step pattern:
```yaml
- cd Runner/suites/Performance/Geekbench/ || exit 0
- >
  ./run.sh
  --outdir "$OUT_DIR"
  --runs "$RUNS"
  --core-list "$CORE_LIST"
  --no-upload
  || true
- $REPO_PATH/Runner/utils/send-to-lava.sh Geekbench.res
```

You can override any option via YAML params using env vars listed below.

---

## All supported Geekbench options

Geekbench CLI supports (as provided by Geekbench `--help`):

### Licensing
- `--unlock EMAIL KEY` unlock Geekbench using EMAIL and KEY

### Load / save / export
- `--load FILE` load and display Geekbench result from FILE
- `--save FILE` save Geekbench result to FILE
- `--export-csv FILE` export result as CSV
- `--export-html FILE` export result as HTML
- `--export-json FILE` export result as JSON
- `--export-xml FILE` export result as XML
- `--export-text FILE` export result as text to FILE

### Upload
- `--upload` upload results to Geekbench Browser
- `--no-upload` do not upload results

### CPU / sysinfo
- `--cpu` run CPU benchmark
- `--sysinfo` display system information and exit

### GPU
- `--gpu [API]` run GPU benchmark (API can be `OpenCL` default)
- `--gpu-list` list available GPU platforms/devices and exit
- `--gpu-platform-id ID`
- `--gpu-device-id ID`

### Pro options
- `--section [IDs]` run specified sections
- `--workload [IDs]` run specified workloads (use with --section)
- `--workload-list` list available sections/workloads
- `--single-core` run single-core workloads
- `--multi-core` run multi-core workloads
- `--cpu-workers N` run multi-core with N threads
- `--iterations N` run workloads with N iterations
- `--workload-gap N` gap (ms) between workloads
- `--export-license DIR` export standalone license file

### Runner forwarding
Your runner supports forwarding:
- Unknown args are forwarded to Geekbench
- You can explicitly separate with `--`:
  ```sh
  ./run.sh --runs 1 -- --cpu --no-upload --iterations 3
  ```

---

## Runner options & environment variables

### Script CLI options (runner)
- `--outdir DIR` output directory
- `--res-file FILE` where to write `.res`
- `--runs N` number of Geekbench invocations (outer loop)
- `--core-list LIST` taskset CPU list (`0-3` or `0,2,4,6`)
- `--bin PATH` Geekbench binary path/name
- `--unlock EMAIL KEY` unlock (wrapper)
- `--no-perf-gov` do not force performance governor
- `--help` show help

### LAVA/YAML env vars (typical)
- `GEEKBENCH_OUTDIR`
- `GEEKBENCH_RES_FILE`
- `GEEKBENCH_RUNS`
- `GEEKBENCH_CORE_LIST`
- `GEEKBENCH_BIN`
- `GEEKBENCH_SET_PERF_GOV` (`1` or `0`)
- `GEEKBENCH_UNLOCK_EMAIL`
- `GEEKBENCH_UNLOCK_KEY`

Geekbench options via env vars:
- `GEEKBENCH_LOAD_FILE`
- `GEEKBENCH_SAVE_FILE`
- `GEEKBENCH_EXPORT_CSV_FILE`
- `GEEKBENCH_EXPORT_HTML_FILE`
- `GEEKBENCH_EXPORT_JSON_FILE`
- `GEEKBENCH_EXPORT_XML_FILE`
- `GEEKBENCH_EXPORT_TEXT_FILE`
- `GEEKBENCH_UPLOAD` / `GEEKBENCH_NO_UPLOAD`
- `GEEKBENCH_CPU`
- `GEEKBENCH_SYSINFO`
- `GEEKBENCH_GPU`
- `GEEKBENCH_GPU_LIST`
- `GEEKBENCH_GPU_PLATFORM_ID`
- `GEEKBENCH_GPU_DEVICE_ID`
- `GEEKBENCH_SECTION`
- `GEEKBENCH_WORKLOAD`
- `GEEKBENCH_WORKLOAD_LIST`
- `GEEKBENCH_SINGLE_CORE`
- `GEEKBENCH_MULTI_CORE`
- `GEEKBENCH_CPU_WORKERS`
- `GEEKBENCH_ITERATIONS`
- `GEEKBENCH_WORKLOAD_GAP`
- `GEEKBENCH_EXPORT_LICENSE_DIR`
- `GEEKBENCH_ARGS` (raw args appended at end)

---

## Examples

### 1) Default CPU benchmark (no upload)
```sh
./run.sh
```

### 1b) Point to a Geekbench bundle directory (runner will chmod +x if needed)
```sh
./run.sh --bin /var/Geekbench-6.1.0-LinuxARM --runs 1 --no-upload
```

### 2) Run 3 times, pin to CPUs 0-3 (taskset), and save results
```sh
./run.sh --runs 3 --core-list "0-3" --save /tmp/gb.result --no-upload --cpu
```

### 3) Unlock once (recommended before using Pro-only options)
```sh
./run.sh --bin /var/Geekbench-6.1.0-LinuxARM \
  --unlock "geekbench@qualcomm.com" "ONGAL-...-7Y6QI" \
  --no-upload --cpu
```

### 4) Pro (requires unlock), run single-core workloads only
```sh
./run.sh --single-core --no-upload --cpu
```

### 5) Pro (requires unlock), run multi-core with 4 workers
```sh
./run.sh --multi-core --cpu-workers 4 --no-upload --cpu
```

### 6) Export a standalone license file (requires unlock)
```sh
./run.sh --bin /var/Geekbench-6.1.0-LinuxARM \
  --unlock "geekbench@qualcomm.com" "ONGAL-...-7Y6QI" \
  --export-license "/var/tmp/geekbench_license" \
  --sysinfo --no-upload
```

### 7) List GPU platforms/devices (OpenCL) and exit
```sh
./run.sh --gpu-list
```

---

## Baseline / gating (.conf)

If your runner implements baseline gating:
- Place a baseline config like `geekbench_baseline.conf` alongside the suite
- Provide it via YAML param (example key names):
  ```yaml
  BASELINE_FILE: "/var/Runner/suites/Performance/Geekbench/geekbench_baseline.conf"
  ALLOWED_DEVIATION: "0.10"
  ```

Typical gating rules:
- Compare measured averages against goals with allowed deviation:
  - PASS if `measured >= goal * (1 - delta)`
  - FAIL otherwise

Recommended minimal gating metrics:
- `single_total`
- `multi_total`

---

## Troubleshooting

### No output / looks stuck
- Ensure `stdbuf` exists (optional) and Geekbench is actually running.
- Heartbeat lines appear every `HEARTBEAT_SECS` while Geekbench runs.
- Check per-iteration logs under `--outdir`.

### SKIP, geekbench binary not found
- Confirm `geekbench_aarch64` is in PATH or provide `--bin` / `GEEKBENCH_BIN`.

### Workload parsing looks incomplete
- Ensure Geekbench output includes the `Single-Core` / `Multi-Core` sections and `Benchmark Summary`.
- If you used `--sysinfo` / `--gpu-list` / `--load`, summary parsing is expected to be absent.

### taskset errors
- If using `--core-list`, ensure `taskset` is present on target.

---

## Support / ownership
This suite follows qcom-linux-testkit conventions (POSIX shell, ShellCheck clean, LAVA friendly).
If you update Geekbench versions, validate parsing against actual `--export-text` output.
