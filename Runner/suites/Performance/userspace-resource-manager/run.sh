#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# userspace-resource-manager test runner (pinned whitelist)

# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" && pwd
)"
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi
# Only source once (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

# ---------- Stable env ----------
umask 022
export LC_ALL=C
export PATH="/usr/sbin:/sbin:/usr/bin:/bin:${PATH}"
# Try best-effort core dumps; ignore on strict POSIX shells.
# shellcheck disable=SC3045
( ulimit -c unlimited ) >/dev/null 2>&1 || true

TESTNAME="userspace-resource-manager"
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1
RES_FILE="./${TESTNAME}.res"

# Optional generic package-set recovery.
# This must be a clean no-op when no package-set mapping exists for the active OS/provider.
if [ -f "$TOOLS/lib_pkg_provider.sh" ]; then
    # shellcheck disable=SC1091
    . "$TOOLS/lib_pkg_provider.sh"
fi

log_info "=== Checking Dependencies ==="
if ! check_dependencies awk grep pgrep date printf; then
    log_skip "$TESTNAME SKIP – base tools missing"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# ---------- Lock (avoid concurrent runs on same host) ----------
LOCKFILE="/tmp/${TESTNAME}.lock"
LOCKDIR="/tmp/${TESTNAME}.lockdir"

if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    log_warn "Another ${TESTNAME} run is active; skipping"
    log_info "Active URM-related processes:"
    pgrep -af 'userspace-resource-manager|Urm(Component|Integration)Tests|run.sh' || true
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
  lock_flock=1
  trap 'exec 9>&-' EXIT INT TERM
else
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    log_warn "Another ${TESTNAME} run is active or stale fallback lockdir exists: $LOCKDIR"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
  fi
  lock_flock=0
  trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
fi

# ---------- Approved list (pinned whitelist) ----------
APPROVED_TESTS="
/usr/bin/UrmComponentTests
/usr/bin/UrmIntegrationTests
"

# Suites that need base configs (all of common/, tests/configs and tests/nodes are needed)
SUITES_REQUIRE_BASE_CFGS="UrmComponentTests UrmIntegrationTests"

# ---------- CLI ----------
print_usage() {
    cat <<EOF
Usage: $0 [--all] [--bin <name|absolute>] [--list] [--timeout SECS]
Policy:
  - Service INACTIVE => overall SKIP (end early)
  - Base configs: suites require common/, tests/configs and tests/nodes (skip if any of them are missing)
  - Any test FAIL => overall FAIL
  - No FAIL & PASS>0 => overall PASS
  - No FAIL & PASS=0 => overall SKIP (everything skipped)

Options:
  --all Run all approved tests (default)
  --bin NAME|PATH Run only one approved test
  --list Print approved set and coverage and exit
  --timeout SECS Per-binary timeout if run_with_timeout() exists (default: 1200)
EOF
}
RUN_MODE="all"
ONE_BIN=""
TIMEOUT_SECS=1200
while [ $# -gt 0 ]; do
    case "$1" in
        --all)
            RUN_MODE="all"
            ;;
        --bin)
            shift
            ONE_BIN="$1"
            RUN_MODE="one"
            ;;
        --list)
            RUN_MODE="list"
            ;;
        --timeout)
            shift
            TIMEOUT_SECS="${1:-1200}"
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            print_usage
            exit 1
            ;;
    esac
    shift
done

# ---------- Whitelist helpers (needed before package recovery) ----------
approved_tests() {
    printf '%s\n' "$APPROVED_TESTS" | awk 'NF'
}
is_approved() {
    cand="$1"
    cbase="$(basename "$cand")"
    for t in $(approved_tests); do
        if [ "$cand" = "$t" ]; then
            return 0
        fi
        if [ "$cbase" = "$(basename "$t")" ]; then
            return 0
        fi
    done
    return 1
}

# ---------- Ensure packages ----------
# Run only when at least one approved test will actually execute:
#   --all              => always recover
#   --bin NAME         => recover only when NAME is non-empty and approved
# This prevents a typo or missing --bin value from triggering network access,
# package installation and post-install actions before the runner skips the
# unapproved test.
# Guard with command -v so the calls are safe even when lib_pkg_provider.sh
# was not sourced or the OS/provider has no mapping.
pkg_recovery_needed=0
if [ "$RUN_MODE" = "all" ]; then
    pkg_recovery_needed=1
elif [ "$RUN_MODE" = "one" ]; then
    if [ -n "$ONE_BIN" ] && is_approved "$ONE_BIN"; then
        pkg_recovery_needed=1
    else
        log_error "[PKG] --bin value '${ONE_BIN}' is not in the approved set; aborting"
        echo "$TESTNAME FAIL" >"$RES_FILE"
        exit 1
    fi
fi
if [ "$pkg_recovery_needed" -eq 1 ]; then
    if command -v pkg_lookup_package_set >/dev/null 2>&1 && \
       command -v pkg_ensure_required_package_set_present >/dev/null 2>&1; then
        if pkg_lookup_package_set urm >/dev/null 2>&1; then
            if ! pkg_ensure_required_package_set_present urm; then
                log_skip "$TESTNAME SKIP - failed to ensure required package set: urm"
                echo "$TESTNAME SKIP" >"$RES_FILE"
                exit 0
            fi
        else
            log_info "No URM package-set mapping for this OS/provider; using image-provided assets"
        fi
    else
        log_info "pkg_lookup_package_set / pkg_ensure_required_package_set_present not available; using image-provided assets"
    fi
fi

# ---------- Helpers ----------
suite_requires_base_cfgs() {
    name="$1"
    for s in $SUITES_REQUIRE_BASE_CFGS; do
        if [ "$name" = "$s" ]; then
            return 0
        fi
    done
    return 1
}
per_suite_timeout() {
    case "$1" in
        UrmComponentTests)
            echo 1800
            ;;
        UrmIntegrationTests)
            echo 2400
            ;;
        *)
            echo "$TIMEOUT_SECS"
            ;;
    esac
}
run_cmd_maybe_timeout() {
    bin="$1"
    shift
    secs="$(per_suite_timeout "$(basename "$bin")")"
    if command -v run_with_timeout >/dev/null 2>&1; then
        run_with_timeout "$secs" "$bin" "$@"
    else
        "$bin" "$@"
    fi
}

# ---------- Banner & deps ----------
log_info "----------------------------------------------------------------------"
log_info "------------------- Starting ${TESTNAME} Testcase ----------------------"
log_info "=== Test Initialization ==="

# ---------- Logs ----------
TS="$(date +%Y%m%d-%H%M%S)"
LOGDIR="./logs/${TESTNAME}-${TS}"
mkdir -p "$LOGDIR"
(dmesg 2>/dev/null || true) > "$LOGDIR/dmesg_snapshot.log"
ln -sfn "$LOGDIR" "./logs/${TESTNAME}-latest" 2>/dev/null || true

# ---------- SoC / Platform info (via functestlib) ----------
if command -v log_soc_info >/dev/null 2>&1; then
    log_soc_info
fi

# ---------- Service gate (use repo helper) ----------
SERVICE_NAME="${SERVICE_NAME:-urm.service}"
log_info "[SERVICE] Checking $SERVICE_NAME via check_systemd_services()"
if check_systemd_services "$SERVICE_NAME"; then
    log_pass "[SERVICE] $SERVICE_NAME is active"
else
    log_warn "[SERVICE] $SERVICE_NAME not active — attempting enable/start"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable urm >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl start urm >/dev/null 2>&1 || true
        systemctl status urm --no-pager -l >/dev/null 2>&1 || true
    else
        log_warn "[SERVICE] systemctl not available; cannot auto-start $SERVICE_NAME"
    fi

    if check_systemd_services "$SERVICE_NAME"; then
        log_pass "[SERVICE] $SERVICE_NAME is active after start attempt"
    else
        log_skip "[SERVICE] $SERVICE_NAME not active — overall SKIP"
        echo "$TESTNAME SKIP" >"$RES_FILE"
        exit 0
    fi
fi

# ---------- Config preflight (check both common/ and tests/) ----------
# Resolution order for each root (first match wins):
#   1. Explicit per-root override (URM_COMMON_CONFIG_DIR / URM_TESTS_CONFIG_DIR)
#   2. Legacy URM_CONFIG_DIR (compatibility fallback for existing callers)
#   3. Built-in default
#
# For test-nodes the candidate order is:
#   1. Explicit URM_TEST_NODES_DIR override
#   2. Legacy URM_CONFIG_DIR (compatibility fallback for existing callers)
#   3. /var/lib/urm  — runtime/writable location, only when non-empty
#   4. /usr/share/urm — package-installed location (default)

# Resolve common-config root
if [ -n "${URM_COMMON_CONFIG_DIR:-}" ]; then
    common_root="$URM_COMMON_CONFIG_DIR"
elif [ -n "${URM_CONFIG_DIR:-}" ]; then
    common_root="$URM_CONFIG_DIR"
else
    common_root="/etc/urm"
fi

# Resolve tests-config root
if [ -n "${URM_TESTS_CONFIG_DIR:-}" ]; then
    tests_root="$URM_TESTS_CONFIG_DIR"
elif [ -n "${URM_CONFIG_DIR:-}" ]; then
    tests_root="$URM_CONFIG_DIR"
else
    tests_root="/usr/share/urm"
fi

# Resolve test-nodes root: explicit override > legacy URM_CONFIG_DIR > populated runtime dir > package dir
if [ -n "${URM_TEST_NODES_DIR:-}" ]; then
    nodes_root="$URM_TEST_NODES_DIR"
elif [ -n "${URM_CONFIG_DIR:-}" ]; then
    nodes_root="$URM_CONFIG_DIR"
elif [ -d "/var/lib/urm/tests/nodes" ] && \
     [ "$(find "/var/lib/urm/tests/nodes" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l | awk '{print $1}')" -gt 0 ]; then
    nodes_root="/var/lib/urm"
else
    nodes_root="/usr/share/urm"
fi

COMMON_CONFIGS_DIR="$common_root/common"
TEST_CONFIGS_DIR="$tests_root/tests/configs"
TEST_NODES_DIR="$nodes_root/tests/nodes"

COMMON_CONFIGS_OK=1
TEST_CONFIGS_OK=1
TEST_NODES_OK=1

REQ_COMMON_FILES="${URM_REQUIRE_COMMON_FILES:-InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml}"
REQ_TEST_CONFIGS="${URM_REQUIRE_TEST_FILES:-InitConfig.yaml PropertiesConfig.yaml ResourcesConfig.yaml SignalsConfig.yaml TargetConfig.yaml ExtFeaturesConfig.yaml Baseline.yaml}"

# common/
if [ ! -d "$COMMON_CONFIGS_DIR" ]; then
    log_warn "[CFG] Missing dir: $COMMON_CONFIGS_DIR"
    COMMON_CONFIGS_OK=0
else
    for f in $REQ_COMMON_FILES; do
        if [ ! -f "$COMMON_CONFIGS_DIR/$f" ]; then
            log_warn "[CFG] Missing file: $COMMON_CONFIGS_DIR/$f"
            COMMON_CONFIGS_OK=0
        fi
    done
fi

# tests/configs
if [ ! -d "$TEST_CONFIGS_DIR" ]; then
    log_warn "[CFG] Missing dir: $TEST_CONFIGS_DIR"
    TEST_CONFIGS_OK=0
else
    for f in $REQ_TEST_CONFIGS; do
        if [ ! -f "$TEST_CONFIGS_DIR/$f" ]; then
            log_warn "[CFG] Missing file: $TEST_CONFIGS_DIR/$f"
            TEST_CONFIGS_OK=0
        fi
    done
fi

# tests/nodes (hard requirement for UrmIntegrationTests and UrmComponentTests)
if [ ! -d "$TEST_NODES_DIR" ]; then
    log_warn "[CFG] Missing dir: $TEST_NODES_DIR"
    TEST_NODES_OK=0
else
    count_nodes="$(
      find "$TEST_NODES_DIR" -mindepth 1 -maxdepth 1 -type f -print 2>/dev/null \
      | wc -l | awk '{print $1}'
    )"
    if [ "${count_nodes:-0}" -le 0 ]; then
        log_warn "[CFG] $TEST_NODES_DIR is empty"
        TEST_NODES_OK=0
    fi
fi

# ---------- Preflight whitelist coverage ----------
: >"$LOGDIR/summary.txt"
preflight_bins() {
    : >"$LOGDIR/coverage.txt"
    : >"$LOGDIR/missing_bins.txt"
    total=0
    present=0
    missing=0
    for t in $(approved_tests); do
        total=$((total+1))
        base="$(basename "$t")"
        resolved="$t"
        if [ ! -x "$resolved" ]; then
            resolved="$(command -v "$base" 2>/dev/null || true)"
        fi
        if [ -x "$resolved" ]; then
            echo "[PRESENT] $base -> $resolved" >>"$LOGDIR/coverage.txt"
            present=$((present+1))
        else
            echo "[MISSING] $base" >>"$LOGDIR/missing_bins.txt"
            echo "SKIP" >"$LOGDIR/${base}.res"
            echo "[SKIP] $base – not found" >>"$LOGDIR/summary.txt"
            missing=$((missing+1))
        fi
    done
    {
        echo "total=$total"
        echo "present=$present"
        echo "missing=$missing"
    } > "$LOGDIR/coverage_counts.env"
    if [ $missing -gt 0 ]; then
        log_warn "Whitelist coverage: $present/$total present, $missing missing"
    fi
}
preflight_bins
if [ -r "$LOGDIR/coverage_counts.env" ]; then
  # shellcheck disable=SC1091
  . "$LOGDIR/coverage_counts.env"
else
  total=0
  present=0
  missing=0
fi

# ---------- List mode ----------
if [ "$RUN_MODE" = "list" ]; then
    log_info "Approved tests:"
    approved_tests | sed 's/^/ - /'
    log_info "Coverage:"
    sed 's/^/ - /' "$LOGDIR/coverage.txt" 2>/dev/null || true
    if [ -s "$LOGDIR/missing_bins.txt" ]; then
        log_info "Missing:"
        sed 's/^/ - /' "$LOGDIR/missing_bins.txt"
    fi
    exit 0
fi

# ---------- Build run list ----------
if [ "$RUN_MODE" = "one" ]; then
    TESTS="$ONE_BIN"
else
    TESTS="$(approved_tests)"
fi
if [ -z "$TESTS" ]; then
    log_skip "$TESTNAME SKIP – approved list empty"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

# ---------- Stage test nodes into the hardcoded runtime path ----------
# UrmComponentTests and UrmIntegrationTests read nodes from the fixed path
# /run/urm/tests/nodes (hardcoded in the binaries). The package installs
# read-only node files under /usr/share/urm/tests/nodes (or /var/lib/urm),
# so we copy them to the writable runtime location before running the tests.
# Cleanup removes only the directory we created, and is registered with trap
# immediately so it runs on exit, interrupt, or termination.
RUNTIME_NODES_DIR="/run/urm/tests/nodes"
if [ "$TEST_NODES_OK" -eq 1 ]; then
    mkdir -p "$RUNTIME_NODES_DIR"
    if cp -r "$TEST_NODES_DIR/"* "$RUNTIME_NODES_DIR/"; then
        log_info "[NODES] Staged test nodes from $TEST_NODES_DIR to $RUNTIME_NODES_DIR"
        # Extend the existing trap to also clean up the staged nodes.
        if [ "$lock_flock" -eq 1 ]; then
            trap 'rm -rf "$RUNTIME_NODES_DIR"; exec 9>&-' EXIT INT TERM
        else
            trap 'rm -rf "$RUNTIME_NODES_DIR"; rmdir "$LOCKDIR" 2>/dev/null || true' EXIT INT TERM
        fi
    else
        log_warn "[NODES] Failed to stage test nodes into $RUNTIME_NODES_DIR — suites requiring nodes will SKIP"
        TEST_NODES_OK=0
    fi
fi

# ---------- Execute ----------
PASS=0
FAIL=0
SKIP=0

run_one() {
    bin="$1"
    name="$(basename "$bin")"
    tlog="$LOGDIR/${name}.log"
    tres="$LOGDIR/${name}.res"

    # whitelist enforcement
    if ! is_approved "$bin"; then
        log_skip "[TEST] $name not in approved set – skipping"
        echo "SKIP" >"$tres"
        echo "[SKIP] $name – not approved" >>"$LOGDIR/summary.txt"
        return 2
    fi

    # base config requirement: common configs, tests/configs as well as tests/nodes
    # If any of them are missing, skip.
    if suite_requires_base_cfgs "$name"; then
        if [ $COMMON_CONFIGS_OK -eq 0 ] || [ $TEST_CONFIGS_OK -eq 0 ] || [ $TEST_NODES_OK -eq 0 ]; then
            log_skip "[CFG] Base configs missing (one or more of common/, tests/configs or tests/nodes not found) — skipping $name"
            echo "SKIP" >"$tres"
            echo "[SKIP] $name – base configs missing" >>"$LOGDIR/summary.txt"
            return 2
        fi
    fi

    # resolve binary
    if [ ! -x "$bin" ] && command -v "$bin" >/dev/null 2>&1; then
        bin="$(command -v "$bin")"
    fi
    if [ ! -x "$bin" ]; then
        log_skip "[TEST] $name missing – skipping"
        echo "SKIP" >"$tres"
        echo "[SKIP] $name – not found" >>"$LOGDIR/summary.txt"
        return 2
    fi

    log_info "--- Running $bin ---"
    log_info "[CI] Logging to $tlog"
    run_cmd_maybe_timeout "$bin" >"$tlog" 2>&1
    rc=$?

    case $rc in
        0)
            log_pass "[TEST] $name PASS"
            echo "PASS" >"$tres"
            echo "[PASS] $name" >>"$LOGDIR/summary.txt"
            return 0
            ;;
        1)
            log_fail "[TEST] $name FAIL"
            echo "FAIL" >"$tres"
            echo "[FAIL] $name (rc=$rc)" >>"$LOGDIR/summary.txt"
            return 1
            ;;
        *)
            log_fail "[TEST] $name UNKNOWN RC=$rc"
            echo "FAIL" >"$tres"
            echo "[FAIL] $name (unexpected rc=$rc)" >>"$LOGDIR/summary.txt"
            return 1
            ;;
    esac
}

for t in $TESTS; do
    run_one "$t"
    rc=$?
    case $rc in
        0)
            PASS=$((PASS+1))
            ;;
        1)
            FAIL=$((FAIL+1))
            ;;
        2)
            SKIP=$((SKIP+1))
            ;;
    esac
done

# ---------- Summaries & gating ----------
log_info "--------------------------------------------------"
log_info "Per-test summary:"
sed -n 'p' "$LOGDIR/summary.txt" | while IFS= read -r L; do
    if [ -n "$L" ]; then
        log_info " $L"
    fi
done

if [ -r "$LOGDIR/coverage_counts.env" ]; then
  # shellcheck disable=SC1091
  . "$LOGDIR/coverage_counts.env"
else
  total=${total:-0}
  present=${present:-0}
  missing=${missing:-0}
fi

log_info "Coverage: ${present:-0}/${total:-0} present"
log_info "Overall counts: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

# Final policy (skips are neutral):
# - Any FAIL -> overall FAIL
# - Else if PASS>0 -> overall PASS
# - Else -> overall SKIP (everything skipped)
if [ "$FAIL" -gt 0 ]; then
  echo "$TESTNAME FAIL" >"$RES_FILE"
  exit 1
fi
if [ "$PASS" -gt 0 ]; then
  echo "$TESTNAME PASS" >"$RES_FILE"
  exit 0
fi

echo "$TESTNAME SKIP" >"$RES_FILE"
exit 0
