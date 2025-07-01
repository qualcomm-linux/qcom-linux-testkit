#!/bin/sh
 
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear
 
# Source init_env and functestlib.sh
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
 
# shellcheck disable=SC1090
. "$INIT_ENV"
 
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
 
TESTNAME="Bluetooth"
test_path=$(find_test_case_by_name "$TESTNAME") || {
    log_fail "$TESTNAME : Test directory not found."
    echo "$TESTNAME FAIL" > "./$TESTNAME.res"
    exit 1
}
 
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
rm -f "$res_file"
 
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "Checking dependency: bluetoothctl"
check_dependencies bluetoothctl
 
log_info "Checking if bluetoothd is running..."
MAX_RETRIES=3
RETRY_DELAY=5
retry=0
 
while [ "$retry" -lt "$MAX_RETRIES" ]; do
    if pgrep bluetoothd >/dev/null 2>&1; then
        log_info "bluetoothd is running"
        break
    fi
    log_warn "bluetoothd not running, retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
    retry=$((retry + 1))
done
 
if [ "$retry" -eq "$MAX_RETRIES" ]; then
    log_fail "Bluetooth daemon not detected after ${MAX_RETRIES} attempts."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
 
log_info "Powering off Bluetooth controller..."
poweroff_output=$(bluetoothctl power off 2>&1)
if echo "$poweroff_output" | grep -q "Changing power off succeeded"; then
    log_pass "Bluetooth powered off successfully"
else
    log_warn "Power off result: $poweroff_output"
    log_fail "Bluetooth power off failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
 
log_info "Powering on Bluetooth controller..."
poweron_output=$(bluetoothctl power on 2>&1)
if echo "$poweron_output" | grep -q "Changing power on succeeded"; then
    log_pass "Bluetooth powered on successfully"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_warn "Power on result: $poweron_output"
    log_fail "Bluetooth power on failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

