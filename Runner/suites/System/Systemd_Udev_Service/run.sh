#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TESTNAME="Systemd_Udev_Service"
LAVA_CASE_ID="udev_service_info"
RES_FILE="$SCRIPT_DIR/${TESTNAME}.res"

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
    echo "$LAVA_CASE_ID FAIL" > "$RES_FILE"
    exit 0
fi

if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

test_result_init "$LAVA_CASE_ID" "$RES_FILE" || exit 1

fail_test() {
    test_result_record FAIL "$1"
    test_result_finish
}

SERVICE_NAME="systemd-udevd.service"

if ! command -v systemctl >/dev/null 2>&1; then
    fail_test "systemctl command not found on the DUT"
fi

log_info "Starting ${TESTNAME}"
log_info "Checking that ${SERVICE_NAME} is active on the DUT"

if ! systemd_service_exists "$SERVICE_NAME"; then
    fail_test "${SERVICE_NAME} is not installed on the DUT"
fi

if ! systemd_service_is_active "$SERVICE_NAME"; then
    fail_test "${SERVICE_NAME} is not active"
fi

SERVICE_PID=$(systemctl show "$SERVICE_NAME" -p MainPID 2>/dev/null |
    sed -n 's/^MainPID=//p' | head -n 1)

case "$SERVICE_PID" in
    ''|*[!0-9]*|0)
        fail_test "Could not determine the main PID for ${SERVICE_NAME}"
        ;;
esac

SERVICE_UID=$(awk '$1 == "Uid:" { print $3; exit }' "/proc/$SERVICE_PID/status" 2>/dev/null)
if [ "$SERVICE_UID" != "0" ]; then
    fail_test "${SERVICE_NAME} main PID $SERVICE_PID is not root-owned (effective UID=${SERVICE_UID:-unknown})"
fi

log_info "${SERVICE_NAME} main PID is $SERVICE_PID (effective UID 0)"
log_info "Completed ${TESTNAME}"
test_result_record PASS "${SERVICE_NAME} is active with a root-owned main process"
test_result_finish
