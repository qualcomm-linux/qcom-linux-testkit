#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# BT_SCAN – Bluetooth scanning validation (non-expect version)

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
BT_ADAPTER="${BT_ADAPTER-}"
BT_SCAN_TARGET_MAC="${BT_SCAN_TARGET_MAC-}"
BT_TARGET_MAC="${BT_TARGET_MAC-}"
BT_SCAN_SECONDS="${BT_SCAN_SECONDS:-15}"
BT_SCAN_RETRIES="${BT_SCAN_RETRIES:-3}"
BT_SCAN_RETRY_DELAY="${BT_SCAN_RETRY_DELAY:-2}"
BT_RUNTIME_READY_WAIT="${BT_RUNTIME_READY_WAIT:-20}"
BT_RUNTIME_RECOVERY_WAIT="${BT_RUNTIME_RECOVERY_WAIT:-40}"
BT_RUNTIME_RECOVERY_ATTEMPTS="${BT_RUNTIME_RECOVERY_ATTEMPTS:-2}"

usage() {
    cat <<EOF_USAGE
Usage: $0 [options]

Options:
  --adapter HCI_ADAPTER
  --target-mac MAC_ADDRESS
  --scan-seconds SECONDS
  --scan-retries COUNT
  --scan-retry-delay SECONDS
EOF_USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --adapter|--target-mac|--scan-seconds|--scan-retries|--scan-retry-delay)
                if [ "$#" -lt 2 ]; then
                    log_error "$1 requires a value"
                    usage >&2
                    return 2
                fi

                case "$1" in
                    --adapter)
                        BT_ADAPTER="$2"
                        ;;
                    --target-mac)
                        BT_SCAN_TARGET_MAC="$2"
                        ;;
                    --scan-seconds)
                        BT_SCAN_SECONDS="$2"
                        ;;
                    --scan-retries)
                        BT_SCAN_RETRIES="$2"
                        ;;
                    --scan-retry-delay)
                        BT_SCAN_RETRY_DELAY="$2"
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
    "$BT_SCAN_SECONDS" \
    "$BT_SCAN_RETRIES" \
    "$BT_SCAN_RETRY_DELAY" \
    "$BT_RUNTIME_READY_WAIT" \
    "$BT_RUNTIME_RECOVERY_WAIT" \
    "$BT_RUNTIME_RECOVERY_ATTEMPTS"
do
    if ! is_unsigned_number "$positive_value" || [ "$positive_value" -eq 0 ]; then
        log_error "Bluetooth scan retry counts and wait values must be positive integers"
        exit 2
    fi
done

testpath="$(find_test_case_by_name "BT_SCAN")" || {
    log_fail "BT_SCAN FAIL - test directory not found"
    printf '%s\n' "BT_SCAN FAIL" >./BT_SCAN.res
    exit 1
}

cd "$testpath" || exit 1
TESTNAME="BT_SCAN"
RES_FILE="./$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"
if ! bt_prepare_bluetooth_stack; then
    test_result_finish "FAIL" "$TESTNAME FAIL - Bluetooth stack preparation failed"
fi

log_info "Checking dependencies: bluetoothctl pgrep"

if ! check_dependencies bluetoothctl pgrep; then
    test_result_finish "SKIP" "$TESTNAME SKIP - required Bluetooth tools are unavailable"
fi

log_info "Ensuring Bluetooth runtime readiness before scanning"
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

# -----------------------------
# 1. Ensure bluetoothd is running
# -----------------------------
log_info "Checking if bluetoothd is running..."
retry=0
MAX_RETRIES=3
RETRY_DELAY=5

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
    test_result_finish "FAIL" "bluetoothd was not detected after $MAX_RETRIES attempts"
fi

test_result_record "PASS" "Bluetooth daemon is running"

# -----------------------------
# 2. Detect adapter (CLI/ENV > auto-detect)
# -----------------------------
if [ -n "$BT_ADAPTER" ]; then
    log_info "Using adapter from BT_ADAPTER/CLI: $ADAPTER"
else
    log_info "Using adapter selected during runtime readiness: $ADAPTER"
fi

if [ -n "$ADAPTER" ]; then
    if [ -n "$BT_ADAPTER" ]; then
        bt_log_selected_adapter "$ADAPTER" "BT_ADAPTER/CLI"
    else
        bt_log_selected_adapter "$ADAPTER" "auto-detect"
    fi
fi

if [ -n "$ADAPTER" ]; then
    log_info "Using adapter: $ADAPTER"
else
    test_result_finish "FAIL" "No usable HCI adapter was found after runtime recovery"
fi

# -----------------------------
# 3. Ensure controller is visible
# -----------------------------
if ! bt_ensure_controller_visible "$ADAPTER"; then
    test_result_finish "FAIL" "Controller is not visible to bluetoothctl after runtime recovery"
fi

test_result_record "PASS" "Bluetooth controller is visible to bluetoothctl"

# -----------------------------
# 4. Ensure power is ON
# -----------------------------
pw="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
if [ "$pw" = "yes" ]; then
    test_result_record "PASS" "Power ON was verified before scanning"
else
    log_info "Controller Power=$pw — enabling now..."
    if ! btpower "$ADAPTER" on; then
        test_result_finish "FAIL" "Failed to power ON the Bluetooth controller"
    fi
    test_result_record "PASS" "Bluetooth controller powered on successfully"
fi

# -----------------------------
# 5. Determine scan target MAC
# -----------------------------
TARGET_MAC="${BT_SCAN_TARGET_MAC:-$BT_TARGET_MAC}"

if [ -n "$TARGET_MAC" ]; then
    log_info "Target MAC provided: $TARGET_MAC — will validate its presence after scan."
else
    log_info "No target MAC provided, BT_SCAN will check for generic device visibility."
fi

# -----------------------------
# 6. Scan using common Bluetooth helper
# -----------------------------
log_info "Testing Bluetooth scan..."
log_info "Scan config: BT_SCAN_SECONDS=${BT_SCAN_SECONDS} BT_SCAN_RETRIES=${BT_SCAN_RETRIES} BT_SCAN_RETRY_DELAY=${BT_SCAN_RETRY_DELAY}"

SCAN_SECONDS="$BT_SCAN_SECONDS"
SCAN_ATTEMPTS="$BT_SCAN_RETRIES"
SCAN_RETRY_DELAY="$BT_SCAN_RETRY_DELAY"
MAC_ID="$TARGET_MAC"
BT_ADAPTER="$ADAPTER"

export SCAN_SECONDS
export SCAN_ATTEMPTS
export SCAN_RETRY_DELAY
export MAC_ID
export BT_ADAPTER

if bt_scan_devices "$TARGET_MAC"; then
    dstate_on="$(bt_get_discovering 2>/dev/null || true)"
    [ -z "$dstate_on" ] && dstate_on="unknown"
    log_info "Discovering state after scan attempts: $dstate_on"

    if [ -n "$TARGET_MAC" ]; then
        test_result_record "PASS" "Target MAC $TARGET_MAC was detected"
    else
        test_result_record "PASS" "At least one Bluetooth device was discovered"
    fi
else
    dstate_on="$(bt_get_discovering 2>/dev/null || true)"
    [ -z "$dstate_on" ] && dstate_on="unknown"
    log_info "Discovering state after failed scan attempts: $dstate_on"

    if [ -n "$TARGET_MAC" ]; then
        log_fail "Target MAC $TARGET_MAC missing after scan attempts."
    else
        log_fail "No Bluetooth devices discovered after scan attempts."
    fi

    test_result_finish "FAIL" "Bluetooth scan did not discover the required device"
fi

# -----------------------------
# 8. Scan OFF via helper + Discovering check
# -----------------------------
log_info "Testing scan OFF..."
if ! bt_set_scan off "$ADAPTER"; then
    # bt_set_scan(off) can be flaky on minimal images; rely on poll helper
    log_warn "bt_set_scan(off) returned non-zero; continuing with scan-off polling."
fi

# Use lib helper to avoid repetitive log spam and handle 'unknown' cleanly.
if bt_scan_poll_off 10 1; then
    # On minimal/ramdisk images bt_scan_poll_off may treat persistent 'unknown' as non-fatal.
    test_result_record "PASS" "Scan OFF cleanup completed"
else
    # If you keep bt_scan_poll_off strict, this may still warn; not a test failure.
    log_warn "Scan OFF cleanup did not confirm Discovering=no (non-fatal)."
fi

test_result_finish
