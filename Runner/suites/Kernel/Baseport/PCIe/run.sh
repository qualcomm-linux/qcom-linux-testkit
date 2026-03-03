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

TESTNAME="PCIe"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="
log_info "Checking if required tools are available"

check_dependencies "lspci"
log_info "Running PCIe "
lspci_output=$(lspci -vvv)

missing=""

if echo "$lspci_output" | grep -q "Device tree node:"; then
    log_info "DT node is present"
else
    log_warn "DT node is not present"
    missing=1
fi

if echo "$lspci_output" | grep -q "Capabilities:"; then
    log_info "Yes, 'Capabilities:' is found"
else
    log_warn "No, 'Capabilities:' is missing"
    missing=1
fi

if echo "$lspci_output" | grep -q "Kernel driver in use:"; then
    log_info "Driver is loaded"
else
    log_warn "Driver is not loaded"
    missing=1
fi

if [ -z "$missing" ]; then
    log_pass "$TESTNAME : Test Passed"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
else
    log_fail "$TESTNAME : Test Failed"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
