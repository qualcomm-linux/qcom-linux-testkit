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

if ! check_dependencies grep; then
    log_skip "$TESTNAME SKIP - missing required grep utility"
    echo "$TESTNAME SKIP" >"$res_file"
    exit 0
fi

log_info "Checking kernel config for QCOM_SCM support..."
if ! check_kernel_config "CONFIG_QCOM_SCM"; then
    log_skip "$TESTNAME : CONFIG_QCOM_SCM not enabled, test Skipped"
    echo "$TESTNAME SKIP" > "$res_file"
    exit 0
fi

log_info "Checking qcom_scm presence using sysfs/current-boot kernel log"

if [ -d /sys/module/qcom_scm ]; then
    log_pass "qcom_scm driver is present in sysfs."
elif get_kernel_log 2>/dev/null | grep -qi '\bqcom_scm\b'; then
    log_pass "qcom_scm present in current-boot kernel log."
else
    log_fail "FAIL: qcom_scm not found in sysfs or current-boot kernel log."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 0
fi

scm_log="./qcom_scm_kernel.log"
scm_err="./qcom_scm_errors.log"
err_patterns='probe failed|fail(ed)?|error|timed out|not found|invalid|corrupt|abort|panic|oops|unhandled'

log_info "Scanning current-boot kernel log for qcom_scm-related errors"
get_kernel_log > "$scm_log" 2>/dev/null || true
grep -iE "qcom_scm.*($err_patterns)" "$scm_log" > "$scm_err" || true

if [ -s "$scm_err" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        log_info "[kernel] $line"
    done < "$scm_err"
    log_fail "FAIL: qcom_scm-related errors detected in current-boot kernel log."
    echo "$TESTNAME FAIL" > "$res_file"
else
    log_pass "$TESTNAME : Test Passed (qcom_scm present and no qcom_scm-related kernel errors)"
    echo "$TESTNAME PASS" > "$res_file"
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
