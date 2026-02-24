#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# BT_ON_OFF - Basic Bluetooth power toggle validation (non-expect version)

# Robustly find and source init_env
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
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

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1091
. "$TOOLS/lib_bluetooth.sh"

# ---------- CLI / env parameters ----------
# BT_ADAPTER can be set from CLI via --adapter or from environment.
BT_ADAPTER="${BT_ADAPTER-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --adapter)
            BT_ADAPTER="$2"
            shift 2
            ;;
        *)
            log_warn "Unknown argument ignored: $1"
            shift 1
            ;;
    esac
done

TESTNAME="BT_ON_OFF"
testpath="$(find_test_case_by_name "$TESTNAME")" || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}

cd "$testpath" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"
log_info "Checking dependency: bluetoothctl"

# verify that all necessary dependencies
check_dependencies bluetoothctl pgrep

log_info "Checking if bluetoothd is running..."
MAX_RETRIES=3
RETRY_DELAY=5
retry=0

while [ "$retry" -lt "$MAX_RETRIES" ]; do
    if pgrep bluetoothd >/dev/null 2>&1; then
        log_info "bluetoothd is running"
        break
    fi
    log_warn "bluetoothd not running, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    retry=$((retry + 1))
done

if [ "$retry" -eq "$MAX_RETRIES" ]; then
    log_fail "Bluetooth daemon not detected after ${MAX_RETRIES} attempts."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# -----------------------------
# Detect adapter with precedence: CLI/ENV > auto-detect
# -----------------------------
if [ -n "$BT_ADAPTER" ]; then
    ADAPTER="$BT_ADAPTER"
    log_info "Using adapter from BT_ADAPTER/CLI: $ADAPTER"
elif findhcisysfs >/dev/null 2>&1; then
    ADAPTER="$(findhcisysfs 2>/dev/null || true)"
else
    ADAPTER=""
fi

if [ -n "$ADAPTER" ]; then
    log_info "Using adapter: $ADAPTER"
else
    log_warn "No HCI adapter found; skipping test."
    echo "$TESTNAME SKIP" > "./$TESTNAME.res"
    exit 0
fi

# --- NEW: warn/diag if non-interactive "bluetoothctl list" is empty (non-fatal) ---
btwarniflistempty "$ADAPTER" || true

# Ensure controller is visible to bluetoothctl (try public-addr if needed)
if ! bt_ensure_controller_visible "$ADAPTER"; then
    # --- NEW: print diagnostics before skipping ---
    btloghcidiag "$ADAPTER"
    log_warn "SKIP — no controller visible to bluetoothctl (HCI RAW/DOWN or attach incomplete)."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Read initial power state
initial_power="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
[ -z "$initial_power" ] && initial_power="unknown"
log_info "Initial Powered = $initial_power"

# ---- Power OFF test ----
log_info "Powering OFF..."
if ! btpower "$ADAPTER" off; then
    log_fail "btpower($ADAPTER, off) failed (command-level error)."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

after_off="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
[ -z "$after_off" ] && after_off="unknown"

if [ "$after_off" = "no" ]; then
    log_pass "Post-OFF verification: Powered=no (as expected)."
else
    log_fail "Post-OFF verification failed (Powered=$after_off)."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# ---- Power ON test ----
log_info "Powering ON..."
if ! btpower "$ADAPTER" on; then
    log_fail "btpower($ADAPTER, on) failed (command-level error)."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

after_on="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
[ -z "$after_on" ] && after_on="unknown"

if [ "$after_on" = "yes" ]; then
    # --- NEW: post-check (covers your "list is empty after run" symptom) ---
    btwarniflistempty "$ADAPTER" || true

    log_pass "Post-ON verification: Powered=yes (as expected)."
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
fi

log_fail "Post-ON verification failed (Powered=$after_on)."
echo "$TESTNAME FAIL" > "$res_file"
exit 0
