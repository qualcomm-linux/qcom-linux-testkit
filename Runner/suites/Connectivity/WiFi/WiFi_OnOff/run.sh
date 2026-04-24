#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_connectivity.sh"

TESTNAME="WiFi_OnOff"
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1

WIFI_DT_PATTERNS_DEFAULT="$(
cat <<'EOF'
qcom,wcn7850
qcom,wcn6855
qcom,wcn6750
qcom,wcn3950
ath12k
ath11k
wifi
wlan
qca
EOF
)"

WIFI_DRIVER_MODULES_DEFAULT="$(
cat <<'EOF'
ath12k_wifi7
ath12k
ath11k
ath11k_pci
ath10k_pci
ath10k_snoc
cfg80211
mac80211
mhi
EOF
)"

WIFI_WAIT_SECS="${WIFI_WAIT_SECS:-30}"
WIFI_WAIT_STEP_SECS="${WIFI_WAIT_STEP_SECS:-2}"
WIFI_PROBE_LOG_DIR="${WIFI_PROBE_LOG_DIR:-./wifi_onoff_dmesg}"
WIFI_PROBE_LOG_TAG="${WIFI_PROBE_LOG_TAG:-${TESTNAME}/probe}"
WIFI_DT_PATTERNS="${WIFI_DT_PATTERNS:-$WIFI_DT_PATTERNS_DEFAULT}"
WIFI_DRIVER_MODULES="${WIFI_DRIVER_MODULES:-$WIFI_DRIVER_MODULES_DEFAULT}"

wifi_iface=""

# Convert a newline-separated config list into normal shell arguments and call
# the requested helper without needing unquoted expansion in run.sh.
run_with_line_args() {
    target_func="$1"
    list_data="$2"

    set --

    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        set -- "$@" "$entry"
    done <<EOF
$list_data
EOF

    "$target_func" "$@"
}

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Config: WIFI_WAIT_SECS=${WIFI_WAIT_SECS} WIFI_WAIT_STEP_SECS=${WIFI_WAIT_STEP_SECS}"
log_info "Config: WIFI_PROBE_LOG_TAG=${WIFI_PROBE_LOG_TAG}"

if [ -n "${WIFI_IFACE:-}" ]; then
    log_info "Config: WIFI_IFACE override requested: ${WIFI_IFACE}"
fi

check_dependencies ip iw

log_info "=== WiFi Kernel Config Validation ==="
wifi_required_cfgs="CONFIG_WIRELESS CONFIG_WLAN CONFIG_CFG80211 CONFIG_MAC80211"

if check_kernel_config "$wifi_required_cfgs"; then
    log_pass "Mandatory WiFi baseline kernel configs are enabled."
else
    log_fail_exit "$TESTNAME" "Mandatory WiFi baseline kernel configs are missing." ""
fi

log_info "=== WiFi Optional Kernel Config Visibility ==="
if check_kernel_config "CONFIG_NL80211_TESTMODE" >/dev/null 2>&1; then
    log_info "Optional WiFi config present: CONFIG_NL80211_TESTMODE"
else
    log_warn "Optional WiFi config not enabled: CONFIG_NL80211_TESTMODE"
fi

if check_kernel_config "CONFIG_WLAN_VENDOR_ATH" >/dev/null 2>&1; then
    log_info "Optional WiFi config present: CONFIG_WLAN_VENDOR_ATH"
else
    log_warn "Optional WiFi config not enabled: CONFIG_WLAN_VENDOR_ATH"
fi

log_info "=== WiFi DT Validation ==="
if run_with_line_args wifi_dt_present "$WIFI_DT_PATTERNS"; then
    log_pass "WiFi DT entry/compatible matched."
else
    log_warn "No WiFi DT entry/compatible matched from configured patterns."
fi

log_info "=== WiFi Module Visibility ==="
run_with_line_args wifi_log_module_info "$WIFI_DRIVER_MODULES"

log_info "=== WiFi Driver Kernel Config Validation ==="
wifi_driver_cfgs="$(infer_wifi_driver_cfgs)"
if [ -n "$wifi_driver_cfgs" ]; then
    if check_kernel_config "$wifi_driver_cfgs"; then
        log_pass "Target-specific WiFi driver kernel configs are enabled."
    else
        log_fail_exit "$TESTNAME" "Target-specific WiFi driver kernel configs are missing." ""
    fi
else
    log_warn "No target-specific WiFi driver config requirement inferred from module/runtime evidence."
fi

log_info "=== WiFi Probe Check ==="
if wifi_has_probe_failures "$WIFI_PROBE_LOG_DIR" "$WIFI_PROBE_LOG_TAG"; then
    log_fail_exit "$TESTNAME" "WiFi driver probe/runtime failures detected in kernel log." ""
else
    log_pass "[$WIFI_PROBE_LOG_TAG] No WiFi probe/runtime failures detected in kernel log."
fi

log_info "=== Waiting for WiFi Interface ==="
wifi_iface="$(wait_for_wifi_interface "$WIFI_WAIT_SECS" "$WIFI_WAIT_STEP_SECS" || true)"

if [ -z "$wifi_iface" ]; then
    log_info "No WiFi interface detected after wait. Collecting diagnostics..."

    run_with_line_args wifi_dump_debug_info "$WIFI_DT_PATTERNS"
    run_with_line_args wifi_log_module_info "$WIFI_DRIVER_MODULES"
    wifi_has_probe_failures "$WIFI_PROBE_LOG_DIR" "$WIFI_PROBE_LOG_TAG" || true

    if wifi_stack_present; then
        log_fail_exit "$TESTNAME" "WiFi stack present, but no usable WiFi interface was found after retries." ""
    fi

    log_skip_exit "$TESTNAME" "No WiFi interface found and no WiFi stack was detected. Skipping." ""
fi

log_pass "Detected WiFi interface: $wifi_iface"

log_info "=== Initial Interface State ==="
ip link show "$wifi_iface" 2>/dev/null || true
if command -v iw >/dev/null 2>&1; then
    iw dev "$wifi_iface" info 2>/dev/null || true
fi

log_info "=== WiFi Toggle Validation ==="

if bring_interface_up_down "$wifi_iface" down; then
    log_info "Brought $wifi_iface down successfully."
    ip link show "$wifi_iface" 2>/dev/null || true
else
    log_info "Failed while bringing $wifi_iface down. Collecting diagnostics..."
    wifi_dump_runtime_info
    wifi_has_probe_failures "$WIFI_PROBE_LOG_DIR" "$WIFI_PROBE_LOG_TAG" || true
    log_fail_exit "$TESTNAME" "Failed to bring $wifi_iface down." ""
fi

sleep 2

if bring_interface_up_down "$wifi_iface" up; then
    log_info "Brought $wifi_iface up successfully."
    ip link show "$wifi_iface" 2>/dev/null || true
    if command -v iw >/dev/null 2>&1; then
        iw dev "$wifi_iface" info 2>/dev/null || true
    fi
    log_pass_exit "$TESTNAME" "$wifi_iface toggled up/down successfully." ""
else
    log_info "Failed while bringing $wifi_iface up. Collecting diagnostics..."
    wifi_dump_runtime_info
    wifi_has_probe_failures "$WIFI_PROBE_LOG_DIR" "$WIFI_PROBE_LOG_TAG" || true
    log_fail_exit "$TESTNAME" "Failed to bring $wifi_iface up after down." ""
fi
