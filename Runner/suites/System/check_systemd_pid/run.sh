#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="check_systemd_pid"
LAVA_CASE_ID="check_systemd_pid"
RES_FILE="$SCRIPT_DIR/${TEST_NAME}.res"

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

log_info "Starting $TEST_NAME"
log_info "Checking whether systemd is the init process with PID 1"

if [ ! -r /proc/1/comm ]; then
    test_result_record FAIL "/proc/1/comm is unavailable or unreadable"
    test_result_finish
fi

INIT_NAME=""
IFS= read -r INIT_NAME < /proc/1/comm || {
    test_result_record FAIL "Could not read the process name for PID 1"
    test_result_finish
}

# Remove a possible carriage return from proc output.
INIT_NAME=$(printf '%s' "$INIT_NAME" | tr -d '\r')

log_info "PID 1 process name: $INIT_NAME"

if [ "$INIT_NAME" != "systemd" ]; then
    test_result_record FAIL "Expected systemd to be PID 1, found '${INIT_NAME:-empty}'"
    test_result_finish
fi

log_info "Verified systemd is running as PID 1"
test_result_record PASS "systemd init manager is PID 1"
test_result_finish
