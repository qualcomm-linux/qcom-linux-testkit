#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Robustly source init_env and functestlib.sh
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

TESTNAME="Probe_Failure_Check"
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1

res_file="./$TESTNAME.res"
log_file="./probe_failures.log"

log_info "-----------------------------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase ----------------------------"

rm -f "$res_file" "$log_file"
{
    echo "Probe Failure Report - $(date)"
    echo "--------------------------------------------------"
} > "$log_file"

if get_kernel_log 2>/dev/null | \
   grep -iE '([[:alnum:]_.-]+:)?[[:space:]]*(probe failed|failed to probe|probe error)' \
   >> "$log_file"; then
    log_error "Probe failures detected; see $log_file"
    log_fail "$TESTNAME : Probe failures found"
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
else
    rm -f "$log_file"
    log_pass "$TESTNAME : No probe failures found"
    echo "$TESTNAME PASS" > "$res_file"
    exit 0
fi
