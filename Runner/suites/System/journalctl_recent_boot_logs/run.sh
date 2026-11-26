#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="journalctl_recent_boot_logs"
LAVA_CASE_ID="$TEST_NAME"
SERVICE_NAME="systemd-journald.service"
COMMAND_TIMEOUT=30
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

trap 'runner_finalize_interrupted_test 129' HUP
trap 'runner_finalize_interrupted_test 130' INT
trap 'runner_finalize_interrupted_test 143' TERM

fail_test() {
    test_result_record FAIL "$1"
    test_result_finish
    exit 0
}

log_file() {
    output_file="$1"

    while IFS= read -r line || [ -n "$line" ]; do
        log_info "$line"
    done < "$output_file"
}

run_bounded_command() {
    command_label="$1"
    output_file="$2"
    shift 2

    if ! : > "$output_file"; then
        fail_test "Could not create output file: $output_file"
    fi

    # The shared helper sets BOUNDED_TIMEOUT_EXPIRED when the deadline expires.
    BOUNDED_TIMEOUT_EXPIRED=0
    run_with_bounded_timeout "$COMMAND_TIMEOUT" "$@" > "$output_file" 2>&1
    command_status=$?
    command_timed_out=${BOUNDED_TIMEOUT_EXPIRED:-0}

    log_info "$command_label output:"
    log_file "$output_file"

    if [ "$command_timed_out" -eq 1 ]; then
        fail_test "$command_label exceeded its ${COMMAND_TIMEOUT}-second deadline"
    fi

    if [ "$command_status" -ne 0 ]; then
        fail_test "$command_label failed with status $command_status"
    fi
}

if ! command -v systemctl >/dev/null 2>&1; then
    fail_test "systemctl command not found on the DUT"
fi

if ! command -v journalctl >/dev/null 2>&1; then
    fail_test "journalctl command not found on the DUT"
fi

log_info "Starting $TEST_NAME"
log_info "Checking systemd-journald status and journal retrieval"

# Test step 1.
run_bounded_command \
    "systemctl status systemd-journald" \
    "$SCRIPT_DIR/systemd-journald-status.log" \
    systemctl status systemd-journald

# Test step 2.
run_bounded_command \
    "systemctl status systemd-journald.service" \
    "$SCRIPT_DIR/systemd-journald-service-status.log" \
    systemctl status "$SERVICE_NAME"

run_bounded_command \
    "systemctl show $SERVICE_NAME" \
    "$SCRIPT_DIR/systemd-journald-service-state.log" \
    systemctl show "$SERVICE_NAME" -p LoadState -p ActiveState -p SubState

SERVICE_LOAD_STATE=$(sed -n 's/^LoadState=//p' \
    "$SCRIPT_DIR/systemd-journald-service-state.log" | head -n 1)
SERVICE_ACTIVE_STATE=$(sed -n 's/^ActiveState=//p' \
    "$SCRIPT_DIR/systemd-journald-service-state.log" | head -n 1)

if [ "$SERVICE_LOAD_STATE" != loaded ]; then
    fail_test "$SERVICE_NAME is not loaded (LoadState=${SERVICE_LOAD_STATE:-missing})"
fi

if [ "$SERVICE_ACTIVE_STATE" != active ]; then
    fail_test "$SERVICE_NAME is not active (ActiveState=${SERVICE_ACTIVE_STATE:-missing})"
fi

log_info "$SERVICE_NAME is active"

# Test step 3. Limit the output while still retrieving recent boot logs.
run_bounded_command \
    "journalctl recent boot logs" \
    "$SCRIPT_DIR/journalctl.log" \
    journalctl --boot --no-pager --lines=50

if grep -Fq "No journal files were found" "$SCRIPT_DIR/journalctl.log"; then
    fail_test "journalctl reports that no journal files were found"
fi

if grep -Fq -- "-- No entries --" "$SCRIPT_DIR/journalctl.log"; then
    fail_test "journalctl returned no log entries for this boot"
fi

if [ ! -s "$SCRIPT_DIR/journalctl.log" ]; then
    fail_test "journalctl produced empty output"
fi

log_info "Journal output retained in $SCRIPT_DIR/journalctl.log"
log_info "Completed $TEST_NAME"

test_result_record PASS \
    "$SERVICE_NAME is active and journalctl successfully retrieved current-boot logs"
test_result_finish
exit 0
