#!/bin/sh

# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

# Import test suite definitions
source $(pwd)/init_env
TESTNAME="Ethernet"

#import test functions library
source $TOOLS/functestlib.sh
test_path=$(find_test_case_by_name "$TESTNAME")
log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

log_info "Checking if dependency:net-tools is available"
check_dependencies net-tools

log_info "Starting Ethernet test..."

IFACE="eth0"

# Check interface existence
if ! ip link show "$IFACE" >/dev/null 2>&1; then
    log_fail "Ethernet interface $IFACE not found"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
fi

# Check if interface is up, try to bring it up if not
if ! ip link show "$IFACE" | grep -q "state UP"; then
    log_warn "Interface $IFACE is down, attempting to bring it up..."
    ip link set "$IFACE" up
    sleep 3
    if ! ip link show "$IFACE" | grep -q "state UP"; then
        log_fail "Failed to bring up $IFACE"
        echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
        exit 1
    fi
fi

# Ping test
log_info "Running ping test to 8.8.8.8..."
if ping -I "$IFACE" -c 4 -W 2 8.8.8.8 >/dev/null 2>&1; then
    log_pass "Ethernet connectivity verified"
    echo "$TESTNAME PASS" > $test_path/$TESTNAME.res
else
    log_fail "Ethernet ping failed"
    echo "$TESTNAME FAIL" > $test_path/$TESTNAME.res
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"

