#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="syslog_logger"
LAVA_CASE_ID="syslog_logger"
RES_FILE="$SCRIPT_DIR/${TEST_NAME}.res"
LOG_FILE="/var/log/messages"
SYSLOG_TAG="syslog logger"
SYSLOG_TOKEN="syslog_logger_test_$$"
SYSLOG_MESSAGE="syslog logger test info ${SYSLOG_TOKEN}"

write_early_fail() {
    echo "$LAVA_CASE_ID FAIL" > "$RES_FILE"
    echo "[FAIL] $1" >&2
    exit 0
}

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
    write_early_fail "Could not find init_env, starting at $SCRIPT_DIR"
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1

trap 'runner_finalize_interrupted_test 129' HUP
trap 'runner_finalize_interrupted_test 130' INT
trap 'runner_finalize_interrupted_test 143' TERM

fail_test() {
    test_result_record FAIL "$1"
    test_result_finish
    exit 0
}

if ! command -v logger >/dev/null 2>&1; then
    fail_test "logger command not found on the DUT"
fi

if ! command -v awk >/dev/null 2>&1; then
    fail_test "awk command not found on the DUT"
fi

log_info "Starting $TEST_NAME"
log_info "Writing a uniquely identifiable syslog message with tag '$SYSLOG_TAG'"

if ! logger -t "$SYSLOG_TAG" "$SYSLOG_MESSAGE"; then
    fail_test "logger command failed"
fi

log_info "Waiting up to 15 seconds for the message in $LOG_FILE"

FOUND=0
ATTEMPT=0
MATCHED_LINE=""

while [ "$ATTEMPT" -lt 15 ]; do
    if [ -r "$LOG_FILE" ]; then
        MATCHED_LINE=$(
            awk -v tag="$SYSLOG_TAG" -v token="$SYSLOG_TOKEN" \
                'index($0, tag) && index($0, token) { print; exit }' \
                "$LOG_FILE" 2>/dev/null
        )

        if [ -n "$MATCHED_LINE" ]; then
            FOUND=1
            break
        fi
    fi

    sleep 1
    ATTEMPT=$((ATTEMPT + 1))
done

if [ "$FOUND" -ne 1 ]; then
    if [ ! -e "$LOG_FILE" ]; then
        fail_test "$LOG_FILE was not created; check the image syslog configuration"
    fi

    if [ ! -r "$LOG_FILE" ]; then
        fail_test "$LOG_FILE is not readable; run the test with appropriate permissions"
    fi

    fail_test "The tagged test message was not found in $LOG_FILE within 15 seconds"
fi

log_info "Found matching log entry: $MATCHED_LINE"

test_result_record PASS "Tagged syslog message found in $LOG_FILE"
test_result_finish
