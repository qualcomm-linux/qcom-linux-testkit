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

# Define Test Metadata
TESTNAME="Kvm-Setup"
RES_FILE="${TESTNAME}.res"

# Clean up old stdout logs from previous runs
rm -f *_stdout_*.log

# Execution
log_info "----------- KVM Setup: Define and Start -----------"

# Clean up any existing result file
rm -f "$RES_FILE"

# Define VM
if virsh list --all | grep -q -w "$VM_NAME"; then
    log_info "Existing VM instance found. Cleaning up..."
    vm_clean
fi

# 2. Define
vm_define
if [ $? -ne 0 ]; then echo "$TESTNAME FAIL" > "$RES_FILE"; exit 1; fi

# 3. Start
vm_start
if [ $? -ne 0 ]; then echo "$TESTNAME FAIL" > "$RES_FILE"; exit 1; fi

# 4. Verify
check_vm_state "$VM_NAME" "running"
if [ $? -eq 0 ]; then
    log_pass "VM is running."
    echo "$TESTNAME PASS" > "$RES_FILE"
else
    log_fail "VM failed to reach 'running' state."
    echo "$TESTNAME FAIL" > "$RES_FILE"
    exit 1
fi