#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="check_openmp_lib"
LAVA_CASE_ID="check_openmp_lib"
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

log_info "Starting $TEST_NAME"
log_info "Checking for the OpenMP runtime library in /usr/lib"

RUNTIME_LIBRARY=""
for library_path in /usr/lib/libgomp.so.1 /usr/lib/libgomp.so; do
    log_info "Checking $library_path"
    if [ -f "$library_path" ]; then
        RUNTIME_LIBRARY="$library_path"
        break
    fi
done

if [ -z "$RUNTIME_LIBRARY" ]; then
    fail_test "No usable libgomp runtime library was found in /usr/lib"
fi

log_info "Verified OpenMP runtime library: $RUNTIME_LIBRARY"
if [ ! -f /usr/lib/libgomp.so ]; then
    log_info "/usr/lib/libgomp.so is absent; the unversioned linker symlink is not required at runtime"
fi

log_info "Completed $TEST_NAME"
test_result_record PASS "OpenMP runtime library is available at $RUNTIME_LIBRARY"
test_result_finish
