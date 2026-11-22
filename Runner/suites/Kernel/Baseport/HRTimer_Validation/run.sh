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

TESTNAME="HRTimer_Validation"
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

if kernel_config_is_enabled CONFIG_HIGH_RES_TIMERS; then
    test_result_record "PASS" "CONFIG_HIGH_RES_TIMERS is enabled"
else
    test_result_record "SKIP" "CONFIG_HIGH_RES_TIMERS not visible or disabled"
fi

if [ ! -r /proc/timer_list ]; then
    test_result_record "SKIP" "/proc/timer_list is not readable"
    test_result_finish "SKIP"
fi

if grep -Eq 'hrtimer|HresTimer|hres_active' /proc/timer_list; then
    test_result_record "PASS" "/proc/timer_list reports hrtimer state"
else
    test_result_record "FAIL" "/proc/timer_list has no hrtimer markers"
fi

base_count="$(grep -cE '^[Tt]imerbase|^cpu: [0-9]+|clock [0-9]+:' /proc/timer_list 2>/dev/null || true)"
if [ -z "$base_count" ]; then
    base_count=0
fi
if [ "$base_count" -gt 0 ]; then
    test_result_record "PASS" "timer bases found in /proc/timer_list (count=$base_count)"
else
    test_result_record "FAIL" "no timer bases found in /proc/timer_list"
fi

online_count="$(get_online_cpus | kernel_count_lines)"
log_info "online CPUs=$online_count timer_list bases/clock lines=$base_count"

if grep -Eq 'resolution:|expires at|active timers:' /proc/timer_list; then
    test_result_record "PASS" "hrtimer resolution/expiry fields are present"
else
    test_result_record "SKIP" "timer_list does not export resolution/expiry fields on this kernel"
fi

test_result_finish
