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

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="shmbridge"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

log_info "Checking if required tools are available"
check_dependencies zcat grep dmesg

log_info "Checking kernel config for QCOM_SCM support..."
if ! zcat /proc/config.gz | grep -q "CONFIG_QCOM_SCM"; then
    log_fail "$TESTNAME : CONFIG_QCOM_SCM not found in kernel config"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Checking dmesg logs for qcom_scm entries..."
dmesg_output=$(dmesg | grep qcom_scm)

if [ -z "$dmesg_output" ]; then
    log_fail "$TESTNAME : No qcom_scm entries found in dmesg"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

echo "$dmesg_output" | while read -r line; do
    log_info "$line"
done

if echo "$dmesg_output" | grep -qi "probe failure"; then
    log_fail "$TESTNAME : Probe failure detected in dmesg logs"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_pass "$TESTNAME : Test Passed (QCOM_SCM present and no probe failures)"
echo "$TESTNAME PASS" > "$res_file"

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
