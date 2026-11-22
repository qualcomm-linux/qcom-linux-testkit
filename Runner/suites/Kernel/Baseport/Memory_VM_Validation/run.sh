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

TESTNAME="Memory_VM_Validation"
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
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ ! -r /proc/meminfo ]; then
    test_result_record "FAIL" "/proc/meminfo is not readable"
    test_result_finish "FAIL"
fi

memtotal="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
memfree="$(awk '/^MemFree:/ {print $2}' /proc/meminfo)"
if is_unsigned_number "$memtotal" && is_unsigned_number "$memfree"; then
    if [ "$memtotal" -gt 0 ] && [ "$memfree" -le "$memtotal" ]; then
        test_result_record "PASS" "MemTotal=$memtotal kB MemFree=$memfree kB"
    else
        test_result_record "FAIL" "MemFree ($memfree) > MemTotal ($memtotal) or MemTotal is 0"
    fi
else
    test_result_record "FAIL" "could not parse MemTotal/MemFree"
fi

if [ -r /proc/buddyinfo ]; then
    test_result_record "PASS" "/proc/buddyinfo is readable"
else
    test_result_record "FAIL" "/proc/buddyinfo is not readable"
fi

if [ -r /proc/pagetypeinfo ]; then
    test_result_record "PASS" "/proc/pagetypeinfo is readable"
else
    test_result_record "SKIP" "/proc/pagetypeinfo not present"
fi

if [ -r /proc/sys/vm/overcommit_memory ]; then
    kernel_record_attribute "overcommit_memory" "/proc/sys/vm/overcommit_memory" 1
fi
if [ -r /proc/sys/vm/swappiness ]; then
    kernel_record_attribute "swappiness" "/proc/sys/vm/swappiness" 1
fi

if [ -d /sys/kernel/mm/transparent_hugepage ]; then
    kernel_record_attribute "THP enabled" "/sys/kernel/mm/transparent_hugepage/enabled"
else
    test_result_record "SKIP" "THP sysfs is not present"
fi

if [ -d /sys/kernel/mm/hugepages ]; then
    test_result_record "PASS" "hugepages sysfs directory exists"
else
    test_result_record "SKIP" "hugepages sysfs is not present"
fi

test_result_finish
