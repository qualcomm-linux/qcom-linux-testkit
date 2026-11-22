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

TESTNAME="Sched_Debug_Proc_Validation"
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

sched_debug=""
if [ -e /sys/kernel/debug/sched/debug ]; then
    sched_debug="/sys/kernel/debug/sched/debug"
elif [ -e /proc/sched_debug ]; then
    sched_debug="/proc/sched_debug"
fi

if [ -z "$sched_debug" ]; then
    test_result_record "SKIP" "sched debug is not exported under debugfs or /proc"
elif kernel_record_attribute "sched debug" "$sched_debug"; then
    if grep -Eq 'cpu#|rq->nr_running|Sched Debug' "$sched_debug"; then
        test_result_record "PASS" "$sched_debug has runqueue content"
    else
        test_result_record "FAIL" "$sched_debug is readable but missing expected fields"
    fi
fi

if [ -r /proc/sys/kernel/sched_child_runs_first ]; then
    kernel_record_attribute "sched_child_runs_first" "/proc/sys/kernel/sched_child_runs_first" 1
fi

if [ -r /sys/kernel/debug/sched/features ]; then
    kernel_record_attribute "sched features" "/sys/kernel/debug/sched/features"
elif [ -r /sys/kernel/debug/sched_features ]; then
    kernel_record_attribute "sched_features" "/sys/kernel/debug/sched_features"
else
    test_result_record "SKIP" "sched features debugfs is not present"
fi

if [ -r /proc/sys/kernel/sched_rt_runtime_us ]; then
    kernel_record_attribute "sched_rt_runtime_us" "/proc/sys/kernel/sched_rt_runtime_us"
fi
if [ -r /proc/sys/kernel/sched_rt_period_us ]; then
    kernel_record_attribute "sched_rt_period_us" "/proc/sys/kernel/sched_rt_period_us" 1
fi

test_result_finish
