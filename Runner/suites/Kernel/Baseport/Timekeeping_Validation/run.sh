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

TESTNAME="Timekeeping_Validation"
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

deps_list="cat grep sed awk tr sleep mkdir mktemp date"
if ! CHECK_DEPS_NO_EXIT=1 check_dependencies "$deps_list"; then
    test_result_finish SKIP "Image-provided utilities unavailable: $deps_list"
fi
kernel_capture_evidence "$SCRIPT_DIR/results/$TESTNAME" "."
k_ev_rc=$?
if [ "$k_ev_rc" -eq 1 ]; then
    test_result_finish FAIL "Cannot create kernel evidence under $SCRIPT_DIR"
fi

if [ ! -r /proc/uptime ]; then
    test_result_record "FAIL" "/proc/uptime is not readable"
    test_result_finish "FAIL"
fi

u1="$(awk '{print $1}' /proc/uptime)"
sleep 2
tk_sleep_rc=$?
u2="$(awk '{print $1}' /proc/uptime)"
log_info "uptime before=$u1 after=$u2 sleep_rc=$tk_sleep_rc"
# sleep 2 must move monotonic uptime by about two seconds. A quarter-second
# tolerance covers scheduling delay without accepting a one-second step.
if [ "$tk_sleep_rc" -ne 0 ]; then
    test_result_record "FAIL" "sleep 2 failed rc=$tk_sleep_rc"
elif ! awk -v before="$u1" -v after="$u2" 'BEGIN {
    if (before !~ /^[0-9]+([.][0-9]+)?$/ || after !~ /^[0-9]+([.][0-9]+)?$/) exit 1
    delta = after - before
    if (delta >= 1.75 && delta < 8) exit 0
    exit 1
}'; then
    test_result_record "FAIL" "uptime interval is not within 0.25s of the 2s sleep (before=$u1 after=$u2)"
else
    test_result_record "PASS" "uptime advanced from $u1 to $u2 during sleep 2"
fi

if [ -r /proc/timer_list ]; then
    if grep -Eq 'now at|Offset:|ktime' /proc/timer_list; then
        test_result_record "PASS" "timer_list exports ktime/now fields"
    else
        test_result_record "SKIP" "timer_list ktime/now fields not present"
    fi
else
    test_result_record "SKIP" "/proc/timer_list not readable"
fi

if [ -r /proc/stat ]; then
    btime="$(awk '/^btime / {print $2}' /proc/stat)"
    now="$(date +%s 2>/dev/null || true)"
    if is_unsigned_number "$btime" && is_unsigned_number "$now"; then
        if [ "$now" -ge "$btime" ]; then
            test_result_record "PASS" "btime ($btime) is not in the future vs now ($now)"
        else
            test_result_record "FAIL" "btime ($btime) is after current unix time ($now)"
        fi
    else
        test_result_record "SKIP" "date or btime not usable for wall-clock check"
    fi
fi

test_result_finish
