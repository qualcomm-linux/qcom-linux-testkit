#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
    echo "[ERROR] Could not find init_env" >&2
    exit 1
fi

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"
# shellcheck disable=SC1090,SC1091
. "$TOOLS/kvm_common.sh"

TESTNAME="Kvm-Suspend"
if command -v find_test_case_by_name >/dev/null 2>&1; then
    test_path=$(find_test_case_by_name "$TESTNAME")
    cd "$test_path" || exit 1
else
    cd "$SCRIPT_DIR" || exit 1
fi

res_file="./$TESTNAME.res"
log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"

if virsh list --all | grep -q -w "$VM_NAME"; then
    log_info "Existing VM instance found. Cleaning up..."
    vm_clean
fi

if ! vm_define || ! vm_start; then
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

log_info "Suspending VM: $VM_NAME"

if ! virsh suspend "$VM_NAME"; then
    log_fail "Failed to issue suspend command."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

if check_vm_state "$VM_NAME" "paused"; then
    log_pass "VM successfully paused."
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "VM failed to enter 'paused' state."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

vm_clean