#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause-Clear
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.

# Import test suite definitions
. "$(pwd)/init_env"
TESTNAME="WIFI"

# Import test functions library
. "$TOOLS/functestlib.sh"
test_path=$(find_test_case_by_name "$TESTNAME")

log_info "--------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "Starting WiFi Test..."

WLAN="wlan0"
SSID_CONF="$(dirname "$0")/wifi_test.conf" # should contain: SSID and PASSWORD

if [ ! -f "$SSID_CONF" ]; then
    log_fail "WiFi config $SSID_CONF not found"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    exit 1
fi

. "$SSID_CONF"

log_info "Loaded SSID=$SSID, PASSWORD=$PASSWORD"

if ! command -v nmcli >/dev/null 2>&1; then
    log_fail "nmcli not found"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    exit 1
fi

# Restart NetworkManager if needed
if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
    log_warn "NetworkManager not active. Trying to start it..."
    systemctl start NetworkManager
    sleep 3
    if ! systemctl is-active NetworkManager >/dev/null 2>&1; then
        log_fail "Failed to start NetworkManager"
        echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
        exit 1
    fi
fi

# Connect to WiFi
log_info "Attempting to connect to SSID: $SSID"
nmcli_output=$(nmcli dev wifi connect "$SSID" password "$PASSWORD" ifname "$WLAN" 2>&1)
log_info "nmcli output: $nmcli_output"
sleep 5

if echo "$nmcli_output" | grep -qi "successfully activated"; then
    log_pass "Connected to $SSID"
    echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
else
    log_fail "Failed to connect to $SSID"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
    exit 1
fi


log_info "-------------------Completed $TESTNAME Testcase----------------------------"

