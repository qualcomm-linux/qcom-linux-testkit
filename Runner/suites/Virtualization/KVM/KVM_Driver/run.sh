#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause
# ---------- Repo env + helpers ----------
SCRIPT_DIR="$(
  cd "$(dirname "$0")" || exit 1
  pwd
)"
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
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    exit 1
fi

# Only source once (idempotent)
# NOTE: We intentionally **do not export** any new vars. They stay local to this shell.
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# shellcheck disable=SC1090
. "$INIT_ENV"
# shellcheck disable=SC1091
. "$TOOLS/functestlib.sh"

# shellcheck disable=SC1091
. "$TOOLS/lib_kvm.sh"

TESTNAME="KVM_Driver"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    log_skip "$TESTNAME SKIP - test path not found"
    test_result_finish SKIP
fi

if ! cd "$test_path"; then
    log_skip "$TESTNAME SKIP - cannot cd into $test_path"
    test_result_finish SKIP
fi

RESULT_DIR="./results/$TESTNAME"
DMESG_DIR="$RESULT_DIR/dmesg"

mkdir -p "$DMESG_DIR" 2>/dev/null || true

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

deps_list="cat grep awk sed tr mkdir uname"
log_info "Checking dependencies: $deps_list"
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! check_dependencies "$deps_list"; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies: $deps_list"
    test_result_finish SKIP
fi

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform >/dev/null 2>&1 || true
    log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='${PLATFORM_KERNEL:-}' arch='${PLATFORM_ARCH:-}'"
else
    log_info "Platform Details: kernel='$(uname -r 2>/dev/null || echo unknown)' arch='$(uname -m 2>/dev/null || echo unknown)'"
fi

if ! kvm_log_readiness "$DMESG_DIR"; then
    test_result_finish FAIL
fi

log_info "=== KVM Kernel Config Validation ==="

mandatory_cfg_missing=0

for cfg in CONFIG_VIRTUALIZATION CONFIG_KVM; do
    if ! check_kernel_config "$cfg"; then
        mandatory_cfg_missing=1
    fi
done

if [ "$mandatory_cfg_missing" -ne 0 ]; then
    log_fail "$TESTNAME FAIL - mandatory KVM kernel config is missing"
    test_result_finish FAIL
fi

# Optional configs: log only, do not gate test result.
for cfg in \
    CONFIG_HAVE_KVM \
    CONFIG_HAVE_KVM_IRQCHIP \
    CONFIG_HAVE_KVM_IRQFD \
    CONFIG_KVM_ARM_PMU \
    CONFIG_KVM_GENERIC_DIRTYLOG_READ_PROTECT
do
    kvm_log_optional_kernel_config "$cfg" || true
done

log_info "=== KVM Device Node Validation ==="
kvm_check_device_node
dev_rc=$?

if [ "$dev_rc" -eq 2 ]; then
    log_fail "$TESTNAME FAIL - /dev/kvm is not available"
    test_result_finish FAIL
fi

if [ "$dev_rc" -ne 0 ]; then
    log_fail "$TESTNAME FAIL - /dev/kvm node validation failed"
    test_result_finish FAIL
fi

log_info "=== KVM ioctl API Validation ==="
kvm_check_api_version
api_rc=$?

if [ "$api_rc" -eq 2 ]; then
    log_skip "$TESTNAME SKIP - KVM API helper dependency is not available"
    test_result_finish SKIP
fi

if [ "$api_rc" -ne 0 ]; then
    log_fail "$TESTNAME FAIL - KVM ioctl API validation failed"
    test_result_finish FAIL
fi

log_info "=== KVM Driver Dmesg Advisory Scan ==="
if ! kvm_check_boot_dmesg_errors "$DMESG_DIR"; then
    log_warn "$TESTNAME WARN - KVM/EL2 dmesg issues detected; not failing due to possible CI dmesg flooding"
fi
 
log_pass "$TESTNAME PASS - KVM kernel config, /dev/kvm, and ioctl API are valid"
test_result_finish PASS

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
