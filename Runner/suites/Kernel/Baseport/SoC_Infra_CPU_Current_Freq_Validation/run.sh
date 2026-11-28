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

TESTNAME="SoC_Infra_CPU_Current_Freq_Validation"
RES_FILE="./$TESTNAME.res"
test_result_init "$TESTNAME" "$RES_FILE" || exit 1

CPU_ROOT="/sys/devices/system/cpu"
REPORT_FILE="./cpu_current_freqs.log"
# Frequencies are in kHz. Twelve digits is far above any real value and keeps the
# numeric comparisons below inside the shell's integer range.
MAX_DIGITS=12

# cpucur_check_cpu <cpu-index> <cpufreq-dir>
# Checks the scaling_cur_freq value that one online CPU reports through its
# cpufreq link and prints one report line: "cpu<N> <policy> <khz>" for a valid
# value, or "cpu<N> <policy> READ_ERROR|INVALID_VALUE(<value>)|OUT_OF_RANGE(<value> not in <min>..<max>)".
# The value must be one positive integer exactly as read; only the trailing
# newline is dropped. The policy name comes from the link target and is "unknown"
# when it cannot be resolved. Runs in a subshell, so it changes no shell state.
# Returns: 0 the value is valid, 1 the value is invalid, 2 the CPU does not
# expose scaling_cur_freq.
cpucur_check_cpu() (
    ccc_cpu="$1"
    ccc_dir="$2"
    ccc_file="$ccc_dir/scaling_cur_freq"

    [ -e "$ccc_file" ] || exit 2

    ccc_link=$(readlink "$ccc_dir" 2>/dev/null) || ccc_link=""
    ccc_policy="${ccc_link##*/}"
    [ -n "$ccc_policy" ] || ccc_policy="unknown"
    ccc_prefix="cpu$ccc_cpu $ccc_policy"

    if ! ccc_cur=$(cat "$ccc_file" 2>/dev/null); then
        printf '%s READ_ERROR\n' "$ccc_prefix"
        exit 1
    fi

    if ! is_unsigned_number "$ccc_cur" ||
       [ "${#ccc_cur}" -gt "$MAX_DIGITS" ] ||
       [ "$ccc_cur" -le 0 ]; then
        ccc_shown=$(printf '%s' "$ccc_cur" | tr -c '[:print:]' '?')
        printf '%s INVALID_VALUE(%s)\n' "$ccc_prefix" "$ccc_shown"
        exit 1
    fi

    # The hardware limits are optional context: without usable limits, only the
    # format of the value is checked.
    if ccc_min=$(cat "$ccc_dir/cpuinfo_min_freq" 2>/dev/null) &&
       ccc_max=$(cat "$ccc_dir/cpuinfo_max_freq" 2>/dev/null) &&
       is_unsigned_number "$ccc_min" && is_unsigned_number "$ccc_max" &&
       [ "${#ccc_min}" -le "$MAX_DIGITS" ] && [ "${#ccc_max}" -le "$MAX_DIGITS" ]; then
        if [ "$ccc_cur" -lt "$ccc_min" ] || [ "$ccc_cur" -gt "$ccc_max" ]; then
            printf '%s OUT_OF_RANGE(%s not in %s..%s)\n' "$ccc_prefix" "$ccc_cur" "$ccc_min" "$ccc_max"
            exit 1
        fi
    fi

    printf '%s %s\n' "$ccc_prefix" "$ccc_cur"
    exit 0
)

log_info "--------------------------------------------------------------------------"
log_info "Starting $TESTNAME"

# Never install packages on the target; skip when a base utility is missing.
if ! CHECK_DEPS_RECOVER=0 CHECK_DEPS_NO_EXIT=1 check_dependencies cat tr grep readlink; then
    test_result_finish "SKIP" "$TESTNAME SKIP: required base utilities are unavailable"
fi

# cpufreq is optional: it needs a driver bound to the CPUs. Only online CPUs are
# checked: an offline CPU has no usable cpufreq state, and the cpufreq link of an
# online CPU always resolves to an active policy. A CPU without a cpufreq link is
# logged, not failed, because cpufreq coverage is a platform choice.
online_total=0
no_cpufreq=0
checked=0
invalid=0
absent=0
online_cpus=$(get_online_cpus)

if ! printf '' >"$REPORT_FILE"; then
    test_result_finish "FAIL" "$TESTNAME FAIL: cannot create the report file $REPORT_FILE in $(pwd)"
fi

for cpu in $online_cpus; do
    is_unsigned_number "$cpu" || continue
    online_total=$((online_total + 1))

    cpufreq_dir="$CPU_ROOT/cpu$cpu/cpufreq"
    if [ ! -e "$cpufreq_dir" ]; then
        no_cpufreq=$((no_cpufreq + 1))
        log_info "cpu$cpu: no cpufreq directory, not checked"
        continue
    fi

    report_line=$(cpucur_check_cpu "$cpu" "$cpufreq_dir")
    cpu_rc=$?
    case "$cpu_rc" in
        0)
            checked=$((checked + 1))
            printf '%s\n' "$report_line" >>"$REPORT_FILE"
            ;;
        1)
            checked=$((checked + 1))
            invalid=$((invalid + 1))
            printf '%s\n' "$report_line" >>"$REPORT_FILE"
            ;;
        *)
            absent=$((absent + 1))
            log_info "cpu$cpu: scaling_cur_freq is not exposed, not checked"
            ;;
    esac
done

log_info "online CPUs: total=$online_total checked=$checked invalid=$invalid no_cpufreq=$no_cpufreq not_exposed=$absent (details: $REPORT_FILE)"
# Replay the report so the job log shows every CPU, its policy and its current
# frequency in kHz. The report file is kept as a result artifact.
log_file_with_label "CPU-CURRENT-FREQ-KHZ" "$REPORT_FILE"

if [ "$checked" -eq 0 ]; then
    test_result_finish "SKIP" "$TESTNAME SKIP: no online CPU exposes scaling_cur_freq, cpufreq is not enabled or no driver is bound (online=$online_total no_cpufreq=$no_cpufreq not_exposed=$absent)"
fi

if [ "$invalid" -gt 0 ]; then
    grep -E 'READ_ERROR|INVALID_VALUE|OUT_OF_RANGE' "$REPORT_FILE" | while IFS= read -r bad_line; do
        log_fail "Invalid current frequency: $bad_line"
    done
    test_result_record "FAIL" "$invalid of $checked online CPUs report an invalid current frequency"
else
    test_result_record "PASS" "All $checked online CPUs report a valid current frequency"
fi

test_result_finish
