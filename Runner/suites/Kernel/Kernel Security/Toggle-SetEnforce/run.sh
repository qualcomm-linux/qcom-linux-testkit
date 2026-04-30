#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

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
    echo "[ERROR] Could not find init_env" >&2
    exit 1
fi

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

TESTNAME="Toggle-SetEnforce"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
res_file="./$TESTNAME.res"
log_info "------------------------$TESTNAME Starting------------------------"

state1=$(getenforce)
log_info "Current state: $state1"

if [ "$state1" = "Permissive" ]; then
    log_info "Running command 'setenforce 1'"
    setenforce 1
    state2=$(getenforce)
    log_info "Output after running command: $state2"
fi
log_info "Running command 'setenforce 0'"
setenforce 0
state3=$(getenforce)
log_info "Output after running command: $state3"
    
if [ "$state3" = "Permissive" ]; then
    log_pass "PASS: Successfully toggled from $state1 to $state3"
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "FAIL: Expected 'Permissive' after toggle but got '$state2'"
    echo "$TESTNAME FAIL" > "$res_file"
fi

log_info "------------------------$TESTNAME Finished------------------------" 