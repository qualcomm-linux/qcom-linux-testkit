# PI_Stress (rt-tests pi_stress) — qcom-linux-testkit

This test wraps **rt-tests `pi_stress`** (Priority Inheritance stress) for **qcom-linux-testkit** and LAVA.
It runs one or more `pi_stress` iterations, collects JSON output, parses KPIs **without requiring Python**, and emits a `.res` summary for LAVA gating.

> **What it measures**
>
> `pi_stress` exercises PI mutexes (priority inheritance) by creating intentional priority-inversion scenarios.
> The JSON output includes an **`inversion` counter** (total inversions observed/generated in that run). With `--iterations 1`,
> you’ll often see min/mean/max all equal (one sample).

---

## Location

```
Runner/suites/Kernel/RT-tests/PI_Stress/
├── run.sh
├── PI_Stress.res                # created at runtime
└── logs_PI_Stress/              # created at runtime (default)
    ├── pi_stress_iter1.json
    ├── parsed_pi_stress.txt
    └── result.txt
```

---

## Requirements

- Run as **root** (recommended/required for best behavior; `--mlockall` especially).
- `pi_stress` binary available on target, either:
  - in `$PATH` (`command -v pi_stress`), or
  - provided via `--binary /path/to/pi_stress`
- Common tools: `uname`, `awk`, `sed`, `grep`, `tr`, `head`, `tail`, `mkdir`, `cat`, `sh`, `tee`, `sleep`, `kill`, `date`

This test uses helpers from:

- `Runner/utils/functestlib.sh` (logging, deps, background workload helper, clock sanity helper if available)
- `Runner/utils/lib_rt.sh` (rt-tests JSON parsing helpers)

---

## Quick start

### Run with a custom binary
```sh
cd Runner/suites/Kernel/RT-tests/PI_Stress
./run.sh --binary /tmp/pi_stress --duration 1m
```

### Enable mlockall and SCHED_RR threads
```sh
./run.sh --binary /tmp/pi_stress --duration 1m --mlockall true --rr true
```

### Multiple iterations
```sh
./run.sh --binary /tmp/pi_stress --duration 1m --iterations 5
```

### Optional: add background workload
```sh
./run.sh --binary /tmp/pi_stress --duration 1m --background-cmd "stress-ng --cpu 4 --timeout 60s"
```

---

## Command line options (run.sh)

```text
--out DIR                 Output directory (default: ./logs_PI_Stress)
--result FILE             Result file path (default: <out>/result.txt)

--duration D              pi_stress runtime per iteration (default: 5m)
--iterations N            Number of iterations (default: 1)

--mlockall true|false     Enable --mlockall (default: false)
--rr true|false           Enable --rr (SCHED_RR) (default: false)

--background-cmd CMD      Optional background workload command (default: empty)
--binary PATH             Explicit pi_stress binary path (default: auto-detect)
--verbose                 Extra logs
-h, --help                Show help
```

**Notes**
- `--mlockall true` may fail if memlock limits are too low; your scripts print memlock(soft/hard) from `/proc/self/limits`.
- `--rr true` switches to SCHED_RR; default is SCHED_FIFO in `pi_stress`.

---

## Outputs

### Result files
- `PI_Stress.res`  
  Contains only the **PASS/FAIL/SKIP** summary for LAVA.
- `logs_PI_Stress/result.txt`  
  Contains parsed KPI lines for LAVA test parsing and artifact collection.
- `logs_PI_Stress/parsed_pi_stress.txt`  
  Same KPI lines (intermediate), helpful for debugging.
- `logs_PI_Stress/pi_stress_iterN.json`  
  Raw JSON output from `pi_stress`.

### Example KPI lines
```text
pi-stress-inversion-min pass 13630990 count
pi-stress-inversion-mean pass 13630990 count
pi-stress-inversion-max pass 13630990 count
pi-stress pass
```

> With only one iteration, min/mean/max are identical because there’s one inversion value sample.

---

## LAVA integration

1) Ensure the repository is available on the DUT (or fetched by your job).  
2) Use a LAVA test definition YAML to call `run.sh` and then send `.res` to LAVA.

Minimal example (Linaro-style CLI mapping):

```yaml
metadata:
  name: pi-stress
  format: "Lava-Test Test Definition 1.0"
  description: "Run rt-tests pi_stress and collect inversion KPI in JSON; parse results without requiring python3."
  os:
    - linux
  scope:
    - functional
    - preempt-rt

params:
  OUT_DIR: "./logs_PI_Stress"
  DURATION: "5m"
  ITERATIONS: "1"
  MLOCKALL: "false"
  RR: "false"
  BACKGROUND_CMD: ""
  BINARY: ""

run:
  steps:
    - cd Runner/suites/Kernel/RT-tests/PI_Stress
    - ./run.sh --out "${OUT_DIR}" --duration "${DURATION}" --iterations "${ITERATIONS}" --mlockall "${MLOCKALL}" --rr "${RR}" --background-cmd "${BACKGROUND_CMD}" --binary "${BINARY}" || true
    - ../../../utils/send-to-lava.sh PI_Stress.res
```

---

## Troubleshooting

### Timestamps show 1970-01-01
If the system clock is invalid at boot, logs may show epoch time. If `functestlib.sh` provides `ensure_reasonable_clock()`,
the script attempts a **local-only** clock sanity step (RTC / kernel build time) before running.

### pi_stress prints large inversion counts
The `inversion` KPI is a **total counter** per run; large values can be normal depending on CPU and load.
Use multiple iterations to compare distribution across runs.

### Missing binary
Provide `--binary /path/to/pi_stress` or ensure `pi_stress` is in `$PATH`.

---

## Exit codes

- The script always exits `0` (LAVA-friendly). PASS/FAIL/SKIP is communicated via `PI_Stress.res`.

---

## Maintainers / notes

- Keep the implementation POSIX `sh` compatible and ShellCheck-clean.
- Prefer existing helpers in `functestlib.sh` and `lib_rt.sh` instead of adding new ones, unless necessary.
