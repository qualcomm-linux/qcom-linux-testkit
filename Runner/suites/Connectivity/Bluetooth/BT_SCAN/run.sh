#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause# BT_SCAN – Bluetooth scanning validation (non-expect version)
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
BT_ADAPTER="${BT_ADAPTER-}"
BT_SCAN_TARGET_MAC="${BT_SCAN_TARGET_MAC-}"
BT_TARGET_MAC="${BT_TARGET_MAC-}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --adapter)
            BT_ADAPTER="$2"
            shift 2
            ;;
        --target-mac)
            BT_TARGET_MAC="$2"
            shift 2
            ;;
        *)
            log_warn "Unknown argument ignored: $1"
            shift 1
            ;;
    esac
done

TESTNAME="BT_SCAN"
testpath="$(find_test_case_by_name "$TESTNAME")" || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 0
}

cd "$testpath" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"
log_info "Checking dependency: bluetoothctl"

check_dependencies bluetoothctl pgrep

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
    log_fail "bluetoothd not detected after $MAX_RETRIES attempts."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

# -----------------------------
# 2. Detect adapter (CLI/ENV > auto-detect)
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
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# -----------------------------
# 3. Ensure controller is visible
# -----------------------------
if ! bt_ensure_controller_visible "$ADAPTER"; then
    log_warn "SKIP — controller not visible to bluetoothctl."
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

# -----------------------------
# 4. Ensure power is ON
# -----------------------------
pw="$(btgetpower "$ADAPTER" 2>/dev/null || true)"
if [ "$pw" = "yes" ]; then
    log_pass "Power ON verified before scan."
else
    log_info "Controller Power=$pw — enabling now..."
    if ! btpower "$ADAPTER" on; then
        log_fail "Failed to power ON controller."
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0
    fi
    log_pass "Power ON successful."
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
# 6. Scan ON via helper
# -----------------------------
log_info "Testing scan ON..."
if ! bt_set_scan on "$ADAPTER"; then
    log_warn "bt_set_scan(on) returned non-zero will still inspect devices list."
fi

# Optional: single Discovering snapshot after scan-on window
dstate_on="$(bt_get_discovering 2>/dev/null || true)"
[ -z "$dstate_on" ] && dstate_on="unknown"
log_info "Discovering state after scan ON window: $dstate_on"

# -----------------------------
# 7. Get devices list after scan ON
# -----------------------------
devices_out="$(
    bluetoothctl devices 2>/dev/null \
        | sanitize_bt_output
)"

if [ -n "$TARGET_MAC" ]; then
    mac_up=$(printf '%s\n' "$TARGET_MAC" | tr '[:lower:]' '[:upper:]')
    if printf '%s\n' "$devices_out" \
        | awk '/^Device /{print toupper($2)}' \
        | grep -q "$mac_up"
    then
        log_pass "Target MAC $TARGET_MAC detected."
    else
        log_fail "Target MAC $TARGET_MAC missing after scan ON window."
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0
    fi
else
    if [ -n "$devices_out" ]; then
        log_info "Devices seen by bluetoothctl after scan ON:"
        printf '%s\n' "$devices_out" | while IFS= read -r line; do
            [ -n "$line" ] && log_info " $line"
        done
        log_pass "At least one device discovered."
    else
        log_fail "No devices discovered in bluetoothctl devices after scan ON."
        echo "$TESTNAME FAIL" > "$res_file"
        exit 0
    fi
fi

# -----------------------------
# 8. Scan OFF via helper + Discovering check
# -----------------------------
log_info "Testing scan OFF..."
if ! bt_set_scan off "$ADAPTER"; then
    log_warn "bt_set_scan(off) returned non-zero continuing with Discovering check."
fi

SCAN_OFF_OK=0
ITER=10
i=1
while [ "$i" -le "$ITER" ]; do
    dstate_off="$(bt_get_discovering 2>/dev/null || true)"
    [ -z "$dstate_off" ] && dstate_off="unknown"

    log_info "Discovering state during scan OFF wait (iteration $i/$ITER): $dstate_off"

    if [ "$dstate_off" = "no" ]; then
        SCAN_OFF_OK=1
        break
    fi

    sleep 2
    i=$((i + 1))
done

if [ "$SCAN_OFF_OK" -eq 1 ]; then
    log_pass "Discovering=no observed after scan OFF polling."
else
    log_warn "Discovering did not transition to 'no' after scan OFF window."
fi

echo "$TESTNAME PASS" > "$res_file"
exit 0
