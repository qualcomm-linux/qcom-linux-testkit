#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_bluetooth.sh"

TESTNAME="BT_SCAN_PAIR"
test_path=$(find_test_case_by_name "$TESTNAME") || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 0
}

if ! cd "$test_path"; then
    log_fail "$TESTNAME : Failed to cd into test directory: $test_path"
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 0
fi

RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"

# Capture BT_MAC from environment (LAVA secret) *before* we touch BT_MAC locally
BT_ENV_MAC=""
if [ -n "${BT_MAC:-}" ]; then
    BT_ENV_MAC="$BT_MAC"
fi

# Defaults
PAIR_RETRIES="${PAIR_RETRIES:-3}"

BT_NAME=""
BT_MAC=""
WHITELIST=""

# -------------------------
# CLI parsing
# -------------------------
if [ -n "$1" ]; then
    if echo "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        # CLI MAC has highest priority
        BT_MAC="$1"
    else
        BT_NAME="$1"
    fi
fi

if [ -n "$2" ]; then
    WHITELIST="$2"
fi

# If BT_MAC not set by CLI, fall back to BT_ENV_MAC (LAVA export)
if [ -z "$BT_MAC" ] && [ -n "$BT_ENV_MAC" ] && \
   echo "$BT_ENV_MAC" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
    BT_MAC="$BT_ENV_MAC"
fi

# Optionally: if BT_MAC still empty and whitelist itself is a MAC, treat it as BT_MAC
if [ -z "$BT_MAC" ] && [ -n "$WHITELIST" ] && \
   echo "$WHITELIST" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
    BT_MAC="$WHITELIST"
fi

if [ -n "$BT_MAC" ]; then
    log_info "Effective BT_MAC resolved to: $BT_MAC"
fi

# Skip if no MAC/name and no list file
if [ -z "$BT_MAC" ] && [ -z "$BT_NAME" ] && [ ! -f "./bt_device_list.txt" ]; then
    log_warn "No BT_MAC/BT_NAME and no bt_device_list.txt found. Skipping test."
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

check_dependencies bluetoothctl rfkill expect hciconfig || {
    log_warn "Missing required tools; skipping $TESTNAME."
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
}

cleanup_bt_test() {
    # Cleanup only the primary MAC we worked with (if any)
    [ -n "$BT_MAC" ] && bt_cleanup_paired_device "$BT_MAC"
    killall -q bluetoothctl 2>/dev/null || true
}
trap cleanup_bt_test EXIT

# RF-kill unblock (best effort)
rfkill unblock bluetooth 2>/dev/null || true

# Detect adapter (no hardcoded hci0)
BT_ADAPTER="${BT_ADAPTER:-}"
if [ -z "$BT_ADAPTER" ]; then
    BT_ADAPTER="$(listhcis | head -n1)"
fi

if [ -z "$BT_ADAPTER" ]; then
    log_fail "No Bluetooth HCI adapter found under /sys/class/bluetooth; cannot run $TESTNAME."
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

log_info "Detected Bluetooth adapter: $BT_ADAPTER"

# Ensure controller is visible to bluetoothctl (public-addr bootstrap)
if bt_ensure_controller_visible "$BT_ADAPTER"; then
    log_info "Bluetooth controller is visible to bluetoothctl after bt_ensure_controller_visible."
else
    log_fail "Bluetooth controller is not visible to bluetoothctl after bt_ensure_controller_visible."
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

# Power on adapter via existing helper; do this regardless of HCICONFIG state.
if ! btpower "$BT_ADAPTER" on; then
    log_fail "Failed to power on adapter $BT_ADAPTER via btpower (RF-kill/firmware issue?)."
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

# Optional debug: show BD address and confirm firmware/driver presence
bdaddr="$(btgetbdaddr "$BT_ADAPTER" 2>/dev/null || true)"
[ -n "$bdaddr" ] && log_info "Adapter $BT_ADAPTER BD_ADDR=$bdaddr"

if ! btkmdpresent; then
    log_warn "Bluetooth kernel modules / driver not clearly present (btkmdpresent failed)."
fi

if ! btfwpresent >/dev/null 2>&1; then
    log_warn "No obvious Bluetooth firmware files found (btfwpresent); continuing anyway."
fi

# Remove any previously paired devices to start clean
bt_remove_all_paired_devices

# Helper: l2ping link verification
verify_link() {
    mac="$1"
    if bt_l2ping_check "$mac" "$RES_FILE"; then
        log_pass "l2ping link check succeeded for $mac"
        echo "$TESTNAME PASS" > "$RES_FILE"
        exit 0
    else
        log_warn "l2ping link check failed for $mac"
    fi
}

# -------------------------
# Direct pairing path (BT_MAC known)
# -------------------------
if [ -n "$BT_MAC" ]; then
    log_info "Direct pairing requested for BT_MAC=$BT_MAC (BT_NAME='$BT_NAME')"
    sleep 2
    for attempt in $(seq 1 "$PAIR_RETRIES"); do
        log_info "Pair attempt $attempt/$PAIR_RETRIES for $BT_MAC"
        bt_cleanup_paired_device "$BT_MAC"

        if bt_pair_with_mac "$BT_MAC"; then
            log_info "Pair succeeded; attempting post-pair connect to $BT_MAC"
            if bt_post_pair_connect "$BT_MAC"; then
                log_pass "Post-pair connect succeeded for $BT_MAC"
                verify_link "$BT_MAC"
            else
                log_warn "Post-pair connect failed; trying l2ping fallback for $BT_MAC"
                verify_link "$BT_MAC"
                bt_cleanup_paired_device "$BT_MAC"
            fi
        else
            log_warn "Pair failed for $BT_MAC (attempt $attempt)"
        fi
    done

    log_warn "Exhausted direct pairing attempts for $BT_MAC"
    log_fail "Direct pairing failed for ${BT_MAC:-$BT_NAME}"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

# -------------------------
# Fallback list-based flow
# -------------------------
if [ -z "$BT_MAC" ] && [ -z "$BT_NAME" ] && [ -f "./bt_device_list.txt" ]; then
    # Skip if list is empty or only comments
    if ! grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' bt_device_list.txt | grep -q .; then
        log_warn "bt_device_list.txt is empty or only comments. Skipping test."
        echo "$TESTNAME SKIP" > "$RES_FILE"
        exit 0
    fi

    log_info "Using fallback device list in bt_device_list.txt"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac

        # split into MAC and NAME (simple space-separated)
        IFS=' ' read -r MAC NAME <<EOF
$line
EOF
        [ -z "$MAC" ] && continue

        # Whitelist filter (name-based simple match)
        if [ -n "$WHITELIST" ] && ! printf '%s' "$NAME" | grep -iq "$WHITELIST"; then
            log_info "Skipping $MAC ($NAME): not in whitelist '$WHITELIST'"
            continue
        fi

        BT_MAC="$MAC"
        BT_NAME="$NAME"

        log_info "===== Attempting $BT_MAC ($BT_NAME) from device list ====="
        bt_cleanup_paired_device "$BT_MAC"

        for attempt in $(seq 1 "$PAIR_RETRIES"); do
            log_info "Pair attempt $attempt/$PAIR_RETRIES for $BT_MAC"
            if bt_pair_with_mac "$BT_MAC"; then
                log_info "Pair succeeded; attempting post-pair connect to $BT_MAC"
                if bt_post_pair_connect "$BT_MAC"; then
                    log_pass "Post-pair connect succeeded for $BT_MAC"
                    verify_link "$BT_MAC"
                else
                    log_warn "Post-pair connect failed; trying l2ping fallback for $BT_MAC"
                    verify_link "$BT_MAC"
                fi
            else
                log_warn "Pair failed for $BT_MAC (attempt $attempt)"
            fi
            bt_cleanup_paired_device "$BT_MAC"
        done

        log_warn "Exhausted $PAIR_RETRIES attempts for $BT_MAC; moving to next entry"
    done < "./bt_device_list.txt"

    log_fail "All fallback devices from bt_device_list.txt failed"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 0
fi

# Should never reach here
log_fail "No execution path matched; exiting with FAIL."
echo "$TESTNAME FAIL" > "$RES_FILE"
exit 0
