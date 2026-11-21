#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="check_libion"
LAVA_CASE_ID="check_libion"
RES_FILE="$SCRIPT_DIR/${TEST_NAME}.res"

RUNNER_DIR=""
SEARCH="$SCRIPT_DIR"

while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/utils/functestlib.sh" ]; then
        RUNNER_DIR="$SEARCH"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$RUNNER_DIR" ]; then
    echo "[ERROR] Could not find Runner/utils/functestlib.sh, starting at $SCRIPT_DIR" >&2
    exit 1
fi

INIT_ENV="$RUNNER_DIR/init_env"
if [ ! -f "$INIT_ENV" ]; then
    # shellcheck disable=SC1091
    . "$RUNNER_DIR/utils/functestlib.sh"
    test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1
    test_result_record FAIL "Could not find init_env: $INIT_ENV"
    test_result_finish
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# Intentional second source; init_env is guarded against reinitialization.
# shellcheck disable=SC1090
. "$INIT_ENV"

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1

if ! command -v find >/dev/null 2>&1; then
    test_result_record FAIL "find command not found on the DUT"
    test_result_finish
fi

FIND_LOG="$SCRIPT_DIR/${TEST_NAME}.find.log"
FIND_TIMEOUT=120

log_info "Starting $TEST_NAME"
log_info "Searching / for paths matching libion*, excluding volatile system trees"

run_with_timeout_log "$FIND_TIMEOUT" "$FIND_LOG" \
    find / \
    \( -path /proc -o -path /sys -o -path /dev -o -path /run \) -prune -o \
    -name 'libion*' -print
FIND_STATUS=$?
if [ "$FIND_STATUS" -ne 0 ]; then
    log_file_with_label "LIBION-SCAN" "$FIND_LOG"
    test_result_record FAIL "Filesystem scan failed or timed out (status=$FIND_STATUS); see $FIND_LOG"
    test_result_finish
fi

if [ -s "$FIND_LOG" ]; then
    log_info "Found matching paths:"
    log_file_with_label "LIBION-SCAN" "$FIND_LOG"
    test_result_record FAIL "libion-related path(s) found in userspace"
    test_result_finish
fi

log_pass "$LAVA_CASE_ID: no paths matching libion* were found"
test_result_record PASS "No paths matching libion* were found outside volatile system trees"
test_result_finish
exit 0
