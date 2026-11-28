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

TESTNAME="Kernel_Taint_Oops_Validation"
RES_FILE="$SCRIPT_DIR/$TESTNAME.res"
# shellcheck disable=SC2034
CHECK_DEPS_RECOVER=0

test_result_init "$TESTNAME" "$RES_FILE" || exit 1

# usage
# Print the supported options without changing hardware.
usage() {
    printf '%s\n' "Usage: $0 [--help]"
}

# parse_args <arguments...>
# Reject unsupported arguments before test setup.
parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            *)
                test_result_finish FAIL "Unsupported option: $1"
                ;;
        esac
    done
}
parse_args "$@"

log_info "-----------------------------------------------------------------------------------------"
log_info "-------------------Starting $TESTNAME Testcase----------------------------"
log_info "=== Test Initialization ==="

deps_list="cat grep sed awk tr mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "Oops|BUG|Internal error"
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ -r /proc/sys/kernel/tainted ]; then
    tainted="$(kernel_attribute_value /proc/sys/kernel/tainted)"
    kernel_record_attribute "tainted" "/proc/sys/kernel/tainted" 1
    log_info "kernel taint value=$tainted"
    if [ "$tainted" != "0" ]; then
        test_result_record "PASS" "kernel is tainted ($tainted); reported, not failed"
    else
        test_result_record "PASS" "kernel taint is 0"
    fi
else
    test_result_record "FAIL" "/proc/sys/kernel/tainted is not readable"
fi

if [ "${DMESG_ACCESS_STATUS:-unavailable}" != available ] || [ ! -r "${KERNEL_DMESG_SNAPSHOT:-}" ]; then
    test_result_record "SKIP" "kernel log unavailable; Oops check unverified"
else
    k_faults="$(kernel_log_filter_faults "$KERNEL_DMESG_SNAPSHOT" 'Oops:|Internal error:|kernel BUG at|Unable to handle|BUG:')" || k_faults=""
    if [ -n "$k_faults" ]; then
        test_result_record "FAIL" "kernel log contains Oops/BUG/abort diagnostic"
    else
        test_result_record "PASS" "no Oops/BUG splat in kernel log"
    fi
fi

test_result_finish
