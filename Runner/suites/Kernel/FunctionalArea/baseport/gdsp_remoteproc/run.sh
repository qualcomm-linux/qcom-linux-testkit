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

TESTNAME="gdsp_remoteproc"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

for gdsp_firmware in gpdsp0 gpdsp1; do
    log_info "Processing $gdsp_firmware"
    rproc_path=$(get_remoteproc_path_by_firmware "$gdsp_firmware")
    if [ -z "$rproc_path" ]; then
        log_fail "$gdsp_firmware remoteproc path not found"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi

    log_info "Found $gdsp_firmware remoteproc at $rproc_path"

    state=$(get_remoteproc_state "$rproc_path")
    if [ "$state" != "running" ]; then
        log_fail "$gdsp_firmware not running initially"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi

    if ! stop_remoteproc "$rproc_path"; then
        log_fail "$gdsp_firmware stop failed"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    else
        log_pass "$gdsp_firmware stop successful"
    fi

    log_info "Restarting $gdsp_firmware"
    if ! start_remoteproc "$rproc_path"; then
        log_fail "$gdsp_firmware start failed"
        echo "$TESTNAME FAIL" > "$res_file"
        exit 1
    fi

    log_pass "$gdsp_firmware PASS"
done

echo "$TESTNAME PASS" > "$res_file"
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
