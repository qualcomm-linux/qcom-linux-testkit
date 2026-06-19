#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# BT_ON_OFF - Basic Bluetooth power toggle validation (non-expect version)

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

# QCA/WCN UART controllers may need a short settle window after Powered=no
# before a new Powered=yes request. Defaults are CI-safe but overridable.
BT_POWER_CYCLE_DELAY="${BT_POWER_CYCLE_DELAY:-10}"
BT_POWER_ON_ATTEMPTS="${BT_POWER_ON_ATTEMPTS:-2}"
BT_POWER_ON_RETRY_DELAY="${BT_POWER_ON_RETRY_DELAY:-10}"
BT_RESTART_SERVICE_ON_RETRY="${BT_RESTART_SERVICE_ON_RETRY:-1}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --adapter)
            BT_ADAPTER="$2"
            shift 2
            ;;
        --power-cycle-delay)
            BT_POWER_CYCLE_DELAY="$2"
            shift 2
            ;;
        --power-on-attempts)
            BT_POWER_ON_ATTEMPTS="$2"
            shift 2
            ;;
        --power-on-retry-delay)
            BT_POWER_ON_RETRY_DELAY="$2"
            shift 2
            ;;
        --restart-service-on-retry)
            BT_RESTART_SERVICE_ON_RETRY="$2"
            shift 2
            ;;
        *)
            log_warn "Unknown argument ignored: $1"
            shift 1
            ;;
    esac
done

case "$BT_POWER_CYCLE_DELAY" in
    ''|*[!0-9]*)
        BT_POWER_CYCLE_DELAY=10
        ;;
esac

case "$BT_POWER_ON_ATTEMPTS" in
    ''|*[!0-9]*)
        BT_POWER_ON_ATTEMPTS=2
        ;;
esac

case "$BT_POWER_ON_RETRY_DELAY" in
    ''|*[!0-9]*)
        BT_POWER_ON_RETRY_DELAY=10
        ;;
esac

case "$BT_RESTART_SERVICE_ON_RETRY" in
    0|1)
        ;;
    *)
        BT_RESTART_SERVICE_ON_RETRY=1
        ;;
esac

if [ "$BT_POWER_ON_ATTEMPTS" -lt 1 ] 2>/dev/null; then
    BT_POWER_ON_ATTEMPTS=1
fi

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
log_info "Config: BT_POWER_CYCLE_DELAY=${BT_POWER_CYCLE_DELAY}s BT_POWER_ON_ATTEMPTS=$BT_POWER_ON_ATTEMPTS BT_POWER_ON_RETRY_DELAY=${BT_POWER_ON_RETRY_DELAY}s BT_RESTART_SERVICE_ON_RETRY=$BT_RESTART_SERVICE_ON_RETRY"
log_info "Checking dependency: bluetoothctl"

# Verify that all necessary dependencies are available.
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

    if command -v bt_adapter_is_usable >/dev/null 2>&1; then
        if ! bt_adapter_is_usable "$ADAPTER"; then
            log_warn "Requested adapter '$ADAPTER' is not currently UP/RUNNING with a valid BD address."
            bt_log_hci_candidates || true
        fi
    fi
else
    bt_log_hci_candidates || true

    if command -v bt_select_usable_adapter >/dev/null 2>&1; then
        ADAPTER="$(bt_select_usable_adapter 2>/dev/null || true)"
    elif findhcisysfs >/dev/null 2>&1; then
        ADAPTER="$(findhcisysfs 2>/dev/null || true)"
    else
        ADAPTER=""
    fi
fi

if [ -n "$ADAPTER" ]; then
    if [ -n "$BT_ADAPTER" ]; then
        bt_log_selected_adapter "$ADAPTER" "BT_ADAPTER/CLI"
    else
        bt_log_selected_adapter "$ADAPTER" "auto-detect"
    fi
fi

# Warn/diag if non-interactive "bluetoothctl list" is empty. This is non-fatal.
btwarniflistempty "$ADAPTER" || true

# Ensure controller is visible to bluetoothctl, trying public-addr if needed.
if ! bt_ensure_controller_visible "$ADAPTER"; then
    btloghcidiag "$ADAPTER" failure "$testpath" || true
    log_warn "SKIP — no controller visible to bluetoothctl (HCI RAW/DOWN or attach incomplete)."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# Read initial power state.
initial_power="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
[ -z "$initial_power" ] && initial_power="unknown"
log_info "Initial Powered = $initial_power"

# ---- Power OFF test ----
log_info "Powering OFF..."
if ! btpower "$ADAPTER" off; then
    log_fail "btpower($ADAPTER, off) failed (command-level error)."
    btloghcidiag "$ADAPTER" failure "$testpath" || true
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

after_off="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
[ -z "$after_off" ] && after_off="unknown"

if [ "$after_off" = "no" ]; then
    log_pass "Post-OFF verification: Powered=no (as expected)."
else
    log_fail "Post-OFF verification failed (Powered=$after_off)."
    btloghcidiag "$ADAPTER" failure "$testpath" || true
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# ---- Power ON test ----
log_info "Waiting ${BT_POWER_CYCLE_DELAY}s before Powering ON..."
sleep "$BT_POWER_CYCLE_DELAY"

log_info "Powering ON..."
on_attempt=1
on_success=0

while [ "$on_attempt" -le "$BT_POWER_ON_ATTEMPTS" ]; do
    log_info "Power ON attempt $on_attempt/$BT_POWER_ON_ATTEMPTS"

    if btpower "$ADAPTER" on; then
        after_on="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
        [ -z "$after_on" ] && after_on="unknown"

        if [ "$after_on" = "yes" ]; then
            on_success=1
            break
        fi

        log_warn "Power ON command returned success, but post-check Powered=$after_on"
    else
        log_warn "btpower($ADAPTER, on) failed on attempt $on_attempt"
    fi

    log_warn "Collecting Bluetooth diagnostics after failed Power ON attempt $on_attempt"
    btloghcidiag "$ADAPTER" failure "$testpath" || true

    if [ "$on_attempt" -lt "$BT_POWER_ON_ATTEMPTS" ]; then
        log_warn "Preparing controlled Power ON retry after ${BT_POWER_ON_RETRY_DELAY}s"
        sleep "$BT_POWER_ON_RETRY_DELAY"

        if command -v rfkill >/dev/null 2>&1; then
            log_info "Running rfkill unblock bluetooth before retry"
            rfkill unblock bluetooth >/dev/null 2>&1 || true
        elif command -v rfkillunblocksysfs >/dev/null 2>&1; then
            log_info "Running rfkillunblocksysfs before retry"
            rfkillunblocksysfs >/dev/null 2>&1 || true
        else
            log_warn "No rfkill unblock helper available before retry"
        fi

        if [ "$BT_RESTART_SERVICE_ON_RETRY" -eq 1 ] 2>/dev/null && command -v systemctl >/dev/null 2>&1; then
            log_info "Restarting bluetooth.service before retry"
            systemctl restart bluetooth >/dev/null 2>&1 || log_warn "systemctl restart bluetooth failed"
            sleep 3
        fi

        if command -v bt_ensure_controller_visible >/dev/null 2>&1; then
            bt_ensure_controller_visible "$ADAPTER" || log_warn "Controller visibility check failed before retry"
        fi
    fi

    on_attempt=$((on_attempt + 1))
done

if [ "$on_success" -eq 1 ]; then
    if [ "$on_attempt" -gt 1 ]; then
        log_warn "Power ON recovered on attempt $on_attempt/$BT_POWER_ON_ATTEMPTS"
    fi

    btwarniflistempty "$ADAPTER" || true

    log_pass "Post-ON verification: Powered=yes (as expected)."
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
fi

after_on="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
[ -z "$after_on" ] && after_on="unknown"

log_fail "Post-ON verification failed after $BT_POWER_ON_ATTEMPTS attempt(s) (Powered=$after_on)."
btloghcidiag "$ADAPTER" failure "$testpath" || true
echo "$TESTNAME FAIL" > "$res_file"
exit 0
