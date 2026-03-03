# Sysbench_Performance

This suite runs a **repeatable Sysbench performance baseline** on Yocto/QLI targets in a CI-friendly way.

It runs the following test cases for one or more thread counts and for N iterations:

- **CPU** (`sysbench cpu`)  
- **Memory bandwidth** (`sysbench memory`)  
- **Threads** (`sysbench threads`)  
- **Mutex** (`sysbench mutex`)  
- **File I/O throughput** (`sysbench fileio`) — **seqwr / seqrd / rndwr / rndrd**

For each case it:
- prints sysbench output live to console (and saves per-iteration logs),
- records per-iteration KPIs into `*.values` files,
- prints a compact per-iteration KPI line (`ITER_SUMMARY`) to console,
- computes averages and writes `OUT_DIR/sysbench_summary.txt`,
- optionally appends per-iteration + avg rows to a CSV (only if `CSV_FILE` is provided),
- optionally enforces PASS/FAIL **baseline gating** (when a baseline file is provided or auto-detected).

---

## KPIs collected (and “better” direction)

| Case | KPI name (run.sh / baseline key) | Unit | Better |
|---|---|---:|---|
| CPU | `cpu_time_sec` | seconds | **lower** |
| Memory | `memory_mem_mbps` | MB/s | **higher** |
| Threads | `threads_time_sec` | seconds | **lower** |
| Mutex | `mutex_time_sec` | seconds | **lower** |
| File I/O seq write | `fileio_seqwr_mbps` | MB/s | **higher** |
| File I/O seq read | `fileio_seqrd_mbps` | MB/s | **higher** |
| File I/O rnd write | `fileio_rndwr_mbps` | MB/s | **higher** |
| File I/O rnd read | `fileio_rndrd_mbps` | MB/s | **higher** |

> Note: even if you think of reads as “GB/s”, the suite **stores and gates in MB/s** for consistency.  
> If you have a baseline in GB/s, convert to MB/s (GB/s × 1024).

---

## Baseline gating (PASS/FAIL)

Baseline gating is enabled when either:
- `BASELINE_FILE` / `--baseline FILE` is set, **or**
- `./sysbench_baseline.conf` exists in the **same folder as `run.sh`** (auto-detected).

`ALLOWED_DEVIATION` / `--delta` controls tolerance:

- **Higher-is-better** metrics (MB/s):  
  **PASS** if `avg >= baseline * (1 - delta)`  
  (recommend **0.05** → “>= 95% of baseline”)
- **Lower-is-better** metrics (seconds):  
  **PASS** if `avg <= baseline * (1 + delta)`  
  (recommend **0.05** → “<= 105% of baseline”)

The console shows a per-metric GATE line and `sysbench_summary.txt` includes a `gate_*` section.

---

## Baseline file format (`sysbench_baseline.conf`)

Plain `key=value` format (comments allowed with `#`). Keys are per-thread-count:

```
# ---- Threads = 4 ----
cpu_time_sec.t4=3.483
memory_mem_mbps.t4=4120.000
threads_time_sec.t4=3.703
mutex_time_sec.t4=0.004

fileio_seqwr_mbps.t4=0.400
fileio_seqrd_mbps.t4=29.300
fileio_rndwr_mbps.t4=0.610
fileio_rndrd_mbps.t4=29.300
```

Use `t1`, `t4`, `t8`, … matching your `THREADS_LIST`.

---

## Parameters (env vars / CLI)

The suite is controlled by environment variables (and equivalent CLI flags). Typical params:

### Common
- `OUT_DIR` (default `./sysbench_out`) – where logs / values / summary go
- `ITERATIONS` (default `1`)
- `TIME` (default `30`)
- `RAND_SEED` (default `1234`)
- `THREADS_LIST` (default `"4"`) – space-separated list of thread counts
- `TASKSET_CPU_LIST` (default empty) – passed to `taskset -c`, e.g. `"6-7"`
- `BASELINE_FILE` (default empty; auto-detects `sysbench_baseline.conf` next to `run.sh`)
- `ALLOWED_DEVIATION` (default `0.10`; recommended `0.05`)
- `CSV_FILE` (default empty → **no CSV by default**)

### CPU
- `CPU_MAX_PRIME` (default `20000`)

### Threads
- `THREAD_LOCKS` (default `20`)
- `THREAD_YIELDS` (default empty → sysbench default)

### Memory
- `MEMORY_OPER` (default `write`) – `read|write`
- `MEMORY_ACCESS_MODE` (default `rnd`) – `seq|rnd`
- `MEMORY_BLOCK_SIZE` (default `1M`)
- `MEMORY_TOTAL_SIZE` (default `100G`)

### File I/O
File I/O uses sysbench `fileio` with a **prepare → run → cleanup** flow.

Recommended knobs (names match the suite params):
- `FILEIO_DIR` – directory where files are created (recommended: **tmpfs** like `/tmp`)
- `FILE_TOTAL_SIZE` – total size per file, e.g. `1G`
- `FILE_BLOCK_SIZE` – e.g. `4K`, `1M`
- `FILE_NUM` – number of files, e.g. `1`, `4`
- `FILE_IO_MODE` – e.g. `sync` (stable), `async`
- `FILE_FSYNC_FREQ` – optional, e.g. `0` (disable) or `1` (every op)

> Your `run.sh` may expose additional `FILE_*` knobs; keep them documented here as you add them.

---

## Safety warning for File I/O

`sysbench fileio` **creates files and performs reads/writes** in `FILEIO_DIR`.

To avoid accidental wear / regression noise:
- Prefer `FILEIO_DIR=/tmp/...` (tmpfs) for CI gating.  
- If you must test real storage, point to a **dedicated mount** (not `/`), and keep sizes small.
- Do **NOT** point fileio at your root filesystem (`/`) unless you fully understand the impact.

---

## Outputs

In `OUT_DIR/` you will see:

- `*_iterN.log` — full sysbench stdout/stderr per test case + iteration
- `*.values` — one KPI value per iteration (for averaging)
- `sysbench_summary.txt` — averages + gating summary
- Optional CSV (only when `CSV_FILE` is set)

Result file:
- `./Sysbench_Performance.res` — `PASS` / `FAIL` / `SKIP`

---

## Examples (using our `run.sh`)

All examples are run from:

```
cd Runner/suites/Performance/Sysbench_Performance/
```

### 1) Full suite (CPU + memory + threads + mutex + fileio)
```
./run.sh
```

### 2) 3 iterations, pin to big cores, tighter gating (95% baseline)
(Uses `./sysbench_baseline.conf` automatically if present.)
```
./run.sh --iterations 3 --threads-list "4" --taskset-cpu-list "6-7" --delta 0.05
```

### 3) Explicit baseline file path
```
./run.sh --baseline ./sysbench_baseline.conf --delta 0.05
```

### 4) Enable CSV (NOT default)
```
./run.sh --csv ./sysbench_out/sysbench.csv
```

### 5) CPU time focus (reduce noise)
You can’t “run only CPU” without editing the script, but you can reduce runtime:
```
./run.sh --iterations 1 --time 15 --cpu-max-prime 20000 --threads-list "4"
```
Then read:
- console `ITER_SUMMARY ... cpu_time_sec=...`
- `OUT_DIR/cpu_t4.values`
- CSV rows (if enabled)

### 6) Memory bandwidth focus (use seq vs rnd)
```
MEMORY_ACCESS_MODE=seq ./run.sh --iterations 1 --threads-list "4"
MEMORY_ACCESS_MODE=rnd ./run.sh --iterations 1 --threads-list "4"
```

### 7) File I/O on tmpfs (recommended for CI)
```
FILEIO_DIR=/tmp/sysbench_fileio ./run.sh --iterations 1 --threads-list "4"
```

### 8) File I/O heavier workload (be careful)
```
FILEIO_DIR=/tmp/sysbench_fileio FILE_TOTAL_SIZE=1G FILE_BLOCK_SIZE=4K FILE_NUM=4 ./run.sh --iterations 1 --threads-list "4"
```

### 9) Verifying seq/rnd IO KPIs
After the run, check:
- `sysbench_summary.txt` for:
  - `fileio_seqwr_mbps`, `fileio_seqrd_mbps`, `fileio_rndwr_mbps`, `fileio_rndrd_mbps`
- per-iteration logs:
  - `fileio_*_iter*.log`

---

## LAVA YAML integration

Your LAVA test definition should:
- `cd Runner/suites/Performance/Sysbench_Performance/`
- run `./run.sh`
- publish `Sysbench_Performance.res` via `send-to-lava.sh`

Keep `CSV_FILE` empty by default (to avoid extra artifacts) and enable only when you explicitly need CSV.

---

## License

Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.  
SPDX-License-Identifier: BSD-3-Clause