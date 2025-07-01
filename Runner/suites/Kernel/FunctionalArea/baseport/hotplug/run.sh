#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

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

TESTNAME="hotplug"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

check_cpu_status() {
    cat /sys/devices/system/cpu/cpu*/online
}
op=0
offline_cpu() {
    echo 0 > "/sys/devices/system/cpu/$1/online"
    op=$(cat "/sys/devices/system/cpu/$1/online")
    if [ "$op" -ne 1 ]; then
        log_pass "/sys/devices/system/cpu/$1/online is offline as expected"
    fi
}

online_cpu() {
    echo 1 > "/sys/devices/system/cpu/$1/online"
    op=$(cat "/sys/devices/system/cpu/$1/online")
    if [ "$op" -ne 0 ]; then
        log_pass "/sys/devices/system/cpu/$1/online is online as expected"
    fi
}

log_info "Initial CPU status:"
check_cpu_status | tee -a "$LOG_FILE"

test_passed=true
for cpu in /sys/devices/system/cpu/cpu[0-7]*; do
    cpu_id=$(basename "$cpu")

    log_info "Offlining $cpu_id"
    offline_cpu "$cpu_id"
    sleep 1

    online_status=$(cat /sys/devices/system/cpu/$cpu_id/online)
    if [ "$online_status" -ne 0 ]; then
        log_fail "Failed to offline $cpu_id"
        test_passed=false
    fi

    log_info "Onlining $cpu_id"
    online_cpu "$cpu_id"
    sleep 1

    online_status=$(cat /sys/devices/system/cpu/$cpu_id/online)
    if [ "$online_status" -ne 1 ]; then
        log_fail "Failed to online $cpu_id"
        test_passed=false
    fi
done

log_info "Final CPU status:"
check_cpu_status | tee -a "$LOG_FILE"

# Print overall test result
if [ "$test_passed" = true ]; then
        log_pass "$TESTNAME : Test Passed"
        echo "$TESTNAME PASS" > "$res_file"
        exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
