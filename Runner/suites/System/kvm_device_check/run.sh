#!/bin/sh
# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(
    cd "$(dirname "$0")" || exit 1
    pwd
)"

TEST_NAME="kvm_device_check"
LAVA_CASE_ID="kvm_device_check"
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

REQUIRE_KVM=${REQUIRE_KVM:-false}
case "$REQUIRE_KVM" in
    true|TRUE|yes|YES|1)
        REQUIRE_KVM=true
        ;;
    false|FALSE|no|NO|0)
        REQUIRE_KVM=false
        ;;
    *)
        test_result_record FAIL "REQUIRE_KVM must be true or false"
        test_result_finish
        ;;
esac

trap 'runner_finalize_interrupted_test 129' HUP
trap 'runner_finalize_interrupted_test 130' INT
trap 'runner_finalize_interrupted_test 143' TERM

fail_test() {
    test_result_record FAIL "$1"
    test_result_finish
}

log_info "Starting $TEST_NAME"
log_info "Checking for the KVM device node at /dev/kvm"

if [ ! -e /dev/kvm ]; then
    if [ "$REQUIRE_KVM" = true ]; then
        fail_test "/dev/kvm does not exist; KVM is required but not exposed on this DUT"
    fi

    test_result_record SKIP "/dev/kvm is not exposed on this DUT; set REQUIRE_KVM=true when KVM is required"
    test_result_finish
fi

if [ ! -c /dev/kvm ]; then
    fail_test "/dev/kvm exists but is not a character device"
fi

log_info "/dev/kvm exists and is a character device"
test_result_record PASS "/dev/kvm is present as a character device"
test_result_finish
