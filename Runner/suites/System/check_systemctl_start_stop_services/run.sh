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
COMMAND_TIMEOUT=30
STATE_PREFIX="$SCRIPT_DIR/${TEST_NAME}.state"

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
SERVICE_RESTORE_REQUIRED=0

read_service_unit() {
    service_output_prefix="$1"
    shift
    systemd_unit_read_properties "$service_output_prefix" 5 \
        "Id,ActiveState,SubState,Result,Job,LoadState" "$@"
}

cleanup_service_state() {
    if ! bounded_timeout_cancel; then
        log_fail "Cannot safely restore $SERVICE_NAME because its command did not stop"
        return 1
    fi

    [ "${SERVICE_RESTORE_REQUIRED:-0}" -eq 1 ] || return 0

    if systemd_unit_restore_active "$STATE_PREFIX" "$COMMAND_TIMEOUT" \
        read_service_unit "$SERVICE_NAME"; then
        SERVICE_RESTORE_REQUIRED=0
        log_info "$SERVICE_NAME is active/running with no pending job after cleanup"
        return 0
    fi
    log_fail "Could not restore $SERVICE_NAME to active/running with no pending job"
    log_file_with_label SYSTEMD-UNIT-JOB "$STATE_PREFIX.current" 32
    return 1
}

handle_signal() {
    signal_name="$1"
    trap '' HUP INT TERM

    test_result_finish FAIL "Test interrupted by $signal_name"
}

trap 'handle_signal HUP' HUP
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

if ! command -v systemctl >/dev/null 2>&1; then
    test_result_record FAIL "systemctl command not found on the DUT"
    test_result_finish
fi

log_info "Starting $TEST_NAME"
log_info "Testing stop/start behavior for $SERVICE_NAME locally on the DUT"

if ! read_service_unit "$STATE_PREFIX.initial" "$SERVICE_NAME"; then
    log_file_with_label SYSTEMD-UNIT-QUERY "$STATE_PREFIX.initial.raw" 40
    test_result_record FAIL "Could not query the initial state of $SERVICE_NAME (status=${SYSTEMD_UNIT_QUERY_STATUS:-unknown}, timeout=${SYSTEMD_UNIT_QUERY_TIMED_OUT:-unknown})"
    test_result_finish
fi

INITIAL_LOAD_STATE=$(systemd_unit_property_value "$STATE_PREFIX.initial.raw" LoadState) || INITIAL_LOAD_STATE=""
if [ "$INITIAL_LOAD_STATE" != "loaded" ]; then
    test_result_record FAIL "$SERVICE_NAME is not installed on the DUT (LoadState=${INITIAL_LOAD_STATE:-unknown})"
    test_result_finish
fi

if ! systemd_unit_rows_match_state "$STATE_PREFIX.initial" active running "$SERVICE_NAME"; then
    log_file_with_label SYSTEMD-UNIT-STATE "$STATE_PREFIX.initial.raw" 40
    test_result_record FAIL "$SERVICE_NAME was not active/running with no pending job before the test"
    test_result_finish
fi

# Shared result finalization invokes this hook on pass, failure, or signal.
SERVICE_RESTORE_REQUIRED=1
# shellcheck disable=SC2034 # Consumed by test_result_finish.
TEST_RESULT_CLEANUP=cleanup_service_state

log_info "Stopping $SERVICE_NAME"
if ! systemd_unit_transition "$STATE_PREFIX" "$COMMAND_TIMEOUT" \
    read_service_unit stop dead "$SERVICE_NAME"; then
    test_result_record FAIL "Could not stop $SERVICE_NAME and verify inactive/dead with no pending job"
    test_result_finish
fi

log_info "Starting $SERVICE_NAME"
if ! systemd_unit_transition "$STATE_PREFIX" "$COMMAND_TIMEOUT" \
    read_service_unit start running "$SERVICE_NAME"; then
    test_result_record FAIL "Could not start $SERVICE_NAME and verify active/running with no pending job"
    test_result_finish
fi

log_info "$SERVICE_NAME stop/start behavior verified"
test_result_record PASS "$SERVICE_NAME was active, stopped, and restarted successfully"
test_result_finish
