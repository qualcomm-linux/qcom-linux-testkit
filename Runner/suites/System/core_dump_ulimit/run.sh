#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="core_dump_ulimit"
LAVA_CASE_ID="core_dump_ulimit"
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
}

log_info "Starting $TEST_NAME"
log_info "Checking the DUT shell core-dump size limit with ulimit -c"

# Linux /bin/sh implementations used by the DUT expose this shell builtin.
# shellcheck disable=SC3045
CORE_LIMIT=$(ulimit -c 2>&1)
ULIMIT_STATUS=$?

if [ "$ULIMIT_STATUS" -ne 0 ]; then
    log_info "ulimit output: $CORE_LIMIT"
    fail_test "Failed to read the core-dump size limit with ulimit -c"
fi

CORE_LIMIT=$(
    printf '%s\n' "$CORE_LIMIT" |
        tr -d '\r' |
        sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
)

log_info "ulimit -c output: $CORE_LIMIT"

if [ "$CORE_LIMIT" != "unlimited" ]; then
    fail_test "Expected core-dump size limit 'unlimited', got '$CORE_LIMIT'"
fi

log_info "Completed $TEST_NAME"
test_result_record PASS "Core-dump size limit is unlimited in the DUT test shell"
test_result_finish
