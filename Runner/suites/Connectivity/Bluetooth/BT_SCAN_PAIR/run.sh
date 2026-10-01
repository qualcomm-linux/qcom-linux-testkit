#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
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

test_path=$(find_test_case_by_name "BT_SCAN_PAIR") || {
    log_fail "BT_SCAN_PAIR FAIL - test directory not found"
    printf '%s\n' "BT_SCAN_PAIR FAIL" >./BT_SCAN_PAIR.res
    exit 1
}

if ! cd "$test_path"; then
    log_fail "BT_SCAN_PAIR FAIL - failed to enter test directory $test_path"
    printf '%s\n' "BT_SCAN_PAIR FAIL" >./BT_SCAN_PAIR.res
    exit 1
fi

TESTNAME="BT_SCAN_PAIR"
RES_FILE="./$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME Testcase"

# Defaults
PAIR_RETRIES="${PAIR_RETRIES:-3}"
BT_RUNTIME_READY_WAIT="${BT_RUNTIME_READY_WAIT:-20}"
BT_RUNTIME_RECOVERY_WAIT="${BT_RUNTIME_RECOVERY_WAIT:-40}"
BT_RUNTIME_RECOVERY_ATTEMPTS="${BT_RUNTIME_RECOVERY_ATTEMPTS:-2}"
BT_ADAPTER="${BT_ADAPTER:-}"

BT_ENV_MAC="${BT_MAC_ENV:-${BT_MAC:-}}"
BT_NAME="${BT_NAME_ENV:-}"
BT_MAC=""
WHITELIST="${BT_WHITELIST_ENV:-}"

usage() {
    cat <<EOF_USAGE
Usage: $0 [TARGET] [WHITELIST]
       $0 [--adapter HCI_ADAPTER] [--target TARGET] [--whitelist FILTER]

TARGET may be a Bluetooth MAC address or device name.
EOF_USAGE
}

set_pair_target() {
    pair_target="$1"

    if printf '%s\n' "$pair_target" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
        BT_MAC="$pair_target"
    else
        BT_NAME="$pair_target"
    fi
}

parse_args() {
    positional_count=0

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --adapter|--target|--whitelist)
                if [ "$#" -lt 2 ]; then
                    log_error "$1 requires a value"
                    usage >&2
                    return 2
                fi

                case "$1" in
                    --adapter)
                        BT_ADAPTER="$2"
                        ;;
                    --target)
                        set_pair_target "$2"
                        ;;
                    --whitelist)
                        WHITELIST="$2"
                        ;;
                esac
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --*)
                log_error "Unknown argument: $1"
                usage >&2
                return 2
                ;;
            *)
                positional_count=$((positional_count + 1))
                case "$positional_count" in
                    1)
                        set_pair_target "$1"
                        ;;
                    2)
                        WHITELIST="$1"
                        ;;
                    *)
                        log_error "Too many positional arguments"
                        usage >&2
                        return 2
                        ;;
                esac
                shift
                ;;
        esac
    done
}

parse_args "$@" || exit $?

for positive_value in \
    "$PAIR_RETRIES" \
    "$BT_RUNTIME_READY_WAIT" \
    "$BT_RUNTIME_RECOVERY_WAIT" \
    "$BT_RUNTIME_RECOVERY_ATTEMPTS"
do
    if ! is_unsigned_number "$positive_value" || [ "$positive_value" -eq 0 ]; then
        log_error "Bluetooth pairing retry counts and wait values must be positive integers"
        exit 2
    fi
done

# If BT_MAC not set by CLI, fall back to BT_ENV_MAC (LAVA export)
if [ -z "$BT_MAC" ] && [ -z "$BT_NAME" ] && [ -n "$BT_ENV_MAC" ] && \
   printf '%s\n' "$BT_ENV_MAC" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
    BT_MAC="$BT_ENV_MAC"
fi

# Optionally: if BT_MAC still empty and whitelist itself is a MAC, treat it as BT_MAC
if [ -z "$BT_MAC" ] && [ -z "$BT_NAME" ] && [ -n "$WHITELIST" ] && \
   printf '%s\n' "$WHITELIST" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'; then
    BT_MAC="$WHITELIST"
fi

if [ -n "$BT_MAC" ]; then
    log_info "Effective BT_MAC resolved to: $BT_MAC"
fi

# Skip if no MAC/name and no list file
if [ -z "$BT_MAC" ] && [ -z "$BT_NAME" ] && [ ! -f "./bt_device_list.txt" ]; then
    test_result_finish "SKIP" "No Bluetooth target and no bt_device_list.txt were provided"
fi

if ! bt_prepare_bluetooth_stack; then
    test_result_finish "FAIL" "$TESTNAME FAIL - Bluetooth stack preparation failed"
fi

if ! check_dependencies \
    bluetoothctl \
    rfkill \
    expect \
    l2ping; then
    test_result_finish "SKIP" "$TESTNAME SKIP - required Bluetooth tools are unavailable"
fi

if ! command -v hciconfig >/dev/null 2>&1; then
    log_info "Optional hciconfig command is unavailable, using sysfs and bluetoothctl for adapter discovery"
fi

log_info "Ensuring Bluetooth runtime readiness before pairing"
if ! bt_ensure_runtime_ready \
    "${BT_ADAPTER:-}" \
    "$BT_RUNTIME_READY_WAIT" \
    "$BT_RUNTIME_RECOVERY_WAIT" \
    "$BT_RUNTIME_RECOVERY_ATTEMPTS"; then
    test_result_finish \
        "FAIL" \
        "${BT_RUNTIME_FAILURE_REASON:-Bluetooth runtime remained unusable after bounded recovery attempts}"
fi

BT_ADAPTER="$BT_RUNTIME_READY_ADAPTER"
test_result_record "PASS" "Bluetooth runtime is ready with usable adapter $BT_ADAPTER"

# shellcheck disable=SC2317  # cleanup is invoked via trap
cleanup_bt_test() {
    # Cleanup only the primary MAC we worked with (if any)
    [ -n "$BT_MAC" ] && bt_cleanup_paired_device "$BT_MAC"
    killall -q bluetoothctl 2>/dev/null || true
}
trap cleanup_bt_test EXIT

# RF-kill unblock (best effort)
rfkill unblock bluetooth 2>/dev/null || true

# Detect adapter (no hardcoded hci0)
if [ -z "$BT_ADAPTER" ]; then
    if command -v bt_select_usable_adapter >/dev/null 2>&1; then
        BT_ADAPTER="$(bt_select_usable_adapter 2>/dev/null || true)"
    else
        BT_ADAPTER="$(listhcis | head -n1)"
    fi
fi

if [ -z "$BT_ADAPTER" ]; then
    test_result_finish "FAIL" "No usable Bluetooth HCI adapter was found after runtime recovery"
fi

log_info "Detected Bluetooth adapter: $BT_ADAPTER"

# Ensure controller is visible to bluetoothctl (public-addr bootstrap)
if bt_ensure_controller_visible "$BT_ADAPTER"; then
    test_result_record "PASS" "Bluetooth controller is visible to bluetoothctl"
else
    test_result_finish "FAIL" "Bluetooth controller is not visible to bluetoothctl after runtime recovery"
fi

# Power on adapter via the existing helper regardless of hciconfig state.
if ! btpower "$BT_ADAPTER" on; then
    test_result_finish "FAIL" "Failed to power on adapter $BT_ADAPTER"
fi

test_result_record "PASS" "Bluetooth adapter $BT_ADAPTER is powered on"

# Optional debug: show BD address and confirm firmware/driver presence
bdaddr="$(btgetbdaddr "$BT_ADAPTER" 2>/dev/null || true)"
[ -n "$bdaddr" ] && log_info "Adapter $BT_ADAPTER BD_ADDR=$bdaddr"

if ! btkmdpresent; then
    log_warn "Bluetooth kernel modules / driver not clearly present (btkmdpresent failed)."
fi

if ! btfwpresent >/dev/null 2>&1; then
    log_warn "No obvious Bluetooth firmware files found with btfwpresent, continuing anyway."
fi

# Remove any previously paired devices to start clean
bt_remove_all_paired_devices

# Helper: l2ping link verification
verify_link() {
    mac="$1"
    if bt_l2ping_check "$mac" "./l2ping.log"; then
        test_result_record "PASS" "l2ping link check succeeded for $mac"
        test_result_finish
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
            log_info "Pair succeeded, attempting post-pair connect to $BT_MAC"
            if bt_post_pair_connect "$BT_MAC"; then
                log_pass "Post-pair connect succeeded for $BT_MAC"
                verify_link "$BT_MAC"
            else
                log_warn "Post-pair connect failed, trying l2ping fallback for $BT_MAC"
                verify_link "$BT_MAC"
                bt_cleanup_paired_device "$BT_MAC"
            fi
        else
            log_warn "Pair failed for $BT_MAC (attempt $attempt)"
        fi
    done

    log_warn "Exhausted direct pairing attempts for $BT_MAC"
    test_result_finish "FAIL" "Direct pairing failed for ${BT_MAC:-$BT_NAME}"
fi

# -------------------------
# Fallback list-based flow
# -------------------------
if [ -z "$BT_MAC" ] && [ -z "$BT_NAME" ] && [ -f "./bt_device_list.txt" ]; then
    # Skip if list is empty or only comments
    if ! grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' bt_device_list.txt | grep -q .; then
        test_result_finish "SKIP" "bt_device_list.txt is empty or contains only comments"
    fi

    log_info "Using fallback device list in bt_device_list.txt"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*)
                continue
                ;;
        esac

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
                log_info "Pair succeeded, attempting post-pair connect to $BT_MAC"
                if bt_post_pair_connect "$BT_MAC"; then
                    log_pass "Post-pair connect succeeded for $BT_MAC"
                    verify_link "$BT_MAC"
                else
                    log_warn "Post-pair connect failed, trying l2ping fallback for $BT_MAC"
                    verify_link "$BT_MAC"
                fi
            else
                log_warn "Pair failed for $BT_MAC (attempt $attempt)"
            fi
            bt_cleanup_paired_device "$BT_MAC"
        done

        log_warn "Exhausted $PAIR_RETRIES attempts for $BT_MAC, moving to the next entry"
    done < "./bt_device_list.txt"

    test_result_finish "FAIL" "All fallback devices from bt_device_list.txt failed"
fi

# Should never reach here
test_result_finish "FAIL" "No Bluetooth pairing execution path matched"
