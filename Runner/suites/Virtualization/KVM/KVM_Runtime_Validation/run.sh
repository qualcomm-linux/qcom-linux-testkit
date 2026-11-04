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

TESTNAME="KVM_Runtime_Validation"
RES_FILE="$PWD/$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1
# shellcheck disable=SC2034 # Consumed by check_dependencies.
CHECK_DEPS_RECOVER=0
if ! check_dependencies cat grep awk sed tr mkdir uname readlink; then
    test_result_finish SKIP "Image lacks KVM runtime inventory tools"
fi
RESULT_DIR=$(test_create_run_directory "$PWD/results/$TESTNAME") || test_result_finish FAIL "Cannot create KVM evidence directory"
if ! kvm_log_readiness "$RESULT_DIR"; then
    test_result_finish FAIL "KVM/EL2 initialization errors were captured"
fi
if ! check_kernel_config "CONFIG_VIRTUALIZATION CONFIG_KVM"; then
    test_result_finish FAIL "Required KVM configuration is missing or unreadable"
fi
if ! kvm_check_device_node; then
    test_result_finish FAIL "Required /dev/kvm is missing or unusable"
fi
test_result_finish PASS "KVM configuration and runtime device are ready, ioctl and VM execution are separate tests"
