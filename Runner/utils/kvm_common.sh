#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
 
UTILS_DIR="$(cd "$(dirname "$0")" && pwd)"
SEARCH="$UTILS_DIR"
INIT_ENV=""

while [ "$SEARCH" != "/" ]; do
    if [ -f "$SEARCH/init_env" ]; then
        INIT_ENV="$SEARCH/init_env"
        break
    fi
    SEARCH=$(dirname "$SEARCH")
done

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] kvm_common.sh: Could not find init_env" >&2
    exit 1
fi

if [ -z "$__INIT_ENV_LOADED" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
fi

# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

export VM_NAME="hk-vm"
export XML_FILE="/var/gunyah/vm.xml"

vm_clean() {
    log_info "Cleaning up existing VM state for: $VM_NAME"
    
    if virsh list --all | grep -q "$VM_NAME"; then
        virsh destroy "$VM_NAME" > /dev/null 2>&1
        sleep 2
    fi
    
    if virsh list --all | grep -q "$VM_NAME"; then
        virsh undefine "$VM_NAME" > /dev/null 2>&1
    fi
}

vm_define() {
    log_info "Defining VM from XML: $XML_FILE"
    if [ ! -f "$XML_FILE" ]; then
        log_fail "XML File not found at $XML_FILE"
        return 1
    fi

    if ! virsh define "$XML_FILE"; then
        log_fail "Failed to define VM."
        return 1
    fi
    return 0
}

vm_start() {
    log_info "Starting VM: $VM_NAME"
    if ! virsh start "$VM_NAME"; then
        log_fail "Failed to start VM."
        return 1
    fi
    
    sleep 5
    return 0
}

check_vm_state() {
    target_vm="$1"
    expected_state="$2"
    
    log_info "Verifying VM state for '$target_vm'... Expecting: $expected_state"
    
    current_state=$(virsh domstate "$target_vm" 2>/dev/null | xargs)
    
    if [ "$current_state" = "$expected_state" ]; then
        log_info "SUCCESS: VM is in '$current_state' state."
        return 0
    else
        log_fail "FAIL: VM state mismatch. Expected '$expected_state', found '$current_state'."
        return 1
    fi
}