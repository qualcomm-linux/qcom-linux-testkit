#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="systemd_modules_load_service"
LAVA_CASE_ID="systemd_modules_load_service"
RES_FILE="$SCRIPT_DIR/${TEST_NAME}.res"
SERVICE_NAME="systemd-modules-load.service"
COMMAND_PREFIX="$SCRIPT_DIR/${TEST_NAME}.systemd"

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

cleanup_systemd_query() {
    bounded_timeout_cancel
}
# shellcheck disable=SC2034 # Consumed by test_result_finish.
TEST_RESULT_CLEANUP=cleanup_systemd_query

if ! command -v systemctl >/dev/null 2>&1; then
    test_result_record FAIL "systemctl command not found on the DUT"
    test_result_finish
fi

log_info "Starting $TEST_NAME"
log_info "Checking $SERVICE_NAME properties and capturing current-boot logs"

if ! systemd_unit_read_properties "$COMMAND_PREFIX" 5 \
    "Id,LoadState,ActiveState,SubState,Result,ExecMainStatus,Job" "$SERVICE_NAME"; then
    log_file_with_label SYSTEMD-UNIT-QUERY "$COMMAND_PREFIX.raw" 40
    test_result_record FAIL "Could not query $SERVICE_NAME properties (status=${SYSTEMD_UNIT_QUERY_STATUS:-unknown}, timeout=${SYSTEMD_UNIT_QUERY_TIMED_OUT:-unknown})"
    test_result_finish
fi

LOAD_STATE=$(systemd_unit_property_value "$COMMAND_PREFIX.raw" LoadState) || LOAD_STATE=""
if [ "$LOAD_STATE" != "loaded" ]; then
    test_result_record FAIL "$SERVICE_NAME is not loaded (LoadState=${LOAD_STATE:-unknown})"
    test_result_finish
fi

run_with_bounded_timeout 5 systemctl status "$SERVICE_NAME" --no-pager --full \
    >"$COMMAND_PREFIX.status.log" 2>&1
STATUS_QUERY_STATUS=$?
STATUS_OUTPUT=$(cat "$COMMAND_PREFIX.status.log" 2>/dev/null)
log_info "systemctl status output:"
log_info "$STATUS_OUTPUT"
if [ "$STATUS_QUERY_STATUS" -ne 0 ]; then
    log_info "systemctl status command did not complete successfully (status=$STATUS_QUERY_STATUS, timeout=${BOUNDED_TIMEOUT_EXPIRED:-0})"
fi

ACTIVE_STATE=$(systemd_unit_property_value "$COMMAND_PREFIX.raw" ActiveState) || ACTIVE_STATE=""
SUB_STATE=$(systemd_unit_property_value "$COMMAND_PREFIX.raw" SubState) || SUB_STATE=""
RESULT=$(systemd_unit_property_value "$COMMAND_PREFIX.raw" Result) || RESULT=""
EXEC_MAIN_STATUS=$(systemd_unit_property_value "$COMMAND_PREFIX.raw" ExecMainStatus) || EXEC_MAIN_STATUS=""
JOB=$(systemd_unit_property_value "$COMMAND_PREFIX.raw" Job) || JOB=""
# systemctl can expose an idle unit's Job property as an empty value.
JOB=${JOB:-0}

log_info "$SERVICE_NAME properties: ActiveState=${ACTIVE_STATE:-unknown}, SubState=${SUB_STATE:-unknown}, Result=${RESULT:-unknown}, ExecMainStatus=${EXEC_MAIN_STATUS:-unknown}"

if [ "$ACTIVE_STATE" != "active" ]; then
    test_result_record FAIL "$SERVICE_NAME is not active (ActiveState=${ACTIVE_STATE:-unknown})"
    test_result_finish
fi

if [ "$SUB_STATE" != "exited" ]; then
    test_result_record FAIL "$SERVICE_NAME is not in the expected exited state (SubState=${SUB_STATE:-unknown})"
    test_result_finish
fi

if [ "$RESULT" != "success" ]; then
    test_result_record FAIL "$SERVICE_NAME did not complete successfully (Result=${RESULT:-unknown})"
    test_result_finish
fi

if [ "$EXEC_MAIN_STATUS" != "0" ]; then
    test_result_record FAIL "$SERVICE_NAME has a nonzero or unavailable ExecMainStatus (${EXEC_MAIN_STATUS:-unknown})"
    test_result_finish
fi

if [ "$JOB" != "0" ]; then
    test_result_record FAIL "$SERVICE_NAME has a pending systemd job (Job=${JOB:-unknown})"
    test_result_finish
fi

if command -v journalctl >/dev/null 2>&1; then
    run_with_bounded_timeout 10 journalctl -b -u "$SERVICE_NAME" --no-pager \
        >"$COMMAND_PREFIX.journal.log" 2>&1
    JOURNAL_QUERY_STATUS=$?
    JOURNAL_OUTPUT=$(cat "$COMMAND_PREFIX.journal.log" 2>/dev/null)
    if [ "$JOURNAL_QUERY_STATUS" -ne 0 ]; then
        log_info "journalctl query did not complete successfully (status=$JOURNAL_QUERY_STATUS, timeout=${BOUNDED_TIMEOUT_EXPIRED:-0})"
    fi
else
    JOURNAL_OUTPUT=""
    log_info "journalctl not found; service properties remain the test verdict"
fi

log_info "Current-boot service journal:"
log_info "$JOURNAL_OUTPUT"

log_pass "$LAVA_CASE_ID: $SERVICE_NAME properties show a successful active (exited) result"
test_result_record PASS "$SERVICE_NAME is active (exited) with Result=success and ExecMainStatus=0"
test_result_finish
