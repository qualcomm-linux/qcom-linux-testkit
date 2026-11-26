#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="systemctl_start_stop_service"
LAVA_CASE_ID="$TEST_NAME"
COMMAND_TIMEOUT=30
STATE_RETRIES=15
RES_FILE="$SCRIPT_DIR/${TEST_NAME}.res"

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

TEST_UNIT_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
[ -n "$TEST_UNIT_ID" ] || TEST_UNIT_ID=$$
TEST_UNIT="qcom-linux-testkit-lifecycle-${TEST_UNIT_ID}.service"
SERVICE_CREATED=0
# shellcheck disable=SC2034  # test_result_finish invokes this named callback.
TEST_RESULT_CLEANUP=cleanup_test_service

trap 'runner_finalize_interrupted_test 129' HUP
trap 'runner_finalize_interrupted_test 130' INT
trap 'runner_finalize_interrupted_test 143' TERM

fail_test() {
    test_result_record FAIL "$1"
    test_result_finish
}

run_bounded_command() {
    command_label="$1"
    output_file="$2"
    shift 2

    if ! : > "$output_file"; then
        log_error "Could not create output file: $output_file"
        return 1
    fi

    BOUNDED_TIMEOUT_EXPIRED=0
    run_with_bounded_timeout "$COMMAND_TIMEOUT" "$@" > "$output_file" 2>&1
    LAST_COMMAND_STATUS=$?
    LAST_COMMAND_TIMED_OUT=${BOUNDED_TIMEOUT_EXPIRED:-0}

    log_info "$command_label output retained in $output_file (status=$LAST_COMMAND_STATUS)"
    while IFS= read -r output_line || [ -n "$output_line" ]; do
        log_info "$output_line"
    done < "$output_file"

    if [ "$LAST_COMMAND_TIMED_OUT" -eq 1 ]; then
        log_error "$command_label exceeded its ${COMMAND_TIMEOUT}-second deadline"
        return 1
    fi

    if [ "$LAST_COMMAND_STATUS" -ne 0 ]; then
        log_error "$command_label failed with status $LAST_COMMAND_STATUS"
        return 1
    fi

    return 0
}

query_unit_state() {
    query_unit="$1"
    query_output="$SCRIPT_DIR/${TEST_NAME}.${query_unit}.show.log"

    run_bounded_command \
        "systemctl show $query_unit" \
        "$query_output" \
        systemctl show "$query_unit" -p LoadState -p ActiveState -p SubState -p Result || return 1

    UNIT_LOAD_STATE=$(sed -n 's/^LoadState=//p' "$query_output" | head -n 1)
    UNIT_ACTIVE_STATE=$(sed -n 's/^ActiveState=//p' "$query_output" | head -n 1)
    [ -n "$UNIT_LOAD_STATE" ] && [ -n "$UNIT_ACTIVE_STATE" ]
}

wait_for_unit_state() {
    wait_unit="$1"
    wait_expected="$2"
    wait_attempt=0

    while [ "$wait_attempt" -lt "$STATE_RETRIES" ]; do
        if ! query_unit_state "$wait_unit"; then
            return 1
        fi

        case "$wait_expected:$UNIT_ACTIVE_STATE" in
            active:active)
                return 0
                ;;
            stopped:inactive|stopped:failed)
                return 0
                ;;
        esac

        sleep 1
        wait_attempt=$((wait_attempt + 1))
    done

    return 1
}

cleanup_test_service() {
    [ "$SERVICE_CREATED" -eq 1 ] || return 0

    log_info "Stopping test-owned unit $TEST_UNIT during cleanup"
    cleanup_log="$SCRIPT_DIR/${TEST_NAME}.cleanup.log"
    if ! run_bounded_command \
        "systemctl stop $TEST_UNIT (cleanup)" \
        "$cleanup_log" \
        systemctl stop "$TEST_UNIT"; then
        return 1
    fi

    if ! wait_for_unit_state "$TEST_UNIT" stopped; then
        log_error "$TEST_UNIT did not stop during cleanup"
        return 1
    fi

    SERVICE_CREATED=0
    return 0
}

if ! command -v systemctl >/dev/null 2>&1; then
    fail_test "systemctl command not found on the DUT"
fi

if ! command -v systemd-run >/dev/null 2>&1; then
    fail_test "systemd-run command not found on the DUT"
fi

SLEEP_COMMAND=$(command -v sleep)
if [ -z "$SLEEP_COMMAND" ]; then
    fail_test "sleep command not found on the DUT"
fi

log_info "Starting $TEST_NAME"
log_info "Testing bounded stop/start behavior for an isolated transient systemd service"

service_log="$SCRIPT_DIR/${TEST_NAME}.systemd-run.log"
SERVICE_CREATED=1
if ! run_bounded_command \
    "systemd-run $TEST_UNIT" \
    "$service_log" \
    systemd-run --unit="$TEST_UNIT" --property=Type=simple "$SLEEP_COMMAND" 300; then
    fail_test "Could not create the test-owned transient service $TEST_UNIT"
fi

if ! wait_for_unit_state "$TEST_UNIT" active; then
    fail_test "$TEST_UNIT did not become active after creation"
fi

stop_log="$SCRIPT_DIR/${TEST_NAME}.stop.log"
if ! run_bounded_command \
    "systemctl stop $TEST_UNIT" \
    "$stop_log" \
    systemctl stop "$TEST_UNIT"; then
    fail_test "Could not stop the test-owned service $TEST_UNIT"
fi

if ! wait_for_unit_state "$TEST_UNIT" stopped; then
    fail_test "$TEST_UNIT did not reach inactive or failed after stop"
fi

start_log="$SCRIPT_DIR/${TEST_NAME}.start.log"
if ! run_bounded_command \
    "systemctl start $TEST_UNIT" \
    "$start_log" \
    systemctl start "$TEST_UNIT"; then
    fail_test "Could not restart the test-owned service $TEST_UNIT"
fi

if ! wait_for_unit_state "$TEST_UNIT" active; then
    fail_test "$TEST_UNIT did not become active after restart"
fi

log_pass "$TEST_UNIT passed its stop/start state checks"

log_info "Completed $TEST_NAME"
test_result_record PASS "systemctl stopped and restarted an isolated transient service successfully"
test_result_finish
