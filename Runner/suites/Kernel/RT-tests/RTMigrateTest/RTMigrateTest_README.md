# RTMigrateTest

`RTMigrateTest` wraps the **rt-tests** `rt-migrate-test` workload in the **qcom-linux-testkit** RT-tests framework.

It follows the same single-flow style as other RT wrappers (e.g., **PMQTest**, **PTSEMATest**):

- Locates `init_env` from the repository root
- Sources `functestlib.sh` and `lib_rt.sh`
- Runs `rt-migrate-test` in JSON mode for `ITERATIONS`
- Parses KPI lines via `perf_parse_rt_tests_json` (no python required)
- Produces:
  - `logs_RTMigrateTest/result.txt` (all KPI lines, per-iteration + aggregate)
  - `RTMigrateTest.res` (PASS/FAIL/SKIP summary for LAVA gating)
- Always exits `0` (LAVA-friendly). Use the `.res` file to gate.

---

## Location

```
Runner/suites/Kernel/RT-tests/RTMigrateTest/
├── run.sh
├── RTMigrateTest.yaml
└── README.md
```

---

## What it measures

`rt-migrate-test` verifies **RT thread scheduler balancing** and migration behavior under RT scheduling. The wrapper extracts per-thread latency metrics (when present in the JSON) and aggregates them across threads and iterations.

Typical KPIs (examples):

- `t<id>-min-latency pass <val> us`
- `t<id>-avg-latency pass <val> us`
- `t<id>-max-latency pass <val> us`

Aggregate KPIs:

- `<prefix>-all-min-latency-{min,mean,max} pass <val> us`
- `<prefix>-all-avg-latency-{min,mean,max} pass <val> us`
- `<prefix>-all-max-latency-{min,mean,max} pass <val> us`
- `<prefix>-worst-thread-max-latency pass <val> us`
- `<prefix>-worst-thread-id pass <tid> id`

> Note: The exact KPI set depends on the JSON schema emitted by your `rt-migrate-test` build. The wrapper is compatible with the same thread-style JSON format used by other rt-tests workloads.

---

## Requirements

### Runtime requirements

- Root access (RT scheduling + priority usage)
- `rt-migrate-test` binary available on the target

### Framework requirements

- `Runner/init_env`
- `Runner/utils/functestlib.sh`
- `Runner/utils/lib_rt.sh` (must provide `perf_parse_rt_tests_json` and `rt_aggregate_iter_latencies`)

---

## Running locally

From the test directory:

```sh
cd Runner/suites/Kernel/RT-tests/RTMigrateTest
./run.sh
```

### Common examples

Run for 1 minute, 3 iterations:

```sh
./run.sh --duration 1m --iterations 3
```

Run with a background workload (example):

```sh
./run.sh --duration 2m --iterations 2 --background-cmd "stress-ng --cpu 4 --timeout 120s"
```

Use an explicit binary path:

```sh
./run.sh --binary /tmp/rt-migrate-test --duration 1m
```

Override output directory:

```sh
./run.sh --out ./logs_RTMigrateTest --duration 1m --iterations 2
```

---

## Parameters

Parameters can be provided either via environment variables (LAVA `params`) or via CLI flags.

| Parameter | Default | Meaning |
|---|---:|---|
| `DURATION` / `--duration` | `5m` | How long each iteration runs (`rt-migrate-test -D`) |
| `ITERATIONS` / `--iterations` | `1` | Number of iterations |
| `BACKGROUND_CMD` / `--background-cmd` | empty | Background workload started during the test |
| `PRIO` / `--prio` | `51` | Lowest thread RT priority (`rt-migrate-test -p`) |
| `QUIET` / `--quiet` | `true` | Add `-q` |
| `MODE_S` / `--mode-s` | `true` | Add `-S` |
| `MODE_C` / `--mode-c` | `true` | Add `-c` |
| `BINARY` / `--binary` | empty | Explicit `rt-migrate-test` path |
| `OUT_DIR` / `--out` | `./logs_RTMigrateTest` | Output directory |

---

## Output files

- **`${OUT_DIR}/result.txt`**
  - Contains all KPI lines:
    - per-iteration KPIs (prefixed with `iteration-<N>-`)
    - aggregate KPIs (computed across all iterations/threads)

- **`${OUT_DIR}/rt-migrate-test-<N>.json`**
  - JSON output from each iteration

- **`RTMigrateTest.res`**
  - One line summary for LAVA gating:
    - `RTMigrateTest PASS`
    - `RTMigrateTest FAIL`
    - `RTMigrateTest SKIP`

---

## LAVA usage

Use `RTMigrateTest.yaml` as a test definition (or include its steps in your job).

The YAML follows the standardized format used by other RT-tests in this repo.

Key steps:

1. `cd Runner/suites/Kernel/RT-tests/RTMigrateTest`
2. Run `./run.sh` with parameters
3. Send the `.res` file via `Runner/utils/send-to-lava.sh`

---

## Notes / Troubleshooting

- If the kernel is not PREEMPT_RT-enabled, results may be worse. The wrapper logs a warning via `rt_log_kernel_rt_status`.
- If `rt-migrate-test` is missing or not executable, the test is marked **SKIP**.
- If any iteration fails or parsing detects a `fail` verdict line, overall result becomes **FAIL** (written to `RTMigrateTest.res`).
