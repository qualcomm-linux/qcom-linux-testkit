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

TESTNAME="CPU_Freq_Sysfs_Validation"
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

policy_root="/sys/devices/system/cpu/cpufreq"
if [ ! -d "$policy_root" ]; then
    test_result_record "SKIP" "cpufreq sysfs is not present"
    test_result_finish "SKIP"
fi

policies=0
for policy in "$policy_root"/policy*; do
    [ -d "$policy" ] || continue
    policies=$((policies + 1))
    pname="$(basename "$policy")"
    kernel_record_attribute "$pname cur_freq" "$policy/scaling_cur_freq" 1
    kernel_record_attribute "$pname min_freq" "$policy/cpuinfo_min_freq" 1
    kernel_record_attribute "$pname max_freq" "$policy/cpuinfo_max_freq" 1
    gov="$(kernel_attribute_value "$policy/scaling_governor")" || gov=""
    avail="$(kernel_attribute_value "$policy/scaling_available_governors")" || avail=""
    case " $avail " in
        *" $gov "*)
            if [ -n "$gov" ]; then
                test_result_record "PASS" "$pname governor $gov is available"
            else
                test_result_record "FAIL" "$pname governor is empty"
            fi
            ;;
        *)
            test_result_record "FAIL" "$pname governor '${gov:-unreadable}' is not in available governors '${avail:-unreadable}'"
            ;;
    esac
    related="$(kernel_attribute_value "$policy/related_cpus")" || related=""
    related_list="$(printf '%s\n' "$related" | tr -s ' ' | sed 's/^ //; s/ $//' | tr ' ' ',')"
    possible="$(read_first_line /sys/devices/system/cpu/possible)" || possible=""
    if ! kernel_cpu_list_valid "$related_list"; then
        test_result_record "FAIL" "$pname related_cpus is not a CPU list ('${related:-unreadable}')"
    else
        related_bad=""
        for rel_cpu in $(expand_cpu_list "$related_list"); do
            if ! cpu_in_list "$rel_cpu" "$possible"; then
                related_bad="${related_bad}${rel_cpu} "
            fi
        done
        if [ -n "$related_bad" ]; then
            test_result_record "FAIL" "$pname related_cpus ($related) is outside possible CPUs $possible"
        else
            test_result_record "PASS" "$pname related_cpus ($related) is inside possible CPUs"
        fi
    fi
    cur="$(kernel_attribute_value "$policy/scaling_cur_freq")" || cur=""
    minf="$(kernel_attribute_value "$policy/cpuinfo_min_freq")" || minf=""
    maxf="$(kernel_attribute_value "$policy/cpuinfo_max_freq")" || maxf=""
    if is_unsigned_number "$cur" && is_unsigned_number "$minf" && is_unsigned_number "$maxf"; then
        if [ "$cur" -ge "$minf" ] && [ "$cur" -le "$maxf" ]; then
            test_result_record "PASS" "$pname cur_freq $cur is within [$minf,$maxf]"
        else
            test_result_record "FAIL" "$pname cur_freq $cur outside [$minf,$maxf]"
        fi
    fi
    if [ -r "$policy/stats/time_in_state" ]; then
        test_result_record "PASS" "$pname stats/time_in_state is readable"
    else
        test_result_record "SKIP" "$pname stats/time_in_state not exported"
    fi
    if [ -r "$policy/scaling_boost_freqs" ] || [ -r "$policy/cpuinfo_boost_freq" ]; then
        test_result_record "PASS" "$pname boost frequency ABI is present"
    fi
done

if [ "$policies" -eq 0 ]; then
    test_result_record "SKIP" "cpufreq core is present but no policy is registered"
    test_result_finish "SKIP"
fi

test_result_finish
