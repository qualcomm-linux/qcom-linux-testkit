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
}

get_unit_property() {
    property="$1"
    systemctl show "$SERVICE_NAME" "-p${property}" 2>/dev/null |
        sed -n "s/^${property}=//p" |
        head -n 1
}

if ! command -v systemctl >/dev/null 2>&1; then
    fail_test "systemctl command not found on the DUT"
fi

log_info "Starting $TEST_NAME"
log_info "Checking $SERVICE_NAME properties and capturing current-boot logs"

LOAD_STATE=$(get_unit_property LoadState)
if [ "$LOAD_STATE" != "loaded" ]; then
    fail_test "$SERVICE_NAME is not loaded (LoadState=${LOAD_STATE:-unknown})"
fi

STATUS_OUTPUT=$(systemctl status "$SERVICE_NAME" --no-pager --full 2>&1 || true)
log_info "systemctl status output:"
log_info "$STATUS_OUTPUT"

ACTIVE_STATE=$(get_unit_property ActiveState)
SUB_STATE=$(get_unit_property SubState)
RESULT=$(get_unit_property Result)
EXEC_MAIN_STATUS=$(get_unit_property ExecMainStatus)

log_info "$SERVICE_NAME properties: ActiveState=${ACTIVE_STATE:-unknown}, SubState=${SUB_STATE:-unknown}, Result=${RESULT:-unknown}, ExecMainStatus=${EXEC_MAIN_STATUS:-unknown}"

if [ "$ACTIVE_STATE" != "active" ]; then
    fail_test "$SERVICE_NAME is not active (ActiveState=${ACTIVE_STATE:-unknown})"
fi

if [ "$SUB_STATE" != "exited" ]; then
    fail_test "$SERVICE_NAME is not in the expected exited state (SubState=${SUB_STATE:-unknown})"
fi

if [ "$RESULT" != "success" ]; then
    fail_test "$SERVICE_NAME did not complete successfully (Result=${RESULT:-unknown})"
fi

if [ "$EXEC_MAIN_STATUS" != "0" ]; then
    fail_test "$SERVICE_NAME has a nonzero or unavailable ExecMainStatus (${EXEC_MAIN_STATUS:-unknown})"
fi

if command -v journalctl >/dev/null 2>&1; then
    JOURNAL_OUTPUT=$(journalctl -b -u "$SERVICE_NAME" --no-pager 2>&1 || true)
else
    JOURNAL_OUTPUT=""
    log_info "journalctl not found; service properties remain the test verdict"
fi

log_info "Current-boot service journal:"
log_info "$JOURNAL_OUTPUT"

log_pass "$LAVA_CASE_ID: $SERVICE_NAME properties show a successful active (exited) result"
test_result_record PASS "$SERVICE_NAME is active (exited) with Result=success and ExecMainStatus=0"
test_result_finish
