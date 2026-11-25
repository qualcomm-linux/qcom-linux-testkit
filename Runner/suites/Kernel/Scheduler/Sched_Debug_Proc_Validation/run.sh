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
elif ! kernel_record_attribute "sched debug" "$sched_debug"; then
    :
else
    sched_cpus_ok() {
        sched_online="$(get_online_cpus | sort -n | awk 'NF { printf "%s%s", sep, $0; sep="," }')"
        sched_missing=""
        for sched_cpu in $(get_online_cpus); do
            if ! grep -Eq "^cpu#${sched_cpu}(,|[[:space:]]|$)" "$sched_debug"; then
                sched_missing="${sched_missing}${sched_cpu} "
            fi
        done
        if grep -Eq 'Sched Debug|^version' "$sched_debug" &&
            [ -z "$sched_missing" ] &&
            awk '
                /\.nr_running/ {
                    seen = 1
                    if ($NF !~ /^-?[0-9]+$/) bad = 1
                }
                END { exit !(seen && !bad) }
            ' "$sched_debug"; then
            return 0
        fi
        return 1
    }
    if sched_cpus_ok; then
        test_result_record "PASS" "$sched_debug has a header and runqueue fields for online CPUs $sched_online"
    else
        sched_before="$sched_online"
        sleep 1
        if sched_cpus_ok; then
            test_result_record "PASS" "$sched_debug matched online CPUs after one resnapshot ($sched_online)"
        elif [ "$sched_online" != "$sched_before" ]; then
            test_result_record "SKIP" "online CPU set changed while reading $sched_debug"
        else
            test_result_record "FAIL" "$sched_debug is missing a CPU/runqueue section for online CPUs ${sched_missing:-$sched_online}"
        fi
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

if [ -r /proc/sys/kernel/sched_rt_runtime_us ] && [ -r /proc/sys/kernel/sched_rt_period_us ]; then
    rt_runtime="$(kernel_attribute_value /proc/sys/kernel/sched_rt_runtime_us)" || rt_runtime=""
    rt_period="$(kernel_attribute_value /proc/sys/kernel/sched_rt_period_us)" || rt_period=""
    if ! is_signed_number "$rt_runtime" || ! is_unsigned_number "$rt_period"; then
        rt_runtime="$(kernel_attribute_value /proc/sys/kernel/sched_rt_runtime_us)" || rt_runtime=""
        rt_period="$(kernel_attribute_value /proc/sys/kernel/sched_rt_period_us)" || rt_period=""
    fi
    if ! is_signed_number "$rt_runtime" || ! is_unsigned_number "$rt_period" || [ "$rt_period" -eq 0 ]; then
        test_result_record "FAIL" "sched RT runtime='$rt_runtime' period='$rt_period' is not a valid pair"
    elif [ "$rt_runtime" = "-1" ] || { [ "$rt_runtime" -ge 0 ] && [ "$rt_runtime" -le "$rt_period" ]; }; then
        test_result_record "PASS" "sched RT runtime=$rt_runtime period=$rt_period"
    else
        test_result_record "FAIL" "sched RT runtime=$rt_runtime is outside -1 or 0..$rt_period"
    fi
fi

test_result_finish
