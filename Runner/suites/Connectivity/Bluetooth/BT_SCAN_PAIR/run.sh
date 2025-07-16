#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

TESTNAME="BT_SCAN_PAIR"
test_path=$(find_test_case_by_name "$TESTNAME") || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}
cd "$test_path" || exit 1
RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"

# Defaults
PAIR_RETRIES="${PAIR_RETRIES:-3}"
SCAN_ATTEMPTS="${SCAN_ATTEMPTS:-2}"

BT_NAME=""
BT_MAC=""
WHITELIST=""

# Parse CLI args
if [ -n "$1" ]; then
    if echo "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        BT_MAC="$1"
    else
        BT_NAME="$1"
    fi
fi
if [ -n "$2" ]; then
    WHITELIST="$2"
    if [ -z "$BT_MAC" ] && echo "$2" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        BT_MAC="$2"
    fi
fi

# Skip if no CLI input and no list file
if [ -z "$BT_MAC" ] && [ -z "$BT_NAME" ] && [ ! -f "./bt_device_list.txt" ]; then
    log_warn "No MAC/name or bt_device_list.txt found. Skipping test."
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

check_dependencies bluetoothctl rfkill expect hciconfig || {
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
}

cleanup_bt_test() {
    [ -n "$BT_MAC" ] && bt_cleanup_paired_device "$BT_MAC"
    killall -q bluetoothctl 2>/dev/null
}
trap cleanup_bt_test EXIT

rfkill unblock bluetooth
retry_command_bt "hciconfig hci0 up" "Bring up hci0" || {
    log_fail "Failed to bring up hci0"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
}

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

# Direct pairing if CLI MAC provided
if [ -n "$BT_MAC" ]; then
    log_info "Direct pairing requested for $BT_MAC"
    sleep 2
    for attempt in $(seq 1 "$PAIR_RETRIES"); do
        log_info "Pair attempt $attempt/$PAIR_RETRIES for $BT_MAC"
        if bt_pair_with_mac "$BT_MAC"; then
            log_info "Pair succeeded; connecting to $BT_MAC"
            if bt_post_pair_connect "$BT_MAC"; then
                log_pass "Post-pair connect succeeded for $BT_MAC"
                verify_link "$BT_MAC"
            else
                log_warn "Connect failed; trying l2ping fallback for $BT_MAC"
                verify_link "$BT_MAC"
                bt_cleanup_paired_device "$BT_MAC"
            fi
        else
            log_warn "Pair failed for $BT_MAC (attempt $attempt)"
            bt_cleanup_paired_device "$BT_MAC"
        fi
    done
    log_warn "Exhausted direct pairing attempts for $BT_MAC"
    # If CLI arg was provided, do not fallback on empty .txt
    if [ -n "$BT_NAME" ] || [ -n "$BT_MAC" ]; then
        log_fail "Direct pairing failed for ${BT_MAC:-$BT_NAME}"
        echo "$TESTNAME FAIL" > "$RES_FILE"
        exit 1
    fi
fi

# Fallback: only if no CLI input and list exists
if [ -z "$BT_MAC" ] && [ -z "$BT_NAME" ] && [ -f "./bt_device_list.txt" ]; then
    # Skip if list is empty or only comments
    if ! grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' bt_device_list.txt | grep -q .; then
        log_warn "bt_device_list.txt is empty or only comments. Skipping test."
        echo "$TESTNAME SKIP" > "$RES_FILE"
        exit 0
    fi

    log_info "Using fallback list in bt_device_list.txt"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|\#*) continue ;; esac
        # split into MAC and NAME
        IFS=' ' read -r MAC NAME <<EOF
$line
EOF
        [ -z "$MAC" ] && continue

        # Whitelist filter
        if [ -n "$WHITELIST" ] && ! printf '%s' "$NAME" | grep -iq "$WHITELIST"; then
            log_info "Skipping $MAC ($NAME): not in whitelist '$WHITELIST'"
            continue
        fi

        BT_MAC=$MAC
        BT_NAME=$NAME

        log_info "===== Attempting $BT_MAC ($BT_NAME) ====="
        bt_cleanup_paired_device "$BT_MAC"

        for attempt in $(seq 1 "$PAIR_RETRIES"); do
            log_info "Pair attempt $attempt/$PAIR_RETRIES for $BT_MAC"
            if bt_pair_with_mac "$BT_MAC"; then
                log_info "Pair succeeded; connecting to $BT_MAC"
                if bt_post_pair_connect "$BT_MAC"; then
                    log_pass "Post-pair connect succeeded for $BT_MAC"
                    verify_link "$BT_MAC"
                else
                    log_warn "Connect failed; trying l2ping fallback for $BT_MAC"
                    verify_link "$BT_MAC"
                fi
            else
                log_warn "Pair failed for $BT_MAC (attempt $attempt)"
            fi
            bt_cleanup_paired_device "$BT_MAC"
        done

        log_warn "Exhausted $PAIR_RETRIES attempts for $BT_MAC; moving to next"
    done < "./bt_device_list.txt"

    log_fail "All fallback devices failed"
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi

# Should never reach here
log_fail "No execution path matched; exiting"
echo "$TESTNAME FAIL" > "$RES_FILE"
exit 1
