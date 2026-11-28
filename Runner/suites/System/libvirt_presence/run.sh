#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="libvirt_presence"
LAVA_CASE_ID="libvirt_presence"
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

REQUIRE_LIBVIRT=${REQUIRE_LIBVIRT:-false}
case "$REQUIRE_LIBVIRT" in
    true|TRUE|yes|YES|1)
        REQUIRE_LIBVIRT=true
        ;;
    false|FALSE|no|NO|0)
        REQUIRE_LIBVIRT=false
        ;;
    *)
        test_result_record FAIL "REQUIRE_LIBVIRT must be true or false"
        test_result_finish
        ;;
esac

trap 'runner_finalize_interrupted_test 129' HUP
trap 'runner_finalize_interrupted_test 130' INT
trap 'runner_finalize_interrupted_test 143' TERM

fail_test() {
    test_result_record FAIL "$1"
    test_result_finish
    exit 0
}

log_info "Starting $TEST_NAME"
log_info "Checking for the virsh libvirt client in PATH"

VIRSH_COMMAND=$(command -v virsh)
if [ -z "$VIRSH_COMMAND" ]; then
    if [ "$REQUIRE_LIBVIRT" = true ]; then
        fail_test "virsh is unavailable in PATH; libvirt is required on this DUT"
    fi

    test_result_record SKIP "virsh is unavailable in PATH; set REQUIRE_LIBVIRT=true when libvirt is required"
    test_result_finish
fi

VIRSH_OUTPUT="$SCRIPT_DIR/${TEST_NAME}.virsh-version.log"
if ! : > "$VIRSH_OUTPUT"; then
    fail_test "Could not create output file: $VIRSH_OUTPUT"
fi

BOUNDED_TIMEOUT_EXPIRED=0
run_with_bounded_timeout 5 "$VIRSH_COMMAND" --version > "$VIRSH_OUTPUT" 2>&1
VIRSH_STATUS=$?
if [ "${BOUNDED_TIMEOUT_EXPIRED:-0}" -eq 1 ]; then
    fail_test "virsh --version exceeded its 5-second deadline"
fi
if [ "$VIRSH_STATUS" -ne 0 ]; then
    fail_test "virsh --version failed with status $VIRSH_STATUS"
fi

while IFS= read -r output_line || [ -n "$output_line" ]; do
    log_info "$output_line"
done < "$VIRSH_OUTPUT"

test_result_record PASS "virsh is executable and reports its libvirt client version"
test_result_finish
