#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="check_esrt_mount_point"
LAVA_CASE_ID="check_esrt_mount_point"
RES_FILE="$SCRIPT_DIR/${TEST_NAME}.res"
ESRT_DIR="/sys/firmware/efi/esrt"

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
log_info "Checking ESRT directory: $ESRT_DIR"

if [ ! -d "$ESRT_DIR" ]; then
    test_result_record FAIL "$ESRT_DIR is missing or is not a directory"
    test_result_finish
fi

if ! command -v ls >/dev/null 2>&1; then
    test_result_record FAIL "ls command not found on the DUT"
    test_result_finish
fi

ESRT_LISTING=$(ls -la "$ESRT_DIR" 2>&1) || {
    log_info "ESRT listing error: $ESRT_LISTING"
    test_result_record FAIL "Could not list $ESRT_DIR"
    test_result_finish
}
log_info "ESRT directory listing:"
log_info "$ESRT_LISTING"

if [ ! -d "$ESRT_DIR/entries" ]; then
    test_result_record FAIL "Expected ESRT directory entry is missing or is not a directory: entries"
    test_result_finish
fi

for name in fw_resource_count fw_resource_count_max fw_resource_version; do
    if [ ! -f "$ESRT_DIR/$name" ]; then
        test_result_record FAIL "Expected ESRT attribute is missing or is not a file: $name"
        test_result_finish
    fi

    if [ ! -r "$ESRT_DIR/$name" ]; then
        test_result_record FAIL "ESRT attribute is not readable: $name"
        test_result_finish
    fi

    value=$(cat "$ESRT_DIR/$name" 2>/dev/null) || {
        test_result_record FAIL "Could not read ESRT attribute: $name"
        test_result_finish
    }
    log_info "$name: $value"
done

log_pass "$LAVA_CASE_ID: ESRT directory and required entries are present"
test_result_record PASS "ESRT directory contains entries, fw_resource_count, fw_resource_count_max, and fw_resource_version"
test_result_finish
