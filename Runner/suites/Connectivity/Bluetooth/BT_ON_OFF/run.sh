#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# BT_ON_OFF - Basic Bluetooth power toggle validation

# ---------- Repo env + helpers ----------
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
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
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
BT_RUNTIME_READY_WAIT="${BT_RUNTIME_READY_WAIT:-20}"
BT_RUNTIME_RECOVERY_WAIT="${BT_RUNTIME_RECOVERY_WAIT:-40}"
BT_RUNTIME_RECOVERY_ATTEMPTS="${BT_RUNTIME_RECOVERY_ATTEMPTS:-2}"

usage() {
    cat <<EOF_USAGE
Usage: $0 [options]

Options:
  --adapter HCI_ADAPTER
  --power-cycle-delay SECONDS
  --power-on-attempts COUNT
  --power-on-retry-delay SECONDS
  --restart-service-on-retry 0|1
EOF_USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --adapter|--power-cycle-delay|--power-on-attempts|--power-on-retry-delay|--restart-service-on-retry)
                if [ "$#" -lt 2 ]; then
                    log_error "$1 requires a value"
                    usage >&2
                    return 2
                fi

                case "$1" in
                    --adapter)
                        BT_ADAPTER="$2"
                        ;;
                    --power-cycle-delay)
                        BT_POWER_CYCLE_DELAY="$2"
                        ;;
                    --power-on-attempts)
                        BT_POWER_ON_ATTEMPTS="$2"
                        ;;
                    --power-on-retry-delay)
                        BT_POWER_ON_RETRY_DELAY="$2"
                        ;;
                    --restart-service-on-retry)
                        BT_RESTART_SERVICE_ON_RETRY="$2"
                        ;;
                esac
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage >&2
                return 2
                ;;
        esac
    done
}

parse_args "$@" || exit $?

for positive_value in \
    "$BT_POWER_CYCLE_DELAY" \
    "$BT_POWER_ON_ATTEMPTS" \
    "$BT_POWER_ON_RETRY_DELAY" \
    "$BT_RUNTIME_READY_WAIT" \
    "$BT_RUNTIME_RECOVERY_WAIT" \
    "$BT_RUNTIME_RECOVERY_ATTEMPTS"
do
    if ! is_unsigned_number "$positive_value" || [ "$positive_value" -eq 0 ]; then
        log_error "Bluetooth retry counts and wait values must be positive integers"
        exit 2
    fi
done

case "$BT_RESTART_SERVICE_ON_RETRY" in
    0|1)
        ;;
    *)
        log_error "--restart-service-on-retry must be 0 or 1"
        exit 2
        ;;
esac

testpath="$(find_test_case_by_name "BT_ON_OFF")" || {
    log_fail "BT_ON_OFF FAIL - test directory not found"
    printf '%s\n' "BT_ON_OFF FAIL" >./BT_ON_OFF.res
    exit 1
}

cd "$testpath" || exit 1
TESTNAME="BT_ON_OFF"
RES_FILE="./$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"
log_info "Config: BT_POWER_CYCLE_DELAY=${BT_POWER_CYCLE_DELAY}s BT_POWER_ON_ATTEMPTS=$BT_POWER_ON_ATTEMPTS BT_POWER_ON_RETRY_DELAY=${BT_POWER_ON_RETRY_DELAY}s BT_RESTART_SERVICE_ON_RETRY=$BT_RESTART_SERVICE_ON_RETRY"
if ! bt_prepare_bluetooth_stack; then
    test_result_finish "FAIL" "$TESTNAME FAIL - Bluetooth stack preparation failed"
fi

log_info "Checking dependency: bluetoothctl"

# Verify that all necessary dependencies are available.
if ! check_dependencies bluetoothctl pgrep; then
    test_result_finish "SKIP" "$TESTNAME SKIP - required Bluetooth tools are unavailable"
fi

log_info "Ensuring Bluetooth runtime readiness before power-cycle validation"
if ! bt_ensure_runtime_ready \
    "$BT_ADAPTER" \
    "$BT_RUNTIME_READY_WAIT" \
    "$BT_RUNTIME_RECOVERY_WAIT" \
    "$BT_RUNTIME_RECOVERY_ATTEMPTS"; then
    test_result_finish \
        "FAIL" \
        "${BT_RUNTIME_FAILURE_REASON:-Bluetooth runtime remained unusable after bounded recovery attempts}"
fi

ADAPTER="$BT_RUNTIME_READY_ADAPTER"
test_result_record "PASS" "Bluetooth runtime is ready with usable adapter $ADAPTER"

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
    test_result_finish "FAIL" "Bluetooth daemon was not detected after ${MAX_RETRIES} attempts"
fi

test_result_record "PASS" "Bluetooth daemon is running"

# -----------------------------
# Detect adapter with precedence: CLI/ENV > auto-detect
# -----------------------------
if [ -n "$BT_ADAPTER" ]; then
    log_info "Using adapter from BT_ADAPTER/CLI: $ADAPTER"

    if command -v bt_adapter_is_usable >/dev/null 2>&1; then
        if ! bt_adapter_is_usable "$ADAPTER"; then
            log_warn "Requested adapter '$ADAPTER' is not currently UP/RUNNING with a valid BD address."
            bt_log_hci_candidates || true
        fi
    fi
else
    bt_log_hci_candidates || true
fi
 
if [ -n "$ADAPTER" ]; then
    if [ -n "$BT_ADAPTER" ]; then
        bt_log_selected_adapter "$ADAPTER" "BT_ADAPTER/CLI"
    else
        bt_log_selected_adapter "$ADAPTER" "auto-detect"
    fi
fi

if [ -z "$ADAPTER" ]; then
    test_result_finish "FAIL" "No usable Bluetooth HCI adapter was found after runtime recovery"
fi

# Warn/diag if non-interactive "bluetoothctl list" is empty. This is non-fatal.
btwarniflistempty "$ADAPTER" || true

# Ensure controller is visible to bluetoothctl, trying public-addr if needed.
if ! bt_ensure_controller_visible "$ADAPTER"; then
    btloghcidiag "$ADAPTER" failure "$testpath" || true
    test_result_finish "FAIL" "No controller is visible to bluetoothctl after runtime recovery"
fi

test_result_record "PASS" "Bluetooth controller is visible to bluetoothctl"

# Read initial power state.
initial_power="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
[ -z "$initial_power" ] && initial_power="unknown"
log_info "Initial Powered = $initial_power"

# ---- Power OFF test ----
log_info "Powering OFF..."
if ! btpower "$ADAPTER" off; then
    btloghcidiag "$ADAPTER" failure "$testpath" || true
    test_result_finish "FAIL" "btpower($ADAPTER, off) did not confirm stable Powered=no"
fi
test_result_record "PASS" "Power OFF completed with consecutive Powered=no confirmations"

# ---- Power ON test ----
log_info "Waiting ${BT_POWER_CYCLE_DELAY}s before Powering ON..."
sleep "$BT_POWER_CYCLE_DELAY"

log_info "Powering ON..."
on_attempt=1
on_success=0

while [ "$on_attempt" -le "$BT_POWER_ON_ATTEMPTS" ]; do
    log_info "Power ON attempt $on_attempt/$BT_POWER_ON_ATTEMPTS"

    if btpower "$ADAPTER" on; then
        on_success=1
        break
    else
        log_warn "btpower($ADAPTER, on) failed on attempt $on_attempt"
    fi

    log_warn "Collecting Bluetooth diagnostics after failed Power ON attempt $on_attempt"
    btloghcidiag "$ADAPTER" failure "$testpath" || true

    if [ "$on_attempt" -lt "$BT_POWER_ON_ATTEMPTS" ]; then
        log_warn "Preparing controlled Power ON retry after ${BT_POWER_ON_RETRY_DELAY}s"
        sleep "$BT_POWER_ON_RETRY_DELAY"

        if [ "$BT_RESTART_SERVICE_ON_RETRY" -eq 1 ] 2>/dev/null; then
            bt_recover_runtime "$ADAPTER" || \
                log_warn "Controlled Bluetooth recovery did not complete before retry"
        elif command -v rfkill >/dev/null 2>&1; then
            log_info "Running rfkill unblock bluetooth before retry"
            rfkill unblock bluetooth >/dev/null 2>&1 || true
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

    test_result_record "PASS" "Power ON completed with consecutive Powered=yes confirmations"
    test_result_finish
fi

after_on="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
[ -z "$after_on" ] && after_on="unknown"

btloghcidiag "$ADAPTER" failure "$testpath" || true
test_result_finish "FAIL" "Stable Powered=yes was not confirmed after $BT_POWER_ON_ATTEMPTS attempts, final observation=$after_on"
