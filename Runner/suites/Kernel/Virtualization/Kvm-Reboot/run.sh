#!/bin/bash

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause-Clear

# Robustly find and source init_env
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEARCH_PATH="$SCRIPT_DIR"
LIB_PATH=""
while [ "$SEARCH_PATH" != "/" ]; do
    if [ -f "$SEARCH_PATH/utils/kvm_common.sh" ]; then
        LIB_PATH="$SEARCH_PATH/utils/kvm_common.sh"
        break
    fi
    SEARCH_PATH=$(dirname "$SEARCH_PATH")
done

if [ -f "$LIB_PATH" ]; then
    # shellcheck disable=SC1090
    . "$LIB_PATH"
else
    echo "[ERROR] Lib not found"
    exit 1
fi

TESTNAME="Kvm-Reboot"
RES_FILE="${TESTNAME}.res"
rm -f "$RES_FILE"

# Clean up old stdout logs from previous runs
rm -f *_stdout_*.log

log_info "----------- KVM Reboot -----------"

if virsh list --all | grep -q -w "$VM_NAME"; then
    log_info "Existing VM instance found. Cleaning up..."
    vm_clean
fi

vm_define && vm_start
if [ $? -ne 0 ]; then echo "$TESTNAME FAIL" > "$RES_FILE"; exit 1; fi

# Test: Reboot
log_info "Rebooting $VM_NAME"
virsh reboot "$VM_NAME"
sleep 5

# Verify Running
check_vm_state "$VM_NAME" "running"
if [ $? -eq 0 ]; then
    log_pass "VM rebooted successfully."
    echo "$TESTNAME PASS" > "$RES_FILE"
else
    log_fail "VM not running after reboot."
    echo "$TESTNAME FAIL" > "$RES_FILE"
fi

# Cleanup
vm_clean