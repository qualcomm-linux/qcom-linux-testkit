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

hres_state="$(kernel_config_state CONFIG_HIGH_RES_TIMERS)" || hres_state=""
case "$hres_state" in
    y|m)
        test_result_record "PASS" "CONFIG_HIGH_RES_TIMERS is enabled"
        ;;
    n)
        test_result_record "SKIP" "CONFIG_HIGH_RES_TIMERS is disabled; low-resolution bases still apply"
        ;;
    *)
        test_result_record "SKIP" "CONFIG_HIGH_RES_TIMERS state is unavailable"
        ;;
esac

if [ ! -r /proc/timer_list ]; then
    test_result_record "SKIP" "/proc/timer_list is not readable"
    test_result_finish "SKIP"
fi

if [ "$hres_state" = "y" ] || [ "$hres_state" = "m" ]; then
    if grep -Eq 'hres_active|HresTimer' /proc/timer_list; then
        test_result_record "PASS" "/proc/timer_list reports high-resolution timer state"
    else
        test_result_record "FAIL" "CONFIG_HIGH_RES_TIMERS is enabled but /proc/timer_list has no hres marker"
    fi
else
    test_result_record "SKIP" "high-resolution marker is not required when CONFIG_HIGH_RES_TIMERS is not enabled"
fi

clock_count="$(grep -cE '^[[:space:]]*clock[[:space:]]+[0-9]+:' /proc/timer_list 2>/dev/null || true)"
if [ "${clock_count:-0}" -gt 0 ]; then
    test_result_record "PASS" "timer_list exports clock bases (count=$clock_count)"
else
    test_result_record "FAIL" "timer_list has no clock-base lines"
fi

hrtimer_online_covered() {
    hrt_online="$(get_online_cpus | sort -n | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
    hrt_missing=""
    for hrt_cpu in $(get_online_cpus); do
        if ! grep -Eq "^cpu: ${hrt_cpu}$" /proc/timer_list; then
            hrt_missing="${hrt_missing}${hrt_cpu} "
        fi
    done
    [ -z "$hrt_missing" ]
}

if hrtimer_online_covered; then
    test_result_record "PASS" "timer_list has a CPU section for online CPUs $hrt_online"
else
    hrt_before="$hrt_online"
    sleep 1
    if hrtimer_online_covered; then
        test_result_record "PASS" "timer_list matched online CPUs after one resnapshot ($hrt_online)"
    elif [ "$hrt_online" != "$hrt_before" ]; then
        test_result_record "SKIP" "online CPU set changed during timer_list capture ($hrt_before -> $hrt_online)"
    else
        test_result_record "FAIL" "timer_list is missing CPU sections for online CPUs: ${hrt_missing:-unknown}"
    fi
fi

if grep -Eq 'resolution:|expires at|active timers:' /proc/timer_list; then
    test_result_record "PASS" "hrtimer resolution/expiry fields are present"
else
    test_result_record "SKIP" "timer_list does not export resolution/expiry fields on this kernel"
fi

test_result_finish
