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

# Only source if not already loaded (idempotent)
if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="WiFi_OnOff"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

check_dependencies ip iw

wifi_iface="$(get_wifi_interface)"
if [ -z "$wifi_iface" ]; then
    log_skip_exit "$TESTNAME" "No WiFi interface found. Skipping." ""
fi

# Bring WiFi down
if bring_interface_up_down "$wifi_iface" down; then
    log_info "Brought $wifi_iface down successfully."
else
    log_fail_exit "$TESTNAME" "Failed to bring $wifi_iface down." ""
fi

sleep 2

# Bring WiFi up
if bring_interface_up_down "$wifi_iface" up; then
    log_info "Brought $wifi_iface up successfully."
    log_pass_exit "$TESTNAME" "$wifi_iface toggled up/down successfully." ""
else
    log_fail_exit "$TESTNAME" "Failed to bring $wifi_iface up after down." ""
fi
