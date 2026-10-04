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

TESTNAME="WiFi_Firmware_Driver"
test_path="$(find_test_case_by_name "$TESTNAME")"
cd "$test_path" || exit 1

RES_FILE="./${TESTNAME}.res"
WIFI_FW_PROBE_LOG_DIR="${WIFI_FW_PROBE_LOG_DIR:-./wifi_firmware_driver_dmesg}"
WIFI_FW_PROBE_LOG_TAG="${WIFI_FW_PROBE_LOG_TAG:-${TESTNAME}/probe}"
WIFI_FW_LOAD_LOG_TAG="${WIFI_FW_LOAD_LOG_TAG:-${TESTNAME}/firmware}"

: >"$RES_FILE"

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Probe log tag: $WIFI_FW_PROBE_LOG_TAG"
log_info "Firmware log tag: $WIFI_FW_LOAD_LOG_TAG"

if ! check_dependencies find grep modprobe lsmod cat stat awk; then
    log_skip "$TESTNAME SKIP - required tools (find/grep/modprobe/lsmod/cat/stat/awk) missing"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

if [ -f /proc/device-tree/model ]; then
    read -r soc_model </proc/device-tree/model
else
    soc_model="Unknown"
fi

log_info "Detected SoC model: $soc_model"

suite_rc=0

log_info "=== WiFi Firmware Detection ==="
if ! wifi_detect_firmware_info; then
    log_skip \
        "$TESTNAME SKIP - No readable ath12k/ath11k/ath10k WiFi firmware asset found under /lib/firmware, including .xz and .zst files"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_info "Detected WiFi firmware family: $WIFI_FW_FAMILY"
log_info "Detected firmware [$WIFI_FW_BASENAME]: $WIFI_FW_FILE (size: $WIFI_FW_SIZE bytes)"

log_info "=== Family-specific Runtime Preparation ==="
if ! wifi_handle_firmware_family "$WIFI_FW_FAMILY" "$WIFI_FW_BASENAME"; then
    suite_rc=1
fi

log_info "=== Family-specific Module Visibility ==="
if ! wifi_verify_family_modules "$WIFI_FW_FAMILY"; then
    suite_rc=1
fi

log_info "=== WiFi Firmware Load Evidence ==="
if wifi_firmware_loaded "$WIFI_FW_FAMILY" "$WIFI_FW_LOAD_LOG_TAG"; then
    log_pass "[$WIFI_FW_LOAD_LOG_TAG] Firmware load/use evidence found."
else
    log_fail "[$WIFI_FW_LOAD_LOG_TAG] Firmware load/use evidence not found."
    suite_rc=1
fi

log_info "=== WiFi Probe Check ==="
if wifi_has_probe_failures "$WIFI_FW_PROBE_LOG_DIR" "$WIFI_FW_PROBE_LOG_TAG"; then
    suite_rc=1
else
    log_pass "[$WIFI_FW_PROBE_LOG_TAG] No WiFi probe/runtime failures detected in kernel log."
fi

if [ "$suite_rc" -eq 0 ]; then
    log_pass "$TESTNAME: PASS - WiFi firmware and driver validation successful."
    echo "$TESTNAME PASS" >"$RES_FILE"
    exit 0
fi

log_fail "$TESTNAME: FAIL - WiFi firmware/driver validation encountered errors."
echo "$TESTNAME FAIL" >"$RES_FILE"
exit 1
