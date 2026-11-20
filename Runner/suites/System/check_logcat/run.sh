#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="check_logcat"
LAVA_CASE_ID="check_logcat"
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

fail_test() {
    test_result_record FAIL "$1"
    test_result_finish
    exit 0
}

pass_test() {
    test_result_record PASS "$1"
    test_result_finish
    exit 0
}

log_info "Starting $TEST_NAME"
log_info "Checking that logcat is unavailable on the DUT"

if command -v logcat >/dev/null 2>&1; then
    LOGCAT_PATH=$(command -v logcat)
    fail_test "logcat is installed at $LOGCAT_PATH; expected it to be unavailable"
fi

# Because command -v confirmed that logcat is absent, this should terminate
# immediately with the shell's command-not-found error.
LOGCAT_OUTPUT=$(sh -c 'logcat' 2>&1)
LOGCAT_STATUS=$?

log_info "Output from attempting to run logcat:"
log_info "$LOGCAT_OUTPUT"
log_info "logcat command exit status: $LOGCAT_STATUS"

if [ "$LOGCAT_STATUS" -ne 127 ]; then
    fail_test "Running logcat returned status $LOGCAT_STATUS; expected command-not-found status 127"
fi

pass_test "logcat is unavailable, as expected"
