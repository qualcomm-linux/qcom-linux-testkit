#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# BT_FW_KMD_Service - Bluetooth FW + KMD + service + controller infra validation
# Non-expect version, using lib_bluetooth.sh helpers.

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
BT_RUNTIME_READY_WAIT="${BT_RUNTIME_READY_WAIT:-20}"
BT_RUNTIME_RECOVERY_WAIT="${BT_RUNTIME_RECOVERY_WAIT:-40}"
BT_RUNTIME_RECOVERY_ATTEMPTS="${BT_RUNTIME_RECOVERY_ATTEMPTS:-2}"

usage() {
    cat <<EOF_USAGE
Usage: $0 [--adapter HCI_ADAPTER]

Environment:
  BT_RUNTIME_READY_WAIT     Initial usable-controller wait, default: 20
  BT_RUNTIME_RECOVERY_WAIT  Wait after one recovery attempt, default: 40
  BT_RUNTIME_RECOVERY_ATTEMPTS Recovery attempts after initial wait, default: 2
  BT_CONTROLLER_VISIBLE_WAIT Controller visibility wait budget, default: 15
EOF_USAGE
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --adapter)
                if [ "$#" -lt 2 ]; then
                    log_error "--adapter requires an HCI adapter"
                    usage >&2
                    return 2
                fi

                BT_ADAPTER="$2"
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

for wait_value in \
    "$BT_RUNTIME_READY_WAIT" \
    "$BT_RUNTIME_RECOVERY_WAIT" \
    "$BT_RUNTIME_RECOVERY_ATTEMPTS"
do
    if ! is_unsigned_number "$wait_value" || [ "$wait_value" -eq 0 ]; then
        log_error "Bluetooth runtime wait values must be positive integers"
        exit 2
    fi
done

testpath="$(find_test_case_by_name "BT_FW_KMD_Service")" || {
    log_fail "BT_FW_KMD_Service FAIL - test directory not found"
    printf '%s\n' "BT_FW_KMD_Service FAIL" >"./BT_FW_KMD_Service.res"
    exit 1
}

cd "$testpath" || exit 1
TESTNAME="BT_FW_KMD_Service"
RES_FILE="./${TESTNAME}.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

WARN_COUNT=0

log_info "------------------------------------------------------------"
log_info "Starting $TESTNAME"

if ! bt_prepare_bluetooth_stack; then
    test_result_finish "FAIL" "$TESTNAME FAIL - Bluetooth stack preparation failed"
fi

log_info "Checking dependencies: bluetoothctl lsmod"
if ! check_dependencies bluetoothctl lsmod; then
    test_result_finish "SKIP" "$TESTNAME SKIP - required Bluetooth tools are unavailable"
fi

if ! command -v hciconfig >/dev/null 2>&1; then
    log_info "Optional hciconfig command is unavailable, using sysfs and bluetoothctl diagnostics"
fi

# ---------- Bluetooth runtime check/ readiness ----------
log_info "Waiting up to ${BT_RUNTIME_READY_WAIT}s for a usable Bluetooth runtime"
if bt_ensure_runtime_ready \
    "$BT_ADAPTER" \
    "$BT_RUNTIME_READY_WAIT" \
    "$BT_RUNTIME_RECOVERY_WAIT" \
    "$BT_RUNTIME_RECOVERY_ATTEMPTS"; then
    if [ "$BT_RUNTIME_RECOVERED" -eq 1 ]; then
        WARN_COUNT=$((WARN_COUNT + 1))
        test_result_record "PASS" "Bluetooth runtime recovered with a valid HCI adapter"
    else
        test_result_record "PASS" "Bluetooth runtime exposed an HCI adapter with a valid BD address"
    fi
else
    test_result_record \
        "FAIL" \
        "${BT_RUNTIME_FAILURE_REASON:-Bluetooth runtime remained unusable after bounded recovery attempts}"
fi

ADAPTER="$BT_RUNTIME_READY_ADAPTER"

# ---------- Bluetooth service / daemon ----------
log_info "Checking if bluetoothd (or bluetooth.service) is running..."
if btsvcactive; then
    test_result_record "PASS" "Bluetooth service/daemon active"
else
    test_result_record "FAIL" "Bluetooth service/daemon is not active"
fi

# ---------- DT node / compatible ----------
# M.2 E-key Bluetooth devices can be instantiated dynamically by pwrseq-pcie-m2,
# so absence of a static qcom,wcn*-bt node is not a functional failure. Keep DT
# discovery as topology evidence and let the runtime checks below own the verdict.
if dt_confirm_node_or_compatible_all \
    "qcom,wcn3950-bt" \
    "qcom,wcn7850-bt" \
    "qcom,wcn6855-bt" \
    "qcom,wcn6750-bt" \
    "qcom,bluetooth" \
    "pcie-m2-e-connector"
then
    test_result_record "PASS" "DT node/compatible for BT or an M.2 E-key connector is present"
else
    dt_runtime_adapter="$ADAPTER"
    if [ -z "$dt_runtime_adapter" ] && \
       command -v bt_select_usable_adapter >/dev/null 2>&1; then
        dt_runtime_adapter="$(bt_select_usable_adapter 2>/dev/null || true)"
    fi

    if [ -n "$dt_runtime_adapter" ] && bt_adapter_is_usable "$dt_runtime_adapter"; then
        log_warn "No static BT DT node or M.2 E-key connector found, operational HCI adapter $dt_runtime_adapter confirms runtime Bluetooth availability (GH#533)."
    else
        log_warn "No static BT DT node or M.2 E-key connector found, deferring the verdict to the authoritative KMD, HCI, service, firmware, and controller checks below (GH#533)."
    fi
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# ---------- Firmware presence ----------
if fw_dir="$(btfwpresent 2>/dev/null)"; then
    test_result_record "PASS" "Firmware present in: $fw_dir"
else
    log_warn "No supported Qualcomm Bluetooth firmware or NVM file found under standard firmware paths"
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# -----------------------------
# Adapter should already be detected before firmware-load validation.
# Keep this fallback for safety.
# -----------------------------
if [ -z "$ADAPTER" ]; then
    if [ -n "$BT_ADAPTER" ]; then
        ADAPTER="$BT_ADAPTER"
        log_info "Using adapter from BT_ADAPTER/CLI: $ADAPTER"
    elif findhcisysfs >/dev/null 2>&1; then
        ADAPTER="$(findhcisysfs 2>/dev/null || true)"
    else
        ADAPTER=""
    fi
 
    if [ -n "$ADAPTER" ]; then
        if [ -n "$BT_ADAPTER" ]; then
            bt_log_selected_adapter "$ADAPTER" "BT_ADAPTER/CLI"
        else
            bt_log_selected_adapter "$ADAPTER" "auto-detect"
        fi
    fi
fi

# ---------- Firmware load kernel log ----------
if command -v btfwloaded >/dev/null 2>&1; then
    btfwloaded "$ADAPTER"
    rc=$?
    case "$rc" in
        0)
            test_result_record "PASS" "Firmware load/setup appears completed in the kernel log"
            ;;
        2)
            log_warn "Firmware load/setup completed after retry, transient errors seen earlier (kernel log)."
            WARN_COUNT=$((WARN_COUNT + 1))
            test_result_record "PASS" "Firmware load/setup completed after a transient retry"
            ;;
        *)
            runtime_bt_ok=1
            fallback_adapter="$ADAPTER"

            if [ -z "$fallback_adapter" ] && findhcisysfs >/dev/null 2>&1; then
                fallback_adapter="$(findhcisysfs 2>/dev/null || true)"
            fi

            if ! btkmdpresent; then
                runtime_bt_ok=0
            fi
            if ! bthcipresent; then
                runtime_bt_ok=0
            fi
            if ! btsvcactive; then
                runtime_bt_ok=0
            fi
            if [ -n "$fallback_adapter" ]; then
                if ! btbdok "$fallback_adapter"; then
                    runtime_bt_ok=0
                fi
            fi

            if [ "$runtime_bt_ok" -eq 1 ]; then
                log_warn "No retained BT firmware-load signature found, but BT runtime state is healthy."
                WARN_COUNT=$((WARN_COUNT + 1))
            else
                test_result_record \
                    "FAIL" \
                    "Firmware load/setup is incomplete and Bluetooth runtime is unhealthy, verify the image firmware package and reboot after provisioning new firmware"
            fi
            ;;
    esac
else
    # No SKIP: continue test, just warn.
    log_warn "btfwloaded() helper not available, firmware-load kernel-log validation not performed."
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# ---------- Kernel modules / KMD ----------
if btkmdpresent; then
    test_result_record "PASS" "Kernel BT driver stack is present"
else
    test_result_record "FAIL" "Kernel BT driver stack was not detected"
fi

# ---------- HCI presence ----------
if bthcipresent; then
    test_result_record "PASS" "HCI is present in /sys/class/bluetooth"
else
    test_result_record "FAIL" "No HCI adapter was found in /sys/class/bluetooth"
fi

# --- Bluetooth service / daemon check via btsvcactive() ---
if btsvcactive; then
    test_result_record "PASS" "Bluetooth service remains active"
else
    log_warn "Bluetooth service is not active (bluetooth.service inactive and bluetoothd not running)."
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# -----------------------------
# Detect adapter (CLI/ENV > auto-detect)
# -----------------------------
if [ -z "$ADAPTER" ]; then
    if [ -n "$BT_ADAPTER" ]; then
        ADAPTER="$BT_ADAPTER"
        log_info "Using adapter from BT_ADAPTER/CLI: $ADAPTER"
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

if [ -z "$ADAPTER" ]; then
    log_warn "No HCI adapter found."

    if [ "$TEST_RESULT_FAIL_COUNT" -gt 0 ]; then
        test_result_finish
    else
        test_result_finish "SKIP" "$TESTNAME SKIP - no HCI adapter was found"
    fi
fi
# ---------- BD address sanity check ----------
if [ -n "$ADAPTER" ]; then
    if btbdok "$ADAPTER"; then
        test_result_record "PASS" "BD address is valid for $ADAPTER"
    else
        test_result_record \
            "FAIL" \
            "BD address is invalid or all zeros for $ADAPTER, verify Qualcomm firmware and platform BD-address provisioning"
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
        WARN_COUNT=$((WARN_COUNT + 1))
    fi
else
    log_warn "Controller visibility not checked (no adapter determined)."
    WARN_COUNT=$((WARN_COUNT + 1))
fi

# ---------- Optional: dump some useful diagnostics ----------
log_info "=== hciconfig -a (if available) ==="
if command -v hciconfig >/dev/null 2>&1; then
    hciconfig -a || true
else
    log_info "Optional hciconfig command is unavailable"
fi

log_info "=== bluetoothctl list (controllers) ==="

out="$(
    run_with_timeout 3 bluetoothctl list 2>/dev/null \
        | sanitize_bt_output || true
)"
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
log_info "Completed with WARN=${WARN_COUNT}, FAIL=${TEST_RESULT_FAIL_COUNT}"
test_result_finish
