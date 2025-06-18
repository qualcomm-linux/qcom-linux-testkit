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

TESTNAME="gdsp_remoteproc"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

# Loop through all remoteproc firmware entries to find gpdsp0 and gpdsp1
for gdsp_firmware in gpdsp0 gpdsp1; do
    for fw_path in /sys/class/remoteproc/remoteproc*/firmware; do
        if grep -q "$gdsp_firmware" "$fw_path"; then
            remoteproc_path=$(dirname "$fw_path")
            log_info "Found $gdsp_firmware at $remoteproc_path"

            state1=$(cat "$remoteproc_path/state")
            if [ "$state1" != "running" ]; then
                log_fail "$gdsp_firmware not running initially"
                echo "$TESTNAME FAIL" > "$res_file"
                exit 1
            fi

            echo stop > "$remoteproc_path/state"
            state2=$(cat "$remoteproc_path/state")
            if [ "$state2" != "offline" ]; then
                log_fail "$gdsp_firmware stop failed"
                echo "$TESTNAME FAIL" > "$res_file"
                exit 1
            else
                log_pass "$gdsp_firmware stop successful"
            fi

            log_info "Restarting $gdsp_firmware"
            echo start > "$remoteproc_path/state"
            state3=$(cat "$remoteproc_path/state")
            if [ "$state3" != "running" ]; then
                log_fail "$gdsp_firmware start failed"
                echo "$TESTNAME FAIL" > "$res_file"
                exit 1
            fi

            log_pass "$gdsp_firmware PASS"
        fi
    done
done

echo "$TESTNAME PASS" > "$res_file"
log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
