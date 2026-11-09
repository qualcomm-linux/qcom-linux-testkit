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

TESTNAME="KVM_EL2_DTB"
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

deps_list="cat grep awk sed find tr mkdir uname readlink sort cp mktemp date"
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

log_info "=== KVM Availability Gate ==="

if ! check_kernel_config "CONFIG_KVM"; then
    log_fail "$TESTNAME FAIL - mandatory KVM kernel config CONFIG_KVM is not enabled"
    test_result_finish FAIL
fi

kvm_check_device_node
dev_rc=$?

if [ "$dev_rc" -eq 2 ]; then
    log_fail "$TESTNAME FAIL - /dev/kvm is not available"
    test_result_finish FAIL
fi

if [ "$dev_rc" -ne 0 ]; then
    log_fail "$TESTNAME FAIL - /dev/kvm exists but is not usable"
    test_result_finish FAIL
fi

log_info "=== Runtime Remoteproc DMA Attachment Validation ==="
log_info "This test performs log-only remoteproc inspection and does not stop/start/reset remoteprocs."

kvm_check_el2_runtime_evidence
el2_rc=$?

if [ "$el2_rc" -eq 2 ]; then
    log_skip "$TESTNAME SKIP - no remoteproc DT/sysfs entries found; EL2-DTB validation is not applicable"
    test_result_finish SKIP
fi

if [ "$el2_rc" -ne 0 ]; then
    log_fail "$TESTNAME FAIL - Verified remoteproc DMA attachment is missing"
    test_result_finish FAIL
fi


log_pass "$TESTNAME PASS - KVM readiness and remoteproc DMA attachment are valid"
test_result_finish PASS

log_info "-------------------Completed $TESTNAME Testcase----------------------------"
exit 0
