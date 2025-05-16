#!/bin/sh

# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

# Import test suite definitions
. $(pwd)/init_env
TESTNAME="Bluetooth"

#import test functions library
. $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Starting Bluetooth Test..."

# Check if bluetoothctl is available
if ! command -v bluetoothctl >/dev/null 2>&1; then
    log_fail "bluetoothctl not found. Please install bluez."
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
fi

# Check if bluetoothd is running
if ! pgrep bluetoothd >/dev/null; then
    log_fail "bluetoothd is not running. Please start the Bluetooth daemon."
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
fi

# Power off Bluetooth controller
log_info "Powering off Bluetooth controller..."
bluetoothctl power off

# Power on Bluetooth controller
log_info "Powering on Bluetooth controller..."
output=$(bluetoothctl power on)

# Check for success message
if echo "$output" | grep -q "Changing power on succeeded"; then
    log_pass "Bluetooth controller powered on successfully."
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
    log_fail "Failed to power on Bluetooth controller."
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"

