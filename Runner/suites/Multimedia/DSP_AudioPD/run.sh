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

TESTNAME="DSP_AudioPD"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if dependency binary is available"
check_dependencies adsprpcd

if is_process_running  "adsprpcd"; then
    log_info "adsprpcd is running"
    PID=$(get_pid "adsprpcd")
else
    log_info "adsprpcd is not running"
    log_info "Manually starting adsprpcd daemon"
    adsprpcd &
    PID=$!
fi
log_info "PID is $PID"
sleep 5

if [ -z "$PID" ]; then
    log_info "Failed to start the binary"
    exit 1
else
    log_info "Binary is running successfully"
fi

check_stack_trace() {
    pid=$1
    if grep -q "do_sys_poll" < "/proc/$pid/stack" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Print overall test result
if check_stack_trace "$PID"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    kill_process "$PID"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    kill_process "$PID"
    exit 1
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"