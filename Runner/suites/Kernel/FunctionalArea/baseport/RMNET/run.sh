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

TESTNAME="RMNET"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

RMNET_MODULE_PATH=$(find_kernel_module "rmnet")

if [ -z "$RMNET_MODULE_PATH" ]; then
    log_error "rmnet.ko module not found in filesystem."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Found rmnet.ko at: $RMNET_MODULE_PATH"

if ! load_kernel_module "$RMNET_MODULE_PATH"; then
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if is_module_loaded "rmnet"; then
    log_info "rmnet module is loaded"
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_error "rmnet module not listed in lsmod"
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "=== Cleanup ==="
unload_kernel_module "rmnet" true

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
