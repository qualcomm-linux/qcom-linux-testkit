#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#Setup requires at least one USB peripheral connected to USB port that supports Host mode function

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

TESTNAME="USBHost"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Check if lsusb is installed
check_dependencies lsusb

# Run lsusb and capture output
usb_output=$(lsusb)
device_count=$(echo "$usb_output" | wc -l)

# Filter out USB hubs
non_hub_count=$(echo "$usb_output" | grep -vi "hub" | wc -l)

echo "Enumerated USB devices..."
echo "$usb_output"

# Check if any USB devices were found
if [ "$device_count" -eq 0 ]; then
    log_fail "$TESTNAME : Test Failed - No USB devices found."
    echo "$TESTNAME FAIL" > "$res_file"

elif [ "$non_hub_count" -eq 0 ]; then
    log_fail "$TESTNAME : Test Failed - Only USB hubs detected, no functional USB devices."
    echo "$TESTNAME FAIL" > "$res_file"
else
    log_pass "$TESTNAME : Test Passed - $non_hub_count non-hub USB device(s) found."
    echo "$TESTNAME PASS" > "$res_file"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
