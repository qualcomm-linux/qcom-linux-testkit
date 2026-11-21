#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="adsprpcd_service"
LAVA_CASE_ID="adsprpcd_service"
SERVICE_NAME="adsprpcd.service"
RES_FILE="$SCRIPT_DIR/${TEST_NAME}.res"
COMMAND_LOG="$SCRIPT_DIR/${TEST_NAME}.command.log"
COMMAND_TIMEOUT=30

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
rm -f "$COMMAND_LOG"
SERVICE_RESTORE_REQUIRED=0
SERVICE_CLEANUP_CANCEL_FAILED=0

fail_test() {
    test_result_record FAIL "$1"
    test_result_finish
    exit 0
}

run_bounded() {
    BOUNDED_TIMEOUT_EXPIRED=0

    run_with_bounded_timeout "$COMMAND_TIMEOUT" "$@" \
        > "$COMMAND_LOG" 2>&1
    COMMAND_STATUS=$?
    COMMAND_TIMED_OUT=${BOUNDED_TIMEOUT_EXPIRED:-0}
    COMMAND_OUTPUT=$(cat "$COMMAND_LOG" 2>/dev/null)
}

check_state() {
    expected_active="$1"
    expected_sub="$2"
    phase="$3"

    run_bounded systemctl show "$SERVICE_NAME" \
        --property=ActiveState --property=SubState

    if [ "$COMMAND_TIMED_OUT" -eq 1 ]; then
        log_info "$phase: systemctl show timed out"
        return 2
    fi

    if [ "$COMMAND_STATUS" -ne 0 ]; then
        log_info "systemctl show output: $COMMAND_OUTPUT"
        log_info "$phase: unable to query $SERVICE_NAME state"
        return 2
    fi

    ACTIVE_STATE=$(printf '%s\n' "$COMMAND_OUTPUT" |
        sed -n 's/^ActiveState=//p' | head -n 1)
    SUB_STATE=$(printf '%s\n' "$COMMAND_OUTPUT" |
        sed -n 's/^SubState=//p' | head -n 1)

    log_info "$phase state: ActiveState=${ACTIVE_STATE:-unknown}, SubState=${SUB_STATE:-unknown}"

    if [ "$ACTIVE_STATE" != "$expected_active" ] ||
        [ "$SUB_STATE" != "$expected_sub" ]; then
        return 1
    fi

    return 0
}

cleanup_service_state() {
    if [ "${SERVICE_CLEANUP_CANCEL_FAILED:-0}" -eq 1 ]; then
        log_fail "Cannot safely restore $SERVICE_NAME because the interrupted command is still running"
        return 1
    fi

    if ! bounded_timeout_cancel; then
        log_fail "Cannot safely restore $SERVICE_NAME because its command did not stop"
        return 1
    fi

    [ "${SERVICE_RESTORE_REQUIRED:-0}" -eq 1 ] || return 0

    check_state active running "Cleanup verification"
    cleanup_state_status=$?
    if [ "$cleanup_state_status" -eq 0 ]; then
        SERVICE_RESTORE_REQUIRED=0
        log_info "$SERVICE_NAME is active/running after cleanup"
        return 0
    fi

    log_info "Attempting to restore $SERVICE_NAME"
    run_bounded systemctl start "$SERVICE_NAME"
    if [ "$COMMAND_TIMED_OUT" -eq 1 ]; then
        log_fail "Recovery start for $SERVICE_NAME timed out"
        return 1
    fi
    if [ "$COMMAND_STATUS" -ne 0 ]; then
        log_fail "Recovery start for $SERVICE_NAME failed: $COMMAND_OUTPUT"
        return 1
    fi

    check_state active running "Recovery verification"
    cleanup_state_status=$?
    if [ "$cleanup_state_status" -ne 0 ]; then
        log_fail "$SERVICE_NAME was not active/running after recovery (state check=$cleanup_state_status)"
        return 1
    fi

    SERVICE_RESTORE_REQUIRED=0
    log_info "Verified $SERVICE_NAME is active/running after recovery"
    return 0
}

handle_signal() {
    signal_name="$1"
    trap '' HUP INT TERM

    if ! bounded_timeout_cancel; then
        SERVICE_CLEANUP_CANCEL_FAILED=1
        log_fail "Could not stop the running command before service cleanup"
    fi

    test_result_finish FAIL "Test interrupted by $signal_name"
    exit 0
}

trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

if ! command -v systemctl >/dev/null 2>&1; then
    fail_test "systemctl command not found on the DUT"
fi

if ! systemd_service_exists "$SERVICE_NAME"; then
    fail_test "$SERVICE_NAME is not installed on the DUT"
fi

log_info "Starting $TEST_NAME"
log_info "Testing stop/start behavior for $SERVICE_NAME locally on the DUT"

check_state active running "Initial check"
STATE_STATUS=$?
if [ "$STATE_STATUS" -eq 2 ]; then
    fail_test "Could not query the initial state of $SERVICE_NAME"
fi
if [ "$STATE_STATUS" -ne 0 ]; then
    fail_test "$SERVICE_NAME was not active and running before the test"
fi

if ! systemd_service_is_active "$SERVICE_NAME"; then
    fail_test "$SERVICE_NAME is not active before the test"
fi

# Shared result finalization invokes this hook on pass, failure, or signal.
SERVICE_RESTORE_REQUIRED=1
# shellcheck disable=SC2034 # Consumed by test_result_finish.
TEST_RESULT_CLEANUP=cleanup_service_state

log_info "Stopping $SERVICE_NAME"
run_bounded systemctl stop "$SERVICE_NAME"

if [ "$COMMAND_TIMED_OUT" -eq 1 ]; then
    fail_test "systemctl stop $SERVICE_NAME timed out"
fi

if [ "$COMMAND_STATUS" -ne 0 ]; then
    log_info "systemctl stop output: $COMMAND_OUTPUT"
    fail_test "systemctl stop $SERVICE_NAME failed"
fi

check_state inactive dead "After stop"
STATE_STATUS=$?
if [ "$STATE_STATUS" -eq 2 ]; then
    fail_test "Could not query $SERVICE_NAME state after stop"
fi
if [ "$STATE_STATUS" -ne 0 ]; then
    fail_test "$SERVICE_NAME did not reach inactive/dead after stop"
fi

log_info "Starting $SERVICE_NAME"
run_bounded systemctl start "$SERVICE_NAME"

if [ "$COMMAND_TIMED_OUT" -eq 1 ]; then
    fail_test "systemctl start $SERVICE_NAME timed out"
fi

if [ "$COMMAND_STATUS" -ne 0 ]; then
    log_info "systemctl start output: $COMMAND_OUTPUT"
    fail_test "systemctl start $SERVICE_NAME failed"
fi

check_state active running "After start"
STATE_STATUS=$?
if [ "$STATE_STATUS" -eq 2 ]; then
    fail_test "Could not query $SERVICE_NAME state after start"
fi
if [ "$STATE_STATUS" -ne 0 ]; then
    fail_test "$SERVICE_NAME did not return to active/running after start"
fi

if ! systemd_service_is_active "$SERVICE_NAME"; then
    fail_test "$SERVICE_NAME is not active after start"
fi

log_info "$SERVICE_NAME stop/start behavior verified"
test_result_record PASS "$SERVICE_NAME was active, stopped, and restarted successfully"
test_result_finish
