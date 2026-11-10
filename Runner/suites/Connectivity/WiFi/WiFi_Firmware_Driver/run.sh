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
. "$TOOLS/lib_connectivity.sh"

TESTNAME="WiFi_Firmware_Driver"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! check_dependencies find grep cat stat awk readlink sort mktemp; then
    test_result_finish SKIP "Image lacks utilities required for WiFi runtime discovery"
fi
RESULT_DIR=$(mktemp -d "$PWD/wifi-firmware.XXXXXX") || test_result_finish FAIL "Cannot create WiFi evidence directory in CWD"
WIFI_FW_PROBE_LOG_DIR="${WIFI_FW_PROBE_LOG_DIR:-$RESULT_DIR}"
WIFI_FW_PROBE_LOG_TAG="${WIFI_FW_PROBE_LOG_TAG:-WiFi_Firmware_Driver/probe}"
WIFI_FW_LOAD_LOG_TAG="${WIFI_FW_LOAD_LOG_TAG:-WiFi_Firmware_Driver/firmware}"
if wifi_has_probe_failures "$WIFI_FW_PROBE_LOG_DIR" "$WIFI_FW_PROBE_LOG_TAG"; then
    test_result_finish FAIL "WiFi driver probe/runtime errors captured in $RESULT_DIR"
fi
if ! wifi_families=$(wifi_runtime_families); then
    test_result_finish FAIL "WiFi runtime discovery did not complete within its budget"
fi
wifi_families=$(printf '%s\n' "$wifi_families" | sort -u)
if [ -z "$wifi_families" ]; then
    test_result_finish SKIP "No supported WiFi family identified from runtime drivers or device modaliases, firmware directories alone do not identify hardware"
fi
for wifi_family in $wifi_families; do
    log_info "Runtime WiFi family: $wifi_family"
    if ! wifi_detect_firmware_info "$wifi_family"; then
        test_result_record FAIL "Runtime family $wifi_family has no runtime consumed-firmware evidence or readable image firmware candidate"
        continue
    fi
    log_info "Firmware evidence=${WIFI_FW_EVIDENCE:-asset} path=$WIFI_FW_FILE size=$WIFI_FW_SIZE"
    if ! wifi_handle_firmware_family "$wifi_family" "$WIFI_FW_BASENAME"; then
        test_result_record FAIL "Cannot prepare runtime WiFi driver for $wifi_family"
        continue
    fi
    if wifi_firmware_loaded "$wifi_family" "$WIFI_FW_LOAD_LOG_TAG" && wifi_verify_family_modules "$wifi_family"; then
        test_result_record PASS "WiFi $wifi_family driver has a registered wireless PHY"
    else
        test_result_record FAIL "WiFi $wifi_family has no bound wireless PHY, inspect firmware and driver initialization"
    fi
done
# Include errors from driver activation, not only those present before it.
if wifi_has_probe_failures "$WIFI_FW_PROBE_LOG_DIR" "$WIFI_FW_PROBE_LOG_TAG"; then
    test_result_record FAIL "WiFi probe/runtime errors found after driver validation"
fi
test_result_finish
