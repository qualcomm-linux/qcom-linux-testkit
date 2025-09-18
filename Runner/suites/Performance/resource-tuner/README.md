# `resource-tuner` Test Runner (`run.sh`)

A pinned **whitelist** test runner for `resource-tuner` that produces per-suite logs and an overall gating result for CI.

---

## What this runs

Only these binaries are executed, in this order (anything else is ignored):
```
/usr/bin/ClientDataManagerTests
/usr/bin/ResourceProcessorTests
/usr/bin/MemoryPoolTests
/usr/bin/SignalConfigProcessorTests
/usr/bin/DeviceInfoTests
/usr/bin/ThreadPoolTests
/usr/bin/MiscTests
/usr/bin/SignalParsingTests
/usr/bin/SafeOpsTests
/usr/bin/ExtensionIntfTests
/usr/bin/RateLimiterTests
/usr/bin/SysConfigAPITests
/usr/bin/ExtFeaturesParsingTests
/usr/bin/RequestMapTests
/usr/bin/TargetConfigProcessorTests
/usr/bin/InitConfigParsingTests
/usr/bin/RequestQueueTests
/usr/bin/CocoTableTests
/usr/bin/ResourceParsingTests
/usr/bin/TimerTests
/usr/bin/resource_tuner_tests
```

---

## Gating policy

* **Service check (early gate):** If `resource-tuner.service` is **not active**, the test **SKIPs overall** and exits.
* **Per‑suite SKIP conditions (neutral):**  
  * Missing binary → **SKIP that suite**, continue.  
  * Missing base configs → **SKIP that suite**, continue.  
  * Missing test nodes for `resource_tuner_tests` → **SKIP that suite**, continue.
* **Final result:**
  * If **any** suite **FAILS** → **overall FAIL**.
  * Else if **≥1** suite **PASS** → **overall PASS**.
  * Else (**everything SKIPPED**) → **overall SKIP**.

> Skips are **neutral**: they never convert a passing run into a failure.

---

## Pre‑checks

### 1) Service
The runner uses the repo helper `check_systemd_services()` to verify **`resource-tuner.service`** is active.
- On failure: overall **SKIP** (ends early).  
- Override service name: `SERVICE_NAME=your.service ./run.sh`

### 2) Config presence
Suites that parse configs require **at least one** of these base config trees:

- `common/` (required files):
  - `InitConfig.yaml`, `PropertiesConfig.yaml`, `ResourcesConfig.yaml`, `SignalsConfig.yaml`

- `custom/` (required files):
  - `InitConfig.yaml`, `PropertiesConfig.yaml`, `ResourcesConfig.yaml`, `SignalsConfig.yaml`, `TargetConfig.yaml`, `ExtFeaturesConfig.yaml`

If **both** trees are missing required files/dirs, config‑parsing suites are **SKIP** only (neutral).

> Override required file lists without editing the script:
```bash
export RT_REQUIRE_COMMON_FILES="InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml"
export RT_REQUIRE_CUSTOM_FILES="InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml TargetConfig.yaml ExtFeaturesConfig.yaml"
```

### 3) Test ResourceSysFsNodes
`/etc/resource-tuner/tests/Configs/ResourceSysFsNodes` must exist and be non‑empty for **`/usr/bin/resource_tuner_tests`**. If missing/empty → **SKIP only that suite**.

### 4) Base tools
Requires: `awk`, `grep`, `date`, `printf`. If missing → **overall SKIP**.

---

## CLI

```
Usage: ./run.sh [--all] [--bin <name|absolute>] [--list] [--timeout SECS]
```

- `--all` (default): run all approved suites.  
- `--bin NAME|PATH`: run a single approved suite.  
- `--list`: print approved list and presence coverage, then exit.  
- `--timeout SECS`: default per‑binary timeout **if** `run_with_timeout()` helper exists (else ignored).

Per‑suite default timeouts (if helper is present):
- `ThreadPoolTests`, `RateLimiterTests`: **1800s**
- `resource_tuner_tests`: **2400s**
- others: **1200s** (default)

---

## Output layout

- **Overall status file:** `./resource-tuner.res` → `PASS` / `FAIL` / `SKIP`
- **Logs directory:** `./logs/resource-tuner-YYYYMMDD-HHMMSS/`
  - Per‑suite logs: `SUITE.log`
  - Per‑suite result markers: `SUITE.res` (`PASS`/`FAIL`/`SKIP`)
  - Coverage summaries: `coverage.txt`, `missing_bins.txt`, `coverage_counts.env`
  - System snapshot: `dmesg_snapshot.log`
- **Symlink to latest:** `./logs/resource-tuner-latest`

**Parsing heuristics:** a suite is considered PASS if the binary exits 0 **or** its log contains
`Run Successful`, `executed successfully`, or `Ran Successfully`. Strings like `Assertion failed`, `Terminating Suite`, `Segmentation fault`, `Backtrace`, or `fail/failed` mark **FAIL**.

---

## Environment overrides

- `SERVICE_NAME`: systemd unit to check (default: `resource-tuner.service`)
- `RT_CONFIG_DIR`: root of config tree (default: `/etc/resource-tuner`)
- `RT_REQUIRE_COMMON_FILES`, `RT_REQUIRE_CUSTOM_FILES`: *space‑separated* filenames that must exist in `common/` / `custom/` respectively to treat that tree as present.

---

## Examples

Run all (normal CI mode):
```bash
./run.sh
```

Run a single suite by basename:
```bash
./run.sh --bin ResourceParsingTests
```

List suites and presence coverage:
```bash
./run.sh --list
```

Use a different config root:
```bash
RT_CONFIG_DIR=/opt/rt/etc ./run.sh
```

---

## Exit status

The script writes the overall result to `resource-tuner.res`. The **process exit code is 0** in all cases in the current version (soft gating). If you want hard CI gating via non‑zero exit on FAIL, that can be added easily on request.

---

## Troubleshooting

- **Overall SKIP immediately** → service inactive. Check `systemctl status resource-tuner.service`.
- **Suite SKIP (config)** → confirm required files exist under `common/` or `custom/` (see lists above).
- **Suite SKIP (missing bin)** → verify the binary is installed and executable under `/usr/bin`.
- **Suite FAIL** → inspect `logs/.../SUITE.log` for the first failure pattern or assertion.
- **Very long runs** → a `run_with_timeout` helper (if available in your repo toolchain) will be used automatically.

## License
- SPDX-License-Identifier: BSD-3-Clause-Clear
- (C) Qualcomm Technologies, Inc. and/or its subsidiaries.
