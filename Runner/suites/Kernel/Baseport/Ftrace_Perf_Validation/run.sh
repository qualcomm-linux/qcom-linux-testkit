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

TESTNAME="Ftrace_Perf_Validation"
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

trdir=""
if [ -e /sys/kernel/tracing/tracing_on ]; then
    trdir="/sys/kernel/tracing"
elif [ -e /sys/kernel/debug/tracing/tracing_on ]; then
    trdir="/sys/kernel/debug/tracing"
fi

if [ -n "$trdir" ]; then
    tracing_on="$(kernel_attribute_value "$trdir/tracing_on")" || tracing_on=""
    case "$tracing_on" in
        0|1)
            test_result_record "PASS" "tracing_on=$tracing_on"
            ;;
        *)
            test_result_record "FAIL" "tracing_on is not 0 or 1 ('${tracing_on:-unreadable}')"
            ;;
    esac
    if [ -r "$trdir/available_tracers" ]; then
        kernel_record_attribute "available_tracers" "$trdir/available_tracers"
    fi
    if [ -r "$trdir/available_events" ]; then
        ev_count="$(kernel_count_lines < "$trdir/available_events")"
        if [ "$ev_count" -gt 0 ]; then
            test_result_record "PASS" "available_events lists $ev_count events"
        else
            test_result_record "FAIL" "available_events is empty"
        fi
    else
        test_result_record "SKIP" "available_events not exported"
    fi
else
    test_result_record "SKIP" "ftrace tracing directory is not present"
fi

if [ -r /proc/sys/kernel/perf_event_paranoid ]; then
    kernel_record_attribute "perf_event_paranoid" "/proc/sys/kernel/perf_event_paranoid" signed
else
    test_result_record "SKIP" "perf_event_paranoid sysctl not present"
fi

if [ -e /proc/sys/kernel/perf_event_max_sample_rate ]; then
    kernel_record_attribute "perf_event_max_sample_rate" "/proc/sys/kernel/perf_event_max_sample_rate" 1
fi

test_result_finish
