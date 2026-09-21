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

* **Service check (early gate):** The selected service (`SERVICE_NAME`, default `urm.service`) must be applicable and active. A genuinely absent/non-applicable service is **overall SKIP**; an applicable service that cannot be started/restarted is **overall FAIL**.
* **Required service restart:** Before the first runnable suite only, the runner restarts the selected service so it observes the staged test nodes. Restart failure or failure to become active is **overall FAIL** with service evidence retained in the log directory.
* **Per‑suite SKIP conditions (neutral):**  
  * Missing binary → **SKIP that suite**, continue.  
  * Missing base configs → **SKIP that suite**, continue.  
  * Missing test nodes → **SKIP that suite**, continue.
* **Final result:**
  * If **any** suite **FAILS** → **overall FAIL**.
  * Else if **≥1** suite **PASS** → **overall PASS**.
  * Else (**everything SKIPPED**) → **overall SKIP**.

> Skips are **neutral**: they never convert a passing run into a failure.

---

## Pre‑checks

### 1) Service
The runner uses the repo helper `check_systemd_services()` to verify the selected systemd unit is active. The default is **`urm.service`** and it can be overridden with `SERVICE_NAME=your.service ./run.sh`.

Runtime contract:
- If the selected service is genuinely absent/non-applicable → overall **SKIP**.
- If the selected service is applicable but cannot be started → overall **FAIL**.
- Before the first runnable suite only, the runner performs a required `systemctl restart "$SERVICE_NAME"`.
- If the required restart fails, or the service does not become active within the bounded wait → overall **FAIL**.
- Restart diagnostics are retained under the run log directory, for example `service_restart.log`, `service_restart_status.log`, and when available `service_restart_journal.log`.

### 2) Config presence
Suites that parse configs require **all** of these base config trees:

- `common/` (required files):
  - `InitConfig.yaml`, `PropertiesConfig.yaml`, `ResourcesConfig.yaml`, `SignalsConfig.yaml`

- `tests/configs/` (required files):
  - `InitConfig.yaml`, `PropertiesConfig.yaml`, `ResourcesConfig.yaml`, `SignalsConfig.yaml`, `TargetConfig.yaml`, `ExtFeaturesConfig.yaml`, `Baseline.yaml`

- `tests/nodes/` (must exist and be non-empty):

If **any** of these trees are missing required files/dirs, config‑parsing suites are **SKIP** only (neutral).

> Override required file lists without editing the script:
```bash
export URM_REQUIRE_COMMON_FILES="InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml"
export URM_REQUIRE_TEST_FILES="InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml TargetConfig.yaml ExtFeaturesConfig.yaml Baseline.yaml"
```

### 3) Test nodes
The runner resolves the test-nodes source directory in the following priority order:

1. **`URM_TEST_NODES_DIR`** – explicit operator override (takes precedence over everything).
2. **`URM_CONFIG_DIR`** – legacy compatibility fallback (same variable honoured by the config roots).
3. **`/var/lib/urm/tests/nodes`** – runtime/writable location, used only when the directory exists **and is non-empty**.
4. **`/usr/share/urm/tests/nodes`** – package-installed default (Yocto and Debian).

Before tests run, the resolved nodes are **copied** into a private temporary directory created with `mktemp -d`, under the path `<tmpdir>/urm/tests/nodes`. This path is passed to each test binary via the `--npath` argument, so the binaries write to a fresh exclusively-owned location rather than a shared fixed path. The temporary directory is removed automatically on exit, interrupt, or termination.

The resolved source directory must exist and be non-empty for **`/usr/bin/UrmIntegrationTests`** and **`/usr/bin/UrmComponentTests`**. If missing, empty, or the copy fails → **SKIP only that suite**.

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
- `--timeout SECS`: default per‑binary timeout for suites without a suite-specific timeout.

Per‑suite default timeouts enforced by this runner's local timeout helper:
- `UrmComponentTests`: **1800s**
- `UrmIntegrationTests`: **2400s**
- others: **1200s** (default)

---

## Timeout helper contract

`run.sh` uses a local timeout helper for URM suites instead of depending on the shared `run_with_timeout()` helper. This is intentional: the local helper closes the lock FD before launching the test command, timeout watcher, and watcher `sleep`, preventing background timeout processes from retaining the flock after the parent exits.

Function contract for `run_cmd_with_timeout_no_lock_fd TIMEOUT_SECS COMMAND [ARG...]`:

- **Arguments:**
  - `TIMEOUT_SECS`: positive integer enables timeout enforcement.
  - Empty, zero, or non-numeric timeout runs `COMMAND` directly without spawning a watcher.
  - `COMMAND [ARG...]`: binary and arguments to execute.
- **Return statuses:**
  - command exit status on normal completion.
  - `124` when this helper's own watcher expires the deadline.
  - other signal-derived statuses are preserved when they were not caused by this helper's timeout watcher.
- **Spawned processes when timeout is enabled:**
  - one command process,
  - one watcher subshell,
  - one watcher `sleep` process.
- **Retained files:**
  - temporary watcher sleep PID and timeout marker files are created under the run log directory while the command is active.
  - these files are removed before the helper returns; the shared `cleanup()` path owns removal on interruption or termination.
- **Timeout logging:**
  - when the watcher expires, the suite log records `[TIMEOUT] command exceeded <seconds>s: <command>`.
  - `run_one()` reports this as `TIMEOUT` / `FAIL` instead of ambiguous `UNKNOWN RC=143` or `UNKNOWN RC=137`.

---

## Locking and diagnostics

The runner keeps `flock` as the primary concurrency guard because URM tests and the service use shared system resources. Cleanup explicitly unlocks and closes FD 9. If `flock` is unavailable, a simple `mkdir` lock directory fallback is used and removed during cleanup.

When `flock` acquisition fails, diagnostics avoid broad `run.sh` process-name matching and prefer:

- `lslocks` entries for `/tmp/userspace-resource-manager.lock`,
- `fuser` output for processes with the lock file open,
- `/proc/*/fd` references to the lock file when available.

---

## Output layout

- **Overall status file:** `./userspace-resource-manager.res` → `PASS` / `FAIL` / `SKIP`
- **Logs directory:** `./logs/userspace-resource-manager-YYYYMMDD-HHMMSS/`
  - Per‑suite logs: `SUITE.log`
  - Per‑suite result markers: `SUITE.res` (`PASS`/`FAIL`/`SKIP`)
  - Coverage summaries: `coverage.txt`, `missing_bins.txt`, `coverage_counts.env`
  - System snapshot: `dmesg_snapshot.log`
  - Service restart evidence when applicable: `service_restart.log`, `service_restart_status.log`, `service_restart_journal.log`
- **Symlink to latest:** `./logs/userspace-resource-manager-latest`

---

## Environment overrides

- `SERVICE_NAME`: systemd unit to check (default: `urm.service`)
- `URM_CONFIG_DIR`: **legacy** compatibility override – sets the root for `common/`, `tests/configs/`, and `tests/nodes/` when the per-root variables below are not set (default: unset; built-in defaults are `/etc/urm`, `/usr/share/urm`, and `/usr/share/urm` respectively).
- `URM_COMMON_CONFIG_DIR`: root for `common/` configs (default: `/etc/urm`). Takes precedence over `URM_CONFIG_DIR`.
- `URM_TESTS_CONFIG_DIR`: root for `tests/configs/` (default: `/usr/share/urm`). Takes precedence over `URM_CONFIG_DIR`.
- `URM_TEST_NODES_DIR`: explicit root for `tests/nodes/` (default: auto-resolved; see [Test nodes](#3-test-nodes) above). Takes precedence over the automatic candidate search.
- `URM_REQUIRE_COMMON_FILES`, `URM_REQUIRE_TEST_FILES`: *space‑separated* filenames that must exist in `common/` / `tests/configs/` respectively to treat that tree as present.

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

Use a different config root (legacy, applies to both common and tests-config roots):
```bash
URM_CONFIG_DIR=/opt/rt/etc ./run.sh
```

Override individual roots:
```bash
URM_COMMON_CONFIG_DIR=/opt/rt/etc/urm URM_TESTS_CONFIG_DIR=/opt/rt/usr/share/urm ./run.sh
```

Point to a custom test-nodes directory:
```bash
URM_TEST_NODES_DIR=/opt/rt/usr/share/urm ./run.sh
```

---

## Exit status

The script writes the overall result to `userspace-resource-manager.res`. The **process exit code is 0** in case of SUCCESS, while the **exit code is 1** in case of overall FAILURE.

---

## Troubleshooting

- **Overall SKIP immediately** → selected service appears absent/non-applicable, or no suite is runnable.
- **Overall FAIL during service setup/restart** → selected service is applicable but failed to start/restart; inspect `logs/.../service_*` files.
- **Suite SKIP (config)** → confirm required files exist under `common/`, `tests/configs` and `tests/nodes` (see lists above).
- **Suite SKIP (missing bin)** → verify the binary is installed and executable under `/usr/bin`.
- **Suite FAIL** → inspect `logs/.../SUITE.log` for the first failure pattern or assertion.
- **Very long runs** → the local timeout helper enforces the configured per-suite deadline and reports helper-expired timeouts as `TIMEOUT` / rc `124`.
- **Unexpected concurrent-run SKIP** → inspect the emitted lock diagnostics (`lslocks`, `fuser`, `/proc/*/fd`) to identify any real lock holder.

## License
- SPDX-License-Identifier: BSD-3-Clause
- (C) Qualcomm Technologies, Inc. and/or its subsidiaries.
