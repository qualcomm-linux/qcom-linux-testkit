#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TESTNAME="core_auth"
result_file="./${TESTNAME}.res"

# ---- Source init_env & tools ----
INIT_ENV=""
SEARCH="$SCRIPT_DIR"
while [ "$SEARCH" != "/" ]; do
  if [ -f "$SEARCH/init_env" ]; then INIT_ENV="$SEARCH/init_env"; break; fi
  SEARCH="$(dirname "$SEARCH")"
done
[ -z "$INIT_ENV" ] && echo "[ERROR] init_env not found" >&2 && exit 1
# shellcheck disable=SC1090
[ -z "$__INIT_ENV_LOADED" ] && . "$INIT_ENV"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

test_path="$(find_test_case_by_name "$TESTNAME" 2>/dev/null)"
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    test_path="$SCRIPT_DIR"
fi

if [ ! -w "$test_path" ]; then
    log_error "Cannot write to test directory: $test_path"
    echo "$TESTNAME FAIL" >"$result_file"
    exit 1
fi

cd "$test_path" || { log_error "cd failed: $test_path"; echo "$TESTNAME FAIL" >"$result_file"; exit 1; }

log_info "-----------------------------------------------------------------------"
log_info "-------------------Found $TESTNAME Testcase----------------------------"

log_info "---------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase-----------------------------"

if [ -z "$1" ]; then
    log_error "Usage: ./run-test.sh core_auth <core_auth_bin_path>"
    echo "$TESTNAME FAIL" > "$result_file"
    exit 1
fi

CORE_AUTH_CMD="$1"

if [ ! -f "$CORE_AUTH_CMD" ] || [ ! -x "$CORE_AUTH_CMD" ]; then
    log_error "core_auth binary not found or not executable at: $CORE_AUTH_CMD"
    echo "$TESTNAME FAIL" > "$result_file"
    exit 1
fi

log_info "Using core_auth binary at: $CORE_AUTH_CMD"

if pgrep -x weston > /dev/null; then
    log_info "Stopping weston..."
    pkill -x weston

    # Wait for weston to stop with timeout
    timeout=10
    count=0
    while [ "$count" -lt "$timeout" ]; do
        if ! pgrep -x weston > /dev/null; then
            log_info "Weston stopped successfully after $count second(s)"
            break
        fi
        sleep 1
        count="$((count + 1))"
    done
    if [ "$count" -eq "$timeout" ]; then
        log_error "Weston couldn't be killed after $count attempts"
        echo "$TESTNAME FAIL" > "$result_file"
        exit 1
    fi
else
    log_info "Weston is not running, no need to kill it again"
fi


"$CORE_AUTH_CMD" > "$test_path/core_auth_log.txt" 2>&1
RC="$?"


cat "$test_path/core_auth_log.txt"

if [ "$RC" -eq 0 ]; then
    log_pass "$TESTNAME : Test Passed with \"return code $RC\""
    echo "$TESTNAME PASS" > "$result_file"

elif grep -q "SUCCESS" "$test_path/core_auth_log.txt"; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$result_file"

elif grep -q "SKIP" "$test_path/core_auth_log.txt"; then
    log_skip "$TESTNAME : Test Skipped"
    echo "$TESTNAME SKIP" > "$result_file"

else
    log_fail "$TESTNAME : Test Failed (exit code: $RC)"
    echo "$TESTNAME FAIL" > "$result_file"
fi

log_info "results written to \"$result_file\""

log_info "-------------------Completed $TESTNAME Testcase----------------------------"