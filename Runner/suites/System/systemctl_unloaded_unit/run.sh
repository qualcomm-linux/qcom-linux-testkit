#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(CDPATH='' cd "$(dirname "$0")" && pwd)" || exit 1

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
    echo "[ERROR] Could not find init_env, starting at $SCRIPT_DIR" >&2
    exit 1
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"
TESTNAME="systemctl_unloaded_unit"
LAVA_CASE_ID="systemctl_unloaded_unit"
RES_FILE="$PWD/${TESTNAME}.res"
STATUS_LOG="$PWD/${TESTNAME}.systemctl.log"
UNIT_NAME="qcom-linux-testkit-unloaded-unit-test.service"

test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1
runner_install_bounded_timeout_cleanup

if ! systemd_service_is_applicable; then
    test_result_finish SKIP "$SYSTEMD_SERVICE_APPLICABILITY_REASON"
fi

log_info "Checking that the test-owned unit name $UNIT_NAME is not installed"
systemd_service_show "$UNIT_NAME" "$STATUS_LOG" 5 --property=LoadState
SYSTEMCTL_STATUS=$SYSTEMD_SERVICE_SHOW_STATUS
SYSTEMCTL_TIMED_OUT=$SYSTEMD_SERVICE_SHOW_TIMED_OUT

log_info "systemctl show output retained in $STATUS_LOG:"
while IFS= read -r line || [ -n "$line" ]; do
    log_info "$line"
done < "$STATUS_LOG"

if [ "$SYSTEMCTL_TIMED_OUT" -eq 1 ]; then
    test_result_finish FAIL "systemctl show exceeded its 5-second deadline"
fi

if [ "$SYSTEMCTL_STATUS" -ne 0 ]; then
    test_result_finish FAIL "systemctl show failed for $UNIT_NAME (rc=$SYSTEMCTL_STATUS)"
fi

if [ "$SYSTEMD_SERVICE_LOAD_STATE" = not-found ]; then
    test_result_record PASS "$UNIT_NAME has LoadState=not-found"
    test_result_finish
fi

test_result_finish FAIL "$UNIT_NAME unexpectedly has LoadState='${SYSTEMD_SERVICE_LOAD_STATE:-missing}', expected not-found"
