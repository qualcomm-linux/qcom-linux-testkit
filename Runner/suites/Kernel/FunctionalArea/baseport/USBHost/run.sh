#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

#Setup requires at least one USB peripheral connected to USB port that supports Host mode function

# Import test suite definitions
. "${PWD}"/init_env
TESTNAME="USBHost"

#import test functions library
. "${TOOLS}"/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Running USB Host enumeration test"

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
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
elif [ "$non_hub_count" -eq 0 ]; then
    log_fail "$TESTNAME : Test Failed - Only USB hubs detected, no functional USB devices."
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
else
    log_pass "$TESTNAME : Test Passed - $non_hub_count non-hub USB device(s) found."
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"