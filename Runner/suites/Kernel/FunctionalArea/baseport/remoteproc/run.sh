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

TESTNAME="remoteproc"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Getting the number of subsystems aavailable"

available_rprocs=$(cat /sys/class/remoteproc/remoteproc*/firmware)

# Check if any line contains "modem"
echo "$available_rprocs" | grep -q "modem"
if [ $? -eq 0 ]; then
    subsystem_count=$(echo "$available_rprocs" | grep -v "modem" | wc -l)
else
    # "modem" not found, count all lines
    subsystem_count=$(echo "$available_rprocs" | wc -l)
fi

# Execute the command and get the output
log_info "Checking if all the remoteprocs are in running state"
output=$(cat /sys/class/remoteproc/remoteproc*/state)

# Count the number of "running" values
count=$(echo "$output" | grep -c "running")
log_info "rproc subsystems in running state : $count, expected subsystems : $subsystem_count"

# Print overall test result
if [ $count -eq $subsystem_count ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
