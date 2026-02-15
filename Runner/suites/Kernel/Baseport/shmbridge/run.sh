#!/bin/sh
 
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause 
# Locate and source init_env
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

TESTNAME="shmbridge"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "==== Test Initialization ===="

log_info "Checking if required tools are available"

if ! check_dependencies zcat grep dmesg; then
    log_skip "$TESTNAME SKIP - missing one or more of zcat grep dmesg utils"
    echo "$TESTNAME SKIP" >"$RES_FILE"
    exit 0
fi

log_info "Checking kernel config for QCOM_SCM support..."
if ! check_kernel_config "CONFIG_QCOM_SCM"; then
    log_skip "$TESTNAME : CONFIG_QCOM_SCM not enabled, test Skipped"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi
 
log_info "Scanning dmesg logs for qcom_scm initialization"

if dmesg | grep -q 'qcom_scm'; then
    if ! scan_dmesg_errors . "" ""; then
        log_pass "$TESTNAME : Test Passed (qcom_scm present and no probe failures)"
        echo "$TESTNAME PASS" > "$res_file" 
    else
        log_fail "FAIL: 'probe failure' detected in dmesg."
        echo "$TESTNAME FAIL" > "$res_file"
    fi
else
    log_fail "FAIL: 'qcom_scm' not found in dmesg."
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"

 