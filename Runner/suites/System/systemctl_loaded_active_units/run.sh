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
TESTNAME="systemctl_loaded_active_units"
LAVA_CASE_ID="systemd_journald_loaded_active"
RES_FILE="$PWD/${TESTNAME}.res"
STATUS_LOG="$PWD/${TESTNAME}.systemctl.log"
SERVICE_NAME="systemd-journald.service"

test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1
runner_install_bounded_timeout_cleanup

if ! systemd_service_is_applicable; then
    test_result_finish SKIP "$SYSTEMD_SERVICE_APPLICABILITY_REASON"
fi

log_info "Checking $SERVICE_NAME is loaded and active (running)"
systemd_service_show "$SERVICE_NAME" "$STATUS_LOG" 5
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
    test_result_finish FAIL "systemctl show failed for $SERVICE_NAME (rc=$SYSTEMCTL_STATUS)"
fi

if [ "$SYSTEMD_SERVICE_LOAD_STATE" = not-found ] ||
   [ "$SYSTEMD_SERVICE_LOAD_STATE" = masked ]; then
    test_result_finish SKIP "$SERVICE_NAME is unavailable in this systemd image (LoadState=$SYSTEMD_SERVICE_LOAD_STATE)"
fi

if [ "$SYSTEMD_SERVICE_LOAD_STATE" != loaded ]; then
    test_result_finish FAIL "$SERVICE_NAME LoadState is '${SYSTEMD_SERVICE_LOAD_STATE:-unknown}', expected 'loaded'"
fi

if [ "$SYSTEMD_SERVICE_ACTIVE_STATE" != active ] ||
   [ "$SYSTEMD_SERVICE_SUB_STATE" != running ]; then
    test_result_finish FAIL "$SERVICE_NAME state is '${SYSTEMD_SERVICE_ACTIVE_STATE:-unknown} (${SYSTEMD_SERVICE_SUB_STATE:-unknown})', expected 'active (running)'"
fi

test_result_record PASS "$SERVICE_NAME is loaded and active (running)"
test_result_finish
