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

TESTNAME="Kvm-Reboot"
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

# Fixes SC2181: Evaluating commands directly instead of checking $?
if ! vm_define || ! vm_start; then
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi

# Test: Reboot
log_info "Rebooting $VM_NAME"
if ! virsh reboot "$VM_NAME"; then
    log_fail "Failed to issue reboot command."
    echo "$TESTNAME FAIL" > "$res_file"
    exit 1
fi
sleep 5

# Verify Running (Fixes SC2181: Evaluating command directly)
if check_vm_state "$VM_NAME" "running"; then
    log_pass "VM rebooted successfully."
    echo "$TESTNAME PASS" > "$res_file"
else
    log_fail "VM not running after reboot."
    echo "$TESTNAME FAIL" > "$res_file"
fi

# Cleanup
vm_clean