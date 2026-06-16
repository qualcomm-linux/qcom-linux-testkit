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
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi
# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="CheckGetenforce"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034

RES_FILE="./$TESTNAME.res"

if ! CHECK_DEPS_NO_EXIT=1 check_dependencies getenforce; then										 
    log_skip "$TESTNAME SKIP: missing dependencies"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
op=$(getenforce)
log_info "Getenforce output: $op"

echo "SELINUX Default Mode is $op" > getenforce.txt

if [ "$op" = "Enforcing" ] || [ "$op" = "Permissive" ]; then
    log_info "SELinux is $op. Testcase PASS."
    log_pass "$TESTNAME : PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
    exit 0
elif [ "$op" = "Disabled" ]; then
    log_info "SELinux is Disabled. Testcase FAIL."
    log_fail "$TESTNAME : FAIL"
    pass=false
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
else
    log_fail "Unknown SELinux state: $op. Testcase FAIL."
    log_fail "$TESTNAME : FAIL"
    pass=false
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi
