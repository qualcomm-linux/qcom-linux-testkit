#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# --------- Robustly source init_env and functestlib.sh ----------
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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# ---------------------------------------------------------------

TESTNAME="Opencv_core"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"


log_info "Checking if dependency binary is available"
check_dependencies opencv_test_core grep chmod

# Navigate to the directory where the fastrpc_test application is located
chmod 755 /usr/bin/opencv_test_core

# Execute the command and capture the output
export OPENCV_OPENCL_RUNTIME=disabled && /usr/bin/opencv_test_core --gtest_filter=Core_AddMixed/ArithmMixedTest.accuracy/0 > opencv_core_result.txt

# Check the log file for the string "SUCCESS" to determine if the test passed
if grep -q "PASSED" opencv_core_result.txt; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$test_path/$TESTNAME.res"
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$test_path/$TESTNAME.res"
fi

# Print the completion of the test case
log_info "-------------------Completed $TESTNAME Testcase----------------------------"