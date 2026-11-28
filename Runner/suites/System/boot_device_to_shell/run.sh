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
TESTNAME="boot_device_to_shell"
LAVA_CASE_ID="boot_device_to_shell"
RES_FILE="$PWD/${TESTNAME}.res"
STATUS_LOG="$PWD/${TESTNAME}.systemctl.log"

test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1
runner_install_bounded_timeout_cleanup

if ! systemd_service_is_applicable; then
    test_result_finish SKIP "$SYSTEMD_SERVICE_APPLICABILITY_REASON"
fi

log_info "Starting $TESTNAME"
log_info "Checking the connected LAVA shell and systemd boot state"

if ! : > "$STATUS_LOG"; then
    test_result_finish FAIL "Could not create systemctl output log: $STATUS_LOG"
fi

BOUNDED_TIMEOUT_EXPIRED=0
run_with_bounded_timeout 5 systemctl is-system-running > "$STATUS_LOG" 2>&1
SYSTEMCTL_STATUS=$?
SYSTEMCTL_TIMED_OUT=${BOUNDED_TIMEOUT_EXPIRED:-0}
SYSTEM_STATE=$(cat "$STATUS_LOG")

log_info "systemctl is-system-running output: $SYSTEM_STATE (rc=$SYSTEMCTL_STATUS)"

if [ "$SYSTEMCTL_TIMED_OUT" -eq 1 ]; then
    test_result_finish FAIL "systemctl is-system-running exceeded its 5-second deadline"
fi

case "$SYSTEM_STATE:$SYSTEMCTL_STATUS" in
    running:0|degraded:1|starting:1)
        ;;
    running:*|degraded:*|starting:*)
        test_result_finish FAIL "systemctl is-system-running returned status $SYSTEMCTL_STATUS for state '$SYSTEM_STATE'"
        ;;
    *)
        test_result_finish FAIL "systemctl is-system-running failed with status $SYSTEMCTL_STATUS and state '${SYSTEM_STATE:-unknown}'"
        ;;
esac

test_result_record PASS "LAVA shell is connected; PID 1 is systemd and system state is $SYSTEM_STATE"
test_result_finish
