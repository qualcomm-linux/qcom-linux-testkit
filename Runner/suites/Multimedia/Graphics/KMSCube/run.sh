#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# KMSCube Validator Script (Yocto-Compatible)
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

TESTNAME="kmscube"
FRAME_COUNT=999
EXPECTED_FRAMES=$((FRAME_COUNT - 1))
test_path=$(find_test_case_by_name "$TESTNAME")
cd "$test_path" || exit 1
RES_FILE="./$TESTNAME.res"
LOG_FILE="./${TESTNAME}_run.log"
rm -f "$RES_FILE" "$LOG_FILE"

log_info "-------------------------------------------------------------------"
log_info "------------------- Starting $TESTNAME Testcase -------------------"

if check_dependencies "$TESTNAME"; then
    log_fail "$TESTNAME : kmscube binary not found"
    echo "$TESTNAME SKIP" > "$RES_FILE"
    exit 1
fi

weston_was_running=0
if weston_is_running; then
    weston_stop
    weston_was_running=1
fi

log_info "Running kmscube test with --count=$FRAME_COUNT..."
if kmscube --count="$FRAME_COUNT" > "$LOG_FILE" 2>&1; then
    if grep -q "Rendered $EXPECTED_FRAMES frames" "$LOG_FILE"; then
        log_pass "$TESTNAME : Test Passed"
        echo "$TESTNAME PASS" > "$RES_FILE"
    else
        log_fail "$TESTNAME : Expected output not found (Rendered $EXPECTED_FRAMES frames)"
        echo "$TESTNAME FAIL" > "$RES_FILE"
    fi
else
    log_fail "$TESTNAME : Execution failed (non-zero exit code)"
    echo "$TESTNAME FAIL" > "$RES_FILE"
fi

if [ "$weston_was_running" -eq 1 ]; then
	log_info "weston realuching after $TESTNAME completion"
    weston_start
fi

log_info "------------------- Completed $TESTNAME Testcase ------------------"
exit 0
