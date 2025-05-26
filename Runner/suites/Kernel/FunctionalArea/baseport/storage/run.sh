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

TESTNAME="storage"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Run the dd command to create a file with random data"
dd if=/dev/random of=/tmp/a.txt bs=1M count=1024

# Check if the file is created
if [ -f /tmp/a.txt ]; then
    echo "File /tmp/a.txt is created."

    # Check if the file is not empty
    if [ -s /tmp/a.txt ]; then
        log_pass "File /tmp/a.txt is not empty. Test Passed"
        log_pass "$TESTNAME : Test Passed"
	echo "$TESTNAME PASS" > "$res_file"
    else
        log_fail "File /tmp/a.txt is empty. Test Failed."
        log_fail "$TESTNAME : Test Failed"
	echo "$TESTNAME FAIL" > "$res_file"
    fi
else
    log_fail "File /tmp/a.txt is not created. Test Failed"
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi
if [ -f /tmp/a.txt ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
