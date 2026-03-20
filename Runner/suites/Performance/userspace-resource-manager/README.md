# `userspace-resource-manager` Test Runner (`run.sh`)

A pinned **whitelist** test runner for `userspace-resource-manager` that produces per-suite logs and an overall gating result for CI.

---

## What this runs

Only these binaries are executed, in this order (anything else is ignored):
```
/usr/bin/UrmComponentTests
/usr/bin/UrmIntegrationTests
```

---

## Gating policy

* **Service check (early gate):** If `urm.service` is **not active**, the test **SKIPs overall** and exits.
* **Per‑suite SKIP conditions (neutral):**  
  * Missing binary → **SKIP that suite**, continue.  
  * Missing base configs → **SKIP that suite**, continue.  
  * Missing test nodes for `UrmIntegrationTests` → **SKIP that suite**, continue.
* **Final result:**
  * If **any** suite **FAILS** → **overall FAIL**.
  * Else if **≥1** suite **PASS** → **overall PASS**.
  * Else (**everything SKIPPED**) → **overall SKIP**.

> Skips are **neutral**: they never convert a passing run into a failure.

---

## Pre‑checks

### 1) Service
The runner uses the repo helper `check_systemd_services()` to verify **`urm.service`** is active.
- On failure: overall **SKIP** (ends early).  
- Override service name: `SERVICE_NAME=your.service ./run.sh`

### 2) Config presence
Suites that parse configs require **at least one** of these base config trees:

- `common/` (required files):
  - `InitConfig.yaml`, `PropertiesConfig.yaml`, `ResourcesConfig.yaml`, `SignalsConfig.yaml`

- `tests/configs/` (required files):
  - `InitConfig.yaml`, `PropertiesConfig.yaml`, `ResourcesConfig.yaml`, `SignalsConfig.yaml`, `TargetConfig.yaml`, `ExtFeaturesConfig.yaml`

If **both** trees are missing required files/dirs, config‑parsing suites are **SKIP** only (neutral).

> Override required file lists without editing the script:
```bash
export RT_REQUIRE_COMMON_FILES="InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml"
export RT_REQUIRE_TEST_FILES="InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml TargetConfig.yaml ExtFeaturesConfig.yaml Baseline.yaml"
```

### 3) Test test nodes
`/etc/urm/tests/nodes` must exist and be non‑empty for **`/usr/bin/UrmIntegrationTests`** and **`/usr/bin/UrmComponentTests`**. If missing/empty → **SKIP only that suite**.

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
- `UrmComponentTests`: **1800s**
- `UrmIntegrationTests`: **2400s**
- others: **1200s** (default)

---

## Output layout

- **Overall status file:** `./userspace-resource-manager.res` → `PASS` / `FAIL` / `SKIP`
- **Logs directory:** `./logs/userspace-resource-manager-YYYYMMDD-HHMMSS/`
  - Per‑suite logs: `SUITE.log`
  - Per‑suite result markers: `SUITE.res` (`PASS`/`FAIL`/`SKIP`)
  - Coverage summaries: `coverage.txt`, `missing_bins.txt`, `coverage_counts.env`
  - System snapshot: `dmesg_snapshot.log`
- **Symlink to latest:** `./logs/userspace-resource-manager-latest`

**Parsing heuristics:** a suite is considered PASS if the binary exits 0 **or** its log contains
`Run Successful`, `executed successfully`, or `Ran Successfully`. Strings like `Assertion failed`, `Terminating Suite`, `Segmentation fault`, `Backtrace`, or `fail/failed` mark **FAIL**.

---

## Environment overrides

- `SERVICE_NAME`: systemd unit to check (default: `urm.service`)
- `RT_CONFIG_DIR`: root of config tree (default: `/etc/urm`)
- `RT_REQUIRE_COMMON_FILES`, `RT_REQUIRE_CUSTOM_FILES`: *space‑separated* filenames that must exist in `common/` / `tests/` respectively to treat that tree as present.

---

## Examples

Run all (normal CI mode):
```bash
./run.sh
```

Run a single suite by basename:
```bash
./run.sh --bin UrmComponentTests
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

The script writes the overall result to `userspace-resource-manager.res`. The **process exit code is 0** in all cases in the current version (soft gating). If you want hard CI gating via non‑zero exit on FAIL, that can be added easily on request.

---

## Troubleshooting

- **Overall SKIP immediately** → service inactive. Check `systemctl status urm.service`.
- **Suite SKIP (config)** → confirm required files exist under `common/` or `tests/` (see lists above).
- **Suite SKIP (missing bin)** → verify the binary is installed and executable under `/usr/bin`.
- **Suite FAIL** → inspect `logs/.../SUITE.log` for the first failure pattern or assertion.
- **Very long runs** → a `run_with_timeout` helper (if available in your repo toolchain) will be used automatically.

## License
- SPDX-License-Identifier: BSD-3-Clause
- (C) Qualcomm Technologies, Inc. and/or its subsidiaries.
