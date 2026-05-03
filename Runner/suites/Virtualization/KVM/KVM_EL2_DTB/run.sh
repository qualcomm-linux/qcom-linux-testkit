#!/bin/sh

# Copyright (c) Qualcomm Technologies, Inc. and/or its subsidiaries.
# SPDX-License-Identifier: BSD-3-Clause

TESTNAME="KVM_EL2_DTB"

# Robustly find and source init_env
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

RES_FALLBACK="$SCRIPT_DIR/${TESTNAME}.res"

if [ -z "$INIT_ENV" ]; then
    echo "[ERROR] Could not find init_env (starting at $SCRIPT_DIR)" >&2
    echo "$TESTNAME SKIP" >"$RES_FALLBACK" 2>/dev/null || true
    exit 0
fi

# Only source if not already loaded (idempotent)
if [ -z "${__INIT_ENV_LOADED:-}" ]; then
    # shellcheck disable=SC1090
    . "$INIT_ENV"
    __INIT_ENV_LOADED=1
fi

# Always source functestlib.sh, using $TOOLS exported by init_env
# shellcheck disable=SC1090,SC1091
. "$TOOLS/functestlib.sh"

# Source KVM helper library
# shellcheck disable=SC1090,SC1091
. "$TOOLS/lib_kvm.sh"

test_path=$(find_test_case_by_name "$TESTNAME")
if [ -z "$test_path" ] || [ ! -d "$test_path" ]; then
    log_skip "$TESTNAME SKIP - test path not found"
    echo "$TESTNAME SKIP" >"$RES_FALLBACK" 2>/dev/null || true
    exit 0
fi

if ! cd "$test_path"; then
    log_skip "$TESTNAME SKIP - cannot cd into $test_path"
    echo "$TESTNAME SKIP" >"$RES_FALLBACK" 2>/dev/null || true
    exit 0
fi

# shellcheck disable=SC2034
res_file="./$TESTNAME.res"
RESULT_DIR="./results/$TESTNAME"
DMESG_DIR="$RESULT_DIR/dmesg"

mkdir -p "$DMESG_DIR" 2>/dev/null || true

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

if command -v detect_platform >/dev/null 2>&1; then
    detect_platform >/dev/null 2>&1 || true
    log_info "Platform Details: machine='${PLATFORM_MACHINE:-unknown}' target='${PLATFORM_TARGET:-unknown}' kernel='${PLATFORM_KERNEL:-}' arch='${PLATFORM_ARCH:-}'"
else
    log_info "Platform Details: kernel='$(uname -r 2>/dev/null || echo unknown)' arch='$(uname -m 2>/dev/null || echo unknown)'"
fi

deps_list="cat grep awk sed find tr mkdir uname"
log_info "Checking dependencies: $deps_list"
if ! check_dependencies "$deps_list"; then
    log_skip "$TESTNAME SKIP - missing one or more dependencies: $deps_list"
    echo "$TESTNAME SKIP" >"$res_file"
    exit 0
fi

log_info "=== KVM Availability Gate ==="

if ! check_kernel_config "CONFIG_KVM"; then
    log_skip "$TESTNAME SKIP - CONFIG_KVM is not enabled"
    echo "$TESTNAME SKIP" >"$res_file"
    exit 0
fi

kvm_check_device_node
dev_rc=$?

if [ "$dev_rc" -eq 2 ]; then
    log_skip "$TESTNAME SKIP - /dev/kvm is not available"
    echo "$TESTNAME SKIP" >"$res_file"
    exit 0
fi

if [ "$dev_rc" -ne 0 ]; then
    log_fail "$TESTNAME FAIL - /dev/kvm exists but is not usable"
    echo "$TESTNAME FAIL" >"$res_file"
    exit 0
fi

log_info "=== Dynamic EL2-DTB Runtime Evidence Validation ==="
log_info "This test performs log-only remoteproc inspection and does not stop/start/reset remoteprocs."

kvm_check_el2_runtime_evidence
el2_rc=$?

if [ "$el2_rc" -eq 2 ]; then
    log_skip "$TESTNAME SKIP - no remoteproc DT/sysfs entries found; EL2-DTB validation is not applicable"
    echo "$TESTNAME SKIP" >"$res_file"
    exit 0
fi

if [ "$el2_rc" -ne 0 ]; then
    log_fail "$TESTNAME FAIL - EL2-DTB remoteproc/IOMMU runtime evidence is missing"
    echo "$TESTNAME FAIL" >"$res_file"
    exit 0
fi

log_info "=== EL2/KVM Dmesg Validation ==="
if ! kvm_check_boot_dmesg_errors "$DMESG_DIR"; then
    log_fail "$TESTNAME FAIL - fatal KVM/EL2 dmesg errors detected"
    echo "$TESTNAME FAIL" >"$res_file"
    exit 0
fi

log_pass "$TESTNAME PASS - dynamic EL2-DTB evidence is valid"
echo "$TESTNAME PASS" >"$res_file"

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
