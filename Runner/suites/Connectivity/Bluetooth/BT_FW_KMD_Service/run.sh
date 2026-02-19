#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause#
# BT_FW_KMD_Service - Bluetooth FW + KMD + service + controller infra validation
# Non-expect version, using lib_bluetooth.sh helpers.

# ---------- init_env + tools ----------
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

TESTNAME="BT_FW_KMD_Service"
testpath="$(find_test_case_by_name "$TESTNAME")" || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}

cd "$testpath" || exit 1
RES_FILE="./${TESTNAME}.res"
rm -f "$RES_FILE"

FAIL_COUNT=0
WARN_COUNT=0

inc_fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); }
inc_warn() { WARN_COUNT=$((WARN_COUNT + 1)); }

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME"

log_info "Checking dependencies: bluetoothctl hciconfig dmesg lsmod"
if ! check_dependencies bluetoothctl hciconfig dmesg lsmod; then
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi
# ---------- Bluetooth service / daemon ----------
log_info "Checking if bluetoothd (or bluetooth.service) is running..."
if btsvcactive; then
    log_pass "Bluetooth service/daemon active."
else
    log_fail "Bluetooth service/daemon NOT active."
    inc_fail
fi

# ---------- DT node / compatible ----------
BT_COMPAT_LIST="
qcom,wcn7850-bt
qcom,wcn6855-bt
qcom,bluetooth
"

if dt_confirm_node_or_compatible_all "BT" "$BT_COMPAT_LIST"; then
    log_pass "DT node/compatible for BT present (at least one entry matched)."
else
    log_fail "DT node/compatible for BT NOT found."
    inc_fail
fi

# ---------- Firmware presence ----------
if fw_dir="$(btfwpresent 2>/dev/null)"; then
    log_pass "Firmware present in: $fw_dir"
else
    log_warn "No BT firmware matching msbtfw*/msnv* found under standard firmware paths."
    inc_warn
fi

# ---------- Firmware load dmesg ----------
if command -v btfwloaded >/dev/null 2>&1; then
    btfwloaded
    rc=$?
    case "$rc" in
        0)
            log_pass "Firmware load/setup appears completed (dmesg)."
            ;;
        2)
            log_warn "Firmware load/setup completed after retry, transient errors seen earlier (dmesg)."
            inc_warn
            ;;
        *)
            log_fail "Firmware load/setup does NOT look clean (see recent Bluetooth/QCA/WCN dmesg lines above)."
            inc_fail
            ;;
    esac
else
    # No SKIP: continue test, just warn.
    log_warn "btfwloaded() helper not available firmware-load dmesg validation not performed."
    inc_warn
fi

# ---------- Kernel modules / KMD ----------
if btkmdpresent; then
    log_pass "Kernel BT driver stack present (bluetooth/hci_uart/btqca or built-in)."
else
    log_fail "Kernel BT driver stack not detected (no bluetooth/hci_uart/btqca in sysfs/dmesg)."
    inc_fail
fi

# ---------- HCI presence ----------
if bthcipresent; then
    log_pass "HCI present in /sys/class/bluetooth."
else
    log_fail "No /sys/class/bluetooth/hci* found (HCI not up)."
    inc_fail
fi

# --- Bluetooth service / daemon check via btsvcactive() ---
if btsvcactive; then
    log_pass "Bluetooth service active (systemd bluetooth.service or bluetoothd)."
else
    log_warn "Bluetooth service is not active (bluetooth.service inactive and bluetoothd not running)."
    inc_warn
fi

# -----------------------------
# Detect adapter (CLI/ENV > auto-detect)
# -----------------------------
if [ -n "$BT_ADAPTER" ]; then
    ADAPTER="$BT_ADAPTER"
    log_info "Using adapter from BT_ADAPTER/CLI: $ADAPTER"
elif findhcisysfs >/dev/null 2>&1; then
    ADAPTER="$(findhcisysfs 2>/dev/null || true)"
else
    ADAPTER=""
fi
 
if [ -z "$ADAPTER" ]; then
    log_warn "No HCI adapter found; skipping BT FW/KMD test."
    echo "$TESTNAME SKIP" > "./$TESTNAME.res"
    exit 0
fi

# ---------- BD address sanity check ----------
if [ -n "$ADAPTER" ]; then
    if btbdok "$ADAPTER"; then
        log_pass "BD address sane for $ADAPTER (not all zeros)."
    else
        log_fail "BD address invalid or all zeros for $ADAPTER."
        inc_fail
    fi
fi

# ---------- Controller visibility (bluetoothctl list + public-addr path) ----------
if [ -n "$ADAPTER" ]; then
    if bt_ensure_controller_visible "$ADAPTER"; then
        # We don't need to log here bt_ensure_controller_visible already logs.
        :
    else
        # For this infra test we treat this as WARN, not FAIL:
        # stack is otherwise OK (firmware, KMD, HCI, BD).
        log_warn "No controller in 'bluetoothctl list' (controller not fully instantiated)."
        inc_warn
    fi
else
    log_warn "Controller visibility not checked (no adapter determined)."
    inc_warn
fi

# ---------- Optional: dump some useful diagnostics ----------
log_info "=== hciconfig -a (if available) ==="
if command -v hciconfig >/dev/null 2>&1; then
    hciconfig -a || true
else
    log_warn "hciconfig command not available."
    inc_warn
fi

log_info "=== bluetoothctl list (controllers) ==="

out="$(bluetoothctl list 2>/dev/null | sanitize_bt_output || true)"
if printf '%s\n' "$out" | grep -qi '^[[:space:]]*Controller[[:space:]]'; then
    # Non-interactive worked print what we got
    printf '%s\n' "$out"
else
    # Non-interactive printed no controllers → retry using interactive method
    log_warn "bluetoothctl list returned no controllers in non-interactive mode, retrying interactive list."

    log_info "=== bluetoothctl list (controllers) ==="
    btctl_script "list" "quit" | sanitize_bt_output || true
fi

log_info "=== lsmod (subset: BT stack) ==="
lsmod 2>/dev/null | grep -E '^(bluetooth|hci_uart|btqca|btbcm|rfkill|cfg80211)\b' || true

# ---------- Final result ----------
log_info "Completed with WARN=${WARN_COUNT}, FAIL=${FAIL_COUNT}"

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "$TESTNAME FAIL" > "$RES_FILE"
else
    echo "$TESTNAME PASS" > "$RES_FILE"
fi

exit 0
