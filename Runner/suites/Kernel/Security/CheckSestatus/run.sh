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

TESTNAME="CheckSestatus"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
# shellcheck disable=SC2034

RES_FILE="./$TESTNAME.res"
rm -f "$RES_FILE"


if ! CHECK_DEPS_NO_EXIT=1 check_dependencies getenforce sestatus; then
    log_skip "$TESTNAME SKIP: missing dependencies"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 0
fi

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

op=$(sestatus)
log_info "sestatus output: $op"

if echo "$op" | grep -qiE "Current mode:\s*(enforcing|permissive)"; then
    mode=$(echo "$op" | awk -F: '/Current mode/ {gsub(/^[ \t]+/, "", $2); print $2}')
    log_info "SELinux is $mode. Testcase PASS."
    log_pass "$TESTNAME : PASS"
    echo "$TESTNAME PASS" > "$RES_FILE"
else
    log_info "SELinux is not in enforcing or permissive mode. Testcase FAIL."
    log_fail "$TESTNAME : FAIL"
    echo "$TESTNAME FAIL" > "$RES_FILE"
fi

